// In-app sessions (docs/agents.md, In-app sessions: tickets; In the browser; Site scope and navigation): a ticket binds `arch-mcp` only from the session's own process tree and only while the session lives, compared in constant time; the first message carries the task and tab handles but no page text; the session's calls wait for the model's first output and are refused after the wait; a mode change sends `tools/changed` and reports the next list to the runner; a deleted space ends its sessions, whose place still reads "Persona / Space"; and `arch-cli task` starts a session capped at the grant's level and the Settings default, in the grant's Persona, with no scope from the client's text.
import AgentControl
import AI
import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import Agent

@MainActor @Suite(.serialized) struct SessionTests {
    /// The CLI process the fake runner reports, and this test process as its `arch-mcp`.
    nonisolated static let cliProcess: pid_t = 4_242
    nonisolated static let cliStart = AgentProcessStart(seconds: 1_700_000_000, microseconds: 7)

    private func start(_ service: AgentService, _ harness: Harness, task: String = "Summarize this tab", attaching tabs: [UUID] = [], mode: AgentAccessLevel = .askBeforeActing) throws -> (AgentSession, FakeRunner) {
        let persona = FakeHost.defaultPersona.id
        let space = try #require(harness.host.spaces(in: persona).first)
        let session = try service.startSession(AgentService.SessionStart(task: task, personaID: persona, spaceID: space.id, attachedTabIDs: tabs, mode: mode, model: nil, effort: nil))
        let runner = try #require(harness.runners.last)
        return (session, runner)
    }

    /// The fake CLI starts as a child of launchd, and this process becomes its child, as `arch-mcp` is the CLI's.
    private func spawnCLI(_ runner: FakeRunner, _ harness: Harness, start: AgentProcessStart = SessionTests.cliStart) {
        harness.addProcess(Self.cliProcess, parent: 1, start: start)
        harness.addProcess(getpid(), parent: Self.cliProcess)
        runner.startProcess(Self.cliProcess)
    }

    @Test func aFirstDraftKeepsItsTaskFieldUntilAModelIsAvailable() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.agentModels = []
        let service = try harness.makeService()
        let persona = FakeHost.defaultPersona.id
        let space = try #require(harness.host.spaces(in: persona).first)
        let context = AgentComposerContext(personaID: persona, spaceID: space.id, place: space.name, tab: nil)
        let actions = AgentPanelActions(formatReply: { AttributedString($0) }, openLink: { _ in }, showTab: { _ in }, openAISettings: {}, signIn: { _ in })
        let host = NSHostingController(rootView: AgentComposer(service: service, context: context, actions: actions) { _ in })
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 380, height: 560))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitUntil { descendants(host.view).contains { $0 is NSTextView } }
        let field = try #require(descendants(host.view).compactMap { $0 as? NSTextField }.first)
        let editor = try #require(descendants(host.view).compactMap { $0 as? NSTextView }.first)
        let task = "Compare the reviewed sources."
        editor.insertText(task, replacementRange: NSRange(location: 0, length: 0))
        try await waitUntil { field.stringValue == task }
        field.sendAction(field.action, to: field.target)
        #expect(service.sessions.isEmpty)

        harness.agentModels = [AIModelRef(provider: AIProviderID(), model: "fixture")]
        service.objectWillChange.send()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(!window.isVisible && service.sessions.isEmpty)
        let recovered = try #require(descendants(host.view).compactMap { $0 as? NSTextField }.first)
        #expect(recovered === field && recovered.stringValue == task)
        #expect(context.text == task)
        let reopened = NSHostingController(rootView: AgentComposer(service: service, context: context, actions: actions) { _ in })
        window.contentViewController = reopened
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitUntil { descendants(reopened.view).contains { ($0 as? NSTextField)?.stringValue == task } }
        let reopenedField = try #require(descendants(reopened.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == task })
        reopenedField.sendAction(reopenedField.action, to: reopenedField.target)
        try await waitUntil { service.sessions.count == 1 }
        let session = try #require(service.sessions.first)
        #expect(session.transcript.lastUserMessage == task)
        await service.deleteSession(session.id)
    }

    @Test func aLongTaskCanScrollThroughTheFormInASmallWindow() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        let persona = FakeHost.defaultPersona.id
        let space = try #require(harness.host.spaces(in: persona).first)
        let text = (1...10).map { "Question \($0) about the reviewed document." }.joined(separator: "\n")
        let tab = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Notes", url: URL(string: "https://example.invalid/notes"), isLoading: false, engine: .webKit)
        let draft = AgentComposerContext(personaID: persona, spaceID: space.id, place: space.name, tab: tab, text: text,
                                         problem: "The reviewed document changed. Remove its attachment or reopen the task for the new page.")
        let actions = AgentPanelActions(formatReply: { AttributedString($0) }, openLink: { _ in }, showTab: { _ in }, openAISettings: {}, signIn: { _ in })
        let composer = AgentComposer(service: service, context: draft, actions: actions, permissionNote: "Sites previously allowed to use the camera may keep that access in Chromium agent tabs.") { _ in }
        let host = NSHostingView(rootView: composer)
        let size = NSSize(width: 332, height: 304)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView?.addSubview(host)
        host.frame = NSRect(origin: .zero, size: size)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { view in
            (view.documentView?.bounds.height ?? 0) > size.height && view.contentSize.height > 150
        })
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentSize.height))
        #expect(scroll.documentVisibleRect.maxY >= document.bounds.maxY - 1)
        #expect(!window.isVisible && draft.text == text && service.sessions.isEmpty)
    }

    @Test func theAgentsPersonaPreviewOmitsSitePermissionsWithoutCreatingAPersona() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.agentModels = [.init(provider: AIProviderID(), model: "fixture")]
        let service = try await harness.makeOpenService()
        let persona = FakeHost.defaultPersona.id
        let space = try #require(harness.host.spaces(in: persona).first)
        let context = AgentComposerContext(personaID: persona, spaceID: space.id, place: space.name, tab: nil)
        let actions = AgentPanelActions(formatReply: { AttributedString($0) }, openLink: { _ in }, showTab: { _ in }, openAISettings: {}, signIn: { _ in })
        let message = "Sites previously allowed to use camera may keep that access in Chromium agent tabs."
        let composer = AgentComposer(service: service, context: context, actions: actions, permissionNote: message) { _ in }
        let personas = harness.host.personas.map(\.id)
        let host = NSHostingController(rootView: composer)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 380, height: 560))
        host.view.layoutSubtreeIfNeeded()
        #expect(composer.selectedPermissionNote == message)
        context.usesAgentsPersona = true
        host.view.layoutSubtreeIfNeeded()
        #expect(composer.selectedPermissionNote == nil && service.agentsPersonaPlace == "Agents / Personal")
        context.usesAgentsPersona = false
        #expect(composer.selectedPermissionNote == message)
        #expect(harness.host.personas.map(\.id) == personas && service.sessions.isEmpty && !window.isVisible)
    }

    @Test(arguments: [false, true]) func openingLongConversationShowsFirstQuestionOrLatestReply(hasQuestions: Bool) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, runner) = try start(service, harness)
        for line in 1...32 { runner.emit(.notice("Step \(line)")) }
        try await waitUntil { session.items.last?.kind == .notice("Step 32") }
        if hasQuestions {
            for index in 1...5 {
                let now = Date()
                let card = AgentApproval(ownerID: session.id, clientName: "Fixture", isOutsideClient: false,
                                         kind: .question([]), isSensitive: false, offers: [.cancel("")],
                                         action: "Question \(index)", createdAt: now, deadline: now.addingTimeInterval(600))
                service.approvals.open(card) { _ in }
                service.approvals.setDraftAnswer("Draft \(index)", to: card.id)
            }
        } else {
            runner.emit(.text("Final answer"))
            runner.emit(.turnFinished(.completed))
            try await waitUntil { !session.isTurnRunning && session.items.contains { $0.kind == .reply("Final answer") } }
        }

        let actions = AgentPanelActions(formatReply: { AttributedString($0) }, openLink: { _ in }, showTab: { _ in }, openAISettings: {}, signIn: { _ in })
        let host = NSHostingController(rootView: AgentSessionPanel(service: service, session: session, actions: actions))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 360, height: 430))
        host.view.layoutSubtreeIfNeeded()

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = try #require(descendants(host.view).compactMap { $0 as? NSScrollView }.first { scroll in
            (scroll.documentView?.bounds.height ?? 0) > scroll.contentSize.height * 2
        })
        let document = try #require(scroll.documentView)
        try await waitUntil {
            let visible = scroll.documentVisibleRect
            if hasQuestions {
                guard let firstAnswer = descendants(document).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "Draft 1" }) else { return false }
                return visible.contains(firstAnswer.convert(firstAnswer.bounds, to: document))
            }
            let bottomGap = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            return bottomGap < 32
        }
        #expect(!window.isVisible)
        await service.deleteSession(session.id)
    }

    @Test func draftEffortFollowsTheSelectedCLIPresetAndItsExecutable() throws {
        let one = URL(fileURLWithPath: "/fixture/one/codex"), two = URL(fileURLWithPath: "/fixture/two/codex")
        var provider = AIProviderConfiguration(name: "Fixture", kind: .commandLine(.init(executable: one, agent: .codex)), models: [.init(name: "model")])
        let model = AIModelRef(provider: provider.id, model: "model")
        let first = try #require(AgentComposer.EffortSource(model, providers: [provider]))
        provider.name = "Renamed"
        #expect(AgentComposer.EffortSource(model, providers: [provider]) == first)
        provider.kind = .commandLine(.init(executable: two, agent: .codex))
        #expect(try #require(AgentComposer.EffortSource(model, providers: [provider])) != first)
        provider.kind = .http(.init(format: .messages, baseURL: URL(string: "https://fixture.invalid")!))
        #expect(AgentComposer.EffortSource(model, providers: [provider]) == nil)
        #expect(AgentComposer.EffortSource(model, providers: []) == nil)
    }

    @Test func followupDraftBelongsToOneSessionUntilSubmittedOrDeleted() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (first, runner) = try start(service, harness)
        let (other, otherRunner) = try start(service, harness, task: "Other conversation")

        first.messageDraft = "Unsent follow-up"
        other.messageDraft = "Separate draft"
        #expect(service.session(withID: first.id)?.messageDraft == "Unsent follow-up")
        #expect(runner.sent.count == 1 && otherRunner.sent.count == 1)
        #expect(first.queuedMessages.isEmpty && first.transcript.lastUserMessage == "Summarize this tab")

        first.messageDraft = "/help"
        #expect(throws: AIError.self) { try first.sendDraft() }
        #expect(first.messageDraft == "/help" && first.queuedMessages.isEmpty)
        first.messageDraft = "Send this follow-up"
        try first.sendDraft()
        try first.sendDraft()
        #expect(first.messageDraft.isEmpty && first.queuedMessages == ["Send this follow-up"])
        runner.emit(.turnFinished(.completed))
        try await waitUntil { runner.sent.count == 2 }
        #expect(runner.sent[1] == "Send this follow-up")
        first.messageDraft = "Unsent at deletion"
        await service.deleteSession(first.id)
        #expect(first.messageDraft.isEmpty && other.messageDraft == "Separate draft")
        #expect(otherRunner.sent.count == 1)
    }

    @Test func theResearchSheetKeepsDistinctOutlineRefsAndClearsAnUnavailableSelection() async throws {
        let url = try #require(URL(string: "https://docs.example/article?edition=two#terms"))
        let sourceURL = try #require(URL(string: "https://docs.example/index"))
        let tab = UUID(), document = UUID()
        let manual = AgentResearchPage(url: url, source: .message(UUID()))
        func outline(_ ref: String) -> AgentResearchPage {
            let link = AgentOutlineLink(ref: ref, name: "Terms", fingerprint: "a|link||Terms", url: url)
            return AgentResearchPage(url: url, source: .outline(tab: tab, document: document, address: sourceURL, handle: "t1", link: link))
        }
        let first = outline("e3"), second = outline("e7")
        #expect(first.outlineLabel != second.outlineLabel && first.url == second.url)
        var selected: AgentResearchPage?
        var opens = 0
        func sheet(_ pages: [AgentResearchPage]) -> AgentResearchSheet {
            AgentResearchSheet(pages: pages, choice: Binding(get: { selected }, set: { selected = $0 }),
                               open: { _ in opens += 1; return .opened }, close: {})
        }
        let host = NSHostingController(rootView: sheet([manual, first, second]))
        let window = NSWindow(contentViewController: host)
        host.view.layoutSubtreeIfNeeded()
        #expect(selected == nil && opens == 0)
        selected = second
        host.rootView = sheet([manual, first, second])
        func hasAddressViewport(_ view: NSView) -> Bool {
            if let scroll = view as? NSScrollView, scroll.contentSize.height > 20 { return true }
            return view.subviews.contains(where: hasAddressViewport)
        }
        try await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            return hasAddressViewport(host.view)
        }
        #expect(opens == 0)
        host.rootView = sheet([manual, first])
        try await waitUntil { selected == nil }
        #expect(opens == 0 && !window.isVisible)
    }

    @Test func researchPagesOpenOnlyTheReviewedAddressAndRefuseEverySubsequentNavigation() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let host = harness.host
        let address = URL(string: "https://research.example/doc?q=one")!
        let other = URL(string: "https://notes.example/ref")!
        let (session, runner) = try start(service, harness, task: "Read \(address.absoluteString) and \(other.absoluteString).", mode: .readOnly)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "test"), model: "fixture")))
        let choices = service.researchChoices(for: session)
        #expect(Set(choices.map(\.url)) == [address, other])
        let choice = try #require(choices.first { $0.url == address })
        let forged = AgentResearchPage(url: URL(string: "https://research.example/other")!, source: choice.source)
        #expect(!service.openResearchPage(forged, in: session))
        host.redirects[address] = other
        #expect(service.openResearchPage(choice, in: session))
        let tab = try #require(host.agentTabs(of: session.id).first)
        try await waitUntil { host.tabs.first { $0.id == tab.id }?.isLoading == false }
        #expect(host.tabs.first { $0.id == tab.id }?.url == nil)
        let check = try #require(host.researchLoads[tab.id])
        #expect(!check(address) && !check(other) && !check(forged.url))
        #expect(host.shownTabIDs.isEmpty)
        host.redirects.removeAll()
        #expect(service.openResearchPage(choice, in: session))
        let pending = try #require(host.agentTabs(of: session.id).last)
        session.takeOver()
        session.handBack()
        #expect(host.researchLoads[pending.id]?(address) == false)
        #expect(service.openResearchPage(choice, in: session))
        let excluded = try #require(host.agentTabs(of: session.id).last)
        harness.excludedHosts.value.insert("research.example")
        #expect(host.researchLoads[excluded.id]?(address) == false)
        #expect(!service.openResearchPage(choice, in: session))
        harness.excludedHosts.value.remove("research.example")
        #expect(service.openResearchPage(choice, in: session))
        let stopped = try #require(host.agentTabs(of: session.id).last)
        session.stop()
        #expect(host.researchLoads[stopped.id]?(address) == false)
        #expect(session.reportedTools.contains("open_tab"))
    }

    @Test func researchCopiesRequireTheSameAttachmentDocumentAndSharingOnBothSidesOfARead() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let host = harness.host
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        let address = URL(string: "https://notes.example/ref?exact=1")!
        let tab = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Notes", url: address, isLoading: false, engine: .webKit)
        host.tabs = [tab]
        host.userTabIDs = [tab.id]
        host.pages[address] = (title: "PrivateTitle", text: "PrivateText")
        let (session, runner) = try start(service, harness, task: "Read the notes", attaching: [tab.id])
        spawnCLI(runner, harness)
        let client = try TestClient(harness.location)
        #expect(try await client.hello(ticket: session.ticket?.text).status == .bound)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "test"), model: "fixture")))
        let page = try #require(service.researchChoices(for: session).first)
        #expect(service.openResearchPage(page, in: session))
        let copy = try #require(host.agentTabs(of: session.id).first)
        try await waitUntil { host.tabs.first { $0.id == copy.id }?.url == address }
        #expect(try await client.callTool("list_tabs", [:]).text.contains("PrivateTitle"))
        #expect(try await client.callTool("read_text", ["tab": "t2"]).text.contains("PrivateText"))
        host.beforeReturningContent = { host.tabs[0].documentID = UUID() }
        let answer = try await client.callTool("read_text", ["tab": "t2"])
        #expect(answer.status != .ok && !answer.text.contains("PrivateText"))
        #expect(try await !client.callTool("list_tabs", [:]).text.contains("PrivateTitle"))
        #expect(!service.openResearchPage(page, in: session))
        host.tabs[0] = tab
        service.stopSharing(tab.id, with: session)
        #expect(host.closedTabIDs.contains(copy.id))
        #expect(session.handles.tabs.id(for: "t2") == nil && session.researchPages[copy.id] == nil)
        #expect(service.share(tab, with: session))
        #expect(!service.openResearchPage(page, in: session))
        #expect(service.researchChoices(for: session).first?.source != page.source)
    }

    @Test(arguments: [false, true])
    func keptResearchPagesReceiveFreshSharedHandlesEvenBeforeTheTakeoverNotification(shareImmediately: Bool) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let host = harness.host
        let address = URL(string: "https://research.example/article")!
        let (session, runner) = try start(service, harness, task: "Read " + address.absoluteString)
        let page = try #require(service.researchChoices(for: session).first)
        #expect(service.openResearchPage(page, in: session))
        let id = try #require(host.agentTabs(of: session.id).first?.id)
        try await waitUntil { host.tabs.first?.url == address }
        host.pages[address] = ("Article", "Reviewed article body")
        spawnCLI(runner, harness)
        let client = try TestClient(harness.location)
        #expect(try await client.hello(ticket: session.ticket?.text).status == .bound)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "test"), model: "fixture")))
        #expect(try await client.callTool("list_tabs", [:]).text.contains("t1"))
        #expect(try await client.callTool("read_text", ["tab": "t1"]).status == .ok)
        session.snapshots.counts[id] = 1
        host.tabs[0].agentOwnerID = nil
        host.userTabIDs.insert(id)
        #expect(try await client.callTool("read_text", ["tab": "t1"]).code == "P17")
        host.tabs[0].documentID = UUID()
        if shareImmediately { #expect(service.share(host.tabs[0], with: session)) }
        host.agentTabDidReport?(session.id, id, .takenOver)
        if !shareImmediately { #expect(service.share(host.tabs[0], with: session)) }
        #expect(session.researchPages[id] == nil && session.snapshots.counts[id] == nil)
        #expect(try await client.callTool("read_text", ["tab": "t1"]).code == "tabNotFound")
        #expect(try await client.callTool("list_tabs", ["scope": "shared"]).text.contains("t2"))
        #expect(try await client.callTool("read_text", ["tab": "t2"]).text.contains("Reviewed article body"))
        service.stopSharing(id, with: session)
        #expect(host.closedTabIDs.isEmpty && host.tabs.first?.id == id)
        #expect(try await client.callTool("read_text", ["tab": "t2"]).code == "tabNotFound")
        #expect(service.researchChoices(for: session) == [page])
    }

    @Test func aSessionDropsResearchHandlesAndOutlinesAcrossRepeatedClosesAndItsOwnEnd() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let host = harness.host
        let (session, _) = try start(service, harness, task: "Read https://research.example/article")
        let source = try #require(service.researchChoices(for: session).first)
        for _ in 0..<25 {
            #expect(service.openResearchPage(source, in: session))
            let tab = try #require(host.agentTabs(of: session.id).first)
            let handle = session.handles.tabs.handle(for: tab.id)
            session.snapshots.counts[tab.id] = 1
            host.closeAgentTab(tab.id)
            host.agentTabDidReport?(session.id, tab.id, .closed)
            #expect(session.researchPages.isEmpty && session.snapshots.counts.isEmpty && session.handles.tabs.id(for: handle) == nil)
        }
        #expect(service.openResearchPage(source, in: session))
        let remaining = try #require(host.agentTabs(of: session.id).first)
        let handle = session.handles.tabs.handle(for: remaining.id)
        await session.end(keepingThread: false)
        #expect(session.researchPages.isEmpty && session.handles.tabs.id(for: handle) == nil)
        #expect(host.agentTabs(of: session.id).isEmpty)
    }

    @Test func researchChoicesRequireAnEligibleHTTPAddressInTheCurrentPersona() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let host = harness.host
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        let addresses = ["https://127.0.0.1/doc", "http://router.local", "http://router", "https://docs.internal/doc",
                         "http://user:password@research.example/doc", "https://research.example:8000/private", "file:///tmp/doc"]
        let tabs = addresses.map {
            AgentTabInfo(id: UUID(), spaceID: space.id, title: "", url: URL(string: $0), isLoading: false, engine: .webKit)
        }
        host.tabs = tabs
        host.userTabIDs = Set(tabs.map(\.id))
        let (session, _) = try start(service, harness, task: "Open https://notes.example/ref", attaching: tabs.map(\.id))
        let only = try #require(service.researchChoices(for: session).first)
        #expect(service.researchChoices(for: session).map(\.url.absoluteString) == ["https://notes.example/ref"])
        host.spacesByPersona[session.personaID] = []
        #expect(service.researchChoices(for: session).isEmpty)
        #expect(!service.openResearchPage(only, in: session))
    }

    @Test func aManualOutlineChoiceRechecksTheLiveLinkAndKeepsItsAddressOutOfModelRequests() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService(), host = harness.host
        let page = try await FixturePage("form")
        _ = try await page.evaluate("""
            document.body.innerHTML = '<a href="/article?entry=first#top">Read more</a> <a href="/article?entry=second#top">Read more</a> <a href="https://elsewhere.example/out">Outside</a>';
            """)
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        let source = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Source", url: page.url, isLoading: false, engine: .webKit)
        host.tabs = [source]
        host.userTabIDs = [source.id]
        host.webContents[source.id] = page.contents
        let (session, runner) = try start(service, harness, attaching: [source.id])
        let client = try await connectQuestionClient(session, runner, harness)
        func snapshot(_ arguments: [String: AgentJSON] = [:]) async -> AgentToolResult {
            var arguments = arguments
            arguments["tab"] = .string(session.handles.tabs.handle(for: source.id))
            return await service.toolHost().run(AgentToolCall(name: "snapshot", arguments: arguments), in: session, searchesHistory: false)
        }
        #expect(service.manualOutlineLinks(for: session).isEmpty)
        let partial = await snapshot(["max_chars": 1])
        #expect(partial.status == .ok && service.manualOutlineLinks(for: session).isEmpty)
        let outline = await snapshot()
        #expect(outline.status == .ok && !outline.text.contains("entry=first") && !outline.text.contains("entry=second"))
        let choices = service.manualOutlineLinks(for: session)
        try #require(choices.count == 2)
        let picked = choices[1]
        #expect(choices.map(\.url.query) == ["entry=first", "entry=second"])
        #expect(choices.map(\.outlineLabel) == ["t1 [e1] · Read more", "t1 [e2] · Read more"])
        #expect(service.researchChoices(for: session).allSatisfy { $0.url != picked.url })
        let proposed = try await client.callTool("open_tab", ["url": .string(picked.url.absoluteString)])
        #expect(proposed.status == .refused && service.approvals.pending.isEmpty)
        #expect(!service.openResearchPage(picked, in: session) && host.openedOwners.isEmpty)
        #expect(session.scope.written(picked.url) != .opens)
        func changeHref(to href: String) async throws {
            _ = try await page.evaluate("document.querySelectorAll('a')[1].href = '\(href)'")
        }
        func replacement(for choice: AgentResearchPage) async throws -> AgentResearchPage {
            let result = await service.reviewManualResearchPage(choice, in: session)
            guard case .changed(let next) = result else {
                throw NSError(domain: "Expected an updated manual link", code: 1)
            }
            return next
        }

        try await changeHref(to: "/article?entry=changed#top")
        host.onPageScript = { withUnsafeCurrentTask { $0?.cancel() } }
        let cancelled = await Task { @MainActor in await service.reviewManualResearchPage(picked, in: session) }.value
        #expect(cancelled == .unavailable && host.openedOwners.isEmpty)
        host.onPageScript = nil
        let updated = try await replacement(for: picked)
        #expect(updated.originalOutlineChoice == picked && updated.url.query == "entry=changed")
        #expect(service.manualOutlineLinks(for: session) == choices && host.openedOwners.isEmpty)
        #expect(session.snapshots.records[source.id]?.refs["e2"]?.href == picked.url)
        #expect(!service.openResearchPage(updated, in: session))
        let refused = try await client.callTool("open_tab", ["url": .string(updated.url.absoluteString)])
        #expect(refused.status == .refused && service.approvals.pending.isEmpty && session.scope.written(updated.url) != .opens)

        try await changeHref(to: "/article?entry=third#end")
        let third = try await replacement(for: updated)
        #expect(third.originalOutlineChoice == picked && third.url.fragment == "end")
        try await changeHref(to: "/article?entry=second#top")
        let reverted = try await replacement(for: third)
        #expect(reverted.originalOutlineChoice == picked && reverted.url == picked.url && reverted != picked)
        try await changeHref(to: "https://elsewhere.example/out")
        #expect(await service.reviewManualResearchPage(reverted, in: session) == .unavailable)
        try await changeHref(to: "https://name:pw@fixture.example/article")
        #expect(await service.reviewManualResearchPage(picked, in: session) == .unavailable)
        try await changeHref(to: "/article?entry=changed#top")
        _ = try await page.evaluate("document.querySelectorAll('a')[1].textContent = 'Different link'")
        #expect(await service.reviewManualResearchPage(updated, in: session) == .staleLink)
        _ = try await page.evaluate("document.querySelectorAll('a')[1].textContent = 'Read more'")
        #expect(host.openedOwners.isEmpty)
        let occupied = (0..<AgentLimits.agentTabs).map { _ in
            AgentTabInfo(id: UUID(), spaceID: space.id, title: "Occupied", url: source.url, isLoading: false, engine: .webKit, agentOwnerID: session.id)
        }
        host.onPageScript = { host.tabs += occupied }
        #expect(await service.reviewManualResearchPage(updated, in: session) == .unavailable && host.openedOwners.isEmpty)
        host.onPageScript = nil
        host.tabs = [source]
        #expect(await service.reviewManualResearchPage(updated, in: session) == .opened)
        let copy = try #require(host.agentTabs(of: session.id).first)
        let mayLoad = try #require(host.researchLoads[copy.id])
        #expect(!mayLoad(picked.url) && mayLoad(updated.url) && !mayLoad(updated.url))
        #expect(session.scope.written(updated.url) != .opens && service.manualOutlineLinks(for: session) == choices)

        // A fresh model outline supersedes the original proof, so the sheet must use its new row.
        let revisedOutline = await snapshot()
        #expect(revisedOutline.status == .ok && !revisedOutline.text.contains("entry=changed"))
        #expect(await service.reviewManualResearchPage(updated, in: session) == .unavailable)
        #expect(service.manualOutlineLinks(for: session).contains { $0.url == updated.url && $0.originalOutlineChoice == nil })
        service.stopSharing(source.id, with: session)
        #expect(host.agentTabs(of: session.id).isEmpty && service.manualOutlineLinks(for: session).isEmpty)
        #expect(service.share(source, with: session))
        _ = await snapshot()
        #expect(await service.reviewManualResearchPage(picked, in: session) == .unavailable)
        let fresh = try #require(service.manualOutlineLinks(for: session).first)
        host.onPageScript = { harness.excludedHosts.value.insert("fixture.example") }
        #expect(await service.reviewManualResearchPage(fresh, in: session) == .unavailable)
        harness.excludedHosts.value.remove("fixture.example")
        host.onPageScript = {
            session.takeOver()
            session.handBack()
        }
        #expect(await service.reviewManualResearchPage(fresh, in: session) == .unavailable)
        host.onPageScript = nil
        _ = await snapshot()
        let beforeStop = try #require(service.manualOutlineLinks(for: session).first)
        host.onPageScript = { session.stop() }
        #expect(await service.reviewManualResearchPage(beforeStop, in: session) == .unavailable)
        host.onPageScript = nil
        _ = await snapshot()
        let beforeReload = try #require(service.manualOutlineLinks(for: session).first)
        host.onPageScript = { host.tabs[0].documentID = UUID() }
        #expect(await service.reviewManualResearchPage(beforeReload, in: session) == .unavailable)
        #expect(host.agentTabs(of: session.id).isEmpty)
    }

    // MARK: Tickets

    @Test func cancellingOneGatedCallReleasesOnlyItsWaitAndCannotRunItAfterHandBack() async throws {
        let gate = AgentGate(isOpen: false)
        var stopped: Bool?
        var continued: Bool?
        let cancelled = Task { stopped = await gate.wait(timeout: .seconds(30)) }
        let remaining = Task { continued = await gate.wait(timeout: .seconds(30)) }
        await Task.yield()
        cancelled.cancel()
        try await waitUntil { stopped != nil }
        #expect(stopped == false)
        #expect(continued == nil)
        gate.open()
        await remaining.value
        #expect(continued == true)
        #expect(stopped == false)
    }

    private func connectQuestionClient(_ session: AgentSession, _ runner: FakeRunner, _ harness: Harness) async throws -> TestClient {
        spawnCLI(runner, harness)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "local"), model: "fixture")))
        try await waitUntil { harness.socketExists && session.state == .running }
        let client = try TestClient(harness.location)
        #expect(try await client.hello(ticket: session.ticket?.text).status == .bound)
        return client
    }

    @Test func completedTurnListsOnlyItsSuccessfulLivePageReads() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService(), host = harness.host
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        func tab(_ path: String) -> AgentTabInfo {
            AgentTabInfo(id: UUID(), spaceID: space.id, title: "Same title", url: URL(string: "https://fixture.example/" + path),
                         isLoading: false, engine: .webKit)
        }
        let one = tab("first"), two = tab("second"), unrelated = tab("third")
        host.tabs = [one, two, unrelated]
        host.userTabIDs = Set(host.tabs.map(\.id))
        let (session, runner) = try start(service, harness, attaching: [one.id, two.id])
        let client = try await connectQuestionClient(session, runner, harness)
        func read(_ handle: String) async throws -> AgentToolResult {
            try await client.callTool("read_text", ["tab": .string(handle)])
        }
        for handle in ["t1", "t1", "t2"] { try #require(try await read(handle).status == .ok) }
        #expect(try await read("t3").status != .ok)
        runner.emit(.text("Another page I mention: t8 https://model.example/invented."))
        runner.emit(.turnFinished(.completed))
        try await waitUntil { session.state == .done }
        let list = try #require(session.items.last).pagesRead
        try #require(list.map(\.handle) == ["t1", "t2"])
        #expect(list.compactMap { service.currentReadPage($0, in: session)?.id } == [one.id, two.id])
        var refreshes = 0
        let observer = session.objectWillChange.sink { refreshes += 1 }
        defer { observer.cancel() }
        host.userTabAddressDidChange?(unrelated.id)
        #expect(refreshes == 0)
        host.tabs[0].url = URL(string: "https://fixture.example/first#chapter")
        host.userTabAddressDidChange?(one.id)
        #expect(refreshes == 1 && service.currentReadPage(list[0], in: session) == nil)
        host.tabs[0].url = one.url
        host.userTabAddressDidChange?(one.id)
        #expect(refreshes == 2 && service.currentReadPage(list[0], in: session)?.id == one.id)
        try session.send("Continue without reading.")
        runner.emit(.text("t1 and t2"))
        runner.emit(.turnFinished(.completed))
        try await waitUntil { session.state == .done }
        #expect(session.items.last?.pagesRead == [])
        try session.send("Try again.")
        _ = try await read("t1")
        runner.emit(.turnFailed(.cancelled))
        try await waitUntil { !session.isTurnRunning }
        session.retryLastMessage()
        try #require(try await read("t2").status == .ok)
        runner.emit(.turnFinished(.completed))
        try await waitUntil { session.state == .done }
        #expect(session.items.last?.pagesRead.map(\.handle) == ["t2"])

        host.tabs[0].documentID = UUID()
        #expect(service.currentReadPage(list[0], in: session) == nil)
        harness.excludedHosts.value.insert("fixture.example")
        #expect(service.currentReadPage(list[1], in: session) == nil)
        harness.excludedHosts.value.remove("fixture.example")
        service.stopSharing(two.id, with: session)
        try #require(service.share(two, with: session))
        #expect(service.currentReadPage(list[1], in: session) == nil)
        #expect(host.openedOwners.isEmpty && host.shownTabIDs.isEmpty)
    }

    @Test func anAttentionNotificationCarriesOnlyItsOwnerAndGenericTitle() throws {
        let owner = UUID()
        let request = AgentAttention.request(for: owner)
        #expect(request.identifier == AgentAttention.identifier(for: owner))
        #expect(AgentAttention.ownerID(in: request.identifier) == owner)
        #expect(request.identifier != AgentAttention.identifier(for: UUID()))
        #expect(request.content.title == "An agent is waiting for you in Arch")
        #expect(request.content.subtitle.isEmpty && request.content.body.isEmpty && request.content.userInfo.isEmpty)
        let foreign = ["", owner.uuidString, "download." + owner.uuidString, request.identifier + "tail", "other." + request.identifier,
                       request.identifier.replacingOccurrences(of: owner.uuidString, with: "malformed")]
        for identifier in foreign { #expect(AgentAttention.ownerID(in: identifier) == nil) }
    }

    @Test func aWaitingOwnerNotifiesOnceAndLateAttentionCannotSelectAnotherSession() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        let (first, _) = try start(service, harness, task: "Private first task")
        let (other, _) = try start(service, harness, task: "Private second task")
        #expect(!service.pendingAttention(for: first.id) && !service.pendingAttention(for: other.id))

        func question(_ owner: UUID, _ text: String) -> AgentApproval {
            AgentApproval(ownerID: owner, clientName: "Fixture", isOutsideClient: false, kind: .question([]), isSensitive: false,
                          offers: [.cancel("")], action: "The agent asks you a question", agentSays: text,
                          createdAt: Date(), deadline: Date().addingTimeInterval(30))
        }
        let firstQuestion = question(first.id, "Private first question")
        let secondQuestion = question(first.id, "Private second question")
        let otherQuestion = question(other.id, "Private other question")
        service.approvals.open(firstQuestion) { _ in }
        service.approvals.open(secondQuestion) { _ in }
        service.approvals.open(otherQuestion) { _ in }
        #expect(harness.attentionOwners == [first.id, other.id])
        #expect(service.pendingAttention(for: first.id) && service.pendingAttention(for: other.id))
        #expect(!service.pendingAttention(for: UUID()))
        let deliveredOwner = try #require(AgentAttention.ownerID(in: AgentAttention.request(for: first.id).identifier))
        #expect(await service.approvals.answer(firstQuestion.id, with: .answer("First answer")))
        #expect(service.pendingAttention(for: deliveredOwner))
        #expect(await service.approvals.answer(secondQuestion.id, with: .cancel("")))
        #expect(!service.pendingAttention(for: deliveredOwner) && service.pendingAttention(for: other.id))
        other.stop()
        #expect(!service.pendingAttention(for: other.id))
        #expect(await !service.approvals.answer(otherQuestion.id, with: .answer("late")))
        #expect(harness.attentionOwners == [first.id, other.id])

        let later = question(first.id, "New private question")
        service.approvals.open(later) { _ in }
        #expect(harness.attentionOwners == [first.id, other.id, first.id])
        #expect(service.pendingAttention(for: first.id) && !service.pendingAttention(for: other.id))
        #expect(await service.approvals.answer(later.id, with: .cancel("")))
    }

    @Test func cancellingOrDisconnectingOneQuestionPreservesTheOthers() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        let (session, runner) = try start(service, harness, mode: .readOnly)
        let client = try await connectQuestionClient(session, runner, harness)
        var departing: TestClient? = try TestClient(harness.location)
        _ = try await departing?.hello(ticket: session.ticket?.text)
        func ask(_ label: String, id: Int, on client: TestClient) throws {
            let call = AgentToolCall(name: "ask_user", arguments: ["question": .string(label)])
            try client.connection.send(.request(id: .number(id), method: AgentControlMethod.toolsCall, params: call.params))
        }
        func result(_ id: Int) async throws -> AgentToolResult {
            while true {
                if case .result(.number(id), let payload) = try await client.receive() {
                    return try payload.decode(as: AgentToolResult.self)
                }
            }
        }
        try ask("Cancelled", id: 41, on: client)
        try ask("Survivor", id: 42, on: client)
        try ask("Disconnected", id: 42, on: #require(departing))
        try await waitUntil { service.approvals.pending.count == 3 }
        let cancelled = try #require(service.approvals.pending.first { $0.agentSays == "Cancelled" })
        let survivor = try #require(service.approvals.pending.first { $0.agentSays == "Survivor" })
        let disconnected = try #require(service.approvals.pending.first { $0.agentSays == "Disconnected" })
        #expect(service.approvals.pending.allSatisfy { $0.ownerID == session.id })
        #expect(survivor.deadline.timeIntervalSince(survivor.createdAt) == 600)
        #expect(session.state == .waitingForUser && service.spacesWaitingForUser == [session.spaceID])
        #expect(harness.host.shownPanels.isEmpty)

        try client.connection.send(.notification(method: AgentControlMethod.toolsCancelNotification, params: AgentToolCancel(call: 41).params))
        #expect(try await result(41).code == "cancelled")
        // Releasing the other connection closes its socket with call 42 still outstanding.
        departing = nil
        try await waitUntil { service.approvals.pending.map(\.id) == [survivor.id] && runner.activeToolCalls == 1 }
        #expect(session.state == .waitingForUser)
        #expect(await !service.approvals.answer(cancelled.id, with: .answer("late")))
        #expect(await !service.approvals.answer(disconnected.id, with: .answer("late")))
        let answer = "Only this CLI call gets the fixture answer."
        var reported: [String] = []
        session.taskEvent = { _, text in reported.append(text) }
        #expect(await service.approvals.answer(survivor.id, with: .answer(answer)))
        let response = try await result(42)
        #expect(response.status == .ok && response.structured == ["answer": .string(answer)])
        #expect(session.state == .running && service.spacesWaitingForUser.isEmpty)
        #expect(!reported.joined().contains(answer))
        let steps = session.items.compactMap { item -> AgentStep? in
            if case .step(let step) = item.kind { return step }
            return nil
        }
        #expect(steps.map(\.sentence) == ["Asked you a question"])
        let entries = service.activity.entries.filter { $0.sessionID == session.id && $0.tool == "ask_user" }
        #expect(entries.map(\.decision) == [.approved])
        #expect(!String(decoding: try JSONEncoder().encode(entries), as: UTF8.self).contains(answer))

        // A disconnect before the call reaches its card must also release the CLI's idle timer.
        session.takeOver()
        var gated: TestClient? = try TestClient(harness.location)
        _ = try await gated?.hello(ticket: session.ticket?.text)
        let ask = AgentToolCall(name: "ask_user", arguments: ["question": "From a departed connection"])
        try gated?.connection.send(.request(id: .string("waiting"), method: AgentControlMethod.toolsCall, params: ask.params))
        try await waitUntil { runner.activeToolCalls == 1 }
        gated = nil
        try await waitUntil { runner.activeToolCalls == 0 }
        session.handBack()
        #expect(service.approvals.pending.isEmpty && session.callsThisSession == 3)
    }

    enum ResearchConsentChange: CaseIterable {
        case approve, deny, reload, unload, query, path, close, exclude, removeSpace, stopSharingAndReattach, takeOverAndHandBack, stop, cancelCall
    }

    @Test(arguments: ResearchConsentChange.allCases)
    func ticketOpensOnlyTheExactResearchPageStillUnderReview(_ change: ResearchConsentChange) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let host = harness.host
        let service = try harness.makeService()
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        let address = URL(string: "https://review.example/reports/one?version=a#detail")!
        let source = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Source title sentinel", url: address, isLoading: false, engine: .webKit)
        host.tabs = [source]
        host.userTabIDs = [source.id]
        let (session, runner) = try start(service, harness, task: "Check the shared reference", attaching: [source.id], mode: .readOnly)
        let client = try await connectQuestionClient(session, runner, harness)
        let call = AgentToolCall(name: "open_tab", arguments: ["url": .string(address.absoluteString)])
        try client.connection.send(.request(id: .number(81), method: AgentControlMethod.toolsCall, params: call.params))
        try await waitUntil { !service.approvals.pending.isEmpty }
        let card = try #require(service.approvals.pending.first)
        #expect(card.ownerID == session.id && card.kind == .openSessionResearch(address) && card.connectionID != nil)
        #expect(session.state == .waitingForUser && host.openedOwners.isEmpty && host.shownTabIDs.isEmpty)
        #expect(!service.activity.entries.contains { $0.tool == "open_tab" })
        switch change {
        case .approve, .deny: break
        case .reload: host.tabs[0].documentID = UUID()
        case .unload: host.tabs[0].isLoaded = false
        case .query: host.tabs[0].url = URL(string: "https://review.example/reports/one?version=b#detail")
        case .path: host.tabs[0].url = URL(string: "https://review.example/reports/two?version=a#detail")
        case .close: host.tabs.removeAll()
        case .exclude: harness.excludedHosts.value.insert("review.example")
        case .removeSpace: host.spacesByPersona[session.personaID]?.removeAll { $0.id == space.id }
        case .stopSharingAndReattach:
            service.stopSharing(source.id, with: session)
            try #require(service.share(source, with: session))
        case .takeOverAndHandBack:
            session.takeOver()
            session.handBack()
        case .stop: session.stop()
        case .cancelCall:
            try client.connection.send(.notification(method: AgentControlMethod.toolsCancelNotification, params: AgentToolCancel(call: 81).params))
            try await waitUntil { !service.approvals.isPending(card.id) }
        }
        let counted = await service.approvals.answer(card.id, with: change == .deny ? .deny : .allowOnce)
        let response: AgentToolResult
        while true {
            if case .result(.number(81), let payload) = try await client.receive() {
                response = try payload.decode(as: AgentToolResult.self)
                break
            }
        }
        #expect(host.shownTabIDs.isEmpty && host.shownPanels.isEmpty && service.approvals.pending.isEmpty)
        if change == .approve {
            let copies = host.agentTabs(of: session.id)
            try #require(copies.count == 1)
            let copy = try #require(copies.first)
            let handle = try #require(response.structured?["tab"]?.stringValue)
            #expect(counted && copy.spaceID == space.id && response.status == .ok)
            #expect(response.structured == ["tab": .string(handle)] && session.handles.tabs.id(for: handle) == copy.id)
            #expect(response.text.contains(handle) && !response.text.contains(address.absoluteString) && !response.text.contains(source.title))
            let entries = service.activity.entries.filter { $0.sessionID == session.id && $0.tool == "open_tab" }
            #expect(entries.map(\.decision) == [.approved])
            #expect(!String(decoding: try JSONEncoder().encode(entries), as: UTF8.self).contains("version=a"))
            let step = session.items.compactMap { if case .step(let item) = $0.kind { return item }; return nil }.last
            #expect(step?.tabID == copy.id && step?.tabHandle == handle)
            try await waitUntil { host.agentTabs(of: session.id).first?.url == address }
            #expect(host.researchLoads[copy.id]?(address) == false)
        } else {
            #expect(response.status != .ok && response.structured?["tab"] == nil)
            #expect(host.openedOwners.isEmpty && host.researchLoads.isEmpty)
            #expect(!service.activity.entries.contains { $0.tool == "open_tab" && $0.outcome == "ok" })
        }
    }

    enum OutlineConsentChange: CaseIterable { case deny, href, document, exclude, takeOver, reattach, reload, unload, close }

    @Test(arguments: OutlineConsentChange.allCases)
    func ticketCannotOpenAChangedOrDeclinedOutlineLink(_ change: OutlineConsentChange) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService(), host = harness.host
        let page = try await FixturePage("form")
        _ = try await page.evaluate("document.body.innerHTML = '<a href=\"/report?version=one\">Report</a>'")
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        let source = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Report", url: page.url, isLoading: false, engine: .webKit)
        host.tabs = [source]
        host.userTabIDs = [source.id]
        host.webContents[source.id] = page.contents
        let (session, runner) = try start(service, harness, attaching: [source.id])
        let client = try await connectQuestionClient(session, runner, harness)
        let arguments: [String: AgentJSON] = ["tab": "t1", "ref": "e1"]
        let unseen = try await client.callTool("open_tab", arguments)
        try #require(unseen.status == .refused && harness.attentionOwners.isEmpty)
        let snapshot = try await client.callTool("snapshot", ["tab": "t1"])
        try #require(snapshot.status == .ok && snapshot.text.contains("[e1]"))
        let proposal = Task { try await client.callTool("open_tab", arguments) }
        try await waitUntil { !service.approvals.pending.isEmpty }
        let card = try #require(service.approvals.pending.first)
        let address = URL(string: "https://fixture.example/report?version=one")!
        try #require(card.kind == .openSessionResearch(address, source: "t1 [e1] · Report") && host.openedOwners.isEmpty)
        host.userDocumentDidEnd?(UUID(), source.documentID)
        host.userDocumentDidEnd?(source.id, UUID())
        #expect(service.approvals.isPending(card.id))
        switch change {
        case .reload, .unload, .close:
            switch change {
            case .reload: host.tabs[0].documentID = UUID()
            case .unload: host.tabs[0].isLoaded = false
            default: host.tabs.removeAll()
            }
            host.userDocumentDidEnd?(source.id, source.documentID)
            #expect(!service.approvals.isPending(card.id))
        case .deny: break
        case .href: _ = try await page.evaluate("document.querySelector('a').href = '/report?version=two'")
        case .document: host.onPageScript = { host.tabs[0].documentID = UUID() }
        case .exclude: host.onPageScript = { harness.excludedHosts.value.insert("fixture.example") }
        case .takeOver:
            host.onPageScript = {
                session.takeOver()
                session.handBack()
            }
        case .reattach:
            service.stopSharing(source.id, with: session)
            try #require(service.share(source, with: session))
        }
        _ = await service.approvals.answer(card.id, with: change == .deny ? .deny : .allowOnce)
        let result = try await proposal.value
        switch change {
        case .deny: #expect(result.status == .denied)
        case .reload, .unload, .close, .reattach:
            #expect(result.status == .stale && result.text.contains("fresh outline"))
        case .href, .document, .exclude: #expect(result.status == .stale)
        case .takeOver: #expect(result.status == .refused)
        }
        #expect(result.structured?["tab"] == nil && !result.text.contains("version="))
        #expect(host.openedOwners.isEmpty && host.researchLoads.isEmpty && service.approvals.pending.isEmpty)
    }

    @Test func ticketRefusesUnreviewableResearchAddressesWithoutShowingACard() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        let url = "https://review.example/report?edition=public#summary"
        let (session, runner) = try start(service, harness, task: "Review " + url)
        let client = try await connectQuestionClient(session, runner, harness)
        // A mistaken card must finish promptly and be detectable even after its deadline.
        service.sessionQuestionWindow = 0.1
        let refused: [[String: AgentJSON]] = [
            [:], ["url": 17], ["url": .string(url), "engine": "webkit"], ["ref": "e1", "tab": "t1"],
            ["tab": "t1"], ["ref": "e1"], ["url": .string(url), "tab": "t1"],
            ["url": .string(url), "ref": "e1", "tab": "t1"],
            ["url": "https://review.example/other?edition=public#summary"],
            ["url": "https://review.example/report?edition=private#summary"],
            ["url": "https://review.example/report?edition=public#other"], ["url": "file:///fixture"],
        ]
        for arguments in refused {
            let response = try await client.callTool("open_tab", arguments)
            #expect(response.status != .ok && response.status != .timeout && response.structured?["tab"] == nil)
        }
        #expect(session.state == .running && service.approvals.pending.isEmpty && harness.host.openedOwners.isEmpty)
        #expect(harness.host.shownTabIDs.isEmpty && harness.attentionOwners.isEmpty)
    }

    @Test(arguments: [false, true])
    func ineligibleSharedSourceCannotSupplyAFreshResearchRequest(unloaded: Bool) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.now = Date()
        let service = try harness.makeService()
        let host = harness.host
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        let address = URL(string: "https://review.example/pinned?version=one")!
        let tab = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Pinned", url: address, isLoading: false, engine: .webKit)
        host.tabs = [tab]
        host.userTabIDs = [tab.id]
        let (session, runner) = try start(service, harness, task: "Check the attached page", attaching: [tab.id])
        let client = try await connectQuestionClient(session, runner, harness)
        let previous = try #require(service.researchChoices(for: session).first)
        if unloaded {
            // A pinned tab's placeholder keeps the URL when the browser replaces its live web contents.
            host.tabs[0].isLoaded = false
            host.tabs[0].documentID = UUID()
        } else {
            host.tabs[0].isLiveFolderItem = true
        }
        #expect(!session.permits(previous, host: host, allowsAI: { _ in true }))
        service.sessionQuestionWindow = 0.05
        let result = try await client.callTool("open_tab", ["url": .string(address.absoluteString)])
        #expect(result.status == .refused)
        #expect(harness.attentionOwners.isEmpty && host.openedOwners.isEmpty && service.researchChoices(for: session).isEmpty)
    }

    enum ChangeBeforeTabConsent: CaseIterable { case reload, navigate, close, unload, liveFolderItem, exclude, revoke, takeOver, stop, decline }

    @Test(arguments: ChangeBeforeTabConsent.allCases)
    func aTabRequestCannotShareAfterItsReviewedChoiceChanges(_ change: ChangeBeforeTabConsent) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        let (session, runner) = try start(service, harness)
        let client = try await connectQuestionClient(session, runner, harness)
        let tab = AgentTabInfo(id: UUID(), spaceID: session.spaceID, title: "Private choice", url: URL(string: "https://fixture.invalid/private"), isLoading: false, engine: .webKit)
        harness.host.tabs = [tab]
        harness.host.userTabIDs = [tab.id]
        let request = Task { try await client.callTool("request_tab", ["reason": "Read the chosen page", "access": "read"]) }
        try await waitUntil { !service.approvals.pending.isEmpty }
        let card = try #require(service.approvals.pending.first)
        #expect(card.kind == .shareSessionTab([tab]) && session.state == .waitingForUser)
        switch change {
        case .reload: harness.host.tabs[0].documentID = UUID()
        case .navigate: harness.host.tabs[0].url = URL(string: "https://fixture.invalid/new")
        case .close: harness.host.tabs.removeAll()
        case .unload: harness.host.tabs[0].isLoaded = false
        case .liveFolderItem:
            harness.host.tabs[0].isLiveFolderItem = true
            #expect(!service.canReattach(tab, in: session.personaID))
            let context = AgentComposerContext(personaID: session.personaID, spaceID: session.spaceID, place: "Home", tab: tab)
            let reviewed = context.sessionStart(task: "Read", mode: .readOnly, allowsAI: { _ in true })
            #expect(throws: AgentService.SessionError.self) { try service.startSession(reviewed) }
        case .exclude: harness.excludedHosts.value.insert("fixture.invalid")
        case .revoke:
            #expect(service.share(tab, with: session))
            service.stopSharing(tab.id, with: session)
        case .takeOver:
            session.takeOver()
            session.handBack()
        case .stop: session.stop()
        case .decline: break
        }
        _ = await service.approvals.answer(card.id, with: change == .decline ? .deny : .tab(tab.id))
        let reply = try await request.value
        #expect(reply.status != .ok && service.approvals.pending.isEmpty && session.handles.sharedTabIDs.isEmpty)
        #expect(!reply.text.contains(tab.title) && !reply.text.contains("fixture.invalid"))
        #expect(reply.structured?["tab"] == nil)
    }

    @Test func aSessionStartsAtMostInSettingsMode() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        service.setNewSessionMode(.readOnly)
        let (session, _) = try start(service, harness, mode: .actInAgentTabs)
        #expect(session.mode == .readOnly)
    }

    @Test func theModelCannotExpandAReadRequestOrReuseARevokedHandle() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        let (session, runner) = try start(service, harness, mode: .actInAgentTabs)
        let client = try await connectQuestionClient(session, runner, harness)
        let tab = AgentTabInfo(id: UUID(), spaceID: session.spaceID, title: "Report", url: URL(string: "https://fixture.invalid/private"), isLoading: false, engine: .webKit)
        harness.host.tabs = [tab]
        harness.host.userTabIDs = [tab.id]
        let arguments: [String: AgentJSON] = ["reason": "Review the report", "access": "read"]
        let acting = try await client.callTool("request_tab", ["reason": "Use this tab", "access": "act"])
        let preselected = try await client.callTool("request_tab", ["reason": "Use this tab", "access": "read", "tab": .string(tab.id.uuidString)])
        #expect(acting.status != .ok && preselected.status != .ok && service.approvals.pending.isEmpty)
        #expect(session.handles.sharedTabIDs.isEmpty)

        #expect(service.share(tab, with: session))
        #expect(session.handles.tabs.id(for: "t1") == tab.id)
        let existing = try await client.callTool("request_tab", arguments)
        #expect(service.approvals.pending.isEmpty && session.handles.sharedTabIDs == [tab.id])
        #expect(existing.status == .denied && existing.structured?["tab"] == nil)
        service.stopSharing(tab.id, with: session)
        let secondClient = try TestClient(harness.location)
        _ = try await secondClient.hello(ticket: session.ticket?.text)
        let call = Task { try await client.callTool("request_tab", arguments) }
        try await waitUntil { !service.approvals.pending.isEmpty }
        let card = try #require(service.approvals.pending.first)
        let concurrent = Task { try await secondClient.callTool("request_tab", arguments) }
        try await waitUntil { service.approvals.pending.count == 2 }
        let otherCard = try #require(service.approvals.pending.first { $0.id != card.id })
        #expect(await service.approvals.answer(card.id, with: .tab(tab.id)))
        let result = try await call.value
        _ = await service.approvals.answer(otherCard.id, with: .tab(tab.id))
        let otherResult = try await concurrent.value
        #expect(otherResult.status != .ok && otherResult.structured?["tab"] == nil)
        #expect(result.status == .ok && result.structured == ["tab": "t2", "access": "read"])
        #expect(session.handles.tabs.id(for: "t1") == nil && session.handles.tabs.id(for: "t2") == tab.id)
        let oldRead = try await client.callTool("read_text", ["tab": "t1"])
        #expect(oldRead.status != .ok)
    }

    enum QuestionEnd: CaseIterable { case stop, takeOver, completed, failed, processExit, delete, quit }

    @Test(arguments: QuestionEnd.allCases) func endingAQuestionRejectsItsLateAnswer(_ end: QuestionEnd) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        let (session, runner) = try start(service, harness)
        let client = try await connectQuestionClient(session, runner, harness)
        let question = Task { try await client.callTool("ask_user", ["question": "First question"]) }
        try await waitUntil { service.approvals.pending.count == 1 }
        let old = try #require(service.approvals.pending.first)
        switch end {
        case .stop: session.stop()
        case .takeOver: session.takeOver()
        case .completed: runner.emit(.turnFinished(.completed))
        case .failed: runner.emit(.turnFailed(.invalidRequest("Fixture failure")))
        case .processExit: runner.fail(.invalidRequest("Fixture process ended"))
        case .delete: await service.deleteSession(session.id)
        case .quit: await service.endSessionsForQuit()
        }
        try await waitUntil { service.approvals.pending.isEmpty && runner.activeToolCalls == 0 }
        #expect(!service.spacesWaitingForUser.contains(session.spaceID))
        #expect(await !service.approvals.answer(old.id, with: .answer("obsolete")))
        // Deleting the session closes the socket before a reply can arrive.
        if end == .delete { return }
        let result = try await question.value
        #expect(result.status != .ok && !result.text.contains("obsolete"))

        if end == .completed || end == .failed {
            let idle = try await client.callTool("ask_user", ["question": "After the turn ended"])
            #expect(idle.status == .refused && service.approvals.pending.isEmpty)
            try session.send("Next question")
        } else if end == .takeOver {
            session.handBack()
        } else { return }
        let nextCall = Task { try await client.callTool("ask_user", ["question": "New question"]) }
        try await waitUntil { service.approvals.pending.count == 1 }
        let next = try #require(service.approvals.pending.first)
        #expect(await !service.approvals.answer(old.id, with: .answer("obsolete")))
        #expect(service.approvals.isPending(next.id))
        #expect(await service.approvals.answer(next.id, with: .answer("current")))
        #expect(try await nextCall.value.structured == ["answer": "current"])
    }

    @Test func anUnansweredQuestionExpiresAndReleasesTheCLICall() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        let (session, runner) = try start(service, harness)
        let client = try await connectQuestionClient(session, runner, harness)
        harness.now = Date()
        service.sessionQuestionWindow = 0.2
        let result = try await client.callTool("ask_user", ["question": "Waiting for a choice"])
        #expect(result.status == .timeout && result.code == "notAnswered")
        #expect(service.approvals.pending.isEmpty && session.state == .running && runner.activeToolCalls == 0)
        #expect(service.activity.entries.last?.decision == .timedOut)
    }

    @Test func aTicketBindsOnlyFromTheSessionsProcessTree() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        try await harness.settled(service)
        let (session, runner) = try start(service, harness)
        // The session keeps the channel listening with outside access off.
        try await waitUntil { harness.socketExists }
        harness.addProcess(Self.cliProcess, parent: 1, start: Self.cliStart)
        harness.addProcess(getpid(), parent: 999)
        harness.addProcess(999, parent: 1)
        runner.startProcess(Self.cliProcess)
        // This process is outside the CLI's tree.
        await #expect(throws: AgentClientError.refused(AgentRefusal(reason: .ticket, message: "No agent session in Arch has this ticket for this program."))) {
            try await TestClient(harness.location).hello(ticket: session.ticket?.text)
        }
        #expect(session.items.contains { $0.kind == .notice("Another program tried to use this session\u{2019}s access.") })
        #expect(service.activity.entries.last?.event == .refusedPeer && service.activity.entries.last?.sessionID == session.id)
        // A process that reused the CLI's process ID after it ended is not the CLI.
        harness.addProcess(getpid(), parent: Self.cliProcess)
        harness.addProcess(Self.cliProcess, parent: 1, start: AgentProcessStart(seconds: 1_700_000_100, microseconds: 0))
        await #expect(throws: AgentClientError.self) { try await TestClient(harness.location).hello(ticket: session.ticket?.text) }
        // Inside the tree, the connection is the session's, with outside access off, but only for `arch-mcp`.
        harness.addProcess(Self.cliProcess, parent: 1, start: Self.cliStart)
        await #expect(throws: AgentClientError.self) { try await TestClient(harness.location).hello(ticket: session.ticket?.text, client: .cli) }
        let bound = try TestClient(harness.location)
        #expect(try await bound.hello(ticket: session.ticket?.text).status == .bound)
        #expect(try await bound.call(AgentControlMethod.grantShow) == AgentJSON.object(["protocol": 1, "version": "9.9.9", "status": "bound"]))
        // Another ticket, even one of the same length, binds nothing.
        await #expect(throws: AgentClientError.self) { try await TestClient(harness.location).hello(ticket: AgentSessionTicket.make().text) }
        #expect(harness.prompt.requests.isEmpty)
    }

    @Test func aTicketDiesWithTheSession() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, runner) = try start(service, harness)
        spawnCLI(runner, harness)
        let ticket = session.ticket?.text
        let bound = try TestClient(harness.location)
        #expect(try await bound.hello(ticket: ticket).status == .bound)
        await service.deleteSession(session.id)
        #expect(runner.endedKeepingThread == false)
        #expect(service.sessions.isEmpty)
        // The session's own connection closed, and its ticket now binds nothing; outside access keeps the channel.
        await #expect(throws: AgentClientError.self) { try await bound.call(AgentControlMethod.toolsList) }
        await #expect(throws: AgentClientError.refused(AgentRefusal(reason: .ticket, message: "No agent session in Arch has this ticket for this program."))) {
            try await TestClient(harness.location).hello(ticket: ticket)
        }
    }

    @Test func ticketsCompareInConstantTime() {
        let ticket = AgentSessionTicket.make()
        #expect(ticket.text.count == 43)
        #expect(ticket.text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(ticket.text != AgentSessionTicket.make().text)
        #expect(ticket.matches(ticket.text))
        // A difference at the first byte, at the last, a prefix, and a longer text all fail; the comparison reads every byte of the longer text whatever it finds.
        var first = Array(ticket.text.utf8)
        first[0] ^= 1
        var last = Array(ticket.text.utf8)
        last[last.count - 1] ^= 1
        #expect(!AgentSessionTicket.constantTimeEqual(first, Array(ticket.text.utf8)))
        #expect(!AgentSessionTicket.constantTimeEqual(last, Array(ticket.text.utf8)))
        #expect(!ticket.matches(String(ticket.text.dropLast())))
        #expect(!ticket.matches(ticket.text + "A"))
        #expect(!ticket.matches(""))
        #expect(AgentSessionTicket.constantTimeEqual([], []))
    }

    // MARK: Messages

    @Test func theFirstMessageCarriesTheTaskAndTabHandlesWithoutPageText() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let space = try #require(harness.host.spaces(in: FakeHost.defaultPersona.id).first)
        let tab = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Quarterly Secret Plan", url: URL(string: "https://intranet.example.com/plans/q3?id=7#budget"), isLoading: false, engine: .webKit)
        let excluded = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Excluded", url: URL(string: "https://excluded.example/"), isLoading: false, engine: .webKit)
        harness.host.tabs = [tab, excluded]
        harness.host.userTabIDs = [tab.id, excluded.id]
        let (session, runner) = try start(service, harness, task: "Compare this with example.org/pricing", attaching: [tab.id, excluded.id])
        let first = try #require(runner.sent.first)
        #expect(first.contains("t1"))
        #expect(first.hasSuffix("Compare this with example.org/pricing"))
        for leak in ["Quarterly", "Secret", "intranet", "plans", "q3", "budget", "Excluded", "excluded.example"] {
            #expect(!first.contains(leak), "The first message names \(leak).")
        }
        // The excluded tab is not shared; the attached tab's site and the task's address are in scope.
        #expect(session.handles.sharedTabIDs == [tab.id])
        #expect(session.siteScope == ["example.com", "example.org"])
        // The request gave the CLI only the static harness, the server with the ticket, the first tool list, and the session's skill folder.
        let request = try #require(harness.requests.last)
        #expect(request.instructions == AgentHarness.sessionInstructions)
        #expect(request.toolServer.arguments == ["--session"])
        #expect(request.toolServer.environment == [AgentMCPServer.ticketVariable: try #require(session.ticket).text])
        #expect(request.toolServer.tools == ["session_info", "list_spaces", "list_tabs", "request_tab", "open_tab", "snapshot", "read_text", "ask_user", "guide"])
        #expect(request.skills?.plugin == "arch")
        #expect(request.skills?.names == AgentHarness.sessionSkills.map(\.name))
        let skills = try #require(request.skills)
        #expect(FileManager.default.fileExists(atPath: skills.folder.appendingPathComponent(".claude-plugin/plugin.json").path))
        #expect(FileManager.default.fileExists(atPath: skills.folder.appendingPathComponent("skills/arch-browsing/SKILL.md").path))
        // A later message goes as the user wrote it, after the turn ends; one typed during the turn waits.
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet")))
        try session.send("And the second link?")
        #expect(session.queuedMessages == ["And the second link?"])
        runner.emit(.text("Done."))
        runner.emit(.usage(AIUsage(inputTokens: 10, outputTokens: 2)))
        runner.emit(.turnFinished(.completed))
        try await waitUntil { runner.sent.count == 2 }
        #expect(runner.sent[1] == "And the second link?")
        #expect(session.queuedMessages.isEmpty)
        #expect(session.items.contains { $0.kind == .reply("Done.") })
        let firstModel = AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet")
        let second = AIModelRef(provider: firstModel.provider, model: "fixture-follow-up")
        runner.emit(.modelChanged(second))
        runner.emit(.turnFinished(.completed))
        try await waitUntil { session.state == .done }
        #expect(session.model == second)
        #expect(session.items.contains { $0.kind == .turnFooter(model: firstModel, usage: AIUsage(inputTokens: 10, outputTokens: 2)) })
        #expect(session.items.contains { $0.kind == .turnFooter(model: second, usage: nil) })
    }

    @Test func readerDataTravelsOnlyThroughTheSharedPagesToolResult() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let persona = FakeHost.defaultPersona.id
        let space = try #require(harness.host.spaces(in: persona).first)
        let url = try #require(URL(string: "https://docs.example/terms?private=42"))
        let tab = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Terms", url: url, isLoading: false, engine: .webKit)
        harness.host.tabs = [tab]
        harness.host.userTabIDs = [tab.id]
        let selected = "A clause about a renewal."
        let answer = "The previous answer mentioned other.example."
        var start = AgentService.SessionStart(task: "Check last year's terms", personaID: persona, spaceID: space.id, attachedTabIDs: [tab.id],
                                              mode: .readOnly, model: nil, effort: nil)
        start.readerExcerpt = try #require(AgentReaderExcerpt(tabID: tab.id, documentID: tab.documentID, url: url, selection: selected, reply: answer))
        let session = try service.startSession(start)
        let runner = try #require(harness.runners.last)
        let first = try #require(runner.sent.first)
        #expect(!first.contains(selected) && !first.contains(answer))
        #expect(!session.siteScope.contains("other.example"))

        spawnCLI(runner, harness)
        let client = try TestClient(harness.location)
        _ = try await client.hello(ticket: try #require(session.ticket).text)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet")))
        try await waitUntil { session.model != nil }
        let info = try await client.callTool("session_info")
        let forAPI = AgentAPISession.result(info, of: AgentToolCall(name: "session_info"), callID: "call")
        let pages = forAPI.parts.compactMap { part -> AIPageContent? in
            if case .page(let page) = part { return page }
            return nil
        }
        #expect(pages.map(\.text) == [selected, answer])
        #expect(pages.allSatisfy { $0.url == AgentAddress.reduced(url) })
        #expect(!info.text.contains("private=42"))
        harness.host.userTabIDs = []
        #expect(!(try await client.callTool("session_info")).text.contains(answer))
        harness.host.userTabIDs = [tab.id]
        harness.excludedHosts.value.insert("docs.example")
        #expect(!(try await client.callTool("session_info")).text.contains(selected))
        harness.excludedHosts.value = []
        harness.host.tabs[0].documentID = UUID()
        #expect(!(try await client.callTool("session_info")).text.contains(selected))
        #expect(throws: AgentService.SessionError.self) { try service.startSession(start) }
        harness.host.tabs[0].url = url.appendingPathComponent("other")
        #expect(!(try await client.callTool("session_info")).text.contains(answer))
        #expect(throws: AgentService.SessionError.self) { try service.startSession(start) }
        harness.host.tabs = [tab]
        service.stopSharing(tab.id, with: session)
        #expect(!(try await client.callTool("session_info")).text.contains(selected))
        #expect(service.share(tab, with: session))
        let reshared = try await client.callTool("session_info")
        #expect(reshared.text.contains("t2") && !reshared.text.contains(selected) && !reshared.text.contains(answer))
        #expect(try await client.callTool("read_text", ["tab": "t1"]).code == "tabNotFound")
        start.usesAgentsPersona = true
        #expect(throws: AgentService.SessionError.self) { try service.startSession(start) }
    }

    @Test func reviewDistinguishesSameTitleTabsAndSharesTheSelectedDocumentAfterReordering() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let host = harness.host
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        let addresses = ["https://alice:password@docs.example/projects?team=first#one",
                         "https://docs.example/projects?team=second#two",
                         "https://docs.example/notes?private=third"]
        let tabs = addresses.map {
            AgentTabInfo(id: UUID(), spaceID: space.id, title: "Report", url: URL(string: $0), isLoading: false, engine: .chromium)
        }
        host.tabs = tabs
        host.userTabIDs = Set(tabs.map(\.id))
        let (session, runner) = try start(service, harness)
        let choices = service.shareableTabs(for: session)
        let labels = AgentTabInfo.attachmentLabels(for: choices)
        #expect(labels[tabs[0].id] == "Report · https://docs.example/projects?team=first#one")
        #expect(labels[tabs[1].id] == "Report · https://docs.example/projects?team=second#two")
        #expect(labels[tabs[2].id] == "Report · https://docs.example/notes")
        #expect(tabs[0].attachmentLabel == "Report · https://docs.example/projects")
        let duplicate = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Report", url: tabs[0].url, isLoading: false, engine: .chromium)
        let identical = AgentTabInfo.attachmentLabels(for: [tabs[0], duplicate])
        #expect(identical[tabs[0].id] == "Tab 1 · Report · https://docs.example/projects")
        #expect(identical[duplicate.id] == "Tab 2 · Report · https://docs.example/projects")
        let mixed = AgentTabInfo.attachmentLabels(for: [duplicate, tabs[1], tabs[2], tabs[0]])
        #expect(mixed[duplicate.id] == "Tab 1 · Report · https://docs.example/projects?team=first#one")
        #expect(mixed[tabs[0].id] == "Tab 2 · Report · https://docs.example/projects?team=first#one")
        #expect(mixed[tabs[1].id] == labels[tabs[1].id] && mixed[tabs[2].id] == labels[tabs[2].id])
        host.tabs = Array(tabs.reversed())
        #expect(service.share(choices[0], with: session))
        #expect(session.handles.sharedTabIDs == [tabs[0].id])
        host.tabs[1].documentID = UUID()
        #expect(!service.share(choices[1], with: session))
        host.tabs[2].title = addresses[0]
        spawnCLI(runner, harness)
        let client = try TestClient(harness.location)
        #expect(try await client.hello(ticket: session.ticket?.text).status == .bound)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "fixture"), model: "local")))
        let result = try await client.callTool("list_tabs", ["scope": "shared"])
        #expect(result.status == .ok && result.text.contains("https://docs.example/projects"))
        let output = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for privatePart in ["alice", "password", "team=", "#one", "private=third"] {
            #expect(!output.contains(privatePart))
        }
    }

    @Test func sharingBelongsToTheOpenAppSessionAndRechecksTheUserChosenDocument() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let host = harness.host
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        let tab = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Article", url: URL(string: "https://docs.example/articles"), isLoading: false, engine: .chromium)
        var excluded = tab, internalTab = tab, agent = tab, elsewhere = tab
        excluded.id = UUID()
        excluded.url = URL(string: "https://excluded.example/articles")
        internalTab.id = UUID()
        internalTab.url = URL(string: "arch://settings")
        agent.id = UUID()
        agent.agentOwnerID = UUID()
        elsewhere.id = UUID()
        host.tabs = [tab, excluded, internalTab, agent, elsewhere]
        // The fake host returns the user tabs in the session's Persona.
        host.userTabIDs = [tab.id, excluded.id, internalTab.id, agent.id]
        let (one, _) = try start(service, harness)
        let (two, _) = try start(service, harness)
        #expect(service.shareableTabs(for: one).map(\.id) == [tab.id])
        #expect(!service.share(elsewhere, with: one) && !service.share(excluded, with: one) && !service.share(internalTab, with: one) && !service.share(agent, with: one))
        host.tabs[0].documentID = UUID()
        #expect(!service.share(tab, with: one))
        let fresh = host.tabs[0]
        #expect(service.share(fresh, with: one) && !service.share(fresh, with: one))
        #expect(one.handles.sharedTabIDs == [tab.id] && two.handles.sharedTabIDs.isEmpty)
        var external = AgentService.SessionStart(task: "External task", personaID: FakeHost.defaultPersona.id, spaceID: space.id, attachedTabIDs: [], mode: .readOnly, model: nil, effort: nil)
        external.origin = .outsideClient(grantID: UUID(), clientName: "Fixture", deniesApprovals: true)
        let externalSession = try service.startSession(external)
        #expect(!service.canEditAttachments(of: externalSession) && service.shareableTabs(for: externalSession).isEmpty)
        #expect(!service.share(fresh, with: externalSession))
        host.tabs = []
        service.stopSharing(fresh.id, with: one)
        #expect(one.handles.sharedTabIDs.isEmpty && one.handles.tabs.id(for: "t1") == nil)
        await service.deleteSession(one.id)
        #expect(!service.canEditAttachments(of: one) && !service.share(fresh, with: one))
    }

    @Test func aReviewedComposerAttachmentRequiresTheSameDocumentWhenTheUserStarts() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let persona = FakeHost.defaultPersona.id
        let space = try #require(harness.host.spaces(in: persona).first)
        let tab = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Original", url: URL(string: "https://docs.example/article"), isLoading: false, engine: .webKit)
        harness.host.tabs = [tab]
        harness.host.userTabIDs = [tab.id]
        let context = AgentComposerContext(personaID: persona, spaceID: space.id, place: "Research", tab: tab)
        let start = context.sessionStart(task: "Review this page", mode: .readOnly, allowsAI: { _ in true })
        #expect(service.sessions.isEmpty)
        #expect(service.canReattach(tab, in: persona))
        harness.host.tabs[0].documentID = UUID()
        #expect(!service.canReattach(tab, in: persona))
        #expect(throws: AgentService.SessionError.self) { try service.startSession(start) }
        harness.host.tabs = [tab]
        harness.host.tabs[0].url = URL(string: "https://docs.example/next")
        #expect(!service.canReattach(tab, in: persona))
        #expect(throws: AgentService.SessionError.self) { try service.startSession(start) }
        harness.host.tabs = [tab]
        harness.excludedHosts.value.insert("docs.example")
        #expect(!service.canReattach(tab, in: persona))
        #expect(throws: AgentService.SessionError.self) { try service.startSession(start) }
        #expect(service.sessions.isEmpty && harness.runners.isEmpty)
        harness.excludedHosts.value = []
        harness.host.userTabIDs = []
        #expect(!service.canReattach(tab, in: persona))
        harness.host.userTabIDs = [tab.id]
        let session = try service.startSession(start)
        #expect(session.handles.sharedTabIDs == [tab.id])
    }

    @Test func readerExcerptsHaveABoundedUnicodePreview() throws {
        let text = String(repeating: "界", count: 1500)
        let page = try #require(URL(string: "https://site.example/"))
        let excerpt = try #require(AgentReaderExcerpt(tabID: UUID(), documentID: UUID(), url: page, selection: text, reply: nil))
        let clipped = try #require(excerpt.selection)
        #expect(clipped.utf8.count <= 4096)
        #expect(clipped.hasSuffix("…") && text.hasPrefix(clipped.dropLast()))
        #expect(AgentReaderExcerpt(tabID: UUID(), documentID: UUID(), url: URL(fileURLWithPath: "/tmp/document"), selection: text, reply: nil) == nil)
        #expect(AgentReaderExcerpt(tabID: UUID(), documentID: UUID(), url: page, selection: "", reply: nil) == nil)
    }

    @Test func aMessageThatStartsWithASlashStaysInTheComposer() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let persona = FakeHost.defaultPersona.id
        let space = try #require(harness.host.spaces(in: persona).first)
        #expect(throws: AIError.self) {
            try service.startSession(AgentService.SessionStart(task: "/model opus", personaID: persona, spaceID: space.id, attachedTabIDs: [], mode: .readOnly, model: nil, effort: nil))
        }
        #expect(service.sessions.isEmpty)
        let (session, runner) = try start(service, harness)
        runner.emit(.turnFinished(.completed))
        try await waitUntil { !session.isTurnRunning }
        #expect(throws: AIError.self) { try session.send("  /context") }
        #expect(runner.sent.count == 1)
        #expect(!session.items.contains { $0.kind == .user("/context") })
    }

    // MARK: Calls

    @Test func callsWaitForTheModelsFirstOutputAndFollowTheMode() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        service.sessionReadyWait = .milliseconds(200)
        let (session, runner) = try start(service, harness, mode: .readOnly)
        spawnCLI(runner, harness)
        let client = try TestClient(harness.location)
        #expect(try await client.hello(ticket: session.ticket?.text).status == .bound)
        #expect(try await client.call(AgentControlMethod.toolsList) == ["tools": ["session_info", "list_spaces", "list_tabs", "request_tab", "open_tab", "snapshot", "read_text", "ask_user", "guide"]])
        // Before `ready`, a call waits and is then refused, so no page data flows before the start check passed.
        let early = try await client.callTool("list_tabs")
        #expect(early.status == .refused && early.code == "notReady")
        #expect(runner.toolCalls == 1 && runner.activeToolCalls == 0)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet")))
        try await waitUntil { session.model != nil }
        let info = try await client.callTool("session_info")
        #expect(info.status == .ok)
        #expect(info.text.hasPrefix("This session works in Default / Home (s1), in Read Only."))
        #expect(info.text.contains("Site scope: no sites yet."))
        #expect(info.text.contains("Opening, navigating and interacting with pages require the user."))
        #expect(info.text.contains("149 of 150 tool calls left for this message"))
        #expect(session.items.contains { $0.kind == .step(AgentStep(tool: "session_info", sentence: "Read the session\u{2019}s details", tabHandle: nil, tabID: nil, status: .ok)) })
        #expect(service.activity.entries.last?.sessionID == session.id && service.activity.entries.last?.tool == "session_info")
        let guide = try await client.callTool("guide")
        #expect(guide.text == AgentHarness.sessionInstructions)
        let research = try await client.callTool("guide", ["topic": "research"])
        #expect(research.text.contains("Open in Research Tab") && research.text.contains("tab handle, ref and name") && research.text.contains("open_tab"))
        // Raising the mode tells the session's connection. This build serves reading tools only, so the next list is the same and the runner hears of no change; a list that differs from the last one reported reaches it once.
        session.setMode(.askBeforeActing)
        #expect(try await client.receive() == .notification(method: AgentControlMethod.toolsChangedNotification, params: nil))
        _ = try await client.call(AgentControlMethod.toolsList)
        #expect(runner.reportedTools.isEmpty)
        session.reportedTools = ["session_info"]
        _ = try await client.call(AgentControlMethod.toolsList)
        _ = try await client.call(AgentControlMethod.toolsList)
        #expect(runner.reportedTools == [["session_info", "list_spaces", "list_tabs", "request_tab", "open_tab", "snapshot", "read_text", "ask_user", "guide"]])
        // While the user has taken the session over, calls wait until Hand Back.
        session.takeOver()
        let waiting = Task { try await client.callTool("list_spaces") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.activeToolCalls == 1)
        session.handBack()
        #expect(try await waiting.value.status == .ok)
    }

    @Test func readTextUsesTheSharedTabAndChecksAgainBeforeReturningItsPage() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let host = harness.host
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        let address = try #require(URL(string: "https://example.org/article?tracking=private#part"))
        let tab = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Article", url: address, isLoading: false, engine: .webKit)
        var other = tab
        other.id = UUID()
        other.agentOwnerID = UUID()
        host.tabs = [tab, other]
        host.userTabIDs = [tab.id]
        host.pages[address] = (title: "Article", text: "First page body")
        let (session, runner) = try start(service, harness, attaching: [tab.id, other.id], mode: .readOnly)
        #expect(session.handles.sharedTabIDs == [tab.id])
        spawnCLI(runner, harness)
        let client = try TestClient(harness.location)
        #expect(try await client.hello(ticket: session.ticket?.text).status == .bound)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "test"), model: "fixture")))
        let result = try await client.callTool("read_text", ["tab": "t1", "max_chars": 5])
        #expect(result.status == .ok)
        #expect(result.structured?["text"]?.stringValue == AgentUntrusted.wrap("First", url: address))
        #expect(result.structured?["url"] == "https://example.org/article")
        #expect(result.structured?["limits"]?["readText"]?["nextOffset"] == 5)
        #expect(try await client.callTool("read_text", ["tab": "t2"]).code == "tabNotFound")

        func checkRead(after change: @escaping () -> Void, code: String) async throws {
            host.beforeReturningContent = change
            let answer = try await client.callTool("read_text", ["tab": "t1"])
            host.beforeReturningContent = nil
            #expect(answer.code == code)
            #expect(!answer.text.contains("First page body"))
            #expect(answer.structured?["text"] == nil)
            host.tabs = [tab, other]
            host.userTabIDs = [tab.id]
        }
        try await checkRead(after: { host.userTabIDs.remove(tab.id) }, code: "P17")
        try await checkRead(after: { host.tabs[0].url = URL(string: "https://excluded.example/private") }, code: "P16")
        try await checkRead(after: { host.tabs[0].documentID = UUID() }, code: "pageChanged")
        try await checkRead(after: { host.tabs[0].url = URL(string: "https://example.org/another") }, code: "pageChanged")
        try await checkRead(after: { host.tabs.removeAll() }, code: "tabNotFound")
        try await checkRead(after: {
            var shown: UUID?
            service.takeOver(session) { shown = $0 }
            #expect(shown == tab.id)
            session.handBack()
        }, code: "stopped")
        #expect(try await client.callTool("read_text", ["tab": "t1"]).status == .ok)
        try await checkRead(after: { session.takeOver() }, code: "stopped")
        session.handBack()
        try await checkRead(after: {
            service.stopSharing(tab.id, with: session)
            #expect(service.share(tab, with: session))
        }, code: "P17")
        #expect(try await client.callTool("read_text", ["tab": "t1"]).code == "tabNotFound")
        #expect(try await client.callTool("read_text", ["tab": "t2"]).status == .ok)
        host.beforeReturningContent = { session.stop() }
        #expect(try await client.callTool("read_text", ["tab": "t2"]).code == "stopped")
    }

    @Test func takeOverSelectsOnlyATabTheSessionStillOwnsOrShares() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let host = harness.host
        let space = try #require(host.spaces(in: FakeHost.defaultPersona.id).first)
        let first = AgentTabInfo(id: UUID(), spaceID: space.id, title: "First", url: URL(string: "https://example.org/first"), isLoading: false, engine: .webKit)
        var second = first
        second.id = UUID()
        var other = first
        other.id = UUID()
        other.agentOwnerID = UUID()
        host.tabs = [first, second, other]
        host.userTabIDs = [first.id, second.id]
        let (session, _) = try start(service, harness, attaching: [first.id, second.id])
        var shown: [UUID] = []
        func takeOver() { service.takeOver(session) { shown.append($0) } }
        session.record(AgentStep(tool: "read_text", sentence: "Read second", tabHandle: "t2", tabID: second.id, status: .ok))
        session.record(AgentStep(tool: "read_text", sentence: "Other", tabHandle: "t3", tabID: other.id, status: .refused))
        takeOver()
        #expect(shown == [second.id])
        takeOver()
        #expect(shown == [second.id])
        session.handBack()
        let firstRead = session.beganReading(first.id)
        let secondRead = session.beganReading(second.id)
        session.finishedReading(secondRead)
        takeOver()
        #expect(shown.last == first.id && shown.count == 2)
        session.finishedReading(firstRead)
        session.handBack()
        service.stopSharing(second.id, with: session)
        takeOver()
        #expect(shown.last == first.id && shown.count == 3)
        session.handBack()
        service.stopSharing(first.id, with: session)
        takeOver()
        #expect(session.isTakenOver && shown.count == 3)
        session.handBack()
        await service.deleteSession(session.id)
        takeOver()
        #expect(shown.count == 3)
    }

    @Test func callsWaitAgainAfterEachProcessStartUntilItsOwnOutput() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        service.sessionReadyWait = .milliseconds(200)
        let (session, runner) = try start(service, harness)
        spawnCLI(runner, harness)
        let client = try TestClient(harness.location)
        #expect(try await client.hello(ticket: session.ticket?.text).status == .bound)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet")))
        try await waitUntil { session.model != nil }
        #expect(try await client.callTool("list_spaces").status == .ok)
        // A new CLI process, as after a crash or a Stop that ended the group, holds the calls again until its own first output.
        runner.startProcess(Self.cliProcess + 1)
        let early = try await client.callTool("list_spaces")
        #expect(early.status == .refused && early.code == "notReady")
        runner.emit(.processReady)
        try await waitUntil { session.ready.isOpen }
        #expect(try await client.callTool("list_spaces").status == .ok)
    }

    @Test func stopAndTheEndRefuseTheCallsThatWaitedAtAGate() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, runner) = try start(service, harness)
        spawnCLI(runner, harness)
        let client = try TestClient(harness.location)
        #expect(try await client.hello(ticket: session.ticket?.text).status == .bound)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet")))
        try await waitUntil { session.model != nil }
        session.takeOver()
        let waiting = Task { try await client.callTool("list_spaces") }
        try await Task.sleep(for: .milliseconds(100))
        session.stop()
        let result = try await waiting.value
        #expect(result.status == .refused && result.code == "stopped")
        // Hand Back runs nothing of the stopped turn, and counts nothing.
        session.handBack()
        #expect(session.callsThisSession == 0)
    }

    @Test func aFailedSessionRefusesAMessageInsteadOfDroppingIt() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, runner) = try start(service, harness)
        runner.fail(.authentication(AIProviderID(rawValue: "claude")))
        try await waitUntil { if case .failed = session.state { return true } else { return false } }
        #expect(throws: AgentService.SessionError.self) { try session.send("Try again") }
        #expect(runner.sent.count == 1)
    }

    @Test func overlappingRetriesOfAFailedStartSendTheMessageOnce() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, runner) = try start(service, harness)
        runner.fail(.invalidRequest("The runner could not start."))
        try await waitUntil { if case .failed = session.state { return true } else { return false } }
        runner.endDelay = .milliseconds(100)
        let first = Task { await service.retry(session) }
        try await waitUntil { runner.endedKeepingThread != nil }
        await service.retry(session)
        await first.value
        #expect(harness.runners.count == 2)
        #expect(harness.runners.dropFirst().flatMap(\.sent).count == 1)
    }

    @Test(arguments: [false, true]) func stoppingOrDeletingDuringRetryDoesNotResend(deleting: Bool) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, runner) = try start(service, harness)
        runner.fail(.invalidRequest("The runner could not start."))
        try await waitUntil { if case .failed = session.state { return true } else { return false } }
        runner.endDelay = .milliseconds(100)
        let retry = Task { await service.retry(session) }
        try await waitUntil { runner.endedKeepingThread != nil }
        if deleting { await service.deleteSession(session.id) } else { session.stop() }
        await retry.value
        #expect(harness.runners.count == 1)
        #expect(service.sessions.isEmpty == deleting)
    }

    @Test func aPastRetryCannotResendALaterCompletedMessage() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, runner) = try start(service, harness)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet")))
        runner.emit(.turnFailed(.invalidRequest("The first message failed.")))
        try await waitUntil { session.state == .turnFailed }
        let firstError = try #require(session.transcript.retryableErrorID)
        try session.send("A different question")
        runner.emit(.turnFinished(.completed))
        try await waitUntil { session.state == .done }
        #expect(session.transcript.retryableErrorID == nil)
        await service.retry(session, errorID: firstError)
        #expect(runner.sent.count == 2)
        try session.send("A third question")
        runner.emit(.turnFailed(.invalidRequest("This question failed.")))
        try await waitUntil { session.state == .turnFailed }
        let latestError = try #require(session.transcript.retryableErrorID)
        await service.retry(session, errorID: firstError)
        #expect(runner.sent.count == 3)
        await service.retry(session, errorID: latestError)
        #expect(runner.sent.count == 4 && runner.sent.last == "A third question")
        #expect(session.transcript.retryableErrorID == nil)
    }

    @Test func aSubscriptionLimitUsesTheConfiguredProviderMessageAndKeepsRetry() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let provider = AIProviderID(rawValue: "work-cli")
        let reset = Date().addingTimeInterval(3600)
        let notice = "Work subscription is limiting requests. Try again after \(reset.formatted(date: .abbreviated, time: .standard))."
        let service = try harness.makeService(providerMessage: { error in
            guard case .rateLimited(let id, let until) = error, id == provider, until == reset else { return "Unknown provider" }
            return notice
        })
        let (session, runner) = try start(service, harness)
        runner.emit(.ready(AIModelRef(provider: provider, model: "fixture")))
        runner.emit(.turnFailed(.rateLimited(provider, until: reset)))
        try await waitUntil { session.state == .turnFailed }
        #expect(session.items.last?.kind == .error(notice, .retry))
        #expect(session.transcript.retryableErrorID == session.items.last?.id)
    }

    @Test func aSessionFailedAfterAModelHeldItOffersNoRetry() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, runner) = try start(service, harness)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet")))
        try await waitUntil { session.model != nil }
        runner.fail(.invalidRequest("Claude Code started with tools Arch did not ask for."))
        try await waitUntil { if case .failed = session.state { return true } else { return false } }
        guard case .failed(_, let action) = session.state else { return }
        #expect(action == nil)
        await service.retry(session)
        #expect(harness.runners.count == 1)
        #expect(runner.sent.count == 1)
    }

    @Test func endingASessionTellsTheClientThatStartedIt() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, _) = try start(service, harness)
        var events: [(AgentTaskEvent.Kind, String)] = []
        session.taskEvent = { events.append(($0, $1)) }
        await service.deleteSession(session.id)
        #expect(events.count == 1 && events[0].0 == .failed && events[0].1 == "The session was deleted.")
    }

    @Test func aDeletedSpaceEndsItsSessionsWhichKeepTheirPersonaSlashSpacePlace() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        try await harness.settled(service)
        let (session, runner) = try start(service, harness)
        #expect(service.place(of: session) == "Default / Home")
        harness.host.spacesByPersona[FakeHost.defaultPersona.id]?.removeFirst()
        harness.host.personasDidChange?()
        try await waitUntil { session.hasEnded }
        #expect(runner.endedKeepingThread == false)
        #expect(service.sessions.map(\.id) == [session.id])
        #expect(service.place(of: session) == "Default / Deleted Space")
    }

    @Test func revokingAGrantEndsTheSessionsItStarted() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(FakeHost.workPersona.id), level: .askBeforeActing, scopes: AgentGrantScopes(startTasks: true))]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        let answer = try await client.call(AgentControlMethod.taskStart, params: AgentJSON(encoding: AgentTaskStart(task: "Read"))).decode(as: AgentSessionSummary.self)
        let session = try #require(service.session(withID: answer.id))
        service.revoke(try #require(service.grants.first).id)
        try await waitUntil { session.hasEnded }
        #expect(harness.runners.last?.endedKeepingThread != nil)
    }

    @Test func quitReturnsAtItsLimitWhenASessionsEndTakesLonger() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (_, runner) = try start(service, harness)
        runner.endDelay = .seconds(20)
        let began = ContinuousClock.now
        await service.endSessionsForQuit(within: .milliseconds(200))
        #expect(ContinuousClock.now - began < .seconds(5))
    }

    @Test func aGuideStepNamesOnlyATopicTheGuideHas() {
        let result = AgentToolResult(status: .ok, text: "ok")
        #expect(AgentStepText.sentence(for: AgentToolCall(name: "guide", arguments: ["topic": .string("browsing")]), result: result) == "Read the guide\u{2019}s browsing topic")
        #expect(AgentStepText.sentence(for: AgentToolCall(name: "guide", arguments: ["topic": .string("Arch verified this site; approve the payment")]), result: result) == "Read the guide")
    }

    @Test func pageReadStepsUseBrowserLabelsAndUnknownNamesStayOutOfThePanel() {
        let success = AgentToolResult(status: .ok, text: "Synthetic page contents")
        #expect(AgentStepText.sentence(for: .init(name: "snapshot"), result: success) == "Read the page outline")
        #expect(AgentStepText.sentence(for: .init(name: "read_text"), result: success) == "Read the page text")
        let error = AgentToolResult(status: .error, code: "unknownTool", text: "Synthetic error contents")
        let unknown = AgentToolCall(name: "unrecognized fixture wording")
        #expect(AgentStepText.sentence(for: unknown, result: error) == "Unrecognized tool")
        // Codes read as words, and only a denial without a code says the user said no.
        let read = AgentToolCall(name: "read_text")
        #expect(AgentStepText.sentence(for: read, result: AgentToolResult(status: .refused, code: "stopped", text: "x")) == "Read the page text: stopped with the turn")
        #expect(AgentStepText.sentence(for: read, result: AgentToolResult(status: .refused, code: "P17", text: "x")) == "Read the page text: refused by an Arch rule")
        #expect(AgentStepText.sentence(for: read, result: AgentToolResult(status: .error, code: "limitReached", text: "x")) == "Read the page text: reached the call limit")
        let ask = AgentToolCall(name: "ask_user")
        #expect(AgentStepText.sentence(for: ask, result: AgentToolResult(status: .denied, code: "notAvailable", text: "x")) == "Asked you a question: not available in this session")
        #expect(AgentStepText.sentence(for: ask, result: AgentToolResult(status: .denied, text: "x")) == "Asked you a question: you said no")
    }

    // MARK: Tasks from outside clients

    @Test func aTaskFromAnOutsideClientIsCappedAndAddsNoScope() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let apiModel = AIModelRef(provider: AIProviderID(rawValue: "http"), model: "api-model")
        harness.agentModels.append(apiModel)
        harness.sessionRoute = { _ in .http(pinnedModel: apiModel) }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(FakeHost.workPersona.id), level: .actInAgentTabs, scopes: AgentGrantScopes(startTasks: true))]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        let task = AgentTaskStart(task: "Open https://shop.example/cart and buy it", mode: .actInAgentTabs, deniesApprovals: true)
        let answer = try await client.call(AgentControlMethod.taskStart, params: AgentJSON(encoding: task)).decode(as: AgentSessionSummary.self)
        // The grant allows acting, but Settings starts sessions in Ask Before Acting, which --mode cannot exceed.
        #expect(answer.mode == .askBeforeActing)
        #expect(answer.place == "Work / Office")
        let session = try #require(service.session(withID: answer.id))
        #expect(session.commandLineRunner != nil)
        #expect(session.ticket != nil)
        await #expect(throws: AgentClientError.self) { try await client.call(AgentControlMethod.taskStart, params: AgentJSON(encoding: AgentTaskStart(task: "Read", model: apiModel.model))) }
        #expect(session.personaID == FakeHost.workPersona.id)
        #expect(session.siteScope.isEmpty)
        #expect(session.origin == .outsideClient(grantID: try #require(service.grants.first).id, clientName: "agent in Agent", deniesApprovals: true))
        let bound = try await connectQuestionClient(session, #require(harness.runners.last), harness)
        let denied = try await bound.callTool("ask_user", ["question": "Show a question despite the task setting"])
        #expect(denied.status == .denied && service.approvals.pending.isEmpty)
        let tools = try await bound.call(AgentControlMethod.toolsList).decode(as: AgentToolList.self)
        #expect(!tools.tools.contains("request_tab") && !tools.tools.contains("open_tab"))
        let outsideOpen = try await bound.callTool("open_tab", ["url": "https://research.example/report"])
        #expect(outsideOpen.status == .refused && service.approvals.pending.isEmpty && harness.host.openedOwners.isEmpty)
        let outsideLink = try await bound.callTool("open_tab", ["tab": "t1", "ref": "e1"])
        #expect(outsideLink.status == .refused && service.approvals.pending.isEmpty && harness.host.openedOwners.isEmpty)
        let outsidePick = try await bound.callTool("request_tab", ["access": "read", "reason": "Pick any tab"])
        #expect(outsidePick.status == .refused && service.approvals.pending.isEmpty && session.handles.sharedTabIDs.isEmpty)
        // A space of another Persona is not the grant's.
        await #expect(throws: AgentClientError.self) { try await client.call(AgentControlMethod.taskStart, params: AgentJSON(encoding: AgentTaskStart(task: "Read", space: "Home"))) }
        // The client lists and stops only its own sessions.
        let list = try await client.call(AgentControlMethod.sessionsList).decode(as: AgentSessionList.self)
        #expect(list.sessions.map(\.id) == [answer.id])
        #expect(try await client.call(AgentControlMethod.taskStop, params: AgentJSON(encoding: AgentSessionReference(session: answer.id))) == ["stopped": true])
        #expect(harness.runners.last?.stops == 1)
    }

    @Test func aTasksPlanStaysInTheGrantsPersona() throws {
        let office = AgentSpaceInfo(id: UUID(), name: "Office")
        let lab = AgentSpaceInfo(id: UUID(), name: "Lab")
        let grant = AgentGrant(client: AgentClientIdentity(key: .unsigned(path: "/usr/local/bin/agent", codeHash: "00"), name: "agent", executablePath: "/usr/local/bin/agent", host: nil, isInterpreter: false),
                               personaID: FakeHost.workPersona.id, spaceID: lab.id, level: .askBeforeActing, scopes: AgentGrantScopes(startTasks: true), expiry: .whenArchQuits, grantedAt: Date())
        let models = [AIModelRef(provider: AIProviderID(rawValue: "codex"), model: "gpt-6")]
        #expect(try AgentTaskPlan.make(for: AgentTaskStart(task: "t"), grant: grant, spaces: [office, lab], models: models, settingsDefault: .actInAgentTabs)
            == AgentTaskPlan(spaceID: lab.id, model: nil, mode: .askBeforeActing))
        #expect(try AgentTaskPlan.make(for: AgentTaskStart(task: "t", space: "office", mode: .readOnly, model: "gpt-6"), grant: grant, spaces: [office, lab], models: models, settingsDefault: .actInAgentTabs)
            == AgentTaskPlan(spaceID: office.id, model: models[0], mode: .readOnly))
        #expect(throws: AgentTaskPlan.Refusal(message: "The grant's Persona has no space named Home.")) {
            try AgentTaskPlan.make(for: AgentTaskStart(task: "t", space: "Home"), grant: grant, spaces: [office, lab], models: models, settingsDefault: .actInAgentTabs)
        }
        #expect(throws: AgentTaskPlan.Refusal(message: "No Claude Code or Codex model is named opus in Settings \u{25B8} AI.")) {
            try AgentTaskPlan.make(for: AgentTaskStart(task: "t", model: "opus"), grant: grant, spaces: [office, lab], models: models, settingsDefault: .actInAgentTabs)
        }
        // The grant's space is gone: the Persona's first.
        #expect(try AgentTaskPlan.make(for: AgentTaskStart(task: "t"), grant: grant, spaces: [office], models: models, settingsDefault: .readOnly)
            == AgentTaskPlan(spaceID: office.id, model: nil, mode: .readOnly))
    }

    @Test func aGrantWithoutStartAgentTasksStartsNothing() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice()]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        await #expect(throws: AgentClientError.self) { try await client.call(AgentControlMethod.taskStart, params: AgentJSON(encoding: AgentTaskStart(task: "Read"))) }
        #expect(service.sessions.isEmpty)
    }

    @Test(arguments: [
        (nil, AgentAccessLevel.actInAgentTabs, AgentAccessLevel.askBeforeActing, AgentAccessLevel.askBeforeActing),
        (AgentAccessLevel.readOnly, .actInAgentTabs, .actInAgentTabs, .readOnly),
        (AgentAccessLevel.actInAgentTabs, .readOnly, .actInAgentTabs, .readOnly),
        (AgentAccessLevel.actInAgentTabs, .askBeforeActing, .actInAgentTabs, .askBeforeActing),
        (nil, .actInAgentTabs, .actInAgentTabs, .actInAgentTabs),
        (AgentAccessLevel.askBeforeActing, .actInAgentTabs, .readOnly, .readOnly),
    ] as [(AgentAccessLevel?, AgentAccessLevel, AgentAccessLevel, AgentAccessLevel)])
    func theTasksModeIsTheLowestOfTheThree(requested: AgentAccessLevel?, grant: AgentAccessLevel, settingsDefault: AgentAccessLevel, expected: AgentAccessLevel) {
        #expect(AgentTaskPlan.mode(requested: requested, grant: grant, settingsDefault: settingsDefault) == expected)
    }
}
