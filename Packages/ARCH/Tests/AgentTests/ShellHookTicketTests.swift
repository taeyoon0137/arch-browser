// Tests shell hook run tickets (`docs/hooks.md`, Shell scripts ▸ Acting).
// A run's ticket binds `arch-cli`, and only `arch-cli`, from the run's script process and its descendants while the run lasts.
// It checks the process ID and start time.
// The socket listens during the run with outside access off.
// The bound connection lists the run's tools.
// It gives their calls to the run's handler.
// It refuses any other tool.
// The run's end closes its connections and the socket.
import AgentControl
import Darwin
import Foundation
import Testing
@testable import Agent

@MainActor @Suite(.serialized) struct ShellHookTicketTests {
    /// The script process the shell runner reports, with this test process as its `arch-cli`.
    nonisolated static let scriptProcess: pid_t = 5_151
    nonisolated static let scriptStart = AgentProcessStart(seconds: 1_700_000_200, microseconds: 3)

    @Test func aRunsTicketBindsArchCLIOnlyFromTheRunsProcessTreeWhileTheRunLasts() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        try await harness.settled(service)
        #expect(!harness.socketExists)
        let run = UUID()
        let calls = Shared<[String]>([])
        let ticket = service.openHookRun(run, tools: ["list_tabs", "rename_tab"]) { call in
            calls.value.append(call.name)
            return AgentToolResult(status: .ok, text: "1 tab in this hook's run.")
        }
        // The run keeps the channel listening with outside access off.
        try await waitUntil { harness.socketExists }
        let refusal = AgentClientError.refused(AgentRefusal(reason: .ticket, message: "No hook run in Arch has this ticket for this program."))
        // Before the script has started, the ticket binds nothing.
        harness.addProcess(getpid(), parent: Self.scriptProcess)
        await #expect(throws: refusal) { try await TestClient(harness.location).hello(ticket: ticket, client: .cli) }

        harness.addProcess(Self.scriptProcess, parent: 1, start: Self.scriptStart)
        service.hookRun(run, didStart: Self.scriptProcess)
        // A process outside the script's tree is refused and logged.
        harness.addProcess(getpid(), parent: 999)
        harness.addProcess(999, parent: 1)
        await #expect(throws: refusal) { try await TestClient(harness.location).hello(ticket: ticket, client: .cli) }
        #expect(service.activity.entries.last?.event == .refusedPeer && service.activity.entries.last?.sessionID == run)
        // A process that reused the script's process ID after it ended is not the script.
        harness.addProcess(getpid(), parent: Self.scriptProcess)
        harness.addProcess(Self.scriptProcess, parent: 1, start: AgentProcessStart(seconds: 1_700_000_300, microseconds: 0))
        await #expect(throws: refusal) { try await TestClient(harness.location).hello(ticket: ticket, client: .cli) }
        harness.addProcess(Self.scriptProcess, parent: 1, start: Self.scriptStart)
        // Only `arch-cli` presents a run's ticket.
        // Another ticket of the same length binds nothing.
        await #expect(throws: AgentClientError.self) { try await TestClient(harness.location).hello(ticket: ticket, client: .mcp) }
        await #expect(throws: refusal) { try await TestClient(harness.location).hello(ticket: try #require(AgentSessionTicket.make()).text, client: .cli) }

        let bound = try TestClient(harness.location)
        #expect(try await bound.hello(ticket: ticket, client: .cli).status == .bound)
        #expect(try await bound.call(AgentControlMethod.toolsList) == ["tools": ["list_tabs", "rename_tab"]])
        let listed = try await bound.callTool("list_tabs")
        #expect(listed.status == .ok && listed.text == "1 tab in this hook's run.")
        let refused = try await bound.callTool("click", ["tab": "t1", "ref": "e1"])
        #expect(refused.status == .refused && refused.code == "notGranted")
        #expect(calls.value == ["list_tabs"])
        // Outside clients' methods are not the run's.
        await #expect(throws: AgentClientError.self) { try await bound.call(AgentControlMethod.sessionsList) }
        #expect(harness.prompt.requests.isEmpty)

        // The run's end closes its connection.
        // Its ticket then binds nothing.
        // The socket closes.
        service.closeHookRun(run)
        await #expect(throws: AgentClientError.self) { try await bound.call(AgentControlMethod.toolsList) }
        try await waitUntil { !harness.socketExists }
    }

    /// `agent/run` on a run's bound connection reaches the run's handler (`docs/hooks.md`, arch-cli agent run and rename).
    /// The answer names each renamed tab by its run handle, never Arch's identifier.
    /// A run without a handler answers -32601.
    @Test func aRunsAgentRunReachesItsHandler() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        try await harness.settled(service)
        let asked = Shared<[[String: AgentJSON]]>([])
        let run = UUID()
        let tab = UUID()
        let ticket = service.openHookRun(run, tools: ["list_tabs"], handles: [tab: "t1"], call: { _ in AgentToolResult(status: .ok, text: "") }, agentRun: { fields in
            asked.value.append(fields)
            return AgentRunResult(status: .completed, actions: [.renamedTab(tab: tab, name: "Named")], reply: "Named it.")
        })
        harness.addProcess(Self.scriptProcess, parent: 1, start: Self.scriptStart)
        harness.addProcess(getpid(), parent: Self.scriptProcess)
        service.hookRun(run, didStart: Self.scriptProcess)
        let bound = try TestClient(harness.location)
        #expect(try await bound.hello(ticket: ticket, client: .cli).status == .bound)
        let result = try await bound.call(AgentControlMethod.agentRun, params: ["prompt": "Name it", "tabs": ["t1"]])
        #expect(result["status"] == "completed" && result["reply"] == "Named it.")
        #expect(result["actions"] == [["renamedTab": ["tab": "t1", "name": "Named"]]])
        #expect(asked.value == [["prompt": "Name it", "tabs": ["t1"]]])
        service.closeHookRun(run)

        let plain = UUID()
        let other = service.openHookRun(plain, tools: ["list_tabs"]) { _ in AgentToolResult(status: .ok, text: "") }
        service.hookRun(plain, didStart: Self.scriptProcess)
        let client = try TestClient(harness.location)
        #expect(try await client.hello(ticket: other, client: .cli).status == .bound)
        await #expect(throws: AgentClientError.self) { try await client.call(AgentControlMethod.agentRun, params: ["prompt": "Name it"]) }
        service.closeHookRun(plain)
    }

    @Test func aProgramInARunThatDroppedTheTicketIsNoOutsideClient() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let run = UUID()
        _ = service.openHookRun(run, tools: ["list_tabs"]) { _ in AgentToolResult(status: .ok, text: "") }
        harness.addProcess(Self.scriptProcess, parent: 1, start: Self.scriptStart)
        service.hookRun(run, didStart: Self.scriptProcess)
        // With Allow Outside Clients on, Arch refuses a script command that cleared ARCH_HOOK_TICKET, as `env -i arch-cli tabs` does.
        harness.addProcess(getpid(), parent: 777)
        harness.addProcess(777, parent: Self.scriptProcess)
        await #expect(throws: AgentClientError.refused(AgentRefusal(reason: .ticket, message: "Programs in a hook's run reach Arch only with the run's ticket."))) {
            try await TestClient(harness.location).hello()
        }
        #expect(service.activity.entries.last?.event == .refusedPeer && service.activity.entries.last?.sessionID == run)
        #expect(harness.prompt.requests.isEmpty)
        // Outside the run's tree, and once the run ends, the same program is an outside client again.
        harness.addProcess(777, parent: 1)
        #expect(try await TestClient(harness.location).hello().status == .noGrant)
        harness.addProcess(777, parent: Self.scriptProcess)
        service.closeHookRun(run)
        #expect(try await TestClient(harness.location).hello().status == .noGrant)
    }

    @Test func aRunsConnectionOutlastsOutsideAccessAndItsTicketDiesWithTheRun() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let run = UUID()
        let ticket = service.openHookRun(run, tools: ["list_tabs"]) { _ in AgentToolResult(status: .ok, text: "") }
        harness.addProcess(Self.scriptProcess, parent: 1, start: Self.scriptStart)
        harness.addProcess(getpid(), parent: Self.scriptProcess)
        service.hookRun(run, didStart: Self.scriptProcess)
        let bound = try TestClient(harness.location)
        #expect(try await bound.hello(ticket: ticket, client: .cli).status == .bound)
        // Turning outside access off keeps the run's own connection.
        try await service.setAllowsOutsideClients(false)
        #expect(try await bound.call(AgentControlMethod.toolsList) == ["tools": ["list_tabs"]])
        service.closeHookRun(run)
        try await waitUntil { !harness.socketExists }
        // A closed run's ticket names no run.
        try await service.setAllowsOutsideClients(true)
        try await waitUntil { harness.socketExists }
        await #expect(throws: AgentClientError.refused(AgentRefusal(reason: .ticket, message: "No hook run in Arch has this ticket for this program."))) {
            try await TestClient(harness.location).hello(ticket: ticket, client: .cli)
        }
    }
}
