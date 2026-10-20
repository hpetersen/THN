import Foundation

enum Feed: String, CaseIterable, Identifiable {
    case top, new, best, ask, show, job
    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: "Top Stories"
        case .new: "Newest"
        case .best: "Best"
        case .ask: "Ask HN"
        case .show: "Show HN"
        case .job: "Jobs"
        }
    }

    var endpoint: String { "\(rawValue)stories" }
}

/// A story as returned by the Firebase HN API.
struct Story: Decodable, Identifiable, Hashable {
    let id: Int
    let type: String?
    let by: String?
    let time: TimeInterval?
    let title: String?
    let url: String?
    let text: String?
    let score: Int
    let descendants: Int?
    /// Top-level comment ids in HN's ranked order.
    let kids: [Int]

    enum CodingKeys: String, CodingKey { case id, type, by, time, title, url, text, score, descendants, kids }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        by = try c.decodeIfPresent(String.self, forKey: .by)
        time = try c.decodeIfPresent(TimeInterval.self, forKey: .time)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 0
        descendants = try c.decodeIfPresent(Int.self, forKey: .descendants)
        kids = try c.decodeIfPresent([Int].self, forKey: .kids) ?? []
    }

    init(id: Int, type: String? = "story", by: String?, time: TimeInterval?, title: String?, url: String?,
         text: String?, score: Int, descendants: Int?, kids: [Int] = []) {
        self.id = id
        self.type = type
        self.by = by
        self.time = time
        self.title = title
        self.url = url
        self.text = text
        self.score = score
        self.descendants = descendants
        self.kids = kids
    }

    static let prefixes = ["Show HN", "Ask HN", "Tell HN", "Launch HN"]

    /// "Show HN", "Ask HN", … taken from the title prefix, or "Hiring" for jobs.
    var tag: String? {
        if type == "job" { return "Hiring" }
        guard let title else { return nil }
        return Self.prefixes.first { title.hasPrefix($0 + ":") || title.hasPrefix($0 + " ") }
    }

    /// The title with its "Show HN:" prefix removed, since the kicker shows it.
    var headline: String {
        guard let title else { return "Untitled" }
        guard let tag, tag != "Hiring", title.hasPrefix(tag) else { return title }
        var rest = title.dropFirst(tag.count)
        while let f = rest.first, f == ":" || f == " " || f == "–" || f == "-" { rest = rest.dropFirst() }
        return rest.isEmpty ? title : String(rest)
    }

    var link: URL? { url.flatMap(URL.init(string:)) }

    var domain: String? {
        guard let host = link?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var commentCount: Int { descendants ?? 0 }

    var date: Date { Date(timeIntervalSince1970: time ?? 0) }

    var timeAgo: String { Self.relative.localizedString(for: date, relativeTo: .now) }

    var hnURL: URL { URL(string: "https://news.ycombinator.com/item?id=\(id)")! }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// A comment node from the Algolia items endpoint, which returns the whole tree in one call.
struct CommentNode: Decodable {
    var id: Int
    let author: String?
    var text: String?
    let created_at_i: TimeInterval?
    var children: [CommentNode]
}

/// A comment flattened for display, with its depth in the thread.
struct Comment: Identifiable, Hashable {
    let id: Int
    let author: String
    let text: AttributedString
    let date: Date
    let depth: Int
    let replyCount: Int
    /// Ids of every ancestor, so a collapsed thread can hide its descendants.
    let ancestors: [Int]

    var timeAgo: String { Story.relative.localizedString(for: date, relativeTo: .now) }

    static func flatten(_ nodes: [CommentNode], depth: Int = 0, ancestors: [Int] = []) -> [Comment] {
        nodes.flatMap { node -> [Comment] in
            let kids = flatten(node.children, depth: depth + 1, ancestors: ancestors + [node.id])
            // Deleted comments have no author or text; keep them only if they have replies.
            guard node.text != nil || !kids.isEmpty else { return [] }
            let me = Comment(
                id: node.id,
                author: node.author ?? "[deleted]",
                text: HTMLText.attributed(node.text ?? "<i>[deleted]</i>"),
                date: Date(timeIntervalSince1970: node.created_at_i ?? 0),
                depth: depth,
                replyCount: kids.count,
                ancestors: ancestors
            )
            return [me] + kids
        }
    }
}

/// A user from the Firebase API.
struct HNUser: Decodable {
    let id: String
    let created: TimeInterval
    let karma: Int
    let about: String?

    var memberSince: String { Date(timeIntervalSince1970: created).formatted(.dateTime.month(.wide).year()) }
}

/// A search hit from Algolia: a story, or a comment with the title of its story.
struct SearchHit: Decodable, Identifiable {
    let objectID: String
    let author: String?
    let title: String?
    let url: String?
    let points: Int?
    let num_comments: Int?
    let created_at_i: TimeInterval?
    let story_text: String?
    let comment_text: String?
    let story_id: Int?
    let story_title: String?

    var id: String { objectID }
    var isComment: Bool { comment_text != nil }

    var story: Story {
        Story(id: Int(objectID) ?? 0, by: author, time: created_at_i, title: title, url: url,
              text: story_text, score: points ?? 0, descendants: num_comments)
    }

    var timeAgo: String {
        Story.relative.localizedString(for: Date(timeIntervalSince1970: created_at_i ?? 0), relativeTo: .now)
    }
}

/// Navigation targets besides `Story`.
struct UserRoute: Hashable { let name: String }
struct ItemRoute: Hashable { let id: Int }
struct AccountRoute: Hashable {}
struct SearchRoute: Hashable {}
