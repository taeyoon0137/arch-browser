// Shell hook run tickets (`docs/hooks.md`, Shell scripts ▸ Acting): a run's ticket binds `arch-cli`, and only `arch-cli`, from the run's script process and its descendants, by process ID and start time, while the run lasts; the socket listens during the run with outside access off; the bound connection lists the run's tools and gives their calls to the run's handler, refusing any other tool; and the run's end closes its connections and the socket.
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
        // Only `arch-cli` presents a run's ticket, and another ticket of the same length binds nothing.
        await #expect(throws: AgentClientError.self) { try await TestClient(harness.location).hello(ticket: ticket, client: .mcp) }
        await #expect(throws: refusal) { try await TestClient(harness.location).hello(ticket: AgentSessionTicket.make().text, client: .cli) }

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

        // The run's end closes its connection; its ticket then binds nothing, and the socket goes.
        service.closeHookRun(run)
        await #expect(throws: AgentClientError.self) { try await bound.call(AgentControlMethod.toolsList) }
        try await waitUntil { !harness.socketExists }
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
