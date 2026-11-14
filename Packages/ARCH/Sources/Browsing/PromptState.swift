// One waiting prompt, with the content a card last showed for a prompt that makes it again as it shows, and what the user has done with it so far: the text in its fields and when its buttons arm. It belongs to its tab, so the text stays while the user is on another tab.
import Combine
import Foundation

final class PromptState: ObservableObject, Identifiable {
    let id = UUID()
    let tabID: UUID
    /// What the card shows. A prompt with `makeContent` takes it again each time a card shows it (`remake()`).
    @Published private(set) var content: PromptContent
    /// Makes the content again each time a card shows the prompt, for a prompt whose notes and buttons follow what can change while it waits, such as Arch's notification permission on a website's notification card. Nil keeps `content`.
    let makeContent: (() -> PromptContent)?
    /// What the fields hold, by field. Once the prompt has ended, the card that showed it clears it after the card has gone, and a prompt that no card showed goes with the queue's last reference to it, so a password does not stay in memory.
    @Published var fieldValues: [String: String]
    @Published var arming: PromptArming
    /// Set once a card has shown the prompt. A card that shows it again, as after the user comes back to its tab, shows at once with its page.
    var hasAppeared = false

    init(tabID: UUID, content: PromptContent, makeContent: (() -> PromptContent)? = nil, now: Date = Date()) {
        self.tabID = tabID
        self.content = content
        self.makeContent = makeContent
        fieldValues = Dictionary(uniqueKeysWithValues: content.fields.map { ($0.id, $0.initialValue) })
        arming = PromptArming(shownAt: now)
    }

    /// Takes the content as `makeContent` makes it now, as a card shows the prompt. The fields keep what the user typed.
    func remake() {
        guard let makeContent else { return }
        content = makeContent()
    }
}
