// The provider-neutral AI interface: typed requests, streamed replies, tool calls, and cancellation. Every AI call in Arch goes through an `AIClient`; `AIService` is the one the app uses.
import Foundation

/// Names the feature that makes a request. The feature decides the route, the page data the request may carry, and its priority.
public struct AIFeatureID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The route that features the user starts fall back to; not a feature itself.
    public static let defaultRoute = AIFeatureID(rawValue: "default")
    public static let pageReader = AIFeatureID(rawValue: "pageReader")
    public static let pageQuestion = AIFeatureID(rawValue: "pageQuestion")
    public static let tabNameHook = AIFeatureID(rawValue: "hook.tabName")
    public static let downloadNameHook = AIFeatureID(rawValue: "hook.downloadName")
    public static let pluginComposer = AIFeatureID(rawValue: "pluginComposer")

    /// A plugin's own feature, `plugin.<plugin identifier>`.
    public static func plugin(_ pluginID: String) -> AIFeatureID {
        AIFeatureID(rawValue: "plugin.\(pluginID)")
    }
}

// MARK: - Requests

/// One request. The interface is stateless: a feature keeps its conversation and sends it whole each time. Requests carry no sampling parameters, so the provider's defaults apply.
public struct AIRequest: Sendable {
    public var feature: AIFeatureID
    /// System text. The service prepends its own line about untrusted page content.
    public var instructions: String?
    public var messages: [AIMessage]
    public var tools: [AITool]
    public var output: AIOutputFormat
    /// nil uses 4,096.
    public var maxOutputTokens: Int?
    /// The one model that serves the request, with no fallback, so that every round of a conversation stays on the model of its first; nil uses `route`, or the feature's route without one. It must still exist and meet the feature's requirements.
    public var pinnedModel: AIModelRef?
    /// The route the request names for itself, which a `perRequest` feature needs and a feature the user starts may use instead of its own; nil uses the feature's route. A stored automatic feature refuses one with `blockedByPolicy(.routeNotAllowed)`.
    public var route: AIRouteChoice?
    /// false leaves the request's Activity entry without content, so Show Content has nothing to show; its part kinds and sizes, model, result, and usage stay.
    public var recordsContent: Bool
    /// Provider destinations approved for a hook, checked again before dispatch. Other features leave this nil.
    public var knownProviders: [AIProviderID: String]? = nil

    public init(feature: AIFeatureID, instructions: String? = nil, messages: [AIMessage],
                tools: [AITool] = [], output: AIOutputFormat = .text, maxOutputTokens: Int? = nil, pinnedModel: AIModelRef? = nil,
                route: AIRouteChoice? = nil, recordsContent: Bool = true) {
        self.feature = feature
        self.instructions = instructions
        self.messages = messages
        self.tools = tools
        self.output = output
        self.maxOutputTokens = maxOutputTokens
        self.pinnedModel = pinnedModel
        self.route = route
        self.recordsContent = recordsContent
    }
}

/// One user or assistant message with typed content parts.
public struct AIMessage: Sendable {
    /// The speaker of a message in an AI conversation.
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public var role: Role
    public var parts: [AIPart]

    public init(role: Role, parts: [AIPart]) {
        self.role = role
        self.parts = parts
    }
}

/// The reply format a request asks the provider to produce.
public enum AIOutputFormat: Sendable {
    case text
    /// A reply that is one JSON value matching the schema, a JSON Schema object.
    case json(schema: Data)
}

// MARK: - Content parts

/// Typed parts let the service apply site exclusions and truncation and let Settings ▸ AI say what each feature sends.
public enum AIPart: Sendable {
    case text(String)
    case page(AIPageContent)
    case selection(AISelection)
    case file(AIFile)
    case download(AIDownloadInfo)
    /// Only in assistant messages.
    case toolCall(AIToolCall)
    /// Only in user messages.
    case toolResult(AIToolResult)
}

/// A page address, title, and readable text supplied to a request.
public struct AIPageContent: Sendable {
    /// The page's address. The service removes the query and fragment before sending.
    public var url: URL
    public var title: String
    /// Readable text from the engine.
    public var text: String
    /// The document's `lang` attribute.
    public var language: String?
    public var isTruncated: Bool

    public init(url: URL, title: String, text: String, language: String? = nil, isTruncated: Bool = false) {
        self.url = url
        self.title = title
        self.text = text
        self.language = language
        self.isTruncated = isTruncated
    }
}

/// Selected text with the page that supplied it.
public struct AISelection: Sendable {
    public var pageURL: URL
    public var pageTitle: String
    public var text: String

    public init(pageURL: URL, pageTitle: String, text: String) {
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.text = text
    }
}

/// A named file part with its bytes and optional source address.
public struct AIFile: Sendable {
    public var name: String
    /// For example `text/plain`, `application/pdf`, or `image/png`.
    public var mediaType: String
    public var data: Data
    /// Where the file came from. Site exclusions apply to it.
    public var sourceURL: URL?

    public init(name: String, mediaType: String, data: Data, sourceURL: URL? = nil) {
        self.name = name
        self.mediaType = mediaType
        self.data = data
        self.sourceURL = sourceURL
    }
}

/// Download metadata a feature may send without the file's bytes.
public struct AIDownloadInfo: Sendable {
    public var filename: String
    public var mediaType: String?
    public var byteCount: Int64?
    public var sourceURL: URL?
    /// The page that started the download.
    public var pageURL: URL?
    public var pageTitle: String?

    public init(filename: String, mediaType: String? = nil, byteCount: Int64? = nil, sourceURL: URL? = nil, pageURL: URL? = nil, pageTitle: String? = nil) {
        self.filename = filename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.pageTitle = pageTitle
    }
}

// MARK: - Replies and streaming

/// The provider-neutral interface for streaming AI requests.
public protocol AIClient: Sendable {
    /// Streams the reply. The stream ends after `.finished` or with an `AIError`. Cancelling the task that reads the stream, or dropping the stream, cancels the request.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error>
}

/// Events arrive in this order: `waiting` (zero or more times), `started`, then `text` and `toolCall` in any order, then `usage` when the provider reports it, then `finished`.
public enum AIEvent: Sendable {
    /// The request waits for a provider slot or a cool-down.
    case waiting(AIWaitReason)
    /// The model that serves the request, after any fallback.
    case started(AIModelRef)
    /// Text to append to the reply.
    case text(String)
    /// A complete tool call. Partial arguments are never delivered.
    case toolCall(AIToolCall)
    case usage(AIUsage)
    case finished(AIFinishReason)
}

/// Why a request is waiting before a provider starts it.
public enum AIWaitReason: Sendable, Equatable {
    case queued
    case rateLimited(until: Date)
}

/// How the provider ended a reply.
public enum AIFinishReason: Sendable, Equatable {
    case completed
    case lengthLimit
    case toolUse
}

/// A streamed request collected into its text, calls, model, and usage.
public struct AIReply: Sendable {
    public var text: String
    public var toolCalls: [AIToolCall]
    public var model: AIModelRef
    public var usage: AIUsage?
    public var finishReason: AIFinishReason
}

extension AIClient {
    /// Collects the stream into one reply. A `.json` reply must parse, or this throws `replyTooLong` for one that reached the length limit and `malformedReply` for any other.
    public func reply(_ request: AIRequest) async throws -> AIReply {
        var text = ""
        var toolCalls: [AIToolCall] = []
        var model: AIModelRef?
        var usage: AIUsage?
        var finishReason: AIFinishReason?
        for try await event in stream(request) {
            switch event {
            case .waiting:
                break
            case .started(let ref):
                model = ref
            case .text(let delta):
                text += delta
            case .toolCall(let call):
                toolCalls.append(call)
            case .usage(let reported):
                // `run` passes on one usage event per round.
                usage = usage.map { $0 + reported } ?? reported
            case .finished(let reason):
                finishReason = reason
            }
        }
        // A stream read by a cancelled task ends without an error.
        if Task.isCancelled { throw AIError.cancelled }
        guard let model, let finishReason else { throw AIError.malformedReply(localized("The reply ended without finishing.")) }
        if case .json = request.output, (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) == nil {
            throw finishReason == .lengthLimit ? AIError.replyTooLong : AIError.malformedReply(localized("The reply is not valid JSON."))
        }
        return AIReply(text: text, toolCalls: toolCalls, model: model, usage: usage, finishReason: finishReason)
    }
}

// MARK: - Tool calls

/// A tool definition offered to a model with a JSON argument schema.
public struct AITool: Sendable {
    /// 1 to 64 characters from `a-z`, `A-Z`, `0-9`, `_`, and `-`.
    public var name: String
    public var description: String
    /// A JSON Schema object for the arguments.
    public var inputSchema: Data

    public init(name: String, description: String, inputSchema: Data) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// A model's complete call to one offered tool.
public struct AIToolCall: Sendable {
    public var id: String
    public var name: String
    /// A JSON object.
    public var arguments: Data

    public init(id: String, name: String, arguments: Data) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The content returned for a tool call, or an error the model can read.
public struct AIToolResult: Sendable {
    public var callID: String
    /// Text, page, selection, and image parts. The service checks them like any other part; a result the checks refuse goes to the model as an error result that says why, and an image goes only to a model with `images` whose format carries images in tool results (`messages`). An image's `sourceURL` names the page it shows, so that site exclusions apply to it.
    public var parts: [AIPart]
    public var isError: Bool
    /// One line sent in place of the result once it is more than `AIToolHistory.wholeRounds` rounds old, or older rounds do not fit the model's input limit, such as "Earlier read_text on t2: ok, 12,000 characters of page text." It must hold no page data. nil uses a line that names the tool.
    public var note: String?
    /// Rechecks a retained agent result against live tab grants before each HTTP attempt.
    /// The returned copy can drop individual rows or replace the result with a refusal.
    public var checkingAccess: (@MainActor @Sendable (AIToolResult) -> AIToolResult)?

    public init(callID: String, parts: [AIPart], isError: Bool = false, note: String? = nil) {
        self.callID = callID
        self.parts = parts
        self.isError = isError
        self.note = note
    }
}

/// A tool together with the code that performs its calls. A model can ask for any offered tool, and a page can try to make it ask, so a tool that changes state must be safe to call at any time.
public struct AIToolHandler: Sendable {
    public var tool: AITool
    public var perform: @Sendable (AIToolCall) async throws -> AIToolResult

    public init(tool: AITool, perform: @escaping @Sendable (AIToolCall) async throws -> AIToolResult) {
        self.tool = tool
        self.perform = perform
    }
}

extension AIClient {
    /// Sends the request with the handlers' tools, performs each tool call the model makes, sends the results back, and repeats until the model finishes without a tool call or `maxRounds` rounds have run. Calls run one at a time in the order the model made them; a call to a tool not offered, or one whose handler throws, becomes an error result for the model. Every round's events are passed on except its `finished(.toolUse)`. One-shot callers can perform the last round's calls and set a total call limit. Reaching either limit ends the run without another model request.
    ///
    /// The model that served the first round serves every later one (`pinnedModel`). Before each round the conversation is prepared as `AIToolHistory` describes, and `AIService` sends older results as notes while a request is over its model's input limit, so a long conversation stays within it. `conversationDidChange` gets the conversation after each round whose calls all ran, and after the final reply or the round limit, before the stream goes on: the request's messages as last sent, the replies, and the results, with no tool call left without its result. A caller that keeps a conversation across requests, as an agent session does, continues from it; a round that fails or is cancelled is not in it. `unavailableTool` hears of each call to a tool not offered, without the model's name or arguments for it.
    public func run(_ request: AIRequest, tools: [AIToolHandler], maxRounds: Int = 8, performsFinalCalls: Bool = false, maximumToolCalls: Int? = nil,
                    conversationDidChange: (@Sendable ([AIMessage]) async -> Void)? = nil,
                    unavailableTool: (@Sendable () async -> Void)? = nil) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runRounds(request, tools: tools, maxRounds: maxRounds, performsFinalCalls: performsFinalCalls, maximumToolCalls: maximumToolCalls, unavailableTool: unavailableTool, conversationDidChange: conversationDidChange, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams model rounds and applies bounded tool calls while preserving the conversation.
    private func runRounds(_ request: AIRequest, tools: [AIToolHandler], maxRounds: Int, performsFinalCalls: Bool, maximumToolCalls: Int?, unavailableTool: (@Sendable () async -> Void)?, conversationDidChange: (@Sendable ([AIMessage]) async -> Void)?,
                           continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws {
        var request = request
        request.tools = tools.map(\.tool)
        var callCount = 0
        for round in 1...max(maxRounds, 1) {
            request.messages = await AIToolHistory.checkingAccess(in: AIToolHistory.prepared(request.messages))
            var text = ""
            var calls: [AIToolCall] = []
            var finishReason = AIFinishReason.completed
            var servingModel: AIModelRef?
            for try await event in stream(request) {
                switch event {
                case .started(let model):
                    servingModel = model
                    continuation.yield(event)
                case .text(let delta):
                    text += delta
                    continuation.yield(event)
                case .toolCall(let call):
                    calls.append(call)
                    continuation.yield(event)
                case .finished(let reason):
                    finishReason = reason
                default:
                    continuation.yield(event)
                }
            }
            try Task.checkCancellation()
            // A bounded one-shot run can apply the final calls without paying for another model request.
            guard !calls.isEmpty, round < maxRounds || performsFinalCalls else {
                if !text.isEmpty { request.messages.append(AIMessage(role: .assistant, parts: [.text(text)])) }
                await conversationDidChange?(request.messages)
                guard calls.isEmpty else { break }
                continuation.yield(.finished(finishReason))
                return
            }
            var results: [AIPart] = []
            for call in calls {
                try Task.checkCancellation()
                if let maximumToolCalls, callCount >= maximumToolCalls { break }
                callCount += 1
                results.append(.toolResult(await Self.perform(call, with: tools, unavailableTool: unavailableTool)))
            }
            try Task.checkCancellation()
            let reply: [AIPart] = (text.isEmpty ? [] : [.text(text)]) + calls.prefix(results.count).map { .toolCall($0) }
            request.messages.append(AIMessage(role: .assistant, parts: reply))
            request.messages.append(AIMessage(role: .user, parts: results))
            request.pinnedModel = request.pinnedModel ?? servingModel
            await conversationDidChange?(request.messages)
            if let maximumToolCalls, callCount >= maximumToolCalls { throw AIError.toolCallLimit }
        }
        throw AIError.toolRoundLimit
    }

    /// Runs an offered tool and turns unavailable tools or thrown errors into error results.
    private static func perform(_ call: AIToolCall, with tools: [AIToolHandler], unavailableTool: (@Sendable () async -> Void)?) async -> AIToolResult {
        guard let handler = tools.first(where: { $0.tool.name == call.name }) else {
            await unavailableTool?()
            return AIToolResult(callID: call.id, parts: [.text("There is no tool named \(call.name).")], isError: true)
        }
        do {
            return try await handler.perform(call)
        } catch {
            return AIToolResult(callID: call.id, parts: [.text(error.localizedDescription)], isError: true)
        }
    }
}

/// How a long tool conversation stays within a model's input limit (`docs/agents.md`, API-key sessions): before each round `run` sends results more than `wholeRounds` rounds old as their one-line notes, and an image in a result only until a reply follows a request that carried it; the service then sends older results as notes too while the request is over the serving model's limit.
enum AIToolHistory {
    /// The rounds of tool results, counted back from the newest, that go whole.
    static let wholeRounds = 8

    /// Rechecks retained tool results against current access before another model round.
    @MainActor static func checkingAccess(in messages: [AIMessage]) -> [AIMessage] {
        messages.map { message in
            var message = message
            message.parts = message.parts.map { part in
                guard case .toolResult(let result) = part, let check = result.checkingAccess else { return part }
                return .toolResult(check(result))
            }
            return message
        }
    }

    static let imageNote = "An image was here and is left out now; call the tool again to see it."

    /// The conversation as the next round sends it. A user message with tool results counts as one round. Each result more than `wholeRounds` rounds back becomes its note, and each image in a result becomes `imageNote` once an assistant message follows the result's message, which means a request that carried the image was answered; a round that failed or was stopped leaves its image for the next request. Applying it again changes nothing.
    static func prepared(_ messages: [AIMessage]) -> [AIMessage] {
        let toolNames = toolNames(in: messages)
        var prepared = messages
        var rounds = 0
        var isAnswered = false
        for index in prepared.indices.reversed() {
            if prepared[index].role == .assistant { isAnswered = true }
            guard hasResults(prepared[index]) else { continue }
            rounds += 1
            let isOld = rounds > wholeRounds
            prepared[index].parts = prepared[index].parts.map { part in
                if isOld { return noted(part, toolNames: toolNames) }
                guard isAnswered, case .toolResult(var result) = part else { return part }
                result.parts = result.parts.map { part in
                    if case .file(let file) = part, AIPartText.isImage(file) { return .text(imageNote) }
                    return part
                }
                return .toolResult(result)
            }
        }
        return prepared
    }

    /// The conversation with the results of the oldest rounds as their notes, one round after another and never the newest, until its parts fit `characterLimit` as `AIPartPolicy` counts them. Page text still over the limit is cut afterward, as in any request.
    static func fitted(_ messages: [AIMessage], characterLimit: Int) -> [AIMessage] {
        var total = AIPartPolicy.characterCount(of: messages)
        guard total > characterLimit else { return messages }
        let toolNames = toolNames(in: messages)
        var fitted = messages
        for index in fitted.indices.filter({ hasResults(fitted[$0]) }).dropLast() where total > characterLimit {
            let before = AIPartPolicy.characterCount(of: [fitted[index]])
            fitted[index].parts = fitted[index].parts.map { noted($0, toolNames: toolNames) }
            total += AIPartPolicy.characterCount(of: [fitted[index]]) - before
        }
        return fitted
    }

    /// Maps tool call identifiers to names for notes about older results.
    private static func toolNames(in messages: [AIMessage]) -> [String: String] {
        var names: [String: String] = [:]
        for message in messages {
            for case .toolCall(let call) in message.parts { names[call.id] = call.name }
        }
        return names
    }

    /// Reports whether a message contains at least one tool result.
    private static func hasResults(_ message: AIMessage) -> Bool {
        message.parts.contains { if case .toolResult = $0 { return true } else { return false } }
    }

    /// A tool result as its note.
    private static func noted(_ part: AIPart, toolNames: [String: String]) -> AIPart {
        guard case .toolResult(let result) = part else { return part }
        let note = result.note ?? "Earlier result of \(toolNames[result.callID] ?? "a tool"), left out to save space."
        return .toolResult(AIToolResult(callID: result.callID, parts: [.text(note)], isError: result.isError, note: note))
    }
}
