// A waiting prompt keeps what its card last showed and what the user has entered so far.
// Field text and button arming stay with its tab while the user visits another tab.
import AppKit
import Combine

final class PromptState: ObservableObject, Identifiable {
    let id = UUID()
    let tabID: UUID
    /// What the card shows. A prompt with `makeContent` takes it again each time a card shows it, and while a card shows it when Arch's notification permission changes (`remake()`).
    @Published private(set) var content: PromptContent
    /// Makes the content again each time a card shows the prompt, for a prompt whose notes and buttons follow what can change while it waits, such as Arch's notification permission on a website's notification card. Nil keeps `content`.
    let makeContent: (() -> PromptContent)?
    /// The open or save panel that answers a page's file chooser in place of a card, or nil for a prompt that a card shows.
    let panel: NSSavePanel?
    /// What the fields hold, by field. Once the prompt has ended, the card that showed it clears it after the card has gone, and a prompt that no card showed goes with the queue's last reference to it, so a password does not stay in memory.
    @Published var fieldValues: [String: String]
    @Published var arming: PromptArming
    /// Set once a card has shown the prompt. A card that shows it again, as after the user comes back to its tab, shows at once with its page.
    var hasAppeared = false

    init(tabID: UUID, content: PromptContent, panel: NSSavePanel? = nil, makeContent: (() -> PromptContent)? = nil, now: Date = Date()) {
        self.tabID = tabID
        let content = content.keepingFirstOfEachID()
        self.content = content
        self.makeContent = makeContent
        self.panel = panel
        fieldValues = Dictionary(uniqueKeysWithValues: content.fields.map { ($0.id, $0.initialValue) })
        arming = PromptArming(shownAt: now)
    }

    /// Takes the content as `makeContent` makes it now, as a card shows the prompt or as what it follows changes while the card shows. The fields keep what the user typed.
    func remake() {
        guard let makeContent else { return }
        content = makeContent().keepingFirstOfEachID()
    }
}
