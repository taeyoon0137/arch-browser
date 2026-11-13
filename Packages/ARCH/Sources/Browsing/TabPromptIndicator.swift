// The sidebar's mark on a tab that waits for the user's answer to a prompt, shown on its row and its favorite's tile while the prompt waits or shows.
import SwiftUI

struct TabPromptIndicator: View {
    @ObservedObject var prompts: TabPromptQueue
    let tabID: UUID?

    var body: some View {
        if prompts.hasPrompt(for: tabID) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Waiting for your answer")
                .accessibilityLabel("waiting for your answer")
        }
    }
}
