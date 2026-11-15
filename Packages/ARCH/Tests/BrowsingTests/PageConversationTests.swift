// Stopping a question about a page while the engine still reads the page: the question shows as stopped at once, and the read that ends later changes nothing. A conversation that grew past what the model takes starts over with its failed question alone.
import AI
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct PageConversationTests {
    private let selection = AISelection(pageURL: URL(string: "https://example.com/")!, pageTitle: "Example", text: "Selected text")

    @Test func stoppingWhileThePageIsReadShowsTheQuestionStoppedAtOnce() async throws {
        let pages = HeldPageSource()
        let conversation = PageConversation(feature: .pageReader, tabID: UUID(), instructions: "", pages: pages, client: RecordingClient())
        conversation.ask("Summarize")
        try await pages.waitForRead()

        conversation.cancel()
        #expect(Self.isStopped(conversation.exchanges.first))
        #expect(!conversation.isAnswering)

        pages.finishRead(throwing: URLError(.timedOut))
        await Self.settle()
        #expect(Self.isStopped(conversation.exchanges.first))
    }

    @Test func aReadThatEndsAfterStopSendsNothing() async throws {
        let pages = HeldPageSource()
        let client = RecordingClient()
        let conversation = PageConversation(feature: .pageQuestion, tabID: UUID(), instructions: "", pages: pages, client: client)
        conversation.ask("What is this?", about: .chosen(selection))
        try await pages.waitForRead()

        conversation.cancel()
        pages.finishRead(returning: AIPageContent(url: selection.pageURL, title: selection.pageTitle, text: "Page text"))
        await Self.settle()
        #expect(Self.isStopped(conversation.exchanges.first))
        #expect(conversation.exchanges.first?.selection == nil)
        #expect(client.requestCount == 0)
    }

    @Test func aReloadAtTheSameAddressWhileReadingKeepsThePageOutOfTheRequest() async throws {
        let pages = HeldPageSource()
        let client = RecordingClient()
        var document = UUID()
        let conversation = PageConversation(feature: .pageReader, tabID: UUID(), instructions: "", pages: pages, client: client, documentID: { document })
        conversation.ask("Summarize")
        try await pages.waitForRead()
        document = UUID()
        pages.finishRead(returning: AIPageContent(url: selection.pageURL, title: selection.pageTitle, text: "A draft from the old document"))
        try await Self.waitUntilAnswered(conversation)
        if case .failed(let error)? = conversation.exchanges.first?.state { #expect(error is PageConversation.PageReloaded) } else { Issue.record("Expected the reload failure.") }
        #expect(client.requestCount == 0)
    }

    @Test func aConversationTooLongForTheModelStartsOverWithTheFailedQuestionAlone() async throws {
        let client = ShortContextClient()
        let conversation = PageConversation(feature: .pageReader, tabID: UUID(), instructions: "", pages: FixedPageSource(), client: client)
        conversation.ask("Summarize")
        try await Self.waitUntilAnswered(conversation)
        #expect(Self.isFinished(conversation.exchanges.first))
        #expect(conversation.exchanges.first?.followsEarlierQuestions == false)

        conversation.ask("And then?")
        try await Self.waitUntilAnswered(conversation)
        let failed = try #require(conversation.exchanges.last)
        #expect(Self.isTooLong(failed))
        #expect(failed.followsEarlierQuestions)

        conversation.startOver(asking: failed.id)
        try await Self.waitUntilAnswered(conversation)
        #expect(conversation.exchanges.map(\.prompt) == ["And then?"])
        #expect(Self.isFinished(conversation.exchanges.first))
        #expect(conversation.exchanges.first?.followsEarlierQuestions == false)
        #expect(client.messageCounts == [1, 3, 1])
    }

    @Test func aReplyBasedOnTwoPagesCannotBeSharedAsAnExcerptOfOne() async throws {
        let pages = HeldPageSource()
        let conversation = PageConversation(feature: .pageReader, tabID: UUID(), instructions: "", pages: pages, client: ShortContextClient(messageLimit: 3))
        conversation.ask("Read")
        try await pages.waitForRead()
        pages.finishRead(returning: AIPageContent(url: selection.pageURL, title: "", text: "First"))
        try await Self.waitUntilAnswered(conversation)
        #expect(conversation.exchanges.last?.replySourceURL == selection.pageURL)
        conversation.pageDidChange()
        let other = selection.pageURL.appendingPathComponent("next")
        conversation.ask("Read again")
        try await pages.waitForRead()
        pages.finishRead(returning: AIPageContent(url: other, title: "", text: "Second"))
        try await Self.waitUntilAnswered(conversation)
        #expect(Self.isFinished(conversation.exchanges.last))
        #expect(conversation.exchanges.last?.replySourceURL == nil)
    }

    private static func isStopped(_ exchange: PageConversation.Exchange?) -> Bool {
        if case .stopped = exchange?.state { true } else { false }
    }

    private static func isFinished(_ exchange: PageConversation.Exchange?) -> Bool {
        if case .finished = exchange?.state { true } else { false }
    }

    private static func isTooLong(_ exchange: PageConversation.Exchange) -> Bool {
        if case .failed(AIError.contextTooLong) = exchange.state { true } else { false }
    }

    private static func waitUntilAnswered(_ conversation: PageConversation) async throws {
        for _ in 0..<200 where conversation.isAnswering { await Task.yield() }
        try #require(!conversation.isAnswering)
    }

    /// Lets the conversation's task, which runs on the main actor, take what the page source handed it.
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// A page source whose page reads end only when the test ends them, as an engine's do when the page is busy.
@MainActor
private final class HeldPageSource: AIPageSource {
    private var read: CheckedContinuation<AIPageContent, any Error>?

    func content(ofTab id: UUID, limit: Int) async throws -> AIPageContent {
        try await withCheckedThrowingContinuation { read = $0 }
    }

    func selection(ofTab id: UUID) async throws -> AISelection? { nil }

    func waitForRead() async throws {
        for _ in 0..<100 where read == nil { await Task.yield() }
        try #require(read != nil)
    }

    func finishRead(returning content: AIPageContent) {
        read?.resume(returning: content)
        read = nil
    }

    func finishRead(throwing error: any Error) {
        read?.resume(throwing: error)
        read = nil
    }
}

/// Counts the requests that reach the model and answers none of them.
private final class RecordingClient: AIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int { lock.withLock { count } }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        lock.withLock { count += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

/// A page source that reads the same short page at once.
@MainActor
private final class FixedPageSource: AIPageSource {
    func content(ofTab id: UUID, limit: Int) async throws -> AIPageContent {
        AIPageContent(url: URL(string: "https://example.com/")!, title: "Example", text: "Page text")
    }

    func selection(ofTab id: UUID) async throws -> AISelection? { nil }
}

/// A model that takes one message: it answers a question on its own and refuses one that carries earlier questions as too long.
private final class ShortContextClient: AIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []
    private let messageLimit: Int

    init(messageLimit: Int = 1) { self.messageLimit = messageLimit }

    var messageCounts: [Int] { lock.withLock { counts } }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        lock.withLock { counts.append(request.messages.count) }
        let fits = request.messages.count <= messageLimit
        return AsyncThrowingStream { continuation in
            guard fits else { return continuation.finish(throwing: AIError.contextTooLong(AIProviderID(rawValue: "test"))) }
            continuation.yield(.text("Reply"))
            continuation.yield(.finished(.completed))
            continuation.finish()
        }
    }
}
