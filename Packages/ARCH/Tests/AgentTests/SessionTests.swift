// In-app sessions (docs/agents.md, In-app sessions: tickets; In the browser; Site scope and navigation): a ticket binds `arch-mcp` only from the session's own process tree and only while the session lives, compared in constant time; the first message carries the task and tab handles but no page text; the session's calls wait for the model's first output and are refused after the wait; a mode change sends `tools/changed` and reports the next list to the runner; and `arch-cli task` starts a session capped at the grant's level and the Settings default, in the grant's Persona, with no scope from the client's text.
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

    // MARK: Tickets

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
            try await TestClient(harness.location).hello(ticket: session.ticket.text)
        }
        #expect(session.items.contains { $0.kind == .notice("Another program tried to use this session\u{2019}s access.") })
        #expect(service.activity.entries.last?.event == .refusedPeer && service.activity.entries.last?.sessionID == session.id)
        // A process that reused the CLI's process ID after it ended is not the CLI.
        harness.addProcess(getpid(), parent: Self.cliProcess)
        harness.addProcess(Self.cliProcess, parent: 1, start: AgentProcessStart(seconds: 1_700_000_100, microseconds: 0))
        await #expect(throws: AgentClientError.self) { try await TestClient(harness.location).hello(ticket: session.ticket.text) }
        // Inside the tree, the connection is the session's, with outside access off, but only for `arch-mcp`.
        harness.addProcess(Self.cliProcess, parent: 1, start: Self.cliStart)
        await #expect(throws: AgentClientError.self) { try await TestClient(harness.location).hello(ticket: session.ticket.text, client: .cli) }
        let bound = try TestClient(harness.location)
        #expect(try await bound.hello(ticket: session.ticket.text).status == .bound)
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
        let ticket = session.ticket.text
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
        #expect(request.toolServer.environment == [AgentMCPServer.ticketVariable: session.ticket.text])
        #expect(request.toolServer.tools == ["session_info", "list_spaces", "list_tabs"])
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
        #expect(try await client.hello(ticket: session.ticket.text).status == .bound)
        #expect(try await client.call(AgentControlMethod.toolsList) == ["tools": ["session_info", "list_spaces", "list_tabs"]])
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
        #expect(runner.reportedTools == [["session_info", "list_spaces", "list_tabs"]])
        // While the user has taken the session over, calls wait until Hand Back.
        session.takeOver()
        let waiting = Task { try await client.callTool("list_spaces") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.activeToolCalls == 1)
        session.handBack()
        #expect(try await waiting.value.status == .ok)
    }

    @Test func callsWaitAgainAfterEachProcessStartUntilItsOwnOutput() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        service.sessionReadyWait = .milliseconds(200)
        let (session, runner) = try start(service, harness)
        spawnCLI(runner, harness)
        let client = try TestClient(harness.location)
        #expect(try await client.hello(ticket: session.ticket.text).status == .bound)
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
        #expect(try await client.hello(ticket: session.ticket.text).status == .bound)
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

    // MARK: Tasks from outside clients

    @Test func aTaskFromAnOutsideClientIsCappedAndAddsNoScope() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
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
