// Which buttons of a prompt Return and Escape press. The card binds them only while it has the window's focus (`PromptCard`).
import Foundation

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
}
