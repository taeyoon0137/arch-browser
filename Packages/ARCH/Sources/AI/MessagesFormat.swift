// The `messages` HTTP message format: `POST {base}/messages` with typed content blocks, and a stream of named events from `message_start` to `message_stop`. JSON output is one forced tool call whose input becomes the reply text.
import Foundation

struct MessagesCodec: AIWireCodec {
    static let path = "messages"
    /// The forced tool that carries a JSON reply.
    static let replyToolName = "reply"

    // MARK: Request

    static func body(for request: AIProviderRequest) throws -> Data {
        var body: [String: Any] = [
            "model": request.model,
            "messages": try request.messages.map(encode),
            "max_tokens": request.maxOutputTokens,
            "stream": true,
        ]
        if let instructions = request.instructions, !instructions.isEmpty {
            body["system"] = instructions
        }
        var tools = try request.tools.map { tool in
            ["name": tool.name, "description": tool.description, "input_schema": try JSONSerialization.requestValue(tool.inputSchema)] as [String: Any]
        }
        if case .json(let schema) = request.output {
            // Forcing the reply tool means the model calls no other tool in this request.
            tools.append(["name": replyToolName, "description": "Reply with one JSON value that matches the input schema.", "input_schema": try JSONSerialization.requestValue(schema)])
            body["tool_choice"] = ["type": "tool", "name": replyToolName]
        }
        if !tools.isEmpty { body["tools"] = tools }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func encode(_ message: AIMessage) throws -> [String: Any] {
        ["role": message.role.rawValue, "content": try message.parts.compactMap(encode)]
    }

    /// The format rejects empty text blocks, so empty text is left out.
    private static func encode(_ part: AIPart) throws -> [String: Any]? {
        switch part {
        case .file(let file):
            if AIPartText.isImage(file) {
                return ["type": "image", "source": ["type": "base64", "media_type": file.mediaType, "data": file.data.base64EncodedString()]]
            }
            if file.mediaType.lowercased() == "application/pdf" {
                return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": file.data.base64EncodedString()]]
            }
            guard let text = AIPartText.block(for: file) else { throw AIError.invalidRequest("This model cannot read \(file.name).") }
            return ["type": "text", "text": text]
        case .toolCall(let call):
            return ["type": "tool_use", "id": call.id, "name": call.name, "input": try JSONSerialization.requestValue(call.arguments)]
        case .toolResult(let result):
            let content = try result.parts.compactMap(encode)
            return ["type": "tool_result", "tool_use_id": result.callID, "content": content, "is_error": result.isError]
        default:
            guard let text = AIPartText.block(for: part), !text.isEmpty else { return nil }
            return ["type": "text", "text": text]
        }
    }

    // MARK: Stream

    private enum Block {
        case text
        case tool(id: String, name: String, arguments: String)
        /// The forced reply tool; its input pieces are passed on as text.
        case reply
    }

    private let provider: AIProviderID
    private let isJSONOutput: Bool
    private var blocks: [Int: Block] = [:]
    private var usage: AIUsage?
    private var finishReason: AIFinishReason?
    private var isStopped = false

    init(provider: AIProviderID, output: AIOutputFormat) {
        self.provider = provider
        if case .json = output { isJSONOutput = true } else { isJSONOutput = false }
    }

    mutating func decode(_ event: ServerSentEvent) throws -> [AIEvent] {
        guard !isStopped else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
            throw AIError.malformedReply("The stream sent data that is not JSON.")
        }
        let index = object["index"] as? Int ?? 0
        switch (object["type"] as? String) ?? event.event ?? "" {
        case "message_start":
            if let reported = (object["message"] as? [String: Any])?["usage"] as? [String: Any] { updateUsage(reported) }
            return []
        case "content_block_start":
            let block = object["content_block"] as? [String: Any] ?? [:]
            guard block["type"] as? String == "tool_use" else {
                blocks[index] = .text
                return (block["text"] as? String).flatMap { $0.isEmpty ? nil : [.text($0)] } ?? []
            }
            let name = block["name"] as? String ?? ""
            blocks[index] = isJSONOutput && name == Self.replyToolName ? .reply : .tool(id: block["id"] as? String ?? "", name: name, arguments: "")
            return []
        case "content_block_delta":
            let delta = object["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                return (delta["text"] as? String).flatMap { $0.isEmpty ? nil : [.text($0)] } ?? []
            case "input_json_delta":
                let piece = delta["partial_json"] as? String ?? ""
                switch blocks[index] {
                case .reply:
                    return piece.isEmpty ? [] : [.text(piece)]
                case .tool(let id, let name, let arguments):
                    blocks[index] = .tool(id: id, name: name, arguments: arguments + piece)
                    return []
                case .text, nil:
                    return []
                }
            default:
                return []
            }
        case "content_block_stop":
            guard case .tool(let id, let name, let arguments) = blocks.removeValue(forKey: index) else { return [] }
            return [.toolCall(AIToolCall(id: id, name: name, arguments: try JSONSerialization.toolArguments(arguments)))]
        case "message_delta":
            if let reported = object["usage"] as? [String: Any] { updateUsage(reported) }
            if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String {
                switch reason {
                case "max_tokens": finishReason = .lengthLimit
                case "tool_use": finishReason = isJSONOutput ? .completed : .toolUse
                case "refusal": throw AIError.refused("")
                default: finishReason = .completed
                }
            }
            return []
        case "message_stop":
            isStopped = true
            return closingEvents()
        case "error":
            throw ProviderErrorInfo(json: object).streamError(provider: provider)
        default:
            return []
        }
    }

    mutating func finish() throws -> [AIEvent] {
        guard !isStopped else { return [] }
        guard finishReason != nil else { throw AIError.providerUnavailable(provider, detail: "The reply ended before it finished.") }
        isStopped = true
        return closingEvents()
    }

    private func closingEvents() -> [AIEvent] {
        (usage.map { [.usage($0)] } ?? []) + [.finished(finishReason ?? .completed)]
    }

    /// `input_tokens` leaves out tokens read from the cache; tokens written to the cache count as input. Later events repeat the totals so far.
    private mutating func updateUsage(_ object: [String: Any]) {
        var current = usage ?? AIUsage(inputTokens: 0, outputTokens: 0)
        if let input = object["input_tokens"] as? Int {
            current.inputTokens = input + (object["cache_creation_input_tokens"] as? Int ?? 0)
        }
        if let cached = object["cache_read_input_tokens"] as? Int { current.cachedInputTokens = cached }
        if let output = object["output_tokens"] as? Int { current.outputTokens = output }
        usage = current
    }
}
