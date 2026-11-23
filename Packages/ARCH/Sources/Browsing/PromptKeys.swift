// Which buttons of a prompt Return and Escape press, and when Escape waits. The card binds them only while it has the window's focus (`PromptCard`).
import Foundation

/// Picks the buttons that Return and Escape press in a prompt, and when Escape waits, for `PromptCard` and `PromptButtonRow`.
enum PromptKeys {
    /// Return and Enter press the default button, or the only one, but never a destructive button.
    static func returnButton(in content: PromptContent) -> PromptButton.ID? {
        let id = content.defaultButtonID ?? (content.buttons.count == 1 ? content.buttons.first?.id : nil)
        guard let id, let button = content.buttons.first(where: { $0.id == id }), !button.isDestructive else { return nil }
        return id
    }

    /// Escape and ⌘. press the cancel button, or the only one.
    static func escapeButton(in content: PromptContent) -> PromptButton.ID? {
        if let id = content.cancelButtonID, content.buttons.contains(where: { $0.id == id }) { return id }
        return content.buttons.count == 1 ? content.buttons.first?.id : nil
    }

    /// Whether Escape waits, as on a card with a button that grants something until the card arms: its cancel answer is remembered too, as a permission's Don't Allow or Cancel for another app is, so a key meant for the page answers neither way. A click on the cancel button still answers.
    static func escapeWaits(for buttons: [PromptButton], isArmed: Bool) -> Bool {
        !isArmed && buttons.contains(where: \.needsArming)
    }
}
