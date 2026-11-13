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
    /// The route the request names for itself, which a `perRequest` feature needs and a feature the user starts may use instead of its own; nil uses the feature's route. A stored automatic feature refuses one with `invalidRequest`.
    public var route: AIRouteChoice?
    /// false leaves the request's Activity entry without content, so Show Content has nothing to show; its part kinds and sizes, model, result, and usage stay.
    public var recordsContent: Bool

    public init(feature: AIFeatureID, instructions: String? = nil, messages: [AIMessage],
                tools: [AITool] = [], output: AIOutputFormat = .text, maxOutputTokens: Int? = nil,
                route: AIRouteChoice? = nil, recordsContent: Bool = true) {
        self.feature = feature
        self.instructions = instructions
        self.messages = messages
        self.tools = tools
        self.output = output
        self.maxOutputTokens = maxOutputTokens
        self.route = route
        self.recordsContent = recordsContent
    }
}

public struct AIMessage: Sendable {
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

public enum AIWaitReason: Sendable, Equatable {
    case queued
    case rateLimited(until: Date)
}

public enum AIFinishReason: Sendable, Equatable {
    case completed
    case lengthLimit
    case toolUse
}

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
        guard let model, let finishReason else { throw AIError.malformedReply("The reply ended without finishing.") }
        if case .json = request.output, (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) == nil {
            throw finishReason == .lengthLimit ? AIError.replyTooLong : AIError.malformedReply("The reply is not valid JSON.")
        }
        return AIReply(text: text, toolCalls: toolCalls, model: model, usage: usage, finishReason: finishReason)
    }
}

// MARK: - Tool calls

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

public struct AIToolResult: Sendable {
    public var callID: String
    /// Text, page, or selection parts. The service checks them like any other part.
    public var parts: [AIPart]
    public var isError: Bool

    public init(callID: String, parts: [AIPart], isError: Bool = false) {
        self.callID = callID
        self.parts = parts
        self.isError = isError
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
    /// Sends the request with the handlers' tools, performs each tool call the model makes, sends the results back, and repeats until the model finishes without a tool call or `maxRounds` rounds have run. Calls run one at a time in the order the model made them; a call to a tool not offered, or one whose handler throws, becomes an error result for the model. Every round's events are passed on except its `finished(.toolUse)`.
    public func run(_ request: AIRequest, tools: [AIToolHandler], maxRounds: Int = 8) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runRounds(request, tools: tools, maxRounds: maxRounds, continuation: continuation)
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

    private func runRounds(_ request: AIRequest, tools: [AIToolHandler], maxRounds: Int, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws {
        var request = request
        request.tools = tools.map(\.tool)
        for round in 1...max(maxRounds, 1) {
            var text = ""
            var calls: [AIToolCall] = []
            var finishReason = AIFinishReason.completed
            for try await event in stream(request) {
                switch event {
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
            guard !calls.isEmpty else {
                continuation.yield(.finished(finishReason))
                return
            }
            guard round < maxRounds else { break }
            var results: [AIPart] = []
            for call in calls {
                try Task.checkCancellation()
                results.append(.toolResult(await Self.perform(call, with: tools)))
            }
            let reply: [AIPart] = (text.isEmpty ? [] : [.text(text)]) + calls.map { .toolCall($0) }
            request.messages.append(AIMessage(role: .assistant, parts: reply))
            request.messages.append(AIMessage(role: .user, parts: results))
        }
        throw AIError.toolRoundLimit
    }

    private static func perform(_ call: AIToolCall, with tools: [AIToolHandler]) async -> AIToolResult {
        guard let handler = tools.first(where: { $0.tool.name == call.name }) else {
            return AIToolResult(callID: call.id, parts: [.text("There is no tool named \(call.name).")], isError: true)
        }
        do {
            return try await handler.perform(call)
        } catch {
            return AIToolResult(callID: call.id, parts: [.text(error.localizedDescription)], isError: true)
        }
    }
}
