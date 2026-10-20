import SwiftUI

@MainActor @Observable
final class FrontPageModel {
    var feed: Feed = .top
    var stories: [Story] = []
    var isLoading = false
    var error: String?
    /// The story opened by the `-screen` launch argument, for device screenshots.
    @ObservationIgnored var autoStory: Int?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            stories = try await HNClient.stories(feed)
            error = nil
        } catch {
            if stories.isEmpty { self.error = error.localizedDescription }
        }
    }
}

struct FrontPageView: View {
    @Bindable var model: FrontPageModel
    @Environment(HNSession.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 1200

    private var isPad: Bool { sizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            Masthead(large: isPad)
            SectionStrip(selection: $model.feed, centered: isPad)
            ScrollView {
                let stories = model.stories.filter { !session.hiddenStories.contains($0.id) && !session.isBlocked($0.by) }
                Group {
                    if let error = model.error {
                        ErrorNotice(message: error) { Task { await model.load() } }
                    } else if stories.isEmpty {
                        ProgressView().tint(Theme.ink).padding(.top, 80)
                    } else if isPad {
                        // Below ~1000pt (iPad 11" portrait, iPhone Duo unfolded) In Brief moves under the lead.
                        PadFrontPage(stories: stories, feed: model.feed, narrow: width < 1000)
                    } else {
                        PhoneFrontPage(stories: stories, feed: model.feed)
                    }
                }
                .padding(.horizontal, isPad ? 40 : 16)
                .padding(.top, isPad ? 20 : 14)
                .padding(.bottom, 32)
                .frame(maxWidth: 1280)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .refreshable { await model.load() }
            .underSideStatus()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .task(id: model.feed) {
            Extras.note("front_page", ["feed": model.feed.rawValue])
            model.stories = []
            await model.load()
        }
    }
}

// MARK: - Header

struct Masthead: View {
    var large = false
    @Environment(HNSession.self) private var session

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Vol. XX · No. \(Calendar.current.ordinality(of: .day, in: .year, for: .now) ?? 1)")
                Spacer()
                // Long date when it fits, short ("Tue, 20 Oct 2026") on narrow screens.
                ViewThatFits {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    Text(Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                }
                .lineLimit(1)
                // Account: sign-in when signed out, your profile when signed in.
                NavigationLink(value: AccountRoute()) {
                    Image(systemName: session.isSignedIn ? "person.fill" : "person")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(session.isSignedIn ? Theme.ink : Theme.muted)
                        .frame(width: 22, height: 16)
                        .contentShape(Rectangle().inset(by: -12))
                }
                .accessibilityLabel(session.username.map { "Account, signed in as \($0)" } ?? "Sign in")
            }
            .font(Theme.meta(11))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Theme.muted)

            DoubleRule()
            Text("The Hacker News")
                .font(Theme.masthead(large ? 66 : 40))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            Text("“All the news that hackers see fit to print” · \(Extras.edition)")
                .font(Theme.body(12).italic())
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, large ? 40 : 16)
        .padding(.top, 4)
    }
}

struct SectionStrip: View {
    @Binding var selection: Feed
    var centered = false

    var body: some View {
        VStack(spacing: 0) {
            // The tabs stop before a side status; the rules run through it to close off the section.
            Rule(color: Theme.ink).stretchUnderSideStatus(margin: centered ? 24 : 0).padding(.top, 6)
            ZStack { ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: centered ? 34 : 20) {
                    ForEach(Feed.allCases) { feed in
                        Button {
                            selection = feed
                        } label: {
                            Text(feed.title)
                                .font(Theme.meta(14, weight: selection == feed ? .bold : .regular))
                                .foregroundStyle(selection == feed ? Theme.accent : Theme.ink)
                                .padding(.vertical, 11)
                                .overlay(alignment: .bottom) {
                                    if selection == feed { Theme.accent.frame(height: 2) }
                                }
                        }
                        .accessibilityAddTraits(selection == feed ? .isSelected : [])
                    }
                    NavigationLink(value: SearchRoute()) {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .regular))
                            Text("Search")
                        }
                        .font(Theme.meta(14))
                        .foregroundStyle(Theme.ink)
                        .padding(.vertical, 11)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
            } }
            .clipped()
            DoubleRule().stretchUnderSideStatus(margin: centered ? 24 : 0)
        }
        .padding(.horizontal, centered ? 24 : 0)
    }
}

private struct ErrorNotice: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("The presses have stopped").font(Theme.headline(22))
            Text(message).font(Theme.body(15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .font(Theme.meta(15, weight: .semibold))
                .padding(.horizontal, 20).frame(minHeight: 44)
                .overlay(Rectangle().stroke(Theme.ink))
        }
        .padding(.top, 80)
    }
}

// MARK: - iPhone

private struct PhoneFrontPage: View {
    let stories: [Story]
    let feed: Feed

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LeadStory(story: stories[0], imageHeight: 220, headlineSize: 27)
                .padding(.bottom, 16)

            if stories.count > 1 {
                Rule()
                ImageRightRow(story: stories[1], thumb: 104).padding(.vertical, 16)
            }
            if stories.count > 2 {
                Rule()
                TextStory(story: stories[2], headlineSize: 20).padding(.vertical, 16)
            }
            if stories.count > 4 {
                Rule(color: Theme.ink)
                HStack(alignment: .top, spacing: 14) {
                    ImageCard(story: stories[3], imageHeight: 100)
                    Theme.rule.frame(width: 1)
                    ImageCard(story: stories[4], imageHeight: 100)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 16)
            }
            if stories.count > 5 {
                SectionHeader(title: "More \(feed.title)")
                ForEach(Array(stories.dropFirst(5).enumerated()), id: \.element.id) { offset, story in
                    BriefRow(story: story, number: offset + 6)
                    Rule()
                }
            }
        }
    }
}

// MARK: - iPad

private struct PadFrontPage: View {
    let stories: [Story]
    let feed: Feed
    /// Lead story full width with In Brief below it, for widths too tight for the sidebar.
    var narrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if narrow {
                VStack(alignment: .leading, spacing: 24) {
                    leadColumn
                    inBrief(columns: 2)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    leadColumn
                        .padding(.trailing, 24)
                        .frame(maxWidth: .infinity)
                    Theme.ink.frame(width: 1)
                    inBrief(columns: 1)
                        .padding(.leading, 24)
                        .frame(width: 330)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if stories.count > 8 {
                VStack(spacing: 0) {
                    DoubleRule()
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: narrow ? 2 : 4), spacing: 24) {
                        ForEach(stories.dropFirst(8).prefix(4)) { story in
                            ImageCard(story: story, imageHeight: narrow ? 180 : 140)
                        }
                    }
                    .padding(.top, 18)
                }
            }

            if stories.count > 12 {
                SectionHeader(title: "More \(feed.title)")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 32, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 0) {
                    ForEach(Array(stories.dropFirst(12).enumerated()), id: \.element.id) { offset, story in
                        VStack(spacing: 0) {
                            BriefRow(story: story, number: offset + 13)
                            Rule()
                        }
                    }
                }
            }
        }
    }

    /// The lead story beside its image, then two image-right stories.
    private var leadColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: stories[0]) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Kicker(story: stories[0])
                        Text(stories[0].headline).font(Theme.headline(32, weight: .bold)).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let text = stories[0].text {
                            Text(HTMLText.plain(text)).font(Theme.body(15)).lineLimit(5)
                        }
                        MetaLine(story: stories[0], showAuthor: true)
                    }
                    .frame(width: narrow ? 260 : 300, alignment: .leading)
                    StoryImage(story: stories[0])
                        .frame(height: 300)
                        .frame(maxWidth: .infinity)
                        .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)

            Rule()
            HStack(alignment: .top, spacing: 24) {
                ForEach(stories.dropFirst(1).prefix(2)) { story in
                    ImageRightRow(story: story, thumb: 110).frame(maxWidth: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
        }
    }

    /// Stories four to eight as numbered briefs, in one column (sidebar) or two (narrow).
    private func inBrief(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("In Brief")
                .font(Theme.body(15).smallCaps().weight(.semibold))
                .tracking(1.5)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)
            Rule(color: Theme.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 32, alignment: .top), count: columns), spacing: 0) {
                ForEach(Array(stories.dropFirst(3).prefix(columns == 1 ? 5 : 4).enumerated()), id: \.element.id) { offset, story in
                    VStack(spacing: 0) {
                        BriefRow(story: story, number: offset + 4)
                        Rule()
                    }
                }
            }
        }
    }
}

// MARK: - Story blocks

private struct SectionHeader: View {
    let title: String
    var body: some View {
        VStack(spacing: 4) {
            Rule(color: Theme.ink)
            Text("— \(title) —")
                .font(Theme.body(14).smallCaps().weight(.semibold))
                .tracking(1.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityAddTraits(.isHeader)
            Rule(color: Theme.ink)
        }
    }
}

struct LeadStory: View {
    let story: Story
    var imageHeight: CGFloat
    var headlineSize: CGFloat

    var body: some View {
        NavigationLink(value: story) {
            VStack(alignment: .leading, spacing: 8) {
                Kicker(story: story)
                Text(story.headline)
                    .font(Theme.headline(headlineSize, weight: .bold))
                    .multilineTextAlignment(.leading)
                StoryImage(story: story, fit: true)
                    .frame(maxWidth: .infinity)
                    .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
                if let domain = story.domain {
                    Text("Preview image · \(domain)")
                        .font(Theme.body(11).italic())
                        .foregroundStyle(Theme.muted)
                }
                if let text = story.text {
                    Text(HTMLText.plain(text)).font(Theme.body(15)).lineLimit(4)
                }
                MetaLine(story: story, showAuthor: true)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ImageRightRow: View {
    let story: Story
    let thumb: CGFloat

    var body: some View {
        NavigationLink(value: story) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Kicker(story: story)
                    Text(story.headline).font(Theme.headline(19)).multilineTextAlignment(.leading)
                    MetaLine(story: story)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                StoryImage(story: story)
                    .frame(width: thumb, height: thumb)
                    .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct TextStory: View {
    let story: Story
    let headlineSize: CGFloat

    var body: some View {
        NavigationLink(value: story) {
            VStack(alignment: .leading, spacing: 6) {
                Kicker(story: story)
                Text(story.headline).font(Theme.headline(headlineSize)).multilineTextAlignment(.leading)
                if let text = story.text {
                    Text("“\(HTMLText.plain(text))”")
                        .font(Theme.body(14).italic())
                        .foregroundStyle(Theme.ink.opacity(0.8))
                        .lineLimit(3)
                }
                MetaLine(story: story, showAuthor: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct ImageCard: View {
    let story: Story
    let imageHeight: CGFloat

    var body: some View {
        NavigationLink(value: story) {
            VStack(alignment: .leading, spacing: 6) {
                StoryImage(story: story)
                    .frame(height: imageHeight)
                    .frame(maxWidth: .infinity)
                    .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
                Kicker(story: story)
                Text(story.headline).font(Theme.headline(17)).multilineTextAlignment(.leading)
                MetaLine(story: story)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

struct BriefRow: View {
    let story: Story
    var number: Int?
    var showAuthor = false

    var body: some View {
        NavigationLink(value: story) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let number {
                    Text("\(number)")
                        .font(Theme.headline(20, weight: .bold))
                        .foregroundStyle(Theme.muted.opacity(0.75))
                        .frame(width: 28, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Kicker(story: story)
                    Text(story.headline).font(Theme.headline(16)).multilineTextAlignment(.leading)
                    MetaLine(story: story, showAuthor: showAuthor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
