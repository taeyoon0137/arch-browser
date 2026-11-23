// The sidebar's mark on a tab that waits for the user's answer to a prompt, shown on its row and its favorite's tile while the prompt waits or shows. It takes the accent color, as the marks that call the user back do, the unread dot and the Library button's count, apart from the audio badge's passive status beside it.
import SwiftUI

/// The prompt mark on a tab's row and its favorite's tile, shown while `prompts` holds a prompt for `tabID`.
struct TabPromptIndicator: View {
    @ObservedObject var prompts: TabPromptQueue
    let tabID: UUID?

    var body: some View {
        if prompts.hasPrompt(for: tabID) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
                .help(localized("Waiting for your answer"))
                .accessibilityLabel(localized("Waiting for your answer"))
        }
    }
}
