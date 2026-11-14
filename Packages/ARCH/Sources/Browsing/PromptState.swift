// One waiting prompt and what the user has done with it so far: the text in its fields and when its buttons arm. It belongs to its tab, so the text stays while the user is on another tab.
import AppKit
import Combine

final class PromptState: ObservableObject, Identifiable {
    let id = UUID()
    let tabID: UUID
    let content: PromptContent
    /// The open or save panel that answers a page's file chooser in place of a card, or nil for a prompt that a card shows.
    let panel: NSSavePanel?
    /// What the fields hold, by field. Once the prompt has ended, the card that showed it clears it after the card has gone, and a prompt that no card showed goes with the queue's last reference to it, so a password does not stay in memory.
    @Published var fieldValues: [String: String]
    @Published var arming: PromptArming
    /// Set once a card has shown the prompt. A card that shows it again, as after the user comes back to its tab, shows at once with its page.
    var hasAppeared = false

    init(tabID: UUID, content: PromptContent, panel: NSSavePanel? = nil, now: Date = Date()) {
        self.tabID = tabID
        self.content = content
        self.panel = panel
        fieldValues = Dictionary(uniqueKeysWithValues: content.fields.map { ($0.id, $0.initialValue) })
        arming = PromptArming(shownAt: now)
    }
}
