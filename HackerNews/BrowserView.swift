import SwiftUI
import WebKit

/// Observable wrapper around a WKWebView so SwiftUI chrome can show progress and history state.
@MainActor @Observable
final class BrowserModel: NSObject {
    let webView: WKWebView
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var host: String = ""
    var zoom: CGFloat = 1 { didSet { webView.pageZoom = zoom } }

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(url: URL) {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        host = Self.displayHost(url)
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.progress = web.estimatedProgress }
            },
            webView.observe(\.canGoBack) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoBack = web.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoForward = web.canGoForward }
            },
            webView.observe(\.url) { [weak self] web, _ in
                MainActor.assumeIsolated { if let u = web.url { self?.host = Self.displayHost(u) } }
            },
        ]
        webView.load(URLRequest(url: url))
    }

    var currentURL: URL? { webView.url }

    static func displayHost(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// In-app browser with newspaper chrome. `onClose` nil hides the Done button (iPad split view).
struct BrowserView: View {
    let story: Story?
    var onClose: (() -> Void)?
    var onShowComments: (() -> Void)?
    @State private var model: BrowserModel
    @Environment(\.openURL) private var openURL

    init(url: URL, story: Story? = nil, onClose: (() -> Void)? = nil, onShowComments: (() -> Void)? = nil) {
        self.story = story
        self.onClose = onClose
        self.onShowComments = onShowComments
        _model = State(initialValue: BrowserModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            WebViewContainer(webView: model.webView)
                .overlay(alignment: .bottom) { commentsPill }
            bottomBar
        }
        .background(Theme.paper)
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack {
                if let onClose {
                    Button("Done", action: onClose)
                        .font(Theme.body(17).weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 60, minHeight: 44, alignment: .leading)
                } else {
                    Color.clear.frame(width: 60, height: 44)
                }
                Spacer()
                VStack(spacing: 1) {
                    Label(model.host, systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .font(Theme.meta(14, weight: .semibold))
                        .imageScale(.small)
                    Text("Opened from The Hacker News")
                        .font(Theme.body(11).italic())
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Menu {
                    Button("Larger Text", systemImage: "textformat.size.larger") { model.zoom = min(model.zoom + 0.15, 2) }
                    Button("Smaller Text", systemImage: "textformat.size.smaller") { model.zoom = max(model.zoom - 0.15, 0.6) }
                    Button("Actual Size", systemImage: "arrow.counterclockwise") { model.zoom = 1 }
                } label: {
                    Text("a\(Text("A").font(.custom("Baskerville", size: 22)))").font(.custom("Baskerville", size: 16))
                }
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 60, minHeight: 44, alignment: .trailing)
                .accessibilityLabel("Text size")
            }
            .padding(.horizontal, 12)
            GeometryReader { geo in
                Theme.plate.overlay(alignment: .leading) {
                    Theme.accent.frame(width: geo.size.width * model.progress)
                }
            }
            .frame(height: 2)
            .opacity(model.progress < 1 ? 1 : 0)
            .animation(.easeOut, value: model.progress)
            Rule(color: Theme.ink)
        }
        .background(Theme.paper)
    }

    @ViewBuilder private var commentsPill: some View {
        if let story, let onShowComments, story.commentCount > 0 {
            Button(action: onShowComments) {
                Label("Back to \(story.commentCount) comments", systemImage: "text.bubble")
                    .font(Theme.body(14))
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Theme.ink)
                    .foregroundStyle(Theme.paper)
                    .shadow(color: Theme.ink.opacity(0.25), radius: 7, y: 4)
            }
            .padding(.bottom, 14)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rule(color: Theme.ink)
            HStack {
                barButton("chevron.backward", "Back", enabled: model.canGoBack) { model.webView.goBack() }
                Spacer()
                barButton("chevron.forward", "Forward", enabled: model.canGoForward) { model.webView.goForward() }
                Spacer()
                if let url = model.currentURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Share")
                } else {
                    barButton("square.and.arrow.up", "Share", enabled: false) {}
                }
                Spacer()
                barButton("arrow.clockwise", "Reload", enabled: true) { model.webView.reload() }
                Spacer()
                barButton("safari", "Open in Safari", enabled: model.currentURL != nil) {
                    if let url = model.currentURL { openURL(url) }
                }
            }
            .font(.system(size: 19, weight: .light))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
        .background(Theme.paper)
    }

    private func barButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Lets any view open a link in the in-app browser.
struct BrowserLink: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}
