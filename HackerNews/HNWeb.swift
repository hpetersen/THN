import Foundation

enum HNError: LocalizedError {
    case message(String)
    /// The request needs an account, or the session cookie is no longer accepted.
    case signedOut
    /// HN asked for a captcha; only the website can finish this sign-in.
    case validationRequired

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .signedOut: "Please sign in to continue."
        case .validationRequired: "Hacker News wants to verify you're human. Sign in on the web instead."
        }
    }
}

/// Signed-in access to news.ycombinator.com. HN has no write API, so this uses the same links and
/// forms as the website: vote, favorite and hide links carry a per-item `auth` token, forms an `hmac`.
enum HNWeb {
    static let base = URL(string: "https://news.ycombinator.com/")!

    /// The `user` cookie value ("name&token"), set by `HNSession`.
    static var userCookie: String?

    struct Page {
        let status: Int
        let location: String?
        let html: String
        let cookies: [String: String]

        /// Readable text of an HN message page, e.g. "You're posting too fast."
        var message: String {
            let body = html.range(of: "<body").map { String(html[$0.lowerBound...]) } ?? html
            let text = HTMLText.decode(body.replacing(#/<[^>]+>/#, with: " "))
            return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        var isLoginWall: Bool {
            (location ?? "").hasPrefix("login") || html.contains("name=\"acct\"")
        }
    }

    // MARK: Requests

    /// Fetches a page, following redirects.
    static func get(_ path: String) async throws -> Page {
        try await send(request(path), followRedirects: true)
    }

    /// Follows an action link (vote, fave, hide, …) and fails if HN bounced us to the login page.
    @discardableResult
    static func act(_ href: String) async throws -> Page {
        let page = try await send(request(href), followRedirects: false)
        if page.isLoginWall { throw HNError.signedOut }
        return page
    }

    /// Posts a form. HN answers success with a redirect and errors with a 200 message page.
    @discardableResult
    static func post(_ action: String, fields: [(String, String)]) async throws -> Page {
        var req = request(action)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { "\(encode($0))=\(encode($1))" }.joined(separator: "&").data(using: .utf8)
        let page = try await send(req, followRedirects: false)
        if page.status == 200 {
            if page.html.contains("g-recaptcha") || page.html.contains("Validation required") { throw HNError.validationRequired }
            if page.isLoginWall, action != "login" { throw HNError.signedOut }
        }
        return page
    }

    /// Posts `form`, treating anything but a redirect as an error message from HN.
    static func submit(_ form: HNForm, pressing button: String? = nil) async throws {
        let page = try await post(form.action, fields: form.postFields(pressing: button))
        guard page.status == 302 else { throw HNError.message(page.message.isEmpty ? "Hacker News did not accept that." : page.message) }
    }

    /// The first form on a page whose action matches.
    static func form(at path: String, action: String) async throws -> HNForm {
        let page = try await get(path)
        if page.isLoginWall { throw HNError.signedOut }
        guard let form = HNForm.all(in: page.html).first(where: { $0.action.trimmingPrefix("/") == action }) else {
            throw HNError.message(page.message.isEmpty ? "That can no longer be changed." : page.message)
        }
        return form
    }

    private static func request(_ path: String) -> URLRequest {
        let url = URL(string: HTMLText.decode(path), relativeTo: base)?.absoluteURL ?? base
        var req = URLRequest(url: url)
        if let userCookie { req.setValue("user=\(userCookie)", forHTTPHeaderField: "Cookie") }
        return req
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    private static func send(_ request: URLRequest, followRedirects: Bool) async throws -> Page {
        let (data, response) = try await session.data(for: request, delegate: followRedirects ? nil : NoRedirect())
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields as? [String: String]) ?? [:]
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: base)
        return Page(
            status: http?.statusCode ?? 0,
            location: http?.value(forHTTPHeaderField: "Location"),
            html: String(decoding: data, as: UTF8.self),
            cookies: Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
        )
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Account

    /// Signs in (or creates the account) and returns the `user` cookie.
    static func signIn(username: String, password: String, create: Bool) async throws -> String {
        var fields = [("acct", username), ("pw", password), ("goto", "news")]
        if create { fields.insert(("creating", "t"), at: 0) }
        let page = try await post("login", fields: fields)
        if let cookie = page.cookies["user"], !cookie.isEmpty { return cookie }
        let message = page.message
        throw HNError.message(message.isEmpty || message.count > 200 ? "Bad login." : message)
    }

    /// Ends the session on the server, then forgets the cookie.
    static func signOut() async {
        if let page = try? await get("news"),
           let logout = ItemLinks.anchors(in: page.html).first(where: { $0.href.hasPrefix("logout") }) {
            _ = try? await send(request(logout.href), followRedirects: false)
        }
        userCookie = nil
    }

    // MARK: Lists

    /// Story ids on an HN list page (favorites, upvoted, hidden) and whether a next page exists.
    static func storyIDs(_ path: String) async throws -> (ids: [Int], more: Bool) {
        let page = try await get(path)
        if page.isLoginWall { throw HNError.signedOut }
        let ids = page.html.matches(of: #/<tr class=['"]athing[^'"]*['"] id=['"](\d+)['"]/#).compactMap { Int($0.output.1) }
        return (ids, page.html.contains("morelink"))
    }

    /// Action links for an item and its comments, following HN's comment pagination.
    static func itemPage(_ id: Int) async throws -> (links: [Int: ItemLinks], form: HNForm?, signedIn: Bool) {
        var links: [Int: ItemLinks] = [:]
        var form: HNForm?
        var signedIn = false
        for p in 1...5 {
            let page = try await get("item?id=\(id)" + (p > 1 ? "&p=\(p)" : ""))
            let anchors = ItemLinks.anchors(in: page.html)
            signedIn = signedIn || anchors.contains { $0.href.hasPrefix("logout") }
            links.merge(ItemLinks.parse(anchors), uniquingKeysWith: { $0.merged($1) })
            if form == nil { form = HNForm.all(in: page.html).first { $0.action.trimmingPrefix("/") == "comment" } }
            guard page.html.contains("morelink") else { break }
        }
        return (links, form, signedIn)
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Item links

/// What the signed-in user can do to one story or comment, as hrefs scraped from the item page.
struct ItemLinks: Hashable {
    enum Vote { case none, up, down }

    var up: String?
    var down: String?
    var unvote: String?
    var vote: Vote = .none
    var fave: String?
    var unfave: String?
    var hide: String?
    var unhide: String?
    var flag: String?
    var unflag: String?
    var reply: String?
    var edit: String?
    var delete: String?

    var canVote: Bool { up != nil || unvote != nil }
    var canDownvote: Bool { down != nil || vote == .down }

    /// The vote link for `how` ("up", "down" or "un"); every vote link shares the item's auth token.
    func voteHref(_ how: String) -> String? {
        guard let any = up ?? down ?? unvote,
              var parts = URLComponents(string: HTMLText.decode(any)) else { return nil }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "how" && $0.name != "goto" }
            + [URLQueryItem(name: "how", value: how), URLQueryItem(name: "js", value: "t")]
        return parts.string
    }

    func merged(_ other: ItemLinks) -> ItemLinks { other.canVote || other.reply != nil ? other : self }

    struct Anchor { let href: String; let id: String?; let classes: String; let text: String }

    /// Every `<a href>` on a page. NSRegularExpression, as Swift Regex takes seconds on a big thread.
    static func anchors(in html: String) -> [Anchor] {
        let ns = html as NSString
        return anchorTag.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let attrs = ns.substring(with: m.range(at: 1))
            guard let href = attribute("href", in: attrs) else { return nil }
            var text = ns.substring(with: m.range(at: 2))
            if text.contains("<") { text = text.replacing(#/<[^>]+>/#, with: "") }
            return Anchor(href: HTMLText.decode(href), id: attribute("id", in: attrs),
                          classes: attribute("class", in: attrs) ?? "", text: HTMLText.decode(text).trimmingCharacters(in: .whitespaces))
        }
    }

    private static let anchorTag = try! NSRegularExpression(pattern: #"<a\s([^>]*)>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
    private static var attributePatterns: [String: NSRegularExpression] = [:]

    static func parse(_ anchors: [Anchor]) -> [Int: ItemLinks] {
        var result: [Int: ItemLinks] = [:]
        for a in anchors {
            guard let q = URLComponents(string: a.href),
                  let id = q.queryItems?.first(where: { $0.name == "id" })?.value.flatMap(Int.init) else { continue }
            let un = q.queryItems?.contains { $0.name == "un" && $0.value == "t" } ?? false
            let how = q.queryItems?.first { $0.name == "how" }?.value
            var links = result[id] ?? ItemLinks()
            switch q.path {
            case "vote":
                switch how {
                case "up":
                    links.up = a.href
                    if a.classes.contains("nosee"), links.vote == .none { links.vote = .up }
                case "down": links.down = a.href
                case "un":
                    links.unvote = a.href
                    links.vote = a.text == "undown" ? .down : .up
                default: break
                }
            case "fave": if un { links.unfave = a.href } else { links.fave = a.href }
            case "hide": if un { links.unhide = a.href } else { links.hide = a.href }
            case "flag": if un { links.unflag = a.href } else { links.flag = a.href }
            case "reply": links.reply = a.href
            case "edit": links.edit = a.href
            case "delete-confirm": links.delete = a.href
            default: continue
            }
            result[id] = links
        }
        return result
    }

    static func attribute(_ name: String, in attrs: String) -> String? {
        let regex = attributePatterns[name] ?? {
            let r = try! NSRegularExpression(pattern: #"(?:^|\s)"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive])
            attributePatterns[name] = r
            return r
        }()
        let ns = attrs as NSString
        guard let m = regex.firstMatch(in: attrs, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1...3).lazy.map { m.range(at: $0) }.first { $0.location != NSNotFound }.map { ns.substring(with: $0) }
    }
}

// MARK: - Forms

/// A form scraped from an HN page. Hidden fields (hmac, fnid, parent…) are posted back untouched.
struct HNForm {
    enum Kind: Hashable { case hidden, text, password, textarea, select([Option]), checkbox, submit }
    struct Option: Hashable { let value: String; let label: String }

    struct Field: Identifiable, Hashable {
        let name: String
        let label: String?
        let kind: Kind
        var value: String
        var id: String { name }
    }

    var action: String
    var fields: [Field]

    /// Fields a person edits: everything but hidden inputs and buttons.
    var visibleFields: [Field] {
        fields.filter { if case .hidden = $0.kind { false } else { $0.kind != .submit } }
    }

    subscript(name: String) -> String? {
        get { fields.first { $0.name == name }?.value }
        set {
            guard let i = fields.firstIndex(where: { $0.name == name }) else { return }
            fields[i].value = newValue ?? ""
        }
    }

    func postFields(pressing button: String? = nil) -> [(String, String)] {
        fields.compactMap { f in
            switch f.kind {
            case .submit: (button != nil && f.value == button) ? (f.name, f.value) : nil
            case .checkbox: f.value.isEmpty ? nil : (f.name, f.value)
            default: (f.name, f.value)
            }
        }
    }

    static func all(in html: String) -> [HNForm] {
        html.matches(of: #/<form\s?([^>]*)>(.*?)</form>/#.dotMatchesNewlines().ignoresCase()).map { m in
            let action = ItemLinks.attribute("action", in: String(m.output.1)) ?? "login"
            let body = String(m.output.2)
            var fields: [Field] = []
            // HN lays forms out as table rows; a row's first cell is the label for its fields.
            for row in body.components(separatedBy: "<tr") {
                let label = row.firstMatch(of: #/<td[^>]*>(.*?)</td>/#.dotMatchesNewlines())
                    .map { HTMLText.decode(String($0.output.1).replacing(#/<[^>]+>/#, with: "")).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty || $0.count > 40 ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: ":")) }
                fields += parseFields(row, label: label)
            }
            return HNForm(action: action, fields: fields)
        }
    }

    private static func parseFields(_ html: String, label: String?) -> [Field] {
        let token = #/<input\s([^>]*)>|<textarea\s([^>]*)>(.*?)</textarea>|<select\s([^>]*)>(.*?)</select>/#
        return html.matches(of: token.dotMatchesNewlines().ignoresCase()).compactMap { m -> Field? in
            if let attrs = m.output.1.map(String.init) {
                guard let name = ItemLinks.attribute("name", in: attrs) else { return nil }
                let value = HTMLText.decode(ItemLinks.attribute("value", in: attrs) ?? "")
                let kind: Kind = switch (ItemLinks.attribute("type", in: attrs) ?? "text").lowercased() {
                case "hidden": .hidden
                case "password": .password
                case "submit": .submit
                case "checkbox": .checkbox
                default: .text
                }
                let checked = attrs.contains("checked")
                return Field(name: name, label: label, kind: kind, value: kind == .checkbox ? (checked ? (value.isEmpty ? "on" : value) : "") : value)
            }
            if let attrs = m.output.2.map(String.init), let name = ItemLinks.attribute("name", in: attrs) {
                return Field(name: name, label: label, kind: .textarea, value: HTMLText.decode(String(m.output.3 ?? "")))
            }
            if let attrs = m.output.4.map(String.init), let name = ItemLinks.attribute("name", in: attrs) {
                var selected = ""
                let options = String(m.output.5 ?? "").matches(of: #/<option\s*([^>]*)>([^<]*)/#.ignoresCase()).map { o in
                    let attrs = String(o.output.1)
                    let label = HTMLText.decode(String(o.output.2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = ItemLinks.attribute("value", in: attrs).map { HTMLText.decode($0) } ?? label
                    if attrs.contains("selected") { selected = value }
                    return Option(value: value, label: label)
                }
                return Field(name: name, label: label, kind: .select(options), value: selected.isEmpty ? (options.first?.value ?? "") : selected)
            }
            return nil
        }
    }
}
