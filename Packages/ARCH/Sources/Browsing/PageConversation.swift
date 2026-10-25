// One conversation with the AI module about a tab's page, as the page reader and the question popover keep it. Each question goes out with the conversation so far, the page's text when it is new to the conversation, and the selected text it is about. A new page's text takes the place of the text of the page read before it, so a request carries only the page now open. The reply streams in, and only a whole reply joins the conversation that later questions carry.
import AI
import Foundation

/// The selected text a question is about.
enum QuestionSelection {
    /// The question is about the whole page.
    case wholePage
    /// Text the user chose, as from the page's context menu.
    case chosen(AISelection)
    /// Whatever the page has selected when the question goes out.
    case current
}

@MainActor
final class PageConversation: ObservableObject {
    /// The page text one question reads at most. The service cuts it further to the model's input limit.
    static let pageTextLimit = 100_000

    struct Exchange: Identifiable {
        enum State {
            case readingPage
            /// The question went out; no model has started on it yet.
            case sent
            case waiting(AIWaitReason)
            case answering
            case finished(AIFinishReason)
            /// The user stopped the reply, or asked another question first.
            case stopped
            case failed(Error)
        }

        let id = UUID()
        /// What the model is asked.
        let prompt: String
        /// What the conversation shows for the question.
        let title: String
        let selectionSource: QuestionSelection
        /// The selected text the question went out with.
        var selection: String?
        var reply = ""
        /// The model that serves the reply, after any fallback.
        var model: AIModelRef?
        var usage: AIUsage?
        var state = State.readingPage
    }

    @Published private(set) var exchanges: [Exchange] = []
    @Published private(set) var isAnswering = false

    private let feature: AIFeatureID
    private let tabID: UUID
    private let instructions: String
    private let pages: any AIPageSource
    private let client: any AIClient
    /// The questions and whole replies that later questions carry.
    private var messages: [AIMessage] = []
    /// Counts the tab's moves to other pages of the same site.
    private var pageChanges = 0
    /// The value of `pageChanges` when the page text in `messages` was read; nil while they carry none.
    private var pageInMessages: Int?
    private var task: Task<Void, Never>?
    private var answeringID: Exchange.ID?

    init(feature: AIFeatureID, tabID: UUID, instructions: String, pages: any AIPageSource, client: any AIClient) {
        self.feature = feature
        self.tabID = tabID
        self.instructions = instructions
        self.pages = pages
        self.client = client
    }

    /// Asks `prompt`, shown as `title`, and streams the reply. A question still being answered stops first.
    func ask(_ prompt: String, title: String? = nil, about selection: QuestionSelection = .wholePage) {
        cancel()
        let exchange = Exchange(prompt: prompt, title: title ?? prompt, selectionSource: selection)
        exchanges.append(exchange)
        answeringID = exchange.id
        isAnswering = true
        task = Task { [weak self] in await self?.answer(exchange) }
    }

    /// Asks a question that ended without a whole reply again, at the end of the conversation.
    func retry(_ id: Exchange.ID) {
        guard let exchange = exchanges.first(where: { $0.id == id }) else { return }
        exchanges.removeAll { $0.id == id }
        ask(exchange.prompt, title: exchange.title, about: exchange.selectionSource)
    }

    /// Stops the reply being written. The question shows as stopped at once, even while the engine still reads its page, and what arrived stays on screen but does not join the conversation.
    func cancel() {
        task?.cancel()
        task = nil
        if let answeringID { update(answeringID) { $0.state = .stopped } }
        answeringID = nil
        isAnswering = false
    }

    /// Clears the conversation, so the next question goes out on its own.
    func startOver() {
        cancel()
        exchanges = []
        messages = []
        pageInMessages = nil
    }

    /// The tab moved to another page of the same site, so the next question carries that page's text.
    func pageDidChange() {
        pageChanges += 1
    }

    private func answer(_ exchange: Exchange) async {
        let id = exchange.id
        do {
            let pageRead = pageChanges
            let carriesPage = pageInMessages != pageRead
            // The page read before goes, so the model answers from the page now open, and the service, which cuts page text from the last page part first, never cuts the new page for the old one.
            let history = carriesPage ? messages.map(Self.withoutPage) : messages
            var parts: [AIPart] = []
            if carriesPage {
                parts.append(.page(try await pages.content(ofTab: tabID, limit: Self.pageTextLimit)))
            }
            let selected = try await selection(for: exchange.selectionSource)
            // An engine finishes a read it has started, so a question stopped during the read takes nothing from it.
            try Task.checkCancellation()
            if let selected {
                update(id) { $0.selection = selected.text }
                parts.append(.selection(selected))
            }
            parts.append(.text(exchange.prompt))
            update(id) { $0.state = .sent }
            let question = AIMessage(role: .user, parts: parts)
            var reply = ""
            for try await event in client.stream(AIRequest(feature: feature, instructions: instructions, messages: history + [question])) {
                try Task.checkCancellation()
                switch event {
                case .waiting(let reason):
                    update(id) { $0.state = .waiting(reason) }
                case .started(let model):
                    update(id) {
                        $0.model = model
                        $0.state = .answering
                    }
                case .text(let text):
                    reply += text
                    update(id) { $0.reply = reply }
                case .usage(let usage):
                    update(id) { $0.usage = usage }
                case .finished(let reason):
                    update(id) { $0.state = .finished(reason) }
                case .toolCall:
                    break
                }
            }
            // A cancelled stream ends without an error.
            try Task.checkCancellation()
            messages = history + [question, AIMessage(role: .assistant, parts: [.text(reply)])]
            if carriesPage { pageInMessages = pageRead }
        } catch where Task.isCancelled {
            // `cancel()` marked the question stopped, which an error from a read that ends later does not undo.
        } catch {
            update(id) { $0.state = Self.isCancellation(error) ? .stopped : .failed(error) }
        }
        if answeringID == id {
            task = nil
            answeringID = nil
            isAnswering = false
        }
    }

    private func selection(for source: QuestionSelection) async throws -> AISelection? {
        switch source {
        case .wholePage: return nil
        case .chosen(let selection): return selection
        case .current: return try await pages.selection(ofTab: tabID)
        }
    }

    private func update(_ id: Exchange.ID, _ change: (inout Exchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }

    /// The message without its page text. A question always keeps its own text.
    private static func withoutPage(_ message: AIMessage) -> AIMessage {
        var message = message
        message.parts.removeAll { if case .page = $0 { true } else { false } }
        return message
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case AIError.cancelled = error { return true }
        return false
    }
}
