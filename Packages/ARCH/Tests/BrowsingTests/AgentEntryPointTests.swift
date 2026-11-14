// The entry points that start an in-app agent session (docs/agents.md, In the browser ▸ Starting a session): the window's place, named "Persona / Space", with its selected tab unless a covered page hides it; the palette's Ask Agent row, offered for two or more words while a model can run a session and starting one with no tab on an excluded site attached; the question that Continue as Agent Task takes from the page reader and the question popover; and the column, where an outside client's card does not replace the composer or a session.
import Agent
import AI
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct AgentEntryPointTests {
    private static let page = URL(string: "https://example.com/plans")!

    @Test func askAgentNeedsTwoWordsOrMore() {
        #expect(AskAgentOffer(text: "", canRunSession: true) == nil)
        #expect(AskAgentOffer(text: "compare", canRunSession: true) == nil)
        #expect(AskAgentOffer(text: "   compare \n", canRunSession: true) == nil)
        #expect(AskAgentOffer(text: "https://example.com/plans", canRunSession: true) == nil)
        #expect(AskAgentOffer(text: "compare plans", canRunSession: true)?.task == "compare plans")
        // The task is the text without the white space around it; white space inside it stays as typed.
        let offer = AskAgentOffer(text: "  compare these\ttwo plans \n", canRunSession: true)
        #expect(offer?.task == "compare these\ttwo plans")
        #expect(AskAgentOffer(text: "compare these two plans", canRunSession: true)?.title == "Ask Agent: \u{201C}compare these two plans\u{201D}")
    }

    @Test func askAgentNeedsAModelThatCanRunASession() {
        #expect(AskAgentOffer(text: "compare these two plans", canRunSession: false) == nil)
    }

    @Test func theWindowsPlaceNamesThePersonaAndSpaceAndLeavesOutACoveredPage() {
        let work = Persona(name: "Work")
        let research = Space(name: "Research", personaID: work.id)
        let tab = Self.tab(url: Self.page)
        let context = BrowserWindowModel.agentComposerContext(in: research, personas: [Persona(name: "Home"), work], selectedTab: tab, isPageCovered: false, text: "compare plans")
        #expect(context.personaID == work.id)
        #expect(context.spaceID == research.id)
        #expect(context.place == "Work / Research")
        #expect(context.tab == tab)
        #expect(context.text == "compare plans")
        // An internal page or the preview covers the tab's page, so no tab goes with the task.
        #expect(BrowserWindowModel.agentComposerContext(in: research, personas: [work], selectedTab: tab, isPageCovered: true, text: "").tab == nil)
        // A space from before Personas belongs to the default one.
        let old = BrowserWindowModel.agentComposerContext(in: Space(name: "Inbox"), personas: [Persona(id: Persona.defaultID, name: "Default")], selectedTab: nil, isPageCovered: false, text: "")
        #expect(old.personaID == Persona.defaultID)
        #expect(old.place == "Default / Inbox")
    }

    @Test func askAgentStartsInTheWindowsPlaceWithItsTabAttached() throws {
        let tab = Self.tab(url: Self.page)
        let context = Self.context(tab: tab)
        let offer = try #require(AskAgentOffer(text: "compare these two plans", canRunSession: true))
        let start = context.sessionStart(task: offer.task, mode: .readOnly) { _ in true }
        #expect(start.task == "compare these two plans")
        #expect(start.personaID == context.personaID)
        #expect(start.spaceID == context.spaceID)
        #expect(start.attachedTabIDs == [tab.id])
        #expect(start.mode == .readOnly)
        // The `agent` route chooses the model, and the tool its effort.
        #expect(start.model == nil)
        #expect(start.effort == nil)
        #expect(!start.usesAgentsPersona)
    }

    @Test func askAgentAttachesNoTabOnAnExcludedSite() {
        let excluded = Self.context(tab: Self.tab(url: Self.page))
        #expect(excluded.sessionStart(task: "compare these two plans", mode: .askBeforeActing) { $0.host != "example.com" }.attachedTabIDs.isEmpty)
        // A page that is not on the web, such as a file, has no site to put in scope, and neither has a tab without a page.
        #expect(Self.context(tab: Self.tab(url: URL(fileURLWithPath: "/tmp/plans.pdf"))).sessionStart(task: "compare these two plans", mode: .askBeforeActing) { _ in true }.attachedTabIDs.isEmpty)
        #expect(Self.context(tab: Self.tab(url: nil)).sessionStart(task: "compare these two plans", mode: .askBeforeActing) { _ in true }.attachedTabIDs.isEmpty)
        #expect(Self.context(tab: nil).sessionStart(task: "compare these two plans", mode: .askBeforeActing) { _ in true }.attachedTabIDs.isEmpty)
    }

    @Test func continueAsAgentTaskTakesTheTypedQuestionOrElseTheLastOneAsked() {
        let summary = PageConversation.Exchange(prompt: "Summarize the page for the user.", title: "Summary", selectionSource: .wholePage)
        let first = PageConversation.Exchange(prompt: "Which plan is cheaper?", title: "Which plan is cheaper?", selectionSource: .current)
        let second = PageConversation.Exchange(prompt: "Does it include support?", title: "Does it include support?", selectionSource: .current)
        #expect(ContinueAsAgentTaskButton.task(draft: "  book the cheaper plan \n", exchanges: [summary, first]) == "book the cheaper plan")
        #expect(ContinueAsAgentTaskButton.task(draft: " ", exchanges: [summary, first, second]) == "Does it include support?")
        // A summary is Arch's own prompt, not the user's question.
        #expect(ContinueAsAgentTaskButton.task(draft: "", exchanges: [first, summary]) == "Which plan is cheaper?")
        #expect(ContinueAsAgentTaskButton.task(draft: "", exchanges: [summary]).isEmpty)
        #expect(ContinueAsAgentTaskButton.task(draft: "", exchanges: []).isEmpty)
    }

    @Test func aClientsCardLeavesTheComposerAndASessionInTheColumn() {
        let client = UUID(), other = UUID()
        // A card shows its client's panel where the column is closed or shows another client's.
        #expect(BrowserWindowModel.agentPanel(showingClient: client, over: nil) == .client(client))
        #expect(BrowserWindowModel.agentPanel(showingClient: client, over: .client(other)) == .client(client))
        // The composer and a session stay, so that a draft and a conversation are not lost; the indicator's menu names the waiting client.
        let composer = AgentPanelContent.composer(Self.context(tab: nil))
        #expect(BrowserWindowModel.agentPanel(showingClient: client, over: composer) == composer)
        let session = UUID()
        #expect(BrowserWindowModel.agentPanel(showingClient: client, over: .session(session)) == .session(session))
    }

    @Test func theExcerptOffersOnlyWhatTheReaderShowsForTheSamePage() throws {
        let id = UUID()
        let selection = AISelection(pageURL: Self.page, pageTitle: "Plans", text: "A particular clause")
        var exchange = PageConversation.Exchange(prompt: "Explain this", title: "Explain this", selectionSource: .current)
        let documentID = UUID()
        exchange.selectionDocumentID = documentID
        exchange.replyDocumentID = documentID
        exchange.selection = selection
        exchange.reply = "The reader’s explanation."
        exchange.replySourceURL = Self.page
        exchange.state = .finished(.completed)
        let excerpt = try #require(ContinueAsAgentTaskButton.excerpt(tabID: id, documentID: documentID, url: Self.page, exchange: exchange, selection: nil))
        #expect(excerpt.selection == selection.text)
        #expect(excerpt.reply == exchange.reply)
        #expect(ContinueAsAgentTaskButton.excerpt(tabID: id, documentID: UUID(), url: Self.page, exchange: exchange, selection: nil) == nil)
        #expect(ContinueAsAgentTaskButton.task(draft: "Check the older terms", exchanges: [exchange]) == "Check the older terms")
        let changed = Self.page.appendingPathComponent("other")
        #expect(ContinueAsAgentTaskButton.excerpt(tabID: id, documentID: documentID, url: changed, exchange: exchange, selection: nil) == nil)
        exchange.state = .stopped
        #expect(ContinueAsAgentTaskButton.excerpt(tabID: id, documentID: documentID, url: Self.page, exchange: exchange, selection: nil)?.reply == nil)
        // The popover offers the chosen text even before its first question.
        #expect(ContinueAsAgentTaskButton.excerpt(tabID: id, documentID: documentID, url: Self.page, exchange: nil, selection: selection)?.selection == selection.text)
        #expect(PageAssistant.matchesMenuSelection("One\nTwo", "One  \r\n  Two "))
        #expect(!PageAssistant.matchesMenuSelection("One", "Other"))
    }

    private static func context(tab: AgentTabInfo?) -> AgentComposerContext {
        AgentComposerContext(personaID: UUID(), spaceID: UUID(), place: "Work / Research", tab: tab)
    }

    private static func tab(url: URL?) -> AgentTabInfo {
        AgentTabInfo(id: UUID(), spaceID: UUID(), title: "Plans", url: url, isLoading: false, engine: .webKit)
    }
}
