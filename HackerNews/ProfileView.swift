import SwiftUI

enum ProfileSection: String, CaseIterable {
    case submissions = "Submissions", comments = "Comments", favorites = "Favorites", upvoted = "Upvoted", hidden = "Hidden"

    /// Upvoted and hidden lists are private to their owner.
    static func available(own: Bool) -> [ProfileSection] { own ? allCases : [.submissions, .comments, .favorites] }
}

/// One page-able list on a profile or the search page: stories, or comments with their story titles.
@MainActor @Observable
final class HitList {
    var stories: [Story] = []
    var comments: [SearchHit] = []
    var isLoading = false
    var hasMore = true
    var error: String?
    private var page = 0
    private let fetch: (Int) async throws -> (stories: [Story], comments: [SearchHit], more: Bool)

    init(fetch: @escaping (Int) async throws -> (stories: [Story], comments: [SearchHit], more: Bool)) {
        self.fetch = fetch
    }

    var isEmpty: Bool { stories.isEmpty && comments.isEmpty }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await fetch(page)
            stories += result.stories.filter { s in !stories.contains { $0.id == s.id } }
            comments += result.comments
            hasMore = result.more
            page += 1
            error = nil
        } catch {
            self.error = HNSession.shared.handle(error)
            hasMore = false
        }
    }

    static func profile(_ user: String, _ section: ProfileSection) -> HitList {
        HitList { page in
            switch section {
            case .submissions, .comments:
                let result = try await HNClient.search(tags: "\(section == .comments ? "comment" : "story"),author_\(user)", byDate: true, page: page)
                let hits = result.hits
                return (section == .comments ? [] : hits.map(\.story), section == .comments ? hits : [], page + 1 < result.nbPages)
            case .favorites, .upvoted, .hidden:
                let path = section == .hidden ? "hidden?p=\(page + 1)" : "\(section.rawValue.lowercased())?id=\(user)&p=\(page + 1)"
                let (ids, more) = try await HNWeb.storyIDs(path)
                return (await HNClient.items(ids), [], more)
            }
        }
    }
}

struct ProfileView: View {
    let username: String
    @Environment(HNSession.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var user: HNUser?
    @State private var error: String?
    @State private var section = ProfileSection.submissions
    @State private var lists = ListCache()
    @State private var sheet: Sheet?
    @State private var confirmSignOut = false

    enum Sheet: String, Identifiable { case edit, submit; var id: String { rawValue } }

    private var isOwn: Bool { session.username == username }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    PaperTabs(items: ProfileSection.available(own: isOwn), selection: $section, title: \.rawValue)
                    HitListView(list: list(for: section), emptyText: emptyText)
                        .id(section)
                }
                .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                .padding(.top, 18)
                .padding(.bottom, 40)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            .refreshable { await load() }
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            Extras.note(isOwn ? "own_profile" : "profile")
            await load()
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit:
                FormSheet(title: "Edit Profile", actionTitle: "Save",
                          note: "Your about text is public. Your email is never shown; HN uses it only to reset a lost password.") {
                    try await HNWeb.form(at: "user?id=\(username)", action: "xuser")
                } onDone: {
                    Task { await load() }
                }
            case .submit:
                FormSheet(title: "Submit", actionTitle: "Submit",
                          note: "Leave the url blank to submit a question for discussion. With no url, the text appears at the top of the thread; with a url, it's posted as the first comment.") {
                    try await HNWeb.form(at: "submit", action: "r")
                } onDone: {
                    Extras.note("submit")
                    lists = ListCache()
                    section = .submissions
                }
            }
        }
        .confirmationDialog("Sign out of \(username)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isOwn ? "YOUR ACCOUNT" : "CONTRIBUTOR")
                .font(Theme.meta(11, weight: .bold)).tracking(0.8)
                .foregroundStyle(Theme.accent)
            Text(username)
                .font(Theme.headline(sizeClass == .regular ? 38 : 33, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
        }
        HStack(spacing: 12) {
            if let user {
                Text("▲ \(user.karma.formatted()) karma")
                Text("Member since \(user.memberSince)")
            } else if let error {
                Text(error)
            } else {
                Text(" ")
            }
        }
        .font(Theme.meta(13))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rule(color: Theme.ink) }
        .overlay(alignment: .bottom) { Rule(color: Theme.ink) }

        if let about = user?.about, !about.isEmpty {
            Text(HTMLText.attributed(about, size: 16))
                .lineSpacing(3)
                .tint(Theme.accent)
                .textSelection(.enabled)
        } else if isOwn, user != nil {
            Text("No about text yet.").font(Theme.body(15).italic()).foregroundStyle(Theme.muted)
        }

        if isOwn {
            HStack(spacing: 10) {
                Button("Submit") { sheet = .submit }
                Button("Edit Profile") { sheet = .edit }
                Button("Sign Out") { confirmSignOut = true }
            }
            .buttonStyle(OutlineButtonStyle())
            .padding(.top, 4)
            ExtrasAccountSection()
        }
    }

    private var emptyText: String {
        switch section {
        case .submissions: "No submissions."
        case .comments: "No comments."
        case .favorites: "No favorites."
        case .upvoted: "Nothing upvoted yet."
        case .hidden: "Nothing hidden."
        }
    }

    /// Lists are made on first view of a tab and kept until the next refresh.
    final class ListCache {
        var lists: [ProfileSection: HitList] = [:]
    }

    private func list(for section: ProfileSection) -> HitList {
        if let list = lists.lists[section] { return list }
        let list = HitList.profile(username, section)
        lists.lists[section] = list
        return list
    }

    private func load() async {
        do {
            user = try await HNClient.user(username)
            error = user == nil ? "No such user." : nil
        } catch {
            self.error = error.localizedDescription
        }
        lists = ListCache()
        if isOwn { await session.refresh() }
    }
}

/// Rows of a `HitList` with a "More" button.
struct HitListView: View {
    let list: HitList
    var emptyText = "Nothing here."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list.stories) { story in
                BriefRow(story: story, showAuthor: true)
                Rule()
            }
            ForEach(list.comments) { hit in
                CommentHitRow(hit: hit)
                Rule()
            }
            if list.isLoading {
                ProgressView().tint(Theme.ink).frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if let error = list.error {
                ErrorLine(message: error).padding(.vertical, 12)
            } else if list.isEmpty, !list.hasMore {
                Text(emptyText).font(Theme.body(15).italic()).foregroundStyle(Theme.muted).padding(.vertical, 12)
            } else if list.hasMore, !list.isEmpty {
                Button("More") { Task { await list.loadMore() } }
                    .buttonStyle(OutlineButtonStyle())
                    .padding(.top, 16)
            }
        }
        .task(id: ObjectIdentifier(list)) { if list.isEmpty { await list.loadMore() } }
    }
}

/// A comment from a profile or search, under the title of the story it belongs to.
struct CommentHitRow: View {
    let hit: SearchHit

    var body: some View {
        NavigationLink(value: ItemRoute(id: hit.story_id ?? Int(hit.objectID) ?? 0)) {
            VStack(alignment: .leading, spacing: 5) {
                if let title = hit.story_title {
                    Text("On \(Text(title).italic())")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                Text(HTMLText.attributed(hit.comment_text ?? "", size: 15))
                    .lineSpacing(2)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                Text([hit.author, hit.timeAgo].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.meta(12))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Loads a story by id (from a comment hit) and shows it.
struct ItemLoaderView: View {
    let id: Int
    @State private var story: Story?
    @State private var error: String?

    var body: some View {
        Group {
            if let story {
                StoryView(story: story)
            } else {
                VStack(spacing: 0) {
                    PaperTopBar(backTitle: "Back")
                    Spacer()
                    if let error { ErrorLine(message: error) } else { ProgressView().tint(Theme.ink) }
                    Spacer()
                }
                .background(Theme.paper)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task {
            do { story = try await HNClient.item(id) } catch { self.error = error.localizedDescription }
        }
    }
}

/// Edits any HN form (profile, submission, story edit): hidden fields go back untouched.
struct FormSheet: View {
    let title: String
    let actionTitle: String
    var note: String?
    let load: () async throws -> HNForm
    var onDone: () -> Void = {}

    @Environment(HNSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: HNForm?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetTopBar(title: title, actionTitle: actionTitle, actionEnabled: form != nil, busy: busy, action: save)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let form {
                        ForEach(form.visibleFields) { field in
                            fieldView(field)
                        }
                        if let note {
                            Text(note).font(Theme.body(13).italic()).foregroundStyle(Theme.muted)
                        }
                    } else if error == nil {
                        ProgressView().tint(Theme.ink).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ErrorLine(message: error)
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .task {
            do { form = try await load() } catch { self.error = session.handle(error) }
        }
    }

    @ViewBuilder private func fieldView(_ field: HNForm.Field) -> some View {
        let label = (field.label ?? field.name).capitalized
        let binding = Binding { form?[field.name] ?? "" } set: { form?[field.name] = $0 }
        switch field.kind {
        case .textarea:
            PaperTextArea(label: label, text: binding)
        case .select(let options):
            HStack {
                Text(label).font(Theme.body(16))
                Spacer()
                Menu {
                    Picker(label, selection: binding) {
                        ForEach(options, id: \.self) { Text($0.label).tag($0.value) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(options.first { $0.value == binding.wrappedValue }?.label ?? binding.wrappedValue)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                    .font(Theme.meta(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
                }
            }
            .overlay(alignment: .bottom) { Rule() }
        case .checkbox:
            Toggle(label, isOn: Binding { !binding.wrappedValue.isEmpty } set: { binding.wrappedValue = $0 ? "on" : "" })
                .font(Theme.body(16))
                .tint(Theme.accent)
        default:
            PaperField(label: label, text: binding, secure: field.kind == .password)
        }
    }

    private func save() {
        guard let form else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await HNWeb.submit(form)
                onDone()
                dismiss()
            } catch {
                self.error = session.handle(error)
            }
        }
    }
}
