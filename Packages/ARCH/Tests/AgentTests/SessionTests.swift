// In-app sessions (docs/agents.md, In-app sessions: tickets; In the browser; Site scope and navigation): a ticket binds `arch-mcp` only from the session's own process tree and only while the session lives, compared in constant time; the first message carries the task and tab handles but no page text; the session's calls wait for the model's first output and are refused after the wait; a mode change sends `tools/changed` and reports the next list to the runner; a deleted space ends its sessions, whose place still reads "Persona / Space"; and `arch-cli task` starts a session capped at the grant's level and the Settings default, in the grant's Persona, with no scope from the client's text.
import AgentControl
import AI
import Darwin
import Foundation
import Testing
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
        #expect(!session.reportedTools.contains("open_tab"))
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
        #expect(request.instructions == AgentHarness.instructions)
        #expect(request.toolServer.arguments == ["--session"])
        #expect(request.toolServer.environment == [AgentMCPServer.ticketVariable: try #require(session.ticket).text])
        #expect(request.toolServer.tools == ["session_info", "list_spaces", "list_tabs", "snapshot", "read_text", "guide"])
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
        #expect(session.items.contains { $0.kind == .turnFooter(model: AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet"), usage: AIUsage(inputTokens: 10, outputTokens: 2)) })
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
        #expect(AgentTabInfo.attachmentLabels(for: [tabs[0], duplicate])[duplicate.id] == tabs[0].attachmentLabel)
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
        #expect(try await client.call(AgentControlMethod.toolsList) == ["tools": ["session_info", "list_spaces", "list_tabs", "snapshot", "read_text", "guide"]])
        // Before `ready`, a call waits and is then refused, so no page data flows before the start check passed.
        let early = try await client.callTool("list_tabs")
        #expect(early.status == .refused && early.code == "notReady")
        #expect(runner.toolCalls == 1 && runner.activeToolCalls == 0)
        runner.emit(.ready(AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet")))
        try await waitUntil { session.model != nil }
        let info = try await client.callTool("session_info")
        #expect(info.status == .ok)
        #expect(info.text.hasPrefix("This session works in Default / Home (s1), in Read Only."))
        #expect(info.text.contains("Site scope: no sites yet. Links you follow by ref open without asking."))
        #expect(info.text.contains("149 of 150 tool calls left for this message"))
        #expect(session.items.contains { $0.kind == .step(AgentStep(tool: "session_info", sentence: "Read the session\u{2019}s details", tabHandle: nil, tabID: nil, status: .ok)) })
        #expect(service.activity.entries.last?.sessionID == session.id && service.activity.entries.last?.tool == "session_info")
        // Raising the mode tells the session's connection. This build serves reading tools only, so the next list is the same and the runner hears of no change; a list that differs from the last one reported reaches it once.
        session.setMode(.askBeforeActing)
        #expect(try await client.receive() == .notification(method: AgentControlMethod.toolsChangedNotification, params: nil))
        _ = try await client.call(AgentControlMethod.toolsList)
        #expect(runner.reportedTools.isEmpty)
        session.reportedTools = ["session_info"]
        _ = try await client.call(AgentControlMethod.toolsList)
        _ = try await client.call(AgentControlMethod.toolsList)
        #expect(runner.reportedTools == [["session_info", "list_spaces", "list_tabs", "snapshot", "read_text", "guide"]])
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
        try await waitUntil { session.state == .done }
        let firstError = try #require(session.transcript.retryableErrorID)
        try session.send("A different question")
        runner.emit(.turnFinished(.completed))
        try await waitUntil { session.state == .done }
        #expect(session.transcript.retryableErrorID == nil)
        await service.retry(session, errorID: firstError)
        #expect(runner.sent.count == 2)
        try session.send("A third question")
        runner.emit(.turnFailed(.invalidRequest("This question failed.")))
        try await waitUntil { session.state == .done }
        let latestError = try #require(session.transcript.retryableErrorID)
        await service.retry(session, errorID: firstError)
        #expect(runner.sent.count == 3)
        await service.retry(session, errorID: latestError)
        #expect(runner.sent.count == 4 && runner.sent.last == "A third question")
        #expect(session.transcript.retryableErrorID == nil)
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
