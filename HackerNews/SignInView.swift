import SwiftUI
import WebKit

/// Where the person icon leads: sign-in when signed out, your own profile once signed in.
struct AccountView: View {
    @Environment(HNSession.self) private var session

    var body: some View {
        if let name = session.username {
            ProfileView(username: name)
        } else {
            VStack(spacing: 0) {
                PaperTopBar()
                ScrollView {
                    VStack(spacing: 32) {
                        SignInForm()
                        ExtrasAccountSection()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Theme.paper)
            .foregroundStyle(Theme.ink)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// Presented when a vote, reply or other action needs an account.
struct SignInSheet: View {
    @Environment(HNSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetTopBar(title: "Sign In")
            ScrollView {
                SignInForm()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
    }
}

struct SignInForm: View {
    enum Mode: String, CaseIterable { case signIn = "Sign In", create = "Create Account" }

    @Environment(HNSession.self) private var session
    @State private var mode = Mode.signIn
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showWebSignIn = false
    @State private var forgotLink: BrowserLink?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("FOR READERS")
                    .font(Theme.meta(11, weight: .bold)).tracking(0.8)
                    .foregroundStyle(Theme.accent)
                Text(mode == .signIn ? "Sign in to vote, comment and submit." : "Join the conversation.")
                    .font(Theme.headline(28, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Use your Hacker News account. Your password goes only to news.ycombinator.com; the app keeps just the sign-in cookie, in your Keychain.")
                    .font(Theme.body(14).italic())
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PaperTabs(items: Mode.allCases, selection: $mode, title: \.rawValue)

            PaperField(label: "Username", text: $username, contentType: .username)
            PaperField(label: "Password", text: $password, secure: true,
                       contentType: mode == .signIn ? .password : .newPassword)

            ErrorLine(message: error)

            Button(action: submit) {
                if busy { ProgressView().tint(Theme.paper) } else { Text(mode.rawValue) }
            }
            .buttonStyle(InkButtonStyle())
            .disabled(busy || username.isEmpty || password.isEmpty)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                if mode == .signIn {
                    Button("Forgot your password?") {
                        forgotLink = BrowserLink(url: HNWeb.base.appending(path: "forgot"))
                    }
                }
                Button("Sign in on the website instead") { showWebSignIn = true }
            }
            .font(Theme.body(15))
            .foregroundStyle(Theme.accent)
            .frame(minHeight: 44)
        }
        .onChange(of: mode) { error = nil }
        .fullScreenCover(item: $forgotLink) { link in
            BrowserView(url: link.url, onClose: { forgotLink = nil })
        }
        .fullScreenCover(isPresented: $showWebSignIn) {
            WebSignInView()
        }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await session.signIn(username: username, password: password, create: mode == .create)
            } catch HNError.validationRequired {
                error = HNError.validationRequired.errorDescription
                showWebSignIn = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Fallback sign-in on news.ycombinator.com itself (for captchas); adopts the cookie once it appears.
struct WebSignInView: View {
    @Environment(HNSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model = WebSignInModel()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(Theme.body(17))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                    Spacer()
                    Label("news.ycombinator.com", systemImage: "lock.fill")
                        .font(Theme.meta(14, weight: .semibold))
                        .imageScale(.small)
                    Spacer()
                    Color.clear.frame(width: 60, height: 44)
                }
                .padding(.horizontal, 12)
                Rule(color: Theme.ink)
            }
            .background(Theme.paper)
            WebSignInContainer(model: model)
        }
        .background(Theme.paper)
        .onChange(of: model.cookie) { _, cookie in
            guard let cookie else { return }
            session.adopt(cookie)
            dismiss()
        }
    }
}

@MainActor @Observable
final class WebSignInModel: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var cookie: String?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.load(URLRequest(url: HNWeb.base.appending(path: "login").appending(queryItems: [URLQueryItem(name: "goto", value: "news")])))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            if let user = cookies.first(where: { $0.name == "user" && $0.domain.contains("ycombinator.com") }) {
                cookie = user.value
            }
        }
    }
}

private struct WebSignInContainer: UIViewRepresentable {
    let model: WebSignInModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
