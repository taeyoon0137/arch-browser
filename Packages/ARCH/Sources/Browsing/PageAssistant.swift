// The AI features that read pages: the page reader beside the page and the question popover over it, which each window shows and opens (`BrowserWindowModel`). They reach the AI module only through its client API, as features the user starts, and keep their conversations in memory: the reader's one per tab until the tab closes or moves to another site, the popover's one question at a time.
import AI
import ARCHEngine
import Combine
import SwiftUI

extension AIFeature {
    static let pageReader = AIFeature(id: .pageReader, name: "Page Reader",
                                      summary: "Summarizes the page in a panel beside it and answers follow-up questions about it.",
                                      trigger: .user, data: AIDataScope(kinds: [.page, .selection]))
    static let pageQuestion = AIFeature(id: .pageQuestion, name: "Page Questions",
                                        summary: "Answers a question about the page or the selected text in a popover over the page.",
                                        trigger: .user, data: AIDataScope(kinds: [.page, .selection]))
}

/// A question about a tab's page in the popover over it.
struct PageQuestion: Identifiable {
    let id = UUID()
    let tabID: UUID
    /// The selected text the question is about, from the page's context menu; nil for a question about the whole page.
    let selection: AISelection?
    /// The popover's question and reply. Each question starts it over, so the popover shows one reply.
    let conversation: PageConversation

    @MainActor func ask(_ text: String) {
        conversation.startOver()
        conversation.ask(text, about: selection.map(QuestionSelection.chosen) ?? .wholePage)
    }
}

@MainActor
public final class PageAssistant: ObservableObject {
    /// Set by the app to open Settings ▸ AI, where errors about models, keys, and limits send the user.
    public var showAISettings: (() -> Void)?

    private weak var session: BrowserSession?
    private let pages = TabPageSource()
    /// Each tab's reader conversation, made when the reader first shows the tab. Views make them while they draw, so only dropping one publishes a change.
    private var readerConversations: [UUID: PageConversation] = [:]
    /// Each tab's address after its last change, to tell a move within a site from a move to another site.
    private var tabAddresses: [UUID: URL] = [:]
    private var tabObservers: [UUID: AnyCancellable] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// Made with the session, which calls `attach(to:)` once it exists.
    nonisolated init() {}

    /// Registers the features and follows the session's tabs. A closed tab's conversations go, a tab that moves to another site starts over, and another page of the same site joins the reader conversation with the next question.
    func attach(to session: BrowserSession) {
        self.session = session
        pages.session = session
        AIService.shared.register(.pageReader)
        AIService.shared.register(.pageQuestion)
        // A favorite's tab is read and asked about like a space's tab.
        session.$tabs.combineLatest(session.$favoriteTabs) { tabs, favoriteTabs in tabs + favoriteTabs.values }
            .sink { [weak self] tabs in self?.follow(tabs) }
            .store(in: &cancellables)
    }

    // MARK: Availability

    /// Whether a provider can serve the page reader. Without one, no menu item or panel shows.
    public static var isReaderAvailable: Bool { AIService.shared.isAvailable(.pageReader) }
    /// Whether a provider can answer questions about pages. Without one, neither the palette nor the context menu offers them.
    static var isQuestionAvailable: Bool { AIService.shared.isAvailable(.pageQuestion) }

    /// Whether the features read `url`: web pages and local files, never internal pages or other schemes.
    static func canRead(_ url: URL) -> Bool {
        AISitePattern.sendableSchemes.contains(url.scheme?.lowercased() ?? "")
    }

    /// How a notice names `url`'s site.
    static func siteName(of url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return "local files" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Page reader

    /// Summarizes the tab's page as a window's reader opens beside it, unless its conversation has begun or AI is off for its site.
    func readerDidShow(_ tab: Tab) {
        guard let url = tab.url, AIService.shared.settings.allowsAI(on: url), readerConversation(for: tab).exchanges.isEmpty else { return }
        summarize(tab)
    }

    /// Stops every reply being written, as when no window shows the reader any more.
    func stopReaderReplies() {
        readerConversations.values.forEach { $0.cancel() }
    }

    /// Stops the replies being written about the tabs `ids`, as when a window that shows them hides its reader while another window shows its own.
    func stopReaderReplies(ofTabs ids: [UUID]) {
        ids.forEach { readerConversations[$0]?.cancel() }
    }

    func readerConversation(for tab: Tab) -> PageConversation {
        if let conversation = readerConversations[tab.id] { return conversation }
        let conversation = PageConversation(feature: .pageReader, tabID: tab.id, instructions: Self.readerInstructions, pages: pages, client: AIService.shared)
        readerConversations[tab.id] = conversation
        return conversation
    }

    func summarize(_ tab: Tab) {
        readerConversation(for: tab).ask(Self.summaryPrompt, title: "Summary")
    }

    /// A follow-up question carries the text selected in the page when it goes out.
    func askInReader(_ question: String, about tab: Tab) {
        readerConversation(for: tab).ask(question, about: .current)
    }

    // MARK: Question popover

    /// The conversation of one question about the tab's page, for a window's popover.
    func makeQuestionConversation(forTab id: UUID) -> PageConversation {
        PageConversation(feature: .pageQuestion, tabID: id, instructions: Self.questionInstructions, pages: pages, client: AIService.shared)
    }

    // MARK: Links in replies

    /// Opens a web link from a reply about `tab`'s page as a page that the tab's page opened: in a new tab of the tab's Persona, in the default engine, selected in the window that shows the tab, or in a small window of its own beside a small window (`BrowserWindowModel.showOpenedPage`), or in the Persona's preferred space while no window shows the tab. Other links open nothing, so a reply cannot hand an address to another app.
    func openLink(_ url: URL, from tab: Tab) -> OpenURLAction.Result {
        guard let session, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .discarded }
        if let window = session.window(showing: tab) {
            window.showOpenedPage(session.makeWebContents(url: url, engine: nil, state: nil, in: tab.personaID), personaID: tab.personaID)
        } else {
            session.openTab(url: url, in: session.preferredSpace(in: tab.personaID).id)
        }
        return .handled
    }

    // MARK: Tabs

    private func follow(_ tabs: [Tab]) {
        let ids = Set(tabs.map(\.id))
        for id in tabObservers.keys where !ids.contains(id) {
            tabObservers[id] = nil
            tabAddresses[id] = nil
            forgetConversations(ofTab: id)
        }
        for tab in tabs where tabObservers[tab.id] == nil {
            // The page's context menu opens in the window that shows the tab, which need not be the active one.
            tab.askAboutSelection = { [weak self, weak tab] text, sourceURL in
                Task { @MainActor [weak self, weak tab] in
                    guard let self, let tab, tab.url == sourceURL, let selection = try? await self.pages.selection(ofTab: tab.id),
                          selection.pageURL == sourceURL, Self.matchesMenuSelection(selection.text, text) else { return }
                    self.session?.window(showing: tab)?.askAboutSelection(selection, in: tab)
                }
            }
            tabObservers[tab.id] = tab.$url.sink { [weak self, weak tab] url in
                if let self, let tab { self.tab(tab, willMoveTo: url) }
            }
        }
    }

    /// The readable selection excludes editable regions and normalizes whitespace; a menu that remained open through a selection change cannot share the old text.
    static func matchesMenuSelection(_ readable: String, _ menu: String) -> Bool {
        readable.split(whereSeparator: \.isWhitespace) == menu.split(whereSeparator: \.isWhitespace)
    }

    /// A move to another site starts the tab's conversations over. Another page of the same site closes the popover, whose reply was about the page it left, and joins the reader conversation with the next question.
    private func tab(_ tab: Tab, willMoveTo url: URL?) {
        let previous = tabAddresses[tab.id]
        tabAddresses[tab.id] = url
        guard let previous, let url, previous.withoutFragment != url.withoutFragment else { return }
        guard Self.site(of: previous) == Self.site(of: url) else { return forgetConversations(ofTab: tab.id) }
        readerConversations[tab.id]?.pageDidChange()
        session?.closePageQuestions(ofTab: tab.id)
    }

    private func forgetConversations(ofTab id: UUID) {
        if let conversation = readerConversations[id] {
            objectWillChange.send()
            conversation.cancel()
            readerConversations[id] = nil
        }
        session?.closePageQuestions(ofTab: id)
    }

    /// The host, or the scheme for an address without one, such as a local file.
    private static func site(of url: URL) -> String {
        url.host?.lowercased() ?? url.scheme ?? ""
    }

    // MARK: Instructions

    private static var readerInstructions: String {
        """
        You help the user read the web page in the page block. Base your answers on that page, and say so when it does not answer a question. \
        When the user asks about selected text, it is in the selection block. Reply in \(replyLanguage) unless the user writes in another language. \
        Keep replies short, and use Markdown only for emphasis, lists, and links.
        """
    }

    private static let summaryPrompt = "Summarize this page in a few short paragraphs or a short list of its main points."

    private static var questionInstructions: String {
        """
        Answer the user's question about the web page in the page block. When a selection block is present, the question is about that selected text. \
        Base the answer on the page, and say so when it does not answer the question. Reply in \(replyLanguage) unless the user writes in another language. \
        Be brief, and use Markdown only for emphasis, lists, and links.
        """
    }

    /// The language of the system's first preferred language, in English, for the instructions.
    private static var replyLanguage: String {
        let code = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}

/// Reads the pages of the session's tabs for AI requests through the engines' readable page content.
@MainActor
final class TabPageSource: AIPageSource {
    weak var session: BrowserSession?

    nonisolated init() {}

    func content(ofTab id: UUID, limit: Int) async throws -> AIPageContent {
        let page = try await readableContent(ofTab: id, limit: limit)
        return AIPageContent(url: page.url, title: page.title, text: page.text, language: page.language, isTruncated: page.isTruncated)
    }

    /// Reads no page text, only the selection.
    func selection(ofTab id: UUID) async throws -> AISelection? {
        let page = try await readableContent(ofTab: id, limit: 0)
        return page.selection.map { AISelection(pageURL: page.url, pageTitle: page.title, text: $0) }
    }

    /// Cancellation ends the read at once, since a page that does not answer, such as one whose script never yields, would keep it waiting after its request or hook has stopped. The engine's late answer is dropped.
    private func readableContent(ofTab id: UUID, limit: Int) async throws -> EngineReadableContent {
        guard let webContents = session?.allTabs.first(where: { $0.id == id })?.webContents else { throw EngineReadableContentError.unreadable }
        let read = PageRead()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard read.start(continuation) else { return }
                webContents.readableContent(limit: limit) { read.end(with: $0) }
            }
        } onCancel: {
            read.end(with: .failure(CancellationError()))
        }
    }
}

/// One page read, which ends once: with the engine's answer or with its cancellation, whichever comes first. A cancellation can come before the read starts.
private final class PageRead: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<EngineReadableContent, Error>?
    private var result: Result<EngineReadableContent, Error>?

    /// Keeps the continuation, or resumes it with the end that came first; returns whether the read should run.
    func start(_ continuation: CheckedContinuation<EngineReadableContent, Error>) -> Bool {
        lock.lock()
        guard let result else {
            self.continuation = continuation
            lock.unlock()
            return true
        }
        lock.unlock()
        continuation.resume(with: result)
        return false
    }

    func end(with result: Result<EngineReadableContent, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
