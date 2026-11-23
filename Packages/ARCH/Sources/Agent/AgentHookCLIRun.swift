// A one-turn hook on the user's CLI. Its MCP peer binds to a fresh ticket and the running process tree.
import AgentControl
import AI
import Foundation

/// A hook's one-turn agent run on the user's CLI: its ticket, tools, call limit, and the process its MCP peer binds to.
@MainActor
final class AgentHookCLIRun {
    let id = UUID()
    let ticket: AgentSessionTicket
    let ready = AgentGate(isOpen: false)
    let tools: [AgentTool]
    let limit: Int
    let knownProviders: [AIProviderID: String]
    let dispatch: @MainActor (AgentToolCall) async -> AgentToolResult
    var runner: (any AgentCommandLineRunning)?
    var spawnedProcess: AgentProcessRecord?
    var didReachLimit = false
    private var calls = 0
    private var executing: Task<AgentToolResult, Never>?

    init?(tools: [AgentTool], limit: Int, knownProviders: [AIProviderID: String], dispatch: @escaping @MainActor (AgentToolCall) async -> AgentToolResult) {
        guard let ticket = AgentSessionTicket.make() else { return nil }
        self.ticket = ticket
        self.tools = tools
        self.limit = limit
        self.knownProviders = knownProviders
        self.dispatch = dispatch
    }

    var liveProcess: AgentProcessRecord? {
        guard let spawnedProcess, runner?.processID == spawnedProcess.processID else { return nil }
        return spawnedProcess
    }

    /// Ends the private tool binding, including a page read whose engine may never answer.
    func finish() {
        ready.shut()
        executing?.cancel()
    }

    func call(_ call: AgentToolCall) async -> AgentToolResult {
        guard !Task.isCancelled, await ready.wait(timeout: AgentSession.readyWait), !Task.isCancelled else {
            return AgentToolResult(status: .refused, code: "notReady", text: "The run has not passed its CLI start check.")
        }
        guard executing == nil else { return AgentToolResult(status: .refused, code: "busy", text: "The run is already handling a tool call.") }
        guard calls < limit else { return AgentToolResult(status: .refused, code: "toolCallLimit", text: "The run reached its tool call limit.") }
        calls += 1
        let task = Task { await dispatch(call) }
        executing = task
        runner?.toolCallDidStart()
        defer {
            executing = nil
            runner?.toolCallDidEnd()
            if calls == limit {
                didReachLimit = true
                ready.shut()
                runner?.stop()
            }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
