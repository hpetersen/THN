import SwiftUI

/// Search the archive (Algolia, as linked from HN's footer).
struct SearchView: View {
    enum Kind: String, CaseIterable { case stories = "Stories", comments = "Comments" }
    enum Sort: String, CaseIterable { case popular = "Popular", newest = "Newest" }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var query = ""
    @State private var kind = Kind.stories
    @State private var sort = Sort.popular
    @State private var list: HitList?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("Search the Archive")
                        .font(Theme.headline(sizeClass == .regular ? 34 : 29, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        TextField("", text: $query, prompt: Text("Stories, comments, people…").foregroundStyle(Theme.muted))
                            .font(Theme.body(19))
                            .focused($focused)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .onSubmit(run)
                        if !query.isEmpty {
                            Button { query = ""; list = nil } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                            }
                            .accessibilityLabel("Clear")
                        }
                    }
                    .frame(minHeight: 40)
                    .overlay(alignment: .bottom) { Rule(color: Theme.ink) }

                    PaperTabs(items: Kind.allCases, selection: $kind, title: \.rawValue)
                        .overlay(alignment: .trailing) {
                            HStack(spacing: 10) {
                                ForEach(Sort.allCases, id: \.self) { s in
                                    Button(s.rawValue) { sort = s }
                                        .font(Theme.body(14).smallCaps().weight(sort == s ? .semibold : .regular))
                                        .foregroundStyle(sort == s ? Theme.accent : Theme.ink)
                                        .frame(minHeight: 44)
                                }
                            }
                        }

                    if let list {
                        HitListView(list: list, emptyText: "Nothing found.")
                    }
                }
                .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                .padding(.top, 18)
                .padding(.bottom, 40)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .underSideStatus()
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // Screenshot launch argument (debug builds): `-query rust`.
            if let q = Self.screenshotQuery {
                query = q
                run()
            } else {
                focused = true
            }
        }
        .onChange(of: kind) { run() }
        .onChange(of: sort) { run() }
    }

    #if DEBUG
    private static let screenshotQuery = UserDefaults.standard.string(forKey: "query")
    #else
    private static let screenshotQuery: String? = nil
    #endif

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let kind = kind, byDate = sort == .newest
        Extras.note("search", ["kind": kind.rawValue.lowercased(), "sort": sort.rawValue.lowercased()])
        list = HitList { page in
            let result = try await HNClient.search(q, tags: kind == .stories ? "story" : "comment", byDate: byDate, page: page)
            let more = page + 1 < result.nbPages
            return kind == .stories ? (result.hits.map(\.story), [], more) : ([], result.hits, more)
        }
    }
}
