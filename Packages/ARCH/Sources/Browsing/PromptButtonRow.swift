// A prompt card's buttons: standard large push buttons at the trailing end, the default one last, or stacked across the card's width with the default one on top when they do not fit on a line and always in a compact card. While the card has the window's focus, the default button is the prominent one and takes Return, and the cancel button takes Escape. A destructive button is red and takes no key. A button that grants something stays dimmed until the card arms, and until then the cancel button takes no Escape (`PromptKeys.escapeWaits`).
import SwiftUI

struct PromptButtonRow: View {
    let buttons: [PromptButton]
    /// The button Return presses (`PromptKeys.returnButton`).
    let defaultID: PromptButton.ID?
    /// The button Escape presses (`PromptKeys.escapeButton`).
    let cancelID: PromptButton.ID?
    /// Whether the card has the window's focus, which binds the keys.
    let isActive: Bool
    let isArmed: Bool
    let layout: PromptLayout
    var focus: FocusState<PromptFocus?>.Binding
    let answer: (PromptButton.ID) -> Void

    var body: some View {
        if layout == .compact {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                row
                stacked
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(buttons) { button($0, fillsWidth: false) }
        }
    }

    private var stacked: some View {
        VStack(spacing: 8) {
            ForEach(buttons.reversed()) { button($0, fillsWidth: true) }
        }
    }

    private func button(_ button: PromptButton, fillsWidth: Bool) -> some View {
        let isDefault = isActive && button.id == defaultID
        let isCancel = isActive && button.id == cancelID && button.id != defaultID && !PromptKeys.escapeWaits(for: buttons, isArmed: isArmed)
        let shortcut: KeyboardShortcut? = isDefault ? .defaultAction : isCancel ? .cancelAction : nil
        return Button(role: button.isDestructive ? .destructive : nil) {
            answer(button.id)
        } label: {
            Text(button.title)
                .frame(minWidth: 56, maxWidth: fillsWidth ? .infinity : nil)
        }
        .controlSize(.large)
        .modifier(PromptPushButtonStyle(isProminent: isDefault))
        .keyboardShortcut(shortcut)
        .disabled(button.needsArming && !isArmed)
        .focused(focus, equals: .button(button.id))
    }
}

/// The default button's prominent style while the card has the focus, the standard bordered one otherwise.
private struct PromptPushButtonStyle: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
