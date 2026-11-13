// A tab asks its prompts through the session's card callback: a page's own dialogs under the page's site with the answer the card gives, and the safe answer when no card can show. The tab's page is a stand-in, so no engine starts.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct TabPromptRoutingTests {
    private static func tab() -> Tab {
        Tab(id: UUID(), webContents: UnloadedWebContents(url: URL(string: "https://example.com/form"), title: "Form", engine: .chromium, state: nil),
            spaceID: UUID(), isPinned: false, personaID: UUID())
    }

    /// Keeps the prompts the tab asked for and answers the oldest one still waiting.
    private final class PromptRecorder {
        private(set) var contents: [PromptContent] = []
        private var waiting: [(PromptResponse) -> Void] = []

        func attach(to tab: Tab) {
            tab.presentPrompt = { [weak self] content, completion in
                self?.contents.append(content)
                self?.waiting.append(completion)
            }
        }

        func respond(_ response: PromptResponse) {
            waiting.removeFirst()(response)
        }
    }

    @Test func aPagesDialogsAskUnderThePagesSiteAndTakeTheCardsAnswer() {
        let tab = Self.tab()
        let prompts = PromptRecorder()
        prompts.attach(to: tab)
        var log: [String] = []

        tab.webContents(tab.webContents, runJavaScriptAlert: "Saved") { log.append("alert") }
        tab.webContents(tab.webContents, runJavaScriptConfirm: "Delete?") { log.append("confirm \($0)") }
        tab.webContents(tab.webContents, runJavaScriptPrompt: "Name?", defaultText: "Ada") { log.append("prompt \($0 ?? "nil")") }
        #expect(prompts.contents.map(\.kind) == [.pageAlert, .pageConfirm, .pageTextInput])
        #expect(prompts.contents.allSatisfy { $0.identity.name == "example.com" && $0.identity.isSecure && $0.title == nil })
        #expect(prompts.contents.map { $0.pageText?.text } == ["Saved", "Delete?", "Name?"])
        #expect(prompts.contents.last?.fields.first?.initialValue == "Ada")

        prompts.respond(.answered(PromptAnswer(buttonID: "ok")))
        prompts.respond(.dismissed)
        prompts.respond(.answered(PromptAnswer(buttonID: "ok", fieldValues: ["text": "Grace"])))
        #expect(log == ["alert", "confirm false", "prompt Grace"])
    }

    @Test func aLeavePageCheckLeavesUnlessTheUserStays() {
        let tab = Self.tab()
        let prompts = PromptRecorder()
        prompts.attach(to: tab)
        var selections = 0
        tab.requestSelection = { selections += 1 }
        var answers: [Bool] = []

        tab.webContents(tab.webContents, runBeforeUnloadPanel: "Ignored") { answers.append($0) }
        tab.webContents(tab.webContents, runBeforeUnloadPanel: "Ignored") { answers.append($0) }
        #expect(selections == 2)
        #expect(prompts.contents.first?.kind == .leavePage && prompts.contents.first?.pageText == nil)
        prompts.respond(.answered(PromptAnswer(buttonID: "stay")))
        prompts.respond(.dismissed)
        #expect(answers == [false, true])
    }

    @Test func withoutACardAPageGetsTheSafeAnswer() {
        let tab = Self.tab()
        var log: [String] = []
        tab.webContents(tab.webContents, runJavaScriptConfirm: "Delete?") { log.append("confirm \($0)") }
        tab.webContents(tab.webContents, runJavaScriptPrompt: "Name?", defaultText: nil) { log.append("prompt \($0 ?? "nil")") }
        tab.webContents(tab.webContents, runBeforeUnloadPanel: "") { log.append("leave \($0)") }
        #expect(log == ["confirm false", "prompt nil", "leave true"])
    }
}
