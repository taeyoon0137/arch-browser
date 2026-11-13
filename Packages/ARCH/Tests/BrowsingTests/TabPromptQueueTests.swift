// The tabs' prompt queue: each tab's prompts wait in order apart from other tabs', an answer reaches its prompt once, after the prompt has left the queue, and closing a tab, a navigation that cancels page dialogs, and quitting end the prompts without the user, oldest first.
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct TabPromptQueueTests {
    private let tab = UUID()
    private let otherTab = UUID()

    private static func content(_ kind: PromptKind) -> PromptContent {
        PromptContent(kind: kind, identity: PromptIdentity(icon: .symbol("globe"), name: "example.com", isSecure: true),
                      buttons: [PromptButton(id: "ok", title: "OK")], defaultButtonID: "ok", cancelButtonID: "ok")
    }

    @Test func eachTabsPromptsWaitInOrderApartFromOtherTabs() throws {
        let queue = TabPromptQueue()
        var log: [String] = []
        queue.enqueue(Self.content(.pageAlert), for: tab) { _ in log.append("first") }
        queue.enqueue(Self.content(.pageConfirm), for: tab) { _ in log.append("second") }
        queue.enqueue(Self.content(.notice), for: otherTab) { _ in log.append("other") }
        #expect(queue.current(for: tab)?.content.kind == .pageAlert)
        #expect(queue.current(for: otherTab)?.content.kind == .notice)
        #expect(queue.hasPrompt(for: tab) && queue.hasPrompt(for: otherTab) && !queue.hasPrompt(for: UUID()) && !queue.hasPrompt(for: nil))

        let first = try #require(queue.current(for: tab))
        queue.answer(first.id, with: PromptAnswer(buttonID: "ok"))
        #expect(log == ["first"])
        #expect(queue.current(for: tab)?.content.kind == .pageConfirm)
        #expect(queue.current(for: otherTab)?.content.kind == .notice)
    }

    @Test func anAnswerReachesItsPromptOnceAfterThePromptLeftTheQueue() throws {
        let queue = TabPromptQueue()
        var responses: [PromptResponse] = []
        var wasWaitingDuringCompletion = true
        queue.enqueue(Self.content(.pageAlert), for: tab) { response in
            responses.append(response)
            wasWaitingDuringCompletion = queue.hasPrompt(for: self.tab)
        }
        queue.enqueue(Self.content(.pageAlert), for: tab) { _ in }
        let first = try #require(queue.current(for: tab))
        let second = try #require(queue.waiting[tab]?.last)

        // Only the prompt a card shows can be answered.
        queue.answer(second.id, with: PromptAnswer(buttonID: "ok"))
        queue.answer(UUID(), with: PromptAnswer(buttonID: "ok"))
        #expect(queue.waiting[tab]?.count == 2)

        queue.answer(first.id, with: PromptAnswer(buttonID: "ok", fieldValues: ["text": "a"]))
        queue.answer(first.id, with: PromptAnswer(buttonID: "ok"))
        #expect(responses == [.answered(PromptAnswer(buttonID: "ok", fieldValues: ["text": "a"]))])
        #expect(!queue.contains(first.id) && queue.contains(second.id))
        // The second prompt waited, so the tab still had one.
        #expect(wasWaitingDuringCompletion)
    }

    @Test func aPromptAskedForInACompletionComesAfterTheTabsOthers() throws {
        let queue = TabPromptQueue()
        queue.enqueue(Self.content(.pageAlert), for: tab) { _ in
            queue.enqueue(Self.content(.leavePage), for: self.tab) { _ in }
        }
        queue.enqueue(Self.content(.sitePermission), for: tab) { _ in }
        queue.answer(try #require(queue.current(for: tab)).id, with: PromptAnswer(buttonID: "ok"))
        #expect(queue.waiting[tab]?.map(\.content.kind) == [.sitePermission, .leavePage])
    }

    @Test func dismissingATabEndsItsPromptsOldestFirstAndClearsTheirFields() throws {
        let queue = TabPromptQueue()
        var log: [String] = []
        var waitingDuringCompletions: [Bool] = []
        queue.enqueue(Self.content(.signIn), for: tab) { response in
            log.append("first \(response == .dismissed)")
            waitingDuringCompletions.append(queue.hasPrompt(for: self.tab))
        }
        queue.enqueue(Self.content(.pageAlert), for: tab) { response in
            log.append("second \(response == .dismissed)")
            waitingDuringCompletions.append(queue.hasPrompt(for: self.tab))
        }
        queue.enqueue(Self.content(.notice), for: otherTab) { _ in log.append("other") }
        let first = try #require(queue.current(for: tab))
        first.fieldValues = ["password": "secret"]

        queue.dismiss(tabID: tab)
        #expect(log == ["first true", "second true"])
        #expect(waitingDuringCompletions == [false, false])
        #expect(first.fieldValues.isEmpty)
        #expect(queue.hasPrompt(for: otherTab))
    }

    @Test func aCancellationOfPageDialogsLeavesTheTabsOtherPrompts() {
        let queue = TabPromptQueue()
        var ended: [PromptKind] = []
        for kind in [PromptKind.sitePermission, .pageAlert, .leavePage, .pageTextInput] {
            queue.enqueue(Self.content(kind), for: tab) { _ in ended.append(kind) }
        }
        queue.dismiss(tabID: tab, pageDialogsOnly: true)
        #expect(ended == [.pageAlert, .pageTextInput])
        #expect(queue.waiting[tab]?.map(\.content.kind) == [.sitePermission, .leavePage])

        // Nothing to cancel changes nothing.
        queue.dismiss(tabID: tab, pageDialogsOnly: true)
        #expect(queue.waiting[tab]?.count == 2)
    }

    @Test func closingEndsEveryPromptAndRefusesNewOnesUntilItReopens() {
        let queue = TabPromptQueue()
        var log: [String] = []
        queue.enqueue(Self.content(.pageAlert), for: tab) { log.append("tab 1 \($0 == .dismissed)") }
        queue.enqueue(Self.content(.leavePage), for: tab) { log.append("tab 2 \($0 == .dismissed)") }
        queue.enqueue(Self.content(.notice), for: otherTab) { log.append("other \($0 == .dismissed)") }

        queue.close()
        #expect(!queue.isAccepting)
        #expect(queue.waiting.isEmpty)
        #expect(Set(log) == ["tab 1 true", "tab 2 true", "other true"])
        #expect(log.firstIndex(of: "tab 1 true")! < log.firstIndex(of: "tab 2 true")!)

        queue.enqueue(Self.content(.pageAlert), for: tab) { log.append("during quit \($0 == .dismissed)") }
        #expect(log.last == "during quit true")
        #expect(!queue.hasPrompt(for: tab))

        queue.reopen()
        queue.enqueue(Self.content(.pageAlert), for: tab) { _ in log.append("after") }
        #expect(queue.hasPrompt(for: tab))
        #expect(log.last == "during quit true")
    }
}
