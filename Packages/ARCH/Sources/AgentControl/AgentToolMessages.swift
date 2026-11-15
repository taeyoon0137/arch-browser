// The control protocol's tool messages, which `arch-cli` and `arch-mcp` send and Arch's endpoint answers (docs/agents.md, Local control channel ▸ Framing and methods; Tools ▸ Results); `AgentControlMethod` names their methods. A call's ID is its JSON-RPC request ID, an integer the client picks: Arch answers each call once, and `progress` and `tools/cancel` name it. The tool host in the app makes the result; `arch-cli` prints its text, or its structured value with `--json`, writes a screenshot's image to a file, and exits with its status's code, and `arch-mcp` turns it into MCP's result. Events, limits, and the input kind travel in the text and the structured value.
import Foundation

/// `tools/list`'s result: the names of the catalog's tools that the connection may call. The client describes them from its own catalog, which is Arch's, since the peer checks admit only the tool of Arch's own bundle.
public struct AgentToolList: Codable, Equatable, Sendable {
    public var tools: [String]

    public init(tools: [String]) {
        self.tools = tools
    }
}

/// `tools/call`'s params. Arch reads a call without `arguments` as one with none.
public struct AgentToolCall: Codable, Equatable, Sendable {
    public var name: String
    public var arguments: [String: AgentJSON]

    public init(name: String, arguments: [String: AgentJSON] = [:]) {
        self.name = name
        self.arguments = arguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decodeIfPresent([String: AgentJSON].self, forKey: .arguments) ?? [:]
    }

    public var params: AgentJSON {
        ["name": .string(name), "arguments": .object(arguments)]
    }
}

/// `tools/call`'s result (docs/agents.md, Tools ▸ Results).
public struct AgentToolResult: Codable, Equatable, Sendable {
    public var status: AgentResultStatus
    /// What went wrong for `error`, such as `tabNotFound`, or the rule that refused, such as `P16`.
    public var code: String?
    /// Text and images. The text starts with one sentence about what happened.
    public var content: [AgentToolContent]
    /// The same facts as a JSON object, with the events since the previous call, the limits that applied, and an action's `inputKind`, for `arch-cli --json` and the API-key session.
    public var structured: AgentJSON?
    /// For `approvalPending`: the approval that `approval_wait` waits on.
    public var approval: String?

    public init(status: AgentResultStatus, code: String? = nil, content: [AgentToolContent], structured: AgentJSON? = nil, approval: String? = nil) {
        self.status = status
        self.code = code
        self.content = content
        self.structured = structured
        self.approval = approval
    }

    /// A result whose content is one text part.
    public init(status: AgentResultStatus, code: String? = nil, text: String, structured: AgentJSON? = nil) {
        self.init(status: status, code: code, content: [.text(text)], structured: structured)
    }

    /// The text parts, one after another.
    public var text: String {
        content.compactMap(\.text).joined(separator: "\n")
    }
}

/// A part of a result's content, encoded as MCP encodes content: `{"type": "text", "text": …}` or `{"type": "image", "data": <base64>, "mimeType": …}`.
public enum AgentToolContent: Equatable, Sendable {
    case text(String)
    /// An image's bytes and type, such as `image/jpeg`.
    case image(Data, mimeType: String)

    /// The text of a text part.
    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    /// The bytes of an image part.
    public var imageData: Data? {
        if case .image(let data, _) = self { return data }
        return nil
    }
}

extension AgentToolContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try container.decode(String.self, forKey: .text))
        case "image": self = .image(try container.decode(Data.self, forKey: .data), mimeType: try container.decode(String.self, forKey: .mimeType))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Not a content type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }

    /// The part as an entry of MCP's `content`.
    public var mcpContent: AgentJSON {
        switch self {
        case .text(let text): return ["type": "text", "text": .string(text)]
        case .image(let data, let mimeType): return ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
        }
    }
}

/// `progress`'s params.
public struct AgentToolProgress: Codable, Equatable, Sendable {
    /// The running call's ID.
    public var call: Int
    /// One sentence for the user.
    public var message: String

    public init(call: Int, message: String) {
        self.call = call
        self.message = message
    }

    public var params: AgentJSON {
        ["call": .number(Double(call)), "message": .string(message)]
    }
}

/// `tools/cancel`'s params.
public struct AgentToolCancel: Codable, Equatable, Sendable {
    /// The call to stop.
    public var call: Int

    public init(call: Int) {
        self.call = call
    }

    public var params: AgentJSON {
        ["call": .number(Double(call))]
    }
}
