// Stopping a question about a page while the engine still reads the page: the question shows as stopped at once, and the read that ends later changes nothing.
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

    private static func isStopped(_ exchange: PageConversation.Exchange?) -> Bool {
        if case .stopped = exchange?.state { true } else { false }
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
