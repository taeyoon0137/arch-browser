// API-key sessions (docs/agents.md, Sessions on the user's CLI ▸ API-key sessions): an agent session on an HTTP model with tools, run in Arch's process on `AIClient.run` with no socket and no CLI. Its tools are the tool host's, bound to the session through `AgentSessionTools`. Their results reach the model as text parts for what the host wrote, page parts for page text, so that the AI interface's checks apply as well as the host's, and image parts for screenshots. The conversation stays in memory until the session ends. The session reports the same `AIAgentEvent`s as a session on the user's CLI, so the panel shows both alike.
import AgentControl
import AI
import Foundation

/// The tool host as one in-app session sees it: bound to the session's Persona, space, mode, and site scope, and deciding each call by the session's rules. Plan task VII.17 binds sessions to a space and adopts this for API-key sessions; until then only tests make one.
@MainActor public protocol AgentSessionTools: AnyObject {
    /// The catalog tools the session may call now, in catalog order, as `tools/list` would name them. The session reads them at the start of each message.
    var tools: [AgentTool] { get }
    /// Runs one call through the tool host and its rules.
    func run(_ call: AgentToolCall) async -> AgentToolResult
}

@MainActor public final class AgentAPISession {
    /// Rounds of model requests per user message.
    public nonisolated static let roundsPerMessage = 50

    /// `ready` with the model before the session's first text or tool call, then each message's text, its usage, and `turnFinished` (`completed`, `stopped`, or `turnLimit` after `roundsPerMessage` rounds) or `turnFailed`. A failed message leaves the session open; the stream ends, without an error, only at `end()`.
    public nonisolated let events: AsyncThrowingStream<AIAgentEvent, any Error>
    public let id: UUID
    /// The model that holds the conversation: the one the session was made with, or from `ready` on the one that served its first round. Every later request is pinned to it.
    public private(set) var model: AIModelRef?
    /// What the model was sent and answered, as the last finished round sent it: the user's messages, the replies, and the tool results, older ones as notes. A round that failed or was stopped is not in it.
    public private(set) var conversation: [AIMessage] = []
    public private(set) var isTurnRunning = false
    /// Messages sent while a turn runs, which start in order after it.
    public private(set) var queuedMessages: [String] = []
    public private(set) var hasEnded = false

    private let client: any AIClient
    private let tools: any AgentSessionTools
    private let feature: AIFeatureID
    private let instructions: String
    private let continuation: AsyncThrowingStream<AIAgentEvent, any Error>.Continuation
    private var isReady = false
    /// The number of the latest message's turn. A stopped turn's task can still deliver events and rounds, which its number tells apart and drops.
    private var turn = 0
    private var turnTask: Task<Void, Never>?
    private var turnUsage: AIUsage?

    /// `client` is the app's `AIService`. With `model` nil, the first round takes the feature's route, whose later models serve only when the earlier fail before any output, and command-line tools never serve, since the requests carry tools.
    public init(client: any AIClient, tools: any AgentSessionTools, feature: AIFeatureID = .agent, model: AIModelRef? = nil,
                instructions: String = AgentHarness.instructions, id: UUID = UUID()) {
        (events, continuation) = AsyncThrowingStream.makeStream()
        self.client = client
        self.tools = tools
        self.feature = feature
        self.model = model
        self.instructions = instructions
        self.id = id
    }

    // MARK: Messages

    /// Sends the user's message, or queues it while a turn runs. The caller writes the first message's preamble with the tab handles (agent decision 12).
    public func send(_ message: String) {
        guard !hasEnded else { return }
        queuedMessages.append(message)
        startNextTurn()
    }

    /// Ends the running turn at once and drops the queued messages. The rounds that finished stay in the conversation; a call the tool host is running ends as the host decides.
    public func stop() {
        queuedMessages.removeAll()
        guard isTurnRunning else { return }
        turnTask?.cancel()
        finishTurn(.turnFinished(.stopped))
    }

    /// Ends the session: stops its turn, drops the conversation, and finishes `events`.
    public func end() {
        guard !hasEnded else { return }
        stop()
        hasEnded = true
        conversation = []
        continuation.finish()
    }

    private func startNextTurn() {
        guard !isTurnRunning, !hasEnded, !queuedMessages.isEmpty else { return }
        let message = queuedMessages.removeFirst()
        isTurnRunning = true
        turn += 1
        turnUsage = nil
        conversation.append(AIMessage(role: .user, parts: [.text(message)]))
        let number = turn
        let request = AIRequest(feature: feature, instructions: instructions, messages: conversation, pinnedModel: model)
        let handlers = tools.tools.map { handler(for: $0, turn: number) }
        turnTask = Task { await runTurn(number, request, handlers) }
    }

    private func runTurn(_ number: Int, _ request: AIRequest, _ handlers: [AIToolHandler]) async {
        let stream = client.run(request, tools: handlers, maxRounds: Self.roundsPerMessage) { [weak self] messages in
            await self?.keep(messages, turn: number)
        }
        var servingModel: AIModelRef?
        let end: AIAgentEvent
        do {
            for try await event in stream {
                guard isCurrent(number) else { return }
                switch event {
                case .started(let ref):
                    servingModel = ref
                case .text(let text):
                    becomeReady(servingModel)
                    continuation.yield(.text(text))
                case .toolCall:
                    becomeReady(servingModel)
                case .usage(let usage):
                    turnUsage = turnUsage.map { $0 + usage } ?? usage
                case .waiting, .finished:
                    break
                }
            }
            end = .turnFinished(.completed)
        } catch AIError.toolRoundLimit {
            end = .turnFinished(.turnLimit)
        } catch {
            end = .turnFailed(error as? AIError ?? .invalidRequest(error.localizedDescription))
        }
        guard isCurrent(number) else { return }
        // A reply without text or tool calls holds the conversation too.
        if case .turnFinished = end { becomeReady(servingModel) }
        finishTurn(end)
    }

    private func isCurrent(_ number: Int) -> Bool {
        turn == number && isTurnRunning
    }

    private func becomeReady(_ servingModel: AIModelRef?) {
        guard !isReady, let ready = model ?? servingModel else { return }
        isReady = true
        model = ready
        continuation.yield(.ready(ready))
    }

    /// The conversation after a finished round of the current turn.
    private func keep(_ messages: [AIMessage], turn number: Int) {
        guard isCurrent(number) else { return }
        conversation = messages
    }

    private func finishTurn(_ end: AIAgentEvent) {
        isTurnRunning = false
        turnTask = nil
        if let turnUsage { continuation.yield(.usage(turnUsage)) }
        turnUsage = nil
        continuation.yield(end)
        startNextTurn()
    }

    // MARK: Tool calls

    private func handler(for tool: AgentTool, turn number: Int) -> AIToolHandler {
        let schema = (try? tool.inputSchema.encoded()) ?? Data(#"{"type":"object"}"#.utf8)
        return AIToolHandler(tool: AITool(name: tool.name, description: tool.description, inputSchema: schema)) { [weak self] call in
            guard let self else { throw CancellationError() }
            return await self.perform(call, turn: number)
        }
    }

    private func perform(_ call: AIToolCall, turn number: Int) async -> AIToolResult {
        guard isCurrent(number) else { return AIToolResult(callID: call.id, parts: [.text("The user stopped this message.")], isError: true) }
        guard let arguments = Self.arguments(call.arguments) else {
            return AIToolResult(callID: call.id, parts: [.text("The arguments of \(call.name) are not a JSON object.")], isError: true)
        }
        let agentCall = AgentToolCall(name: call.name, arguments: arguments)
        return Self.result(await tools.run(agentCall), of: agentCall, callID: call.id)
    }

    /// A call's arguments as an object; empty arguments, which some providers send for a tool without parameters, are none.
    nonisolated static func arguments(_ data: Data) -> [String: AgentJSON]? {
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard case .object(let arguments)? = try? AgentJSON.decode(data) else { return nil }
        return arguments
    }

    // MARK: Results

    /// The host's result as the model reads it: a status line unless the call succeeded, then the content, with each untrusted block that names its page as a page part and each image as an image part. The note says what the result held, without page text. It is an error result unless it succeeded or waits for the user, as MCP marks it.
    nonisolated static func result(_ result: AgentToolResult, of call: AgentToolCall, callID: String) -> AIToolResult {
        var parts: [AIPart] = []
        switch result.status {
        case .ok:
            break
        case .approvalPending:
            parts.append(.text("Waiting for the user in Arch; call approval_wait with this ID: \(result.approval ?? "")"))
        default:
            parts.append(.text("Status: \(result.status.rawValue)" + (result.code.map { " (\($0))" } ?? "") + "."))
        }
        var pageCharacters = 0
        var images = 0
        for content in result.content {
            switch content {
            case .text(let text):
                for part in Self.parts(ofHostText: text) {
                    if case .page(let page) = part { pageCharacters += page.text.count }
                    parts.append(part)
                }
            case .image(let data, let mimeType):
                images += 1
                parts.append(.file(AIFile(name: "screenshot", mediaType: mimeType, data: data)))
            }
        }
        var held: [String] = []
        if pageCharacters > 0 { held.append("\(number(pageCharacters)) characters of page text") }
        if images > 0 { held.append(images == 1 ? "1 image" : "\(images) images") }
        if held.isEmpty { held.append(result.text.count == 1 ? "1 character" : "\(number(result.text.count)) characters") }
        let tab = call.arguments["tab"]?.stringValue.flatMap { $0.count <= 16 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? " on \($0)" : nil } ?? ""
        let status = result.status.rawValue + (result.code.map { " (\($0))" } ?? "")
        let note = "Earlier \(call.name)\(tab): \(status), \(held.joined(separator: " and ")), left out to save space."
        return AIToolResult(callID: callID, parts: parts, isError: result.status != .ok && result.status != .approvalPending, note: note)
    }

    /// The host's text with each untrusted block that names its page (`AgentUntrusted.wrap`) as a page part, so that the AI interface checks the page's site and strips its address; the text around the blocks, and a block without an address, stay text. The wrapper escapes every `</untrusted` inside a block, so the first closing tag ends it.
    nonisolated static func parts(ofHostText text: String) -> [AIPart] {
        let opening = "<untrusted source=\"page\""
        let closing = "</untrusted>"
        var parts: [AIPart] = []
        var pending = ""
        var rest = text[...]
        while let start = rest.range(of: opening),
              let tagEnd = rest[start.upperBound...].firstIndex(of: ">"),
              let end = rest[tagEnd...].range(of: closing) {
            if let url = pageURL(in: rest[start.upperBound..<tagEnd]) {
                pending += rest[..<start.lowerBound]
                if !pending.isEmpty { parts.append(.text(pending)) }
                pending = ""
                let content = rest[rest.index(after: tagEnd)..<end.lowerBound].replacingOccurrences(of: "<\\/untrusted", with: "</untrusted")
                parts.append(.page(AIPageContent(url: url, title: "", text: content)))
            } else {
                pending += rest[..<end.upperBound]
            }
            rest = rest[end.upperBound...]
        }
        pending += rest
        if !pending.isEmpty { parts.append(.text(pending)) }
        return parts
    }

    /// The `url` attribute of an untrusted block's opening tag, unescaped.
    private nonisolated static func pageURL(in attributes: Substring) -> URL? {
        guard let start = attributes.range(of: " url=\""), let end = attributes[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let value = attributes[start.upperBound..<end]
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: value)
    }

    private nonisolated static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
