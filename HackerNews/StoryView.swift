import SwiftUI

@MainActor @Observable
final class CommentsModel {
    enum Order: String, CaseIterable { case top = "Top", newest = "Newest" }

    let story: Story
    var order: Order = .top { didSet { rebuild() } }
    var comments: [Comment] = []
    var collapsed: Set<Int> = []
    var isLoading = false
    var error: String?
    /// Signed-in action links for the story and each comment, scraped from the HN item page.
    var links: [Int: ItemLinks] = [:]
    var actionError: String?
    private var commentForm: HNForm?
    private var initialVote = ItemLinks.Vote.none
    private var tree: [CommentNode] = []
    private var nextLocalID = -1
    /// Comments posted here this visit, for the header count.
    private(set) var postedCount = 0
    /// The comment just posted, so the thread can scroll to and highlight it.
    var justPosted: Int?
    private var rank: [Int]?

    init(story: Story) { self.story = story }

    var storyLinks: ItemLinks? { links[story.id] }

    /// The story's score including a vote cast here.
    var score: Int {
        let vote = storyLinks?.vote ?? .none
        return story.score + (vote == .up ? 1 : 0) - (initialVote == .up ? 1 : 0)
    }

    var visible: [Comment] {
        guard !collapsed.isEmpty else { return comments }
        return comments.filter { c in !c.ancestors.contains(where: collapsed.contains) }
    }

    func load() async {
        guard tree.isEmpty, story.commentCount > 0 else { return }
        // Stories from search lack Firebase's ranked `kids`; fetch them for "Top" order.
        if story.kids.isEmpty, let full = try? await HNClient.item(story.id) { rank = full.kids }
        isLoading = true
        defer { isLoading = false }
        do {
            tree = try await HNClient.commentTree(for: story.id)
            rebuild()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadActions() async {
        guard HNSession.shared.isSignedIn else {
            links = [:]
            commentForm = nil
            return
        }
        do {
            let page = try await HNWeb.itemPage(story.id)
            guard page.signedIn else { throw HNError.signedOut }
            links = page.links
            commentForm = page.form
            initialVote = page.links[story.id]?.vote ?? .none
        } catch {
            actionError = HNSession.shared.handle(error)
        }
    }

    /// Casts or withdraws a vote; `how` is "up", "down" or "un".
    func vote(_ id: Int, _ how: String) async {
        guard let before = links[id], let href = before.voteHref(how) else { return }
        links[id]?.vote = how == "up" ? .up : how == "down" ? .down : .none
        if how != "un", links[id]?.unvote == nil { links[id]?.unvote = before.voteHref("un") }
        do {
            try await HNWeb.act(href)
            Extras.note("vote", ["how": how, "on": id == story.id ? "story" : "comment"])
        } catch {
            links[id] = before
            actionError = HNSession.shared.handle(error)
        }
    }

    enum StoryToggle { case favorite, hide, flag }

    /// Favorites, hides or flags the story, or undoes it.
    /// Toggles a link on the story, or on a comment when `id` is given (flagging).
    func toggle(_ kind: StoryToggle, id: Int? = nil) async {
        let id = id ?? story.id
        guard let before = links[id] else { return }
        let (on, off): (WritableKeyPath<ItemLinks, String?>, WritableKeyPath<ItemLinks, String?>) = switch kind {
        case .favorite: (\.fave, \.unfave)
        case .hide: (\.hide, \.unhide)
        case .flag: (\.flag, \.unflag)
        }
        let undo = before[keyPath: off] != nil
        guard let href = undo ? before[keyPath: off] : before[keyPath: on] else { return }
        var after = before
        after[keyPath: undo ? on : off] = Self.togglingUn(href)
        after[keyPath: undo ? off : on] = nil
        links[id] = after
        do {
            try await HNWeb.act(href)
            Extras.note(id == story.id ? "story_action" : "comment_action", ["action": "\(kind)", "undo": "\(undo)"])
            if kind == .hide {
                if undo { HNSession.shared.hiddenStories.remove(story.id) } else { HNSession.shared.hiddenStories.insert(story.id) }
            }
        } catch {
            links[id] = before
            actionError = HNSession.shared.handle(error)
        }
    }

    /// `fave?id=1&auth=x` <-> `fave?id=1&un=t&auth=x`.
    private static func togglingUn(_ href: String) -> String? {
        guard var parts = URLComponents(string: href) else { return nil }
        let items = parts.queryItems ?? []
        parts.queryItems = items.contains { $0.name == "un" }
            ? items.filter { $0.name != "un" }
            : [items.first { $0.name == "id" }, URLQueryItem(name: "un", value: "t")].compactMap { $0 } + items.filter { $0.name != "id" }
        return parts.string
    }

    /// The HN form behind a composer: the item page's comment box, a reply page, or an edit page.
    func form(for target: ComposeTarget) async throws -> HNForm {
        switch target {
        case .story:
            if let commentForm { return commentForm }
            guard let form = try await HNWeb.itemPage(story.id).form else { throw HNError.message("This thread is closed to new comments.") }
            return form
        case .reply(let c):
            guard let href = links[c.id]?.reply else { throw HNError.message("This comment can no longer be replied to.") }
            return try await HNWeb.form(at: href, action: "comment")
        case .edit(let c):
            guard let href = links[c.id]?.edit else { throw HNError.message("This comment can no longer be edited.") }
            return try await HNWeb.form(at: href, action: "xedit")
        }
    }

    /// Posts the composer's text, then shows it in the thread right away (Algolia lags behind HN).
    func send(_ text: String, with form: HNForm, for target: ComposeTarget) async throws {
        var form = form
        form["text"] = text
        try await HNWeb.submit(form)
        Extras.note("comment", ["kind": target.id.components(separatedBy: "-")[0]])
        let html = Self.html(text)
        switch target {
        case .story, .reply:
            let parent: Int? = if case .reply(let c) = target { c.id } else { nil }
            let node = CommentNode(id: nextLocalID, author: HNSession.shared.username, text: html,
                                   created_at_i: Date.now.timeIntervalSince1970, children: [])
            nextLocalID -= 1
            if let parent { Self.update(&tree, id: parent) { $0.children.insert(node, at: 0) } } else { tree.insert(node, at: 0) }
            collapsed.remove(parent ?? 0)
            postedCount += 1
            rebuild()
            justPosted = node.id
            await adoptPostedID(node.id)
        case .edit(let c):
            Self.update(&tree, id: c.id) { $0.text = html }
            rebuild()
        }
    }

    /// Swaps the placeholder id of a just-posted comment for its real HN id, so Edit and Delete work.
    private func adoptPostedID(_ localID: Int) async {
        guard let page = try? await HNWeb.itemPage(story.id) else { return }
        links = page.links
        var known = Set<Int>()
        func collect(_ nodes: [CommentNode]) { for n in nodes { known.insert(n.id); collect(n.children) } }
        collect(tree)
        // Our newest comment is the highest id we may edit that the thread doesn't know yet.
        guard let real = page.links.filter({ $0.value.edit != nil && !known.contains($0.key) }).keys.max() else { return }
        Self.update(&tree, id: localID) { $0.id = real }
        rebuild()
        if justPosted == localID { justPosted = real }
    }

    func delete(_ id: Int) async {
        guard let href = links[id]?.delete else { return }
        do {
            try await HNWeb.submit(try await HNWeb.form(at: href, action: "xdelete"), pressing: "Yes")
            links[id] = nil
            Self.update(&tree, id: id) { $0.text = nil }
            rebuild()
        } catch {
            actionError = HNSession.shared.handle(error)
        }
    }

    private static func update(_ nodes: inout [CommentNode], id: Int, _ change: (inout CommentNode) -> Void) {
        for i in nodes.indices {
            if nodes[i].id == id { change(&nodes[i]); return }
            update(&nodes[i].children, id: id, change)
        }
    }

    /// HN's plain-text formatting as the HTML Algolia would return: blank lines become paragraphs.
    private static func html(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let paragraphs = escaped.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return paragraphs.enumerated().map { $0 == 0 ? $1 : "<p>\($1)" }.joined()
    }

    func toggle(_ comment: Comment) {
        if collapsed.contains(comment.id) { collapsed.remove(comment.id) } else { collapsed.insert(comment.id) }
    }

    private func rebuild() {
        let sorted: [CommentNode]
        switch order {
        case .top:
            // Firebase `kids` carries HN's ranking; Algolia's tree does not.
            let rank = Dictionary((self.rank ?? story.kids).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            // Comments just posted here (negative ids) go first, as on HN.
            sorted = tree.sorted { (rank[$0.id] ?? ($0.id < 0 ? $0.id : .max)) < (rank[$1.id] ?? ($1.id < 0 ? $1.id : .max)) }
        case .newest:
            sorted = tree.sorted { ($0.created_at_i ?? 0) > ($1.created_at_i ?? 0) }
        }
        comments = Comment.flatten(sorted)
    }
}

/// What a composer writes: a top-level comment, a reply, or an edit of your own comment.
enum ComposeTarget: Identifiable {
    case story, reply(Comment), edit(Comment)

    var id: String {
        switch self {
        case .story: "story"
        case .reply(let c): "reply-\(c.id)"
        case .edit(let c): "edit-\(c.id)"
        }
    }
}

enum CommentAction { case upvote, downvote, unvote, reply, edit, delete, report }

struct StoryView: View {
    let story: Story
    var openBrowserOnAppear = false
    @State private var comments: CommentsModel
    @State private var browserLink: BrowserLink?
    @State private var showArticlePane = true
    @State private var width: CGFloat = 1200
    @State private var composing: ComposeTarget?
    @State private var editingStory = false
    @State private var deleting: Int?
    @State private var reporting: Comment?
    @Environment(HNSession.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.sideStatus) private var sideStatus

    init(story: Story, openBrowserOnAppear: Bool = false) {
        self.story = story
        self.openBrowserOnAppear = openBrowserOnAppear
        _comments = State(initialValue: CommentsModel(story: story))
    }

    /// The article opens beside the story when there's room for both (iPad, iPhone Duo unfolded).
    private var canSplit: Bool { sizeClass == .regular && story.link != nil && width >= 820 }
    private var splitWithBrowser: Bool { canSplit && showArticlePane }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar(doubleRule: true) {
                ShareLink(item: story.link ?? story.hnURL) {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share")
                storyMenu
                if canSplit {
                    Button {
                        withAnimation { showArticlePane.toggle() }
                    } label: {
                        Image(systemName: showArticlePane ? "rectangle.righthalf.inset.filled" : "rectangle.split.2x1")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(showArticlePane ? "Hide article" : "Show article")
                }
            }
            if splitWithBrowser, let url = story.link {
                HStack(spacing: 0) {
                    // The article gets the larger share: about a third for the story, 320–500pt.
                    storyColumn.frame(width: min(500, max(320, width * 0.35)))
                    Theme.ink.frame(width: 1)
                    BrowserView(url: url, fillsSideStatus: true).id(url)
                        .ignoresSafeArea(.container, edges: sideStatus.edges)
                }
            } else {
                storyColumn
            }
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .toolbar(.hidden, for: .navigationBar)
        .tint(Theme.accent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .fullScreenCover(item: $browserLink) { link in
            BrowserView(url: link.url, story: link.url == story.link ? story : nil,
                        onClose: { browserLink = nil }, onShowComments: { browserLink = nil })
        }
        .sheet(item: $composing) { target in
            ComposeSheet(target: target, story: story, model: comments)
        }
        .sheet(isPresented: $editingStory) {
            if let href = comments.storyLinks?.edit {
                FormSheet(title: "Edit Story", actionTitle: "Save") {
                    try await HNWeb.form(at: href, action: "xedit")
                }
            }
        }
        .confirmationDialog("Delete this \(deleting == story.id ? "story" : "comment")?", isPresented: Binding {
            deleting != nil
        } set: { if !$0 { deleting = nil } }, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = deleting { Task { await comments.delete(id) } }
            }
        }
        .confirmationDialog("Report \(reporting?.author ?? "")'s comment", isPresented: Binding {
            reporting != nil
        } set: { if !$0 { reporting = nil } }, titleVisibility: .visible, presenting: reporting) { comment in
            let links = comments.links[comment.id]
            if links?.unflag != nil {
                Button("Unflag") { act { await comments.toggle(.flag, id: comment.id) } }
            } else if !session.isSignedIn || links?.flag != nil {
                Button("Flag for Hacker News Moderators") { act { await comments.toggle(.flag, id: comment.id) } }
            }
            Button("Report by Email") {
                let subject = "Reporting comment \(comment.id)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let body = "https://news.ycombinator.com/item?id=\(comment.id)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: "mailto:hn@ycombinator.com?subject=\(subject)&body=\(body)") { UIApplication.shared.open(url) }
            }
            Button("Block \(comment.author)", role: .destructive) { session.setBlocked(comment.author, true) }
        } message: { _ in
            Text("Flagging alerts Hacker News moderators. Blocking hides this person's stories and comments on this device.")
        }
        .alert("Hacker News", isPresented: Binding { comments.actionError != nil } set: { if !$0 { comments.actionError = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(comments.actionError ?? "")
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.hasPrefix("http") == true else { return .systemAction }
            browserLink = BrowserLink(url: url)
            return .handled
        })
        .task {
            Extras.note("story", ["type": story.tag ?? story.type ?? "story"])
            if openBrowserOnAppear, sizeClass != .regular, let url = story.link {
                // A cover requested mid-push is dropped; wait for the transition to finish.
                try? await Task.sleep(for: .milliseconds(700))
                browserLink = BrowserLink(url: url)
            }
            await comments.load()
        }
        .task(id: session.username) { await comments.loadActions() }
    }

    private var storyMenu: some View {
        let links = comments.storyLinks
        let signedIn = session.isSignedIn
        return Menu {
            if !signedIn || links?.fave != nil || links?.unfave != nil {
                Button(links?.unfave != nil ? "Unfavorite" : "Favorite", systemImage: links?.unfave != nil ? "star.slash" : "star") {
                    act { await comments.toggle(.favorite) }
                }
            }
            if !signedIn || links?.hide != nil || links?.unhide != nil {
                Button(links?.unhide != nil ? "Unhide" : "Hide", systemImage: links?.unhide != nil ? "eye" : "eye.slash") {
                    act { await comments.toggle(.hide) }
                }
            }
            if !signedIn || links?.flag != nil || links?.unflag != nil {
                Button(links?.unflag != nil ? "Unflag" : "Flag", systemImage: "flag") {
                    act { await comments.toggle(.flag) }
                }
            }
            if links?.edit != nil {
                Button("Edit Story", systemImage: "pencil") { editingStory = true }
            }
            if links?.delete != nil {
                Button("Delete Story", systemImage: "trash", role: .destructive) { deleting = story.id }
            }
            if let by = story.by, by != session.username {
                Button(session.isBlocked(by) ? "Unblock \(by)" : "Block \(by)", systemImage: "hand.raised") {
                    session.setBlocked(by, !session.isBlocked(by))
                }
            }
            Divider()
            Button("Open on Hacker News", systemImage: "safari") { browserLink = BrowserLink(url: story.hnURL) }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }
        .accessibilityLabel("More")
    }

    /// Runs a signed-in action, or asks to sign in first.
    private func act(_ work: @escaping () async -> Void) {
        session.require { Task { await work() } }
    }

    private var storyColumn: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header
                CommentsHeader(model: comments)
                if story.type != "job" {
                    Button {
                        session.require { composing = .story }
                    } label: {
                        Label("Write a letter to the editor", systemImage: "pencil.line")
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .padding(.bottom, 4)
                }
                if comments.isLoading {
                    ProgressView().tint(Theme.ink).frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if let error = comments.error {
                    Text(error).font(Theme.body(14)).foregroundStyle(Theme.muted)
                } else if comments.comments.isEmpty {
                    Text("No letters yet.").font(Theme.body(15).italic()).foregroundStyle(Theme.muted)
                }
                ForEach(comments.visible) { comment in
                    CommentRow(comment: comment, isOP: comment.author == story.by,
                               isCollapsed: comments.collapsed.contains(comment.id),
                               isBlocked: session.isBlocked(comment.author),
                               links: comments.links[comment.id], signedIn: session.isSignedIn) {
                        withAnimation(.snappy) { comments.toggle(comment) }
                    } onAction: { action in
                        handle(action, on: comment)
                    }
                    .id(comment.id)
                    .background(comments.justPosted == comment.id ? Theme.accent.opacity(0.08) : .clear)
                }
            }
            .padding(.horizontal, sizeClass == .regular ? 24 : 16)
            .padding(.top, 16)
            .padding(.bottom, 40)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: comments.justPosted) { old, id in
            // Scroll to a new comment once; a later id swap (placeholder to real) keeps the position.
            guard let id, old == nil else { return }
            withAnimation(.easeInOut) { proxy.scrollTo(id, anchor: .center) }
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeOut(duration: 0.6)) { comments.justPosted = nil }
            }
        }
        // Keep the headline in view while the comment thread loads in below it.
        .defaultScrollAnchor(.top)
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .underSideStatus()
        }
    }

    private func handle(_ action: CommentAction, on comment: Comment) {
        if action == .report {
            reporting = comment
            return
        }
        session.require {
            switch action {
            case .upvote: Task { await comments.vote(comment.id, "up") }
            case .downvote: Task { await comments.vote(comment.id, "down") }
            case .unvote: Task { await comments.vote(comment.id, "un") }
            case .reply: composing = .reply(comment)
            case .edit: composing = .edit(comment)
            case .delete: deleting = comment.id
            case .report: break
            }
        }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if let tag = story.tag {
                Text(tag.uppercased())
                    .font(Theme.meta(11, weight: .bold)).tracking(0.8)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Rectangle().stroke(Theme.accent))
            }
            if let domain = story.domain {
                Text(domain).font(Theme.body(12).italic()).foregroundStyle(Theme.muted)
            }
        }
        Text(story.headline)
            .font(Theme.headline(sizeClass == .regular ? 34 : 31, weight: .bold))
        HStack(spacing: 12) {
            if let by = story.by {
                NavigationLink(value: UserRoute(name: by)) {
                    Text("By \(Text(by).fontWeight(.semibold).foregroundStyle(Theme.ink))")
                }
                .buttonStyle(.plain)
            }
            Text(story.timeAgo)
            if story.type != "job" { storyVote }
        }
        .font(Theme.meta(13))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rule(color: Theme.ink) }
        .overlay(alignment: .bottom) { Rule(color: Theme.ink) }

        if let url = story.link {
            if !splitWithBrowser {
                StoryImage(story: story, fit: true)
                    .frame(maxWidth: .infinity)
                    .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
                Button {
                    browserLink = BrowserLink(url: url)
                    Extras.note("article")
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Read the full article").font(Theme.body(15).weight(.semibold))
                            Text(url.host().map { $0 + url.path() } ?? url.absoluteString)
                                .font(Theme.body(12).italic())
                                .foregroundStyle(Theme.paper.opacity(0.8))
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .background(Theme.ink)
                    .foregroundStyle(Theme.paper)
                }
            }
        }
        if let text = story.text {
            Text(HTMLText.attributed(text, size: 17))
                .lineSpacing(3)
                .tint(Theme.accent)
                .padding(.top, 4)
        }
    }

    /// "▲ 123 points": tap to upvote, tap again to withdraw. Red once voted.
    @ViewBuilder private var storyVote: some View {
        let links = comments.storyLinks
        let voted = links?.vote == .up
        if session.isSignedIn, links?.canVote != true {
            Text("▲ \(comments.score) points")
        } else {
            Button {
                act { await comments.vote(story.id, voted ? "un" : "up") }
            } label: {
                Text("▲ \(comments.score) points")
                    .fontWeight(voted ? .semibold : .regular)
                    .foregroundStyle(voted ? Theme.accent : Theme.muted)
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voted ? "\(comments.score) points, upvoted. Remove vote" : "\(comments.score) points. Upvote")
        }
    }
}

private struct CommentsHeader: View {
    @Bindable var model: CommentsModel

    var body: some View {
        VStack(spacing: 0) {
            DoubleRule().padding(.top, 10)
            HStack(alignment: .firstTextBaseline) {
                Text("Letters \(Text("— \(model.story.commentCount + model.postedCount)").italic())")
                    .font(Theme.headline(22, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                ForEach(CommentsModel.Order.allCases, id: \.self) { order in
                    Button(order.rawValue) { model.order = order }
                        .font(Theme.body(14).smallCaps().weight(model.order == order ? .semibold : .regular))
                        .foregroundStyle(model.order == order ? Theme.accent : Theme.ink)
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) {
                            if model.order == order { Theme.accent.frame(height: 2).padding(.bottom, 8) }
                        }
                        .padding(.leading, 10)
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct CommentRow: View {
    let comment: Comment
    let isOP: Bool
    let isCollapsed: Bool
    let isBlocked: Bool
    let links: ItemLinks?
    let signedIn: Bool
    let toggle: () -> Void
    let onAction: (CommentAction) -> Void

    private var indent: CGFloat { CGFloat(min(comment.depth, 6)) * 12 }
    private var isDeleted: Bool { comment.author == "[deleted]" }
    /// Signed out, actions are offered and lead to sign-in; signed in, only what HN allows.
    private var canVote: Bool { !isDeleted && (signedIn ? links?.canVote == true : true) }
    private var canReply: Bool { !isDeleted && comment.id > 0 && (signedIn ? links?.reply != nil : true) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if comment.depth > 0 {
                Color.clear.frame(width: indent - 12)
                Theme.muted.opacity(0.45).frame(width: 1).padding(.trailing, 11)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if canVote { voteArrow }
                    if isDeleted {
                        Text(comment.author).font(Theme.body(15).smallCaps()).foregroundStyle(Theme.muted)
                    } else {
                        NavigationLink(value: UserRoute(name: comment.author)) {
                            Text(comment.author)
                                .font(Theme.body(15).smallCaps().weight(.semibold))
                                .foregroundStyle(Theme.ink)
                        }
                        .buttonStyle(.plain)
                    }
                    if isOP {
                        Text("AUTHOR")
                            .font(Theme.meta(9, weight: .bold)).tracking(0.6)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(Rectangle().stroke(Theme.accent))
                    }
                    Button(action: toggle) {
                        HStack(spacing: 6) {
                            Text("· \(comment.timeAgo)").font(Theme.meta(12)).foregroundStyle(Theme.muted)
                            Spacer()
                            Text(isCollapsed ? "[+\(comment.replyCount + 1)]" : "[–]")
                                .font(Theme.meta(12)).foregroundStyle(Theme.muted)
                        }
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(comment.author), \(comment.timeAgo). \(isCollapsed ? "Expand" : "Collapse") thread")
                }

                if isBlocked, !isCollapsed {
                    Text("Comment from a user you blocked.")
                        .font(Theme.body(14).italic())
                        .foregroundStyle(Theme.muted)
                } else if !isCollapsed {
                    Text(comment.text)
                        .lineSpacing(2.5)
                        .tint(Theme.accent)
                        .textSelection(.enabled)
                    actionLine
                }
            }
            .padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) { Rule().padding(.leading, indent) }
    }

    /// ▲ before the author, red once voted; ▼ too for accounts HN lets downvote.
    private var voteArrow: some View {
        let vote = links?.vote ?? .none
        return HStack(spacing: 2) {
            Button { onAction(vote == .up ? .unvote : .upvote) } label: {
                Text("▲").foregroundStyle(vote == .up ? Theme.accent : Theme.muted)
                    .frame(width: 22, height: 30).contentShape(Rectangle())
            }
            .accessibilityLabel(vote == .up ? "Remove upvote" : "Upvote")
            if links?.canDownvote == true {
                Button { onAction(vote == .down ? .unvote : .downvote) } label: {
                    Text("▼").foregroundStyle(vote == .down ? Theme.accent : Theme.muted)
                        .frame(width: 22, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel(vote == .down ? "Remove downvote" : "Downvote")
            }
        }
        .font(Theme.meta(11))
        .buttonStyle(.plain)
        .padding(.leading, -5)
    }

    @ViewBuilder private var actionLine: some View {
        let edit = links?.edit != nil, delete = links?.delete != nil
        HStack(spacing: 18) {
            if canReply { Button("Reply") { onAction(.reply) } }
            if edit { Button("Edit") { onAction(.edit) } }
            if delete { Button("Delete") { onAction(.delete) } }
            if !isDeleted, !edit, !delete { Button("Report") { onAction(.report) } }
        }
        .font(Theme.body(14).smallCaps().weight(.semibold))
        .foregroundStyle(Theme.muted)
        .buttonStyle(.plain)
        .frame(minHeight: 28)
    }
}

/// "Letter to the editor": writes a comment, a reply, or edits your own comment.
private struct ComposeSheet: View {
    let target: ComposeTarget
    let story: Story
    let model: CommentsModel

    @Environment(HNSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var form: HNForm?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var title: String {
        switch target {
        case .story: "Letter to the Editor"
        case .reply(let c): "Reply to \(c.author)"
        case .edit: "Edit Letter"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetTopBar(title: title, actionTitle: target.isEdit ? "Save" : "Post",
                        actionEnabled: form != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        busy: busy, action: post)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    quoted
                    PaperTextArea(label: nil, text: $text, minHeight: 220)
                        .focused($focused)
                    ErrorLine(message: error)
                    Text("Blank lines separate paragraphs. Text surrounded by *asterisks* is italicized. Indent lines by two spaces for code. URLs become links.")
                        .font(Theme.body(12).italic())
                        .foregroundStyle(Theme.muted)
                    if let name = session.username {
                        Text("Signed by \(Text(name).fontWeight(.semibold))")
                            .font(Theme.meta(12))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .interactiveDismissDisabled(!text.isEmpty && !target.isEdit)
        .task {
            focused = true
            do {
                let loaded = try await model.form(for: target)
                if target.isEdit { text = loaded["text"] ?? "" }
                form = loaded
            } catch {
                self.error = session.handle(error)
            }
        }
    }

    @ViewBuilder private var quoted: some View {
        switch target {
        case .story:
            Text("On \(Text(story.headline).italic())")
                .font(Theme.body(14))
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
        case .reply(let c):
            HStack(spacing: 10) {
                Theme.muted.opacity(0.45).frame(width: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.author).font(Theme.body(14).smallCaps().weight(.semibold))
                    Text(c.text).font(Theme.body(14)).lineLimit(5)
                }
                .foregroundStyle(Theme.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .edit:
            EmptyView()
        }
    }

    private func post() {
        guard let form else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await model.send(text, with: form, for: target)
                dismiss()
            } catch {
                self.error = session.handle(error)
            }
        }
    }
}

private extension ComposeTarget {
    var isEdit: Bool { if case .edit = self { true } else { false } }
}
