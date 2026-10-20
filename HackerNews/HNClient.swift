import Foundation

enum HNClient {
    private static let firebase = URL(string: "https://hacker-news.firebaseio.com/v0/")!

    /// The first `limit` stories of a feed, in feed order.
    static func stories(_ feed: Feed, limit: Int = 30) async throws -> [Story] {
        let idsURL = firebase.appending(path: "\(feed.endpoint).json")
        let (data, _) = try await URLSession.shared.data(from: idsURL)
        let ids = Array(try JSONDecoder().decode([Int].self, from: data).prefix(limit))
        return await items(ids)
    }

    /// Stories for `ids`, in the same order; missing or deleted ones are dropped.
    static func items(_ ids: [Int]) async -> [Story] {
        let stories = await withTaskGroup(of: (Int, Story?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, try? await item(id)) }
            }
            var result = [(Int, Story)]()
            for await (index, story) in group {
                if let story { result.append((index, story)) }
            }
            return result
        }
        return stories.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func item(_ id: Int) async throws -> Story {
        let (data, _) = try await URLSession.shared.data(from: firebase.appending(path: "item/\(id).json"))
        return try JSONDecoder().decode(Story.self, from: data)
    }

    /// The top-level comment trees of a story (Algolia returns every level in one request).
    static func commentTree(for id: Int) async throws -> [CommentNode] {
        let url = URL(string: "https://hn.algolia.com/api/v1/items/\(id)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let root = try JSONDecoder().decode(CommentNode.self, from: data)
        return root.children
    }

    static func user(_ name: String) async throws -> HNUser? {
        let (data, _) = try await URLSession.shared.data(from: firebase.appending(path: "user/\(name).json"))
        return try JSONDecoder().decode(HNUser?.self, from: data)
    }

    struct SearchPage: Decodable {
        let hits: [SearchHit]
        let nbPages: Int
    }

    /// Algolia search. `tags` is e.g. "story", "comment", or "story,author_pg".
    static func search(_ query: String = "", tags: String, byDate: Bool = false, page: Int = 0) async throws -> SearchPage {
        var url = URLComponents(string: "https://hn.algolia.com/api/v1/\(byDate ? "search_by_date" : "search")")!
        url.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "tags", value: tags),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "hitsPerPage", value: "30"),
        ]
        let (data, _) = try await URLSession.shared.data(from: url.url!)
        return try JSONDecoder().decode(SearchPage.self, from: data)
    }
}
