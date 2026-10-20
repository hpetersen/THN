import Foundation
import Security

/// The signed-in Hacker News account. The `user` cookie lives in the Keychain.
@MainActor @Observable
final class HNSession {
    static let shared = HNSession()

    private(set) var username: String?
    private(set) var karma: Int?
    /// Set when an action needs an account; the root view presents the sign-in sheet.
    var showSignIn = false
    /// Stories hidden this session, so the front page drops them without a reload.
    var hiddenStories: Set<Int> = []
    /// Users whose stories and comments are hidden on this device.
    private(set) var blockedUsers = Set(UserDefaults.standard.stringArray(forKey: "blockedUsers") ?? [])

    var isSignedIn: Bool { username != nil }

    private init() {
        if let cookie = Keychain.read() { adopt(cookie) }
    }

    func signIn(username: String, password: String, create: Bool) async throws {
        adopt(try await HNWeb.signIn(username: username, password: password, create: create))
        Extras.note(create ? "account_created" : "signed_in")
    }

    /// Takes over a `user` cookie, from the sign-in form or the web sign-in fallback.
    func adopt(_ cookie: String) {
        HNWeb.userCookie = cookie
        Keychain.write(cookie)
        username = cookie.split(separator: "&").first.map(String.init)
        karma = nil
        Task { await refresh() }
    }

    func refresh() async {
        guard let username else { return }
        karma = (try? await HNClient.user(username))?.karma
    }

    func signOut() async {
        await HNWeb.signOut()
        forget()
        Extras.note("signed_out")
    }

    /// Drops the account locally, e.g. when HN no longer accepts the cookie.
    func forget() {
        HNWeb.userCookie = nil
        Keychain.delete()
        username = nil
        karma = nil
    }

    func isBlocked(_ user: String?) -> Bool { user.map(blockedUsers.contains) ?? false }

    func setBlocked(_ user: String, _ blocked: Bool) {
        if blocked { blockedUsers.insert(user) } else { blockedUsers.remove(user) }
        UserDefaults.standard.set(Array(blockedUsers), forKey: "blockedUsers")
        Extras.note(blocked ? "user_blocked" : "user_unblocked")
    }

    /// Runs `action` when signed in; otherwise asks for sign-in first.
    func require(_ action: () -> Void) {
        if isSignedIn { action() } else { showSignIn = true }
    }

    /// Turns an expired session into a sign-in prompt; returns other errors' messages.
    func handle(_ error: Error) -> String? {
        if case HNError.signedOut = error {
            forget()
            showSignIn = true
            return nil
        }
        return error.localizedDescription
    }
}

private enum Keychain {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "news.ycombinator.com",
        kSecAttrAccount as String: "user-cookie",
    ]

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
