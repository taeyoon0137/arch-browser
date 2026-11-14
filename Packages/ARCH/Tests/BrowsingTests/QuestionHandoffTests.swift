import Agent
import AI
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct QuestionHandoffTests {
    @Test func continuingAQuestionRechecksItsWindowDocumentAndPopoverBeforeCancelling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchQuestionTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let browser = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(browser.spaces.first)
        let record = SessionSnapshot.WindowRecord(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true)
        let window = BrowserWindowModel(session: browser, record: record, kind: .main)
        let otherWindow = BrowserWindowModel(session: browser, record: record, kind: .main)
        let url = try #require(URL(string: "https://arch-question-fixture.invalid/article"))
        let tab = browser.openTab(url: url, in: space.id, select: false, engine: .webKit)
        let other = browser.openTab(url: url, in: space.id, select: false, engine: .webKit)
        window.selectTab(tab.id)
        otherWindow.selectTab(other.id)
        func present(_ name: String) throws -> (PageQuestion, AgentHandoffSource) {
            window.openPageQuestion(in: tab, selection: nil)
            let question = try #require(window.pageQuestion)
            question.ask(name)
            return (question, AgentHandoffSource(tab: tab, documentID: question.documentID, questionID: question.id))
        }
        let (old, beforeReplacement) = try present("Old request")
        let (active, source) = try present("Latest request")
        #expect(!old.conversation.isAnswering && active.conversation.isAnswering)
        let before = AgentReaderExcerpt(tabID: tab.id, documentID: tab.documentID, url: url, selection: "From the source", reply: nil)
        window.dismissPageQuestion(old.id)
        window.continueAsAgentTask("Old request", from: beforeReplacement, excerpt: before)
        otherWindow.continueAsAgentTask("Latest request", from: source, excerpt: before)
        #expect(active.conversation.isAnswering && window.pageQuestion?.id == active.id)
        #expect(window.agentPanel == nil && otherWindow.agentPanel == nil)
        window.continueAsAgentTask("Hidden reader action", from: .init(tab: tab, documentID: tab.documentID), excerpt: before)
        #expect(window.agentPanel == nil && active.conversation.isAnswering)

        tab.webContents(tab.webContents, didCommitDocumentAt: url)
        window.continueAsAgentTask("Latest request", from: source, excerpt: before)
        #expect(window.agentPanel == nil)
        let (current, reviewed) = try present("Question still being answered")
        window.selectTab(other.id)
        window.continueAsAgentTask("Wrong tab", from: reviewed, excerpt: nil)
        #expect(window.pageQuestion == nil && window.agentPanel == nil && !current.conversation.isAnswering)
        window.selectTab(tab.id)
        let (last, ready) = try present("The user's last question")
        let prompt = ContinueAsAgentTaskButton.task(draft: "", exchanges: last.conversation.exchanges)
        let excerpt = ContinueAsAgentTaskButton.excerpt(tabID: tab.id, documentID: tab.documentID, url: url,
                                                        exchange: last.conversation.exchanges.last, selection: nil)
        #expect(prompt == "The user's last question" && excerpt == nil)
        window.continueAsAgentTask(prompt, from: ready, excerpt: before)
        guard case .composer(let context) = window.agentPanel else {
            Issue.record("The reviewed question did not open its composer")
            return
        }
        #expect(context.text == prompt && context.tab?.id == tab.id && context.tab?.documentID == tab.documentID)
        #expect(context.readerExcerpt == nil && window.pageQuestion == nil && !last.conversation.isAnswering)
        #expect(window.selectedTab === tab && otherWindow.selectedTab === other)
    }
}
