import SwiftUI

/// Broadsheet palette and type: cream newsprint, ink, hairline rules, red kickers.
enum Theme {
    static let paper = Color(hex: 0xF3EDE0)
    static let ink = Color(hex: 0x1B1A17)
    static let muted = Color(hex: 0x5C5446)
    static let rule = Color(hex: 0xCFC5B0)
    static let plate = Color(hex: 0xDCCFB4)
    static let accent = Color(hex: 0xA3341A)

    /// Blackletter nameplate (Chomsky). Swap the name here for Engravers' Old English BT if licensed.
    static func masthead(_ size: CGFloat) -> Font { .custom("Chomsky", size: size) }
    static func headline(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func body(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }
    static func meta(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A 1pt horizontal rule.
struct Rule: View {
    var color: Color = Theme.rule
    var height: CGFloat = 1
    var body: some View { color.frame(height: height) }
}

/// The newspaper "double rule": two hairlines with a gap.
struct DoubleRule: View {
    var body: some View {
        VStack(spacing: 2) {
            Rule(color: Theme.ink)
            Rule(color: Theme.ink)
        }
    }
}

/// Small uppercase kicker above a headline: red for HN post types, grey for domains.
struct Kicker: View {
    let story: Story
    var body: some View {
        if let tag = story.tag {
            Text(tag.uppercased())
                .font(Theme.meta(11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.accent)
        } else if let domain = story.domain {
            Text(domain)
                .font(Theme.meta(11))
                .foregroundStyle(Theme.muted)
        }
    }
}

struct MetaLine: View {
    let story: Story
    var showAuthor = false
    var body: some View {
        Text(parts.joined(separator: " · "))
            .font(Theme.meta(12))
            .foregroundStyle(Theme.muted)
    }
    private var parts: [String] {
        var p: [String] = []
        if showAuthor, let by = story.by { p.append(by) }
        if story.type != "job" {
            p.append("\(story.score) points")
            p.append("\(story.commentCount) comments")
        }
        p.append(story.timeAgo)
        return p
    }
}
