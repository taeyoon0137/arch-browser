// A `tools/call` and its result as the control protocol carries them (docs/agents.md, Tools ▸ Results). The tool host in the app makes the result; `arch-cli` prints its text, or its structured value with `--json`, and exits with its status's code. Events, limits, and the input kind join the result with the tasks that produce them.
import Foundation

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
}

public struct AgentToolResult: Codable, Equatable, Sendable {
    public var status: AgentResultStatus
    /// What went wrong for `error`, such as `tabNotFound`, or the rule that refused, such as `P16`.
    public var code: String?
    /// The text starts with one sentence about what happened.
    public var content: [AgentContentPart]
    /// The same facts as JSON, for `arch-cli --json` and MCP's `structuredContent`.
    public var structured: AgentJSON?

    public init(status: AgentResultStatus, code: String? = nil, text: String, structured: AgentJSON? = nil) {
        self.status = status
        self.code = code
        self.content = [.text(text)]
        self.structured = structured
    }

    /// The text parts, one after another.
    public var text: String {
        content.compactMap(\.text).joined(separator: "\n")
    }
}

/// A part of a result's content. Only text parts exist until screenshots (plan task VII.13).
public struct AgentContentPart: Codable, Equatable, Sendable {
    public var type: String
    public var text: String?

    public static func text(_ text: String) -> AgentContentPart {
        AgentContentPart(type: "text", text: text)
    }
}
