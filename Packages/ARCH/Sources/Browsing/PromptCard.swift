// A tab's prompt as Arch's card: who asks, the glyph, Arch's question and its explanation, the page's own words in their box, what an extension gets, the fields, the notes, and the buttons, on the prompt surface. The card holds the keyboard focus for its prompt and binds Return and Escape while it has it; it knows nothing of the queue and only reports its answer once.
import SwiftUI

struct PromptCard: View {
    @ObservedObject var state: PromptState
    let width: CGFloat
    let maxHeight: CGFloat
    /// Whether the card's pane is the window's focused pane, whose card alone takes the keys.
    let isFocusedPane: Bool
    /// Whether the card arrives now for the first time, when a failed login shakes it.
    let isArriving: Bool
    let takesFocusOnAppear: Bool
    /// Each change asks the card to take the focus.
    let focusRequests: Int
    let onFocusChange: (Bool) -> Void
    let onAnswer: (PromptAnswer) -> Void

    @FocusState private var focus: PromptFocus?
    @AccessibilityFocusState private var isVoiceOverOnHeading: Bool
    @State private var isArmed = false
    @State private var shakes: CGFloat = 0
    @State private var hasAnswered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cornerRadius: CGFloat = 14
    private static let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    private var content: PromptContent { state.content }
    private var layout: PromptLayout { PromptLayout.layout(forCardWidth: width) }
    private var isActive: Bool { isFocusedPane && focus != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PromptIdentityRow(identity: content.identity, isHeader: content.title == nil)
                .modifier(VoiceOverHeading(isHeading: content.title == nil, focus: $isVoiceOverOnHeading))
            PromptScrollArea {
                middle
            }
            PromptButtonRow(buttons: content.buttons, defaultID: PromptKeys.returnButton(in: content), cancelID: PromptKeys.escapeButton(in: content),
                            isActive: isActive, isArmed: isArmed, layout: layout, focus: $focus, answer: press)
                .padding(.top, layout.spacing(18))
        }
        .padding(layout == .compact ? EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12) : EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: maxHeight, alignment: .top)
        .contentShape(Self.shape)
        .modifier(PromptSurface(shape: Self.shape))
        .focusable(interactions: .edit)
        .focused($focus, equals: .card)
        .focusEffectDisabled()
        .focusSection()
        .onKeyPress(.return) {
            press(PromptKeys.returnButton(in: content))
            return .handled
        }
        .onExitCommand { press(PromptKeys.escapeButton(in: content)) }
        .modifier(PromptShake(animatableData: shakes))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(content.kind.accessibilityName), \(content.identity.name)")
        .onChange(of: focus) { onFocusChange($1 != nil) }
        .onChange(of: focusRequests) { takeFocus() }
        .onAppear {
            if takesFocusOnAppear { DispatchQueue.main.async { takeFocus() } }
            if isArriving, content.shakesOnArrival, !reduceMotion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation(PromptMotion.shake) { shakes += 1 } }
            }
        }
        .onDisappear { if focus != nil { onFocusChange(false) } }
        .task(id: state.arming) { await arm() }
    }

    // MARK: Parts

    /// Everything between the identity row and the buttons, which scrolls in a card taller than its pane allows.
    private var middle: some View {
        VStack(alignment: .leading, spacing: 0) {
            if content.title != nil || content.message != nil || content.glyph != nil {
                mainBlock
                    .padding(.top, layout.spacing(12))
            }
            if let pageText = content.pageText {
                PageAuthoredTextView(text: pageText, author: content.identity.name)
                    .padding(.top, layout.spacing(10))
            }
            if !content.items.isEmpty {
                items
                    .padding(.top, layout.spacing(8))
            }
            if !content.fields.isEmpty {
                PromptFieldStack(fields: content.fields, values: $state.fieldValues, focus: $focus, onSubmit: { press(PromptKeys.returnButton(in: content)) })
                    .onExitCommand { press(PromptKeys.escapeButton(in: content)) }
                    .padding(.top, layout.spacing(12))
            }
            if !content.notes.isEmpty {
                PromptNoteList(notes: content.notes)
                    .padding(.top, layout.spacing(12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The glyph tile beside the title and message, or in a compact card the glyph's symbol before the title.
    @ViewBuilder private var mainBlock: some View {
        if layout == .regular {
            HStack(alignment: .top, spacing: 12) {
                if let glyph = content.glyph { PromptGlyphTile(glyph: glyph) }
                words
                    .padding(.top, content.glyph == nil ? 0 : 1)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let glyph = content.glyph { PromptInlineGlyph(glyph: glyph) }
                    title
                }
                message
            }
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 3) {
            title
            message
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var title: some View {
        if let title = content.title {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isVoiceOverOnHeading)
        }
    }

    @ViewBuilder private var message: some View {
        if let message = content.message {
            switch content.messageStyle {
            case .text:
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .path:
                Text(verbatim: message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(message)
            }
        }
    }

    private var items: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(content.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                    Text(item)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Behavior

    /// Gives the focus to the prompt's first field, or to the card, and VoiceOver to its title, or to the identity row of a page's own dialog.
    private func takeFocus() {
        focus = content.focusedFieldID.map(PromptFocus.field) ?? .card
        DispatchQueue.main.async { isVoiceOverOnHeading = true }
    }

    /// Reports the button the user chose, once, unless it waits to arm.
    private func press(_ id: PromptButton.ID?) {
        guard let id, !hasAnswered, let button = content.buttons.first(where: { $0.id == id }), !button.needsArming || isArmed else { return }
        hasAnswered = true
        onAnswer(PromptAnswer(buttonID: id, fieldValues: state.fieldValues))
    }

    /// Dims the buttons that grant something until `PromptArming.delay` after the card last showed.
    private func arm() async {
        let wait = state.arming.armedAt.timeIntervalSinceNow
        isArmed = wait <= 0
        guard wait > 0 else { return }
        try? await Task.sleep(for: .seconds(wait))
        guard !Task.isCancelled else { return }
        isArmed = state.arming.isArmed(at: Date())
    }
}

/// Where VoiceOver goes when the card takes the focus: the title, or for a page's own dialog, which has none, the identity row that heads it.
private struct VoiceOverHeading: ViewModifier {
    let isHeading: Bool
    var focus: AccessibilityFocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if isHeading {
            content.accessibilityFocused(focus)
        } else {
            content
        }
    }
}
