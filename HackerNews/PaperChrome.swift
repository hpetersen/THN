import SwiftUI

/// Newsprint replacement for the system navigation bar: serif back link, small masthead, plain ink icons.
struct PaperTopBar<Trailing: View>: View {
    var backTitle = "Front Page"
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

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
                            Text(backTitle).font(Theme.body(16))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Back to \(backTitle.lowercased())")
                    Spacer()
                    trailing
                }
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 10)
            Rule(color: Theme.ink)
        }
        .background(Theme.paper)
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
