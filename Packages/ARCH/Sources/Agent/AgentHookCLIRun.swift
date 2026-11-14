// A one-turn hook on the user's CLI. Its MCP peer binds to a fresh ticket and the running process tree.
import AgentControl
import AI
import Foundation

@MainActor
final class AgentHookCLIRun {
    let id = UUID()
    let ticket = AgentSessionTicket.make()
    let ready = AgentGate(isOpen: false)
    let tools: [AgentTool]
    let limit: Int
    let dispatch: @MainActor (AgentToolCall) async -> AgentToolResult
    var runner: (any AgentCommandLineRunning)?
    var spawnedProcess: AgentProcessRecord?
    var didReachLimit = false
    private var calls = 0
    private var executing = false

    init(tools: [AgentTool], limit: Int, dispatch: @escaping @MainActor (AgentToolCall) async -> AgentToolResult) {
        self.tools = tools
        self.limit = limit
        self.dispatch = dispatch
    }

    var liveProcess: AgentProcessRecord? {
        guard let spawnedProcess, runner?.processID == spawnedProcess.processID else { return nil }
        return spawnedProcess
    }

    func call(_ call: AgentToolCall) async -> AgentToolResult {
        guard !Task.isCancelled, await ready.wait(timeout: AgentSession.readyWait), !Task.isCancelled else {
            return AgentToolResult(status: .refused, code: "notReady", text: "The run has not passed its CLI start check.")
        }
        guard !executing else { return AgentToolResult(status: .refused, code: "busy", text: "The run is already handling a tool call.") }
        guard calls < limit else { return AgentToolResult(status: .refused, code: "toolCallLimit", text: "The run reached its tool call limit.") }
        calls += 1
        executing = true
        runner?.toolCallDidStart()
        defer {
            executing = false
            runner?.toolCallDidEnd()
            if calls == limit {
                didReachLimit = true
                ready.shut()
                runner?.stop()
            }
        }
        guard tools.contains(where: { $0.name == call.name }) else { return AgentToolResult(status: .refused, code: "notGranted", text: "The hook did not grant this tool.") }
        return await dispatch(call)
    }
}
