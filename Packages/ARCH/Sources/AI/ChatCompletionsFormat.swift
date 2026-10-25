// The `chatCompletions` HTTP message format: `POST {base}/chat/completions` with role messages, and a stream of `data:` lines that ends with `data: [DONE]`. Many model servers on the Mac itself serve it on a loopback address.
import Foundation

struct ChatCompletionsCodec: AIWireCodec {
    static let path = "chat/completions"

    // MARK: Request

    static func body(for request: AIProviderRequest) throws -> Data {
        var messages: [[String: Any]] = []
        if let instructions = request.instructions, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        for message in request.messages {
            messages += try encode(message)
        }
        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": request.maxOutputTokens,
        ]
        if !request.tools.isEmpty {
            body["tools"] = try request.tools.map { tool in
                ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": try JSONSerialization.requestValue(tool.inputSchema)]]
            }
        }
        if case .json(let schema) = request.output {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "reply", "schema": try JSONSerialization.requestValue(schema)]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// One message can become several: each tool result is a `tool` message of its own, sent before the rest of the user's parts.
    private static func encode(_ message: AIMessage) throws -> [[String: Any]] {
        switch message.role {
        case .assistant:
            var encoded: [String: Any] = ["role": "assistant"]
            let text = message.parts.compactMap { part -> String? in
                if case .toolCall = part { return nil }
                return AIPartText.block(for: part)
            }.joined(separator: "\n\n")
            let calls = message.parts.compactMap { part -> [String: Any]? in
                guard case .toolCall(let call) = part else { return nil }
                return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": String(decoding: call.arguments, as: UTF8.self)]]
            }
            encoded["content"] = text.isEmpty && !calls.isEmpty ? NSNull() : text
            if !calls.isEmpty { encoded["tool_calls"] = calls }
            return [encoded]
        case .user:
            var encoded: [[String: Any]] = []
            var content: [[String: Any]] = []
            for part in message.parts {
                switch part {
                case .toolResult(let result):
                    let text = AIPartText.text(of: result.parts)
                    encoded.append(["role": "tool", "tool_call_id": result.callID, "content": result.isError ? "Error: \(text)" : text])
                case .file(let file):
                    if AIPartText.isImage(file) {
                        content.append(["type": "image_url", "image_url": ["url": "data:\(file.mediaType);base64,\(file.data.base64EncodedString())"]])
                    } else if let text = AIPartText.block(for: file) {
                        content.append(["type": "text", "text": text])
                    } else {
                        throw AIError.invalidRequest("This model cannot read \(file.name).")
                    }
                case .toolCall:
                    break
                default:
                    if let text = AIPartText.block(for: part), !text.isEmpty { content.append(["type": "text", "text": text]) }
                }
            }
            if !content.isEmpty {
                // Plain text goes as a string, which every server of this format accepts.
                let isText = content.allSatisfy { $0["type"] as? String == "text" }
                let joined = content.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                encoded.append(["role": "user", "content": isText ? joined as Any : content as Any])
            }
            return encoded
        }
    }

    // MARK: Stream

    private struct PartialToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private let provider: AIProviderID
    /// Tool call arguments arrive in pieces and are joined by index.
    private var toolCalls: [Int: PartialToolCall] = [:]
    private var finishReason: AIFinishReason?
    private var usage: AIUsage?
    private var isDone = false

    init(provider: AIProviderID, output: AIOutputFormat) {
        self.provider = provider
    }

    mutating func decode(_ event: ServerSentEvent) throws -> [AIEvent] {
        guard !isDone else { return [] }
        if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            isDone = true
            return try closingEvents()
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
            throw AIError.malformedReply("The stream sent data that is not JSON.")
        }
        // Some compatible servers send `"error": null` in every chunk.
        if let error = object["error"], !(error is NSNull) {
            throw ProviderErrorInfo(json: object).streamError(provider: provider)
        }
        if let reported = object["usage"] as? [String: Any] {
            usage = Self.usage(reported)
        }
        var events: [AIEvent] = []
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return events }
        if let delta = choice["delta"] as? [String: Any] {
            if let text = delta["content"] as? String, !text.isEmpty {
                events.append(.text(text))
            }
            for piece in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = piece["index"] as? Int ?? 0
                var call = toolCalls[index] ?? PartialToolCall()
                if let id = piece["id"] as? String, !id.isEmpty { call.id = id }
                if let function = piece["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { call.name = name }
                    if let arguments = function["arguments"] as? String { call.arguments += arguments }
                }
                toolCalls[index] = call
            }
        }
        if let reason = choice["finish_reason"] as? String {
            switch reason {
            case "length": finishReason = .lengthLimit
            case "tool_calls", "function_call": finishReason = .toolUse
            case "content_filter": throw AIError.refused("The provider's content filter stopped the reply.")
            default: finishReason = .completed
            }
            events += try completedToolCalls()
        }
        return events
    }

    mutating func finish() throws -> [AIEvent] {
        guard !isDone else { return [] }
        // Some servers end without `[DONE]` once they have sent a finish reason.
        guard finishReason != nil else { throw AIError.providerUnavailable(provider, detail: "The reply ended before it finished.") }
        isDone = true
        return try closingEvents()
    }

    private mutating func closingEvents() throws -> [AIEvent] {
        var events = try completedToolCalls()
        if let usage { events.append(.usage(usage)) }
        events.append(.finished(finishReason ?? .completed))
        return events
    }

    private mutating func completedToolCalls() throws -> [AIEvent] {
        defer { toolCalls = [:] }
        return try toolCalls.keys.sorted().compactMap { index in
            guard let call = toolCalls[index] else { return nil }
            return .toolCall(AIToolCall(id: call.id, name: call.name, arguments: try JSONSerialization.toolArguments(call.arguments)))
        }
    }

    /// `prompt_tokens` includes cached tokens here; `inputTokens` leaves them out.
    private static func usage(_ object: [String: Any]) -> AIUsage {
        let prompt = object["prompt_tokens"] as? Int ?? 0
        let cached = (object["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        return AIUsage(inputTokens: max(prompt - cached, 0), outputTokens: object["completion_tokens"] as? Int ?? 0, cachedInputTokens: cached)
    }
}
