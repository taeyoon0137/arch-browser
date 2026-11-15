// arch-mcp's MCP server without I/O (docs/agents.md, arch-mcp): it takes the client's lines, Arch's control messages, and the outcome of each connection attempt one at a time and returns the effects to carry out, which the standard input loop in `ArchCLI` performs. It checks the protocol only; every tool call goes to Arch's tool host, which decides it.
import Foundation

/// The MCP protocol versions arch-mcp speaks.
public enum AgentMCPVersion {
    /// Oldest first.
    public static let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    public static var newest: String { supported[supported.count - 1] }

    /// `initialize` answers with the client's version when arch-mcp speaks it, otherwise with the newest, which a client that does not speak it disconnects from.
    public static func negotiated(forRequested requested: String) -> String {
        supported.contains(requested) ? requested : newest
    }

    /// Tool annotations and a progress notification's `message` came with 2025-03-26.
    static let annotations = "2025-03-26"
    static let progressMessage = "2025-03-26"
}

/// Splits standard input into MCP's stdio messages, one per line, and refuses a line longer than a control frame can carry.
public struct AgentLineReader: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// The next line without its newline and a carriage return before it, or nil until a newline arrives. Empty lines are skipped. Throws for a line longer than `AgentFrame.maximumLength` bytes, as soon as that many wait without a newline.
    public mutating func nextLine() throws -> Data? {
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex ..< newline])
            buffer = Data(buffer[(newline + 1)...])
            if line.last == 0x0D { line.removeLast() }
            guard line.count <= AgentFrame.maximumLength else { throw AgentFrameError.tooLong(line.count) }
            if !line.isEmpty { return line }
        }
        guard buffer.count <= AgentFrame.maximumLength else { throw AgentFrameError.tooLong(buffer.count) }
        return nil
    }

    /// What is left when standard input ends: a last line without a newline, or nil.
    public mutating func finish() -> Data? {
        defer { buffer = Data() }
        var line = buffer
        if line.last == 0x0D { line.removeLast() }
        return line.isEmpty ? nil : line
    }
}

public struct AgentMCPServer {
    public enum Mode: Equatable, Sendable {
        /// An outside client, which Arch's grant governs.
        case outside
        /// The server of an in-app session, started by the session's CLI with `--session`. It presents the session's ticket and ends when its connection does.
        case session(ticket: String)
    }

    /// What the loop does for the server, in order.
    public enum Effect: Equatable, Sendable {
        /// A message for the client, written as one line on standard output.
        case reply(AgentRPCMessage)
        /// A message for Arch, sent as one frame on the control socket.
        case send(AgentRPCMessage)
        /// Connect to Arch, check that the listener is Arch, and say this `hello`; then report `connected(_:)` or `connectionFailed(_:)`.
        case connect(AgentHello)
        /// A sentence for standard error.
        case log(String)
        case exit(AgentExitCode)
    }

    /// The environment variable that carries an in-app session's ticket to `arch-mcp --session`.
    public static let ticketVariable = "ARCH_AGENT_TICKET"
    public static let serverName = "arch"

    public let mode: Mode
    /// The app's version, as `serverInfo` reports it.
    public let version: String
    /// The `instructions` of `initialize`'s result.
    public let instructions: String

    /// The version `initialize` agreed on; nil until then.
    private var protocolVersion: String?
    private var link = Link.disconnected
    /// Requests waiting for a connection to Arch.
    private var waiting: [Request] = []
    /// Requests sent to Arch, by the control request's ID.
    private var pending: [Int: Request] = [:]
    private var nextControlID = 1
    /// Whether the client has received a tool list, which a new connection may change.
    private var hasListedTools = false

    private enum Link {
        case disconnected, connecting, connected
    }

    /// A client request that Arch answers.
    private struct Request {
        enum Kind {
            case list
            case call(AgentToolCall, progressToken: AgentJSON?)
        }

        var id: AgentRPCID
        var kind: Kind
        /// The progress notifications sent for this call, since each must report more progress than the one before.
        var progress = 0
    }

    public init(mode: Mode, version: String, instructions: String? = nil) {
        self.mode = mode
        self.version = version
        self.instructions = instructions ?? (mode == .outside ? AgentHarness.mcpInstructions : AgentHarness.boundMCPInstructions)
    }

    /// An in-app session's server connects at once, so that its CLI's first `tools/list` comes from the session; an outside client connects when it first needs Arch.
    public mutating func start() -> [Effect] {
        guard case .session = mode else { return [] }
        link = .connecting
        return [.connect(hello)]
    }

    /// Standard input closed: the client is done.
    public mutating func inputEnded() -> [Effect] {
        [.exit(.done)]
    }

    // MARK: - The client

    /// One line from the client.
    public mutating func receive(line: Data) -> [Effect] {
        let message: AgentRPCMessage
        do {
            message = try AgentRPCMessage.decode(line)
        } catch {
            return [.reply(.error(id: nil, error: error as? AgentRPCError ?? .parseError()))]
        }
        switch message {
        case .request(let id, let method, let params):
            return request(id: id, method: method, params: params)
        case .notification(let method, let params):
            return notification(method: method, params: params)
        case .result, .error:
            // arch-mcp sends the client no requests, so an answer answers nothing.
            return []
        }
    }

    private mutating func request(id: AgentRPCID, method: String, params: AgentJSON?) -> [Effect] {
        switch method {
        case "initialize":
            return initialize(id: id, params: params)
        case "ping":
            return [.reply(.result(id: id, result: .object([:])))]
        case "tools/list":
            guard protocolVersion != nil else { return [notInitialized(id)] }
            return forward(Request(id: id, kind: .list))
        case "tools/call":
            guard protocolVersion != nil else { return [notInitialized(id)] }
            return call(id: id, params: params)
        default:
            // Any other method, before `initialize` too, such as the `server/discover` that Claude Code sends first.
            return [.reply(.error(id: id, error: .methodNotFound(method)))]
        }
    }

    private func notInitialized(_ id: AgentRPCID) -> Effect {
        .reply(.error(id: id, error: .invalidRequest("Send initialize first.")))
    }

    private mutating func initialize(id: AgentRPCID, params: AgentJSON?) -> [Effect] {
        guard protocolVersion == nil else { return [.reply(.error(id: id, error: .invalidRequest("initialize was already answered.")))] }
        guard let requested = params?["protocolVersion"]?.stringValue else {
            return [.reply(.error(id: id, error: .invalidParams("initialize needs a protocolVersion.")))]
        }
        let agreed = AgentMCPVersion.negotiated(forRequested: requested)
        protocolVersion = agreed
        return [.reply(.result(id: id, result: [
            "protocolVersion": .string(agreed),
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": ["name": .string(Self.serverName), "version": .string(version)],
            "instructions": .string(instructions),
        ]))]
    }

    private mutating func call(id: AgentRPCID, params: AgentJSON?) -> [Effect] {
        guard let name = params?["name"]?.stringValue else { return [.reply(.error(id: id, error: .invalidParams("tools/call needs a tool name.")))] }
        let arguments: [String: AgentJSON]
        switch params?["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let object)?: arguments = object
        default: return [.reply(.error(id: id, error: .invalidParams("A tool's arguments must be an object.")))]
        }
        guard AgentToolCatalog.tool(named: name) != nil else { return [.reply(.error(id: id, error: .invalidParams("Unknown tool: \(name)")))] }
        var token: AgentJSON?
        switch params?["_meta"]?["progressToken"] {
        case let value? where value.stringValue != nil: token = value
        case .number(let number)? where number.rounded() == number: token = .number(number)
        default: token = nil
        }
        return forward(Request(id: id, kind: .call(AgentToolCall(name: name, arguments: arguments), progressToken: token)))
    }

    private mutating func notification(method: String, params: AgentJSON?) -> [Effect] {
        guard method == "notifications/cancelled", let id = params?["requestId"].flatMap(AgentRPCID.init) else { return [] }
        // A request still waiting for the connection never reaches Arch. `MCPServerLoop` connects before it reads the next line, so there the request has always been sent.
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index)
            return []
        }
        guard let entry = pending.first(where: { $0.value.id == id }) else { return [] }
        pending[entry.key] = nil
        guard case .call = entry.value.kind else { return [] }
        return [.send(.notification(method: AgentControlMethod.toolsCancelNotification, params: AgentToolCancel(call: entry.key).params))]
    }

    // MARK: - Arch

    /// Arch answered `hello` and the connection is open.
    public mutating func connected(_ answer: AgentHelloAnswer) -> [Effect] {
        if case .session = mode, answer.status != .bound {
            return [.log("Arch did not bind this connection to its agent session."), .exit(.noGrant)]
        }
        link = .connected
        // Arch's list may differ from the one the client has, which came from the catalog or an earlier connection.
        var effects = hasListedTools ? listChanged() : []
        let requests = waiting
        waiting = []
        for request in requests { effects += send(request) }
        return effects
    }

    /// No connection could be made, or the open one closed. A session's server ends with it; an outside client's tool calls get the reason as an error result and its tool lists come from the catalog until a later request connects again.
    public mutating func connectionFailed(_ error: AgentClientError) -> [Effect] {
        if case .session = mode { return [.log(error.message), .exit(error.exitCode)] }
        link = .disconnected
        let requests = waiting + pending.sorted { $0.key < $1.key }.map(\.value)
        waiting = []
        pending = [:]
        var effects: [Effect] = [.log(error.message)]
        for request in requests {
            switch request.kind {
            case .list: effects.append(.reply(.result(id: request.id, result: toolList(names: nil))))
            case .call: effects.append(.reply(.result(id: request.id, result: errorResult(error.message))))
            }
        }
        return effects
    }

    /// One message from Arch on the open connection.
    public mutating func receive(control message: AgentRPCMessage) -> [Effect] {
        switch message {
        case .result(.number(let controlID), let result):
            guard let request = pending.removeValue(forKey: controlID) else { return [] }
            return [answer(request, with: result)]
        case .error(.number(let controlID)?, let error):
            guard let request = pending.removeValue(forKey: controlID) else { return [] }
            switch request.kind {
            case .list: return [.reply(.error(id: request.id, error: .internalError(error.message)))]
            case .call: return [.reply(.result(id: request.id, result: errorResult(error.message)))]
            }
        case .error(nil, let error):
            return [.log("Arch could not read a message: \(error.message)")]
        case .notification(AgentControlMethod.progressNotification, let params):
            guard let progress = try? params?.decode(as: AgentToolProgress.self) else { return [] }
            return progressed(progress)
        case .notification(AgentControlMethod.toolsChangedNotification, _):
            return listChanged()
        case .notification(AgentControlMethod.revokedNotification, _):
            return [.log("Arch ended this client's grant.")]
        case .request(let id, let method, _):
            return [.send(.error(id: id, error: .methodNotFound(method)))]
        default:
            return []
        }
    }

    private var hello: AgentHello {
        if case .session(let ticket) = mode { return AgentHello(client: .mcp, version: version, ticket: ticket) }
        return AgentHello(client: .mcp, version: version)
    }

    private mutating func forward(_ request: Request) -> [Effect] {
        switch link {
        case .connected:
            return send(request)
        case .connecting:
            waiting.append(request)
            return []
        case .disconnected:
            waiting.append(request)
            link = .connecting
            return [.connect(hello)]
        }
    }

    private mutating func send(_ request: Request) -> [Effect] {
        let controlID = nextControlID
        nextControlID += 1
        pending[controlID] = request
        switch request.kind {
        case .list: return [.send(.request(id: .number(controlID), method: AgentControlMethod.toolsList, params: nil))]
        case .call(let call, _): return [.send(.request(id: .number(controlID), method: AgentControlMethod.toolsCall, params: call.params))]
        }
    }

    private mutating func answer(_ request: Request, with result: AgentJSON) -> Effect {
        switch request.kind {
        case .list:
            guard let list = try? result.decode(as: AgentToolList.self) else {
                return .reply(.error(id: request.id, error: .internalError("Arch's tool list could not be read.")))
            }
            return .reply(.result(id: request.id, result: toolList(names: list.tools)))
        case .call:
            guard let result = try? result.decode(as: AgentToolResult.self) else {
                return .reply(.result(id: request.id, result: errorResult("Arch's answer could not be read.")))
            }
            return .reply(.result(id: request.id, result: callResult(result)))
        }
    }

    private mutating func progressed(_ progress: AgentToolProgress) -> [Effect] {
        guard var request = pending[progress.call], case .call(_, let token?) = request.kind else { return [] }
        request.progress += 1
        pending[progress.call] = request
        var params: [String: AgentJSON] = ["progressToken": token, "progress": .number(Double(request.progress))]
        if supports(AgentMCPVersion.progressMessage) { params["message"] = .string(progress.message) }
        return [.reply(.notification(method: "notifications/progress", params: .object(params)))]
    }

    private func listChanged() -> [Effect] {
        guard protocolVersion != nil else { return [] }
        return [.reply(.notification(method: "notifications/tools/list_changed", params: nil))]
    }

    // MARK: - Results

    private func supports(_ version: String) -> Bool {
        (protocolVersion ?? AgentMCPVersion.newest) >= version
    }

    /// MCP's `tools/list` result for the tools Arch named, in its order, or for the whole catalog.
    private mutating func toolList(names: [String]?) -> AgentJSON {
        hasListedTools = true
        let lookup = mode == .outside ? AgentToolCatalog.tool(named:) : AgentToolCatalog.sessionTool(named:)
        let tools = names.map { $0.compactMap(lookup) } ?? AgentToolCatalog.tools
        return ["tools": .array(tools.map { tool in
            guard !supports(AgentMCPVersion.annotations), case .object(var definition) = tool.mcpDefinition else { return tool.mcpDefinition }
            definition["annotations"] = nil
            return .object(definition)
        })]
    }

    /// MCP's `tools/call` result for Arch's: the content and `isError` unless the call succeeded or waits for the user. It carries no `structuredContent`, which no tool's schema asks for: Codex 0.164.0 gives its model only `structuredContent` when a result has it, and the model would lose the text, the image, and the sentences of a refusal.
    private func callResult(_ result: AgentToolResult) -> AgentJSON {
        var content = result.content.map(\.mcpContent)
        if result.status == .approvalPending {
            guard let approval = result.approval else { return errorResult("Arch's answer could not be read: it waits for an approval it does not name.") }
            content.insert(["type": "text", "text": .string("Waiting for the user in Arch; call approval_wait with this ID: \(approval)")], at: 0)
        }
        return ["content": .array(content), "isError": .bool(result.status != .ok && result.status != .approvalPending)]
    }

    private func errorResult(_ message: String) -> AgentJSON {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }
}
