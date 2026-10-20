import SwiftUI

/// Newsprint replacement for the system navigation bar: serif back link, small masthead, plain ink icons.
struct PaperTopBar<Trailing: View>: View {
    var backTitle = "Front Page"
    /// A full-width double rule under the bar (the story page), instead of a single hairline.
    var doubleRule = false
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss
    @State private var width: CGFloat = 400
    @State private var topInset: CGFloat = 50

    /// Corner padding when no status bar sits above the bar (iPhone Duo), else the usual 10pt.
    private var sidePadding: CGFloat { topInset < 24 ? 26 : 10 }
    /// When the room inside the padding is under ~365pt (iPhone Duo folded), the back link drops
    /// its title so it doesn't run into the centred masthead.
    private var compact: Bool { width - 2 * sidePadding < 365 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("The Hacker News")
                    .font(Theme.masthead(24))
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 0) {
                    Button { dismiss() } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left").font(.system(size: 16, weight: .medium))
                            if !compact { Text(backTitle).font(Theme.body(16)) }
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Back to \(backTitle.lowercased())")
                    Spacer()
                    trailing
                }
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.ink)
            }
            // With no status bar above (iPhone Duo unfolded), keep the controls off the rounded corners.
            .padding(.horizontal, sidePadding)
            if doubleRule {
                DoubleRule()
            } else {
                Rule(color: Theme.ink)
            }
        }
        .background(Theme.paper)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
    }
}

extension PaperTopBar where Trailing == EmptyView {
    init(backTitle: String = "Front Page") {
        self.init(backTitle: backTitle) { EmptyView() }
    }
}

/// Top bar for sheets: Cancel on the left, a serif title, and the primary action on the right.
struct SheetTopBar: View {
    let title: String
    var actionTitle: String?
    var actionEnabled = true
    var busy = false
    var action: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(Theme.headline(17))
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(Theme.body(17))
                        .frame(minHeight: 44)
                    Spacer()
                    if busy {
                        ProgressView().tint(Theme.ink).frame(minWidth: 44, minHeight: 44)
                    } else if let actionTitle {
                        Button(actionTitle, action: action)
                            .font(Theme.body(17).weight(.bold))
                            .frame(minHeight: 44)
                            .disabled(!actionEnabled)
                            .opacity(actionEnabled ? 1 : 0.4)
                    }
                }
                .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16)
            DoubleRule()
        }
        .background(Theme.paper)
    }
}

/// A labelled text field drawn as a ruled line on the page.
struct PaperField: View {
    let label: String
    @Binding var text: String
    var secure = false
    var contentType: UITextContentType?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.body(13).smallCaps().weight(.semibold))
                .tracking(1)
                .foregroundStyle(Theme.muted)
            Group {
                if secure { SecureField("", text: $text) } else { TextField("", text: $text) }
            }
            .font(Theme.body(19))
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(minHeight: 34)
            Rule(color: Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// A multi-line serif editor in a hairline box.
struct PaperTextArea: View {
    let label: String?
    @Binding var text: String
    var minHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(Theme.body(13).smallCaps().weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.muted)
            }
            TextEditor(text: $text)
                .font(Theme.body(17))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: minHeight)
                .background(Color.white.opacity(0.35))
                .overlay(Rectangle().stroke(Theme.rule))
                .accessibilityLabel(label ?? "Text")
        }
    }
}

/// A status column down one side of the screen (iPhone Duo), found from lopsided side safe areas.
struct SideStatus: Equatable {
    var edges: Edge.Set = []
    var inset: CGFloat = 0
}

private struct SideStatusKey: EnvironmentKey { static let defaultValue = SideStatus() }

extension EnvironmentValues {
    var sideStatus: SideStatus {
        get { self[SideStatusKey.self] }
        set { self[SideStatusKey.self] = newValue }
    }
}

/// THN never extends into a side status column: the page ends in a full-height ink rule and the
/// column stays blank paper. One side far larger than the other marks the column; even insets,
/// as on iPhone landscape, are left alone.
private struct SideStatusBorder: ViewModifier {
    @State private var status = SideStatus()

    func body(content: Content) -> some View {
        content
            .environment(\.sideStatus, status)
            .overlay(alignment: status.edges == .leading ? .leading : .trailing) {
                if !status.edges.isEmpty {
                    Theme.ink.frame(width: 1).ignoresSafeArea(edges: .vertical)
                }
            }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
                let gap = insets.trailing - insets.leading
                status = gap > 40 ? SideStatus(edges: .trailing, inset: insets.trailing)
                    : gap < -40 ? SideStatus(edges: .leading, inset: insets.leading) : SideStatus()
            }
    }
}

extension View {
    /// Applied to each screen and full-screen overlay: borders off a side status column (iPhone Duo).
    func detectsSideStatus() -> some View { modifier(SideStatusBorder()) }
}

/// Solid ink button with paper type, like "Read the full article".
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(16).weight(.semibold))
            .foregroundStyle(Theme.paper)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.8 : 1))
    }
}

/// Hairline-boxed button, like the front page's "Try again".
struct OutlineButtonStyle: ButtonStyle {
    var color: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.meta(14, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(Rectangle().stroke(color))
            .background(configuration.isPressed ? Theme.plate.opacity(0.5) : .clear)
            .contentShape(Rectangle())
    }
}

/// Section tabs between ink rules, matching the front page's section strip.
struct PaperTabs<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        VStack(spacing: 0) {
            Rule(color: Theme.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(items, id: \.self) { item in
                        Button {
                            selection = item
                        } label: {
                            Text(title(item))
                                .font(Theme.meta(14, weight: selection == item ? .bold : .regular))
                                .foregroundStyle(selection == item ? Theme.accent : Theme.ink)
                                .padding(.vertical, 11)
                                .overlay(alignment: .bottom) {
                                    if selection == item { Theme.accent.frame(height: 2) }
                                }
                        }
                        .accessibilityAddTraits(selection == item ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 2)
            }
            Rule(color: Theme.ink)
        }
        .clipped()
    }
}

/// Italic error line in the accent colour.
struct ErrorLine: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message)
                .font(Theme.body(14).italic())
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
