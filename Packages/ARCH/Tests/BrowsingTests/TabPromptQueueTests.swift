// The tabs' prompt queue: each tab's prompts wait in order apart from other tabs', an answer reaches its prompt once, after the prompt has left the queue, closing a tab, a navigation that cancels page dialogs, and quitting end the prompts without the user, oldest first, and let go of them, a close the user asks for ends the tab's prompts unless its leave-page card is the question, and a prompt queued with a maker makes its content again as a card shows it.
import Foundation
import AppKit
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
        var firstID: PromptState.ID?
        var queueDuringCompletion: (containsFirst: Bool, current: PromptState?)?
        queue.enqueue(Self.content(.pageAlert), for: tab) { response in
            responses.append(response)
            queueDuringCompletion = (firstID.map(queue.contains) ?? true, queue.current(for: self.tab))
        }
        queue.enqueue(Self.content(.pageAlert), for: tab) { _ in }
        let first = try #require(queue.current(for: tab))
        let second = try #require(queue.waiting[tab]?.last)
        firstID = first.id

        // Only the prompt a card shows can be answered.
        queue.answer(second.id, with: PromptAnswer(buttonID: "ok"))
        queue.answer(UUID(), with: PromptAnswer(buttonID: "ok"))
        #expect(queue.waiting[tab]?.count == 2)

        queue.answer(first.id, with: PromptAnswer(buttonID: "ok", fieldValues: ["text": "a"]))
        queue.answer(first.id, with: PromptAnswer(buttonID: "ok"))
        #expect(responses == [.answered(PromptAnswer(buttonID: "ok", fieldValues: ["text": "a"]))])
        #expect(!queue.contains(first.id) && queue.contains(second.id))
        // The first prompt had left the queue when its completion ran, and the second was the tab's current one.
        let during = try #require(queueDuringCompletion)
        #expect(!during.containsFirst)
        #expect(during.current === second)
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

    @Test func dismissingATabEndsItsPromptsOldestFirstAndLetsGoOfThem() throws {
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
        weak var first: PromptState?
        do {
            let state = try #require(queue.current(for: tab))
            state.fieldValues = ["password": "secret"]
            first = state
        }

        queue.dismiss(tabID: tab)
        #expect(log == ["first true", "second true"])
        #expect(waitingDuringCompletions == [false, false])
        // No card showed it, so the prompt and its password went with the queue's reference.
        #expect(first == nil)
        #expect(queue.hasPrompt(for: otherTab))
    }

    @Test func aCloseEndsTheTabsPromptsUnlessItsLeavePageCardIsTheQuestion() throws {
        let queue = TabPromptQueue()
        var ended: [PromptKind] = []
        // A favorite's tab or a space's tab alike: its page's alert ends, so the page can answer its leave-page check.
        queue.enqueue(Self.content(.pageAlert), for: tab) { _ in ended.append(.pageAlert) }
        queue.enqueue(Self.content(.sitePermission), for: tab) { _ in ended.append(.sitePermission) }
        #expect(queue.endForClose(tabID: tab))
        #expect(ended == [.pageAlert, .sitePermission])
        #expect(!queue.hasPrompt(for: tab))

        // While the tab's leave-page card shows, a second close changes nothing.
        queue.enqueue(Self.content(.leavePage), for: tab) { _ in ended.append(.leavePage) }
        queue.enqueue(Self.content(.pageAlert), for: tab) { _ in ended.append(.pageAlert) }
        #expect(!queue.endForClose(tabID: tab))
        #expect(queue.waiting[tab]?.map(\.content.kind) == [.leavePage, .pageAlert])
        #expect(ended == [.pageAlert, .sitePermission])

        // A tab without prompts closes.
        #expect(queue.endForClose(tabID: otherTab))
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

    /// A file chooser waits after the tab's earlier prompts with its panel, is no page dialog, so a navigation's cancellation leaves it, and only Choose gives the page files.
    @Test func aFileChooserWaitsInOrderWithThePanelThatAnswersIt() throws {
        let queue = TabPromptQueue()
        let panel = NSSavePanel()
        var chosen: [Bool] = []
        queue.enqueue(Self.content(.pageAlert), for: tab) { _ in }
        queue.enqueue(TabPromptContent.fileChooser(identity: PromptIdentity(icon: .symbol("globe"), name: "example.com", isSecure: true)), panel: panel, for: tab) {
            chosen.append(TabPromptContent.fileChooserResult($0))
        }
        #expect(queue.current(for: tab)?.panel == nil)
        queue.dismiss(tabID: tab, pageDialogsOnly: true)
        let chooser = try #require(queue.current(for: tab))
        #expect(chooser.content.kind == .fileChooser && chooser.panel === panel)
        queue.answer(chooser.id, with: PromptAnswer(buttonID: "choose"))
        #expect(chosen == [true] && !queue.hasPrompt(for: tab))

        for ending in ["cancel", nil] {
            queue.enqueue(TabPromptContent.fileChooser(identity: chooser.content.identity), panel: NSSavePanel(), for: tab) { chosen.append(TabPromptContent.fileChooserResult($0)) }
            let next = try #require(queue.current(for: tab))
            if let ending { queue.answer(next.id, with: PromptAnswer(buttonID: ending)) } else { queue.dismiss(tabID: tab) }
        }
        #expect(chosen == [true, false, false])
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

    /// A prompt queued with a maker takes its content again each time a card shows it (`PromptState.remake()`), and keeps what its fields hold; without a maker, a prompt keeps the content it was queued with.
    @Test func aQueuedPromptMakesItsContentAgainOnlyWithAMaker() throws {
        let queue = TabPromptQueue()
        var made: [String] = []
        let makeContent = { () -> PromptContent in
            var content = Self.content(.sitePermission)
            content.title = "made \(made.count + 1)"
            content.fields = [PromptField(id: "text", kind: .text, label: "Text", initialValue: "")]
            made.append(content.title ?? "")
            return content
        }
        queue.enqueue(makeContent(), for: tab, makeContent: makeContent) { _ in }
        queue.enqueue(Self.content(.pageAlert), for: otherTab) { _ in }

        let remade = try #require(queue.current(for: tab))
        remade.fieldValues["text"] = "typed"
        remade.remake()
        #expect(made == ["made 1", "made 2"])
        #expect(remade.content.title == "made 2")
        #expect(remade.fieldValues == ["text": "typed"])

        let kept = try #require(queue.current(for: otherTab))
        let queued = kept.content
        kept.remake()
        #expect(kept.content == queued)
        #expect(made.count == 2)
    }
}
