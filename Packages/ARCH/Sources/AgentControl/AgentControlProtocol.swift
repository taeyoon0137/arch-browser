// The control protocol's version, Arch's first message, `ready`, and the client's, `hello` (docs/agents.md, Local control channel ▸ Framing and methods). `ready`, `hello`, and its answer keep this shape in every protocol version, so that a client and an Arch of different versions can still name both versions.
import Foundation

public enum AgentControlProtocol {
    /// The version this build speaks. A `hello` with another version is refused, and the client exits with code 75.
    public static let version = 1
    /// The notification without params that Arch writes once its peer checks pass. The client sends nothing before it arrives.
    public static let readyMethod = "ready"
    public static let helloMethod = "hello"
}

/// The methods a client calls after `hello`, and the notifications Arch sends (docs/agents.md, Local control channel ▸ Framing and methods). The methods of later tasks join as they are built; Arch answers any other method with JSON-RPC error -32601.
public enum AgentControlMethod {
    /// The tools the connection's grant allows, as MCP's `tools/list` result.
    public static let toolsList = "tools/list"
    /// One tool call, params `AgentToolCall`, answered with an `AgentToolResult`. The request's ID is the call's ID.
    public static let toolsCall = "tools/call"
    /// The connection's status, as in the answer to `hello`.
    public static let grantShow = "grant/show"
    /// Gives up the client's own grant, answered with `{"released": true}` or false when it had none.
    public static let grantRelease = "grant/release"

    /// A call still waits, as for the grant sheet: params `{"call": <request ID>, "message": "…"}`.
    public static let progressNotification = "progress"
    /// The grant ended: params `{"message": "…"}`. Arch closes the connection after it.
    public static let revokedNotification = "revoked"
}

/// The control protocol's own JSON-RPC error codes, in the range JSON-RPC leaves to servers.
public enum AgentControlErrorCode {
    /// The client has no grant: the user did not allow it, or asked a moment ago, and `arch-cli` exits 6.
    public static let noGrant = -32001
    /// More calls than `AgentLimits.callsPerConnection` run on the connection.
    public static let busy = -32002
}

/// The program that connects: `arch-cli`, or the same binary run as `arch-mcp`.
public enum AgentClientKind: String, Codable, Sendable {
    case cli = "arch-cli"
    case mcp = "arch-mcp"
}

/// The client's first message.
public struct AgentHello: Codable, Equatable, Sendable {
    public var `protocol`: Int
    public var client: AgentClientKind
    /// The client's version, from the bundle that contains it.
    public var version: String
    /// An in-app session's ticket (`ARCH_AGENT_TICKET`), which only `arch-mcp --session` sends.
    public var ticket: String?

    public init(protocol: Int = AgentControlProtocol.version, client: AgentClientKind, version: String, ticket: String? = nil) {
        self.protocol = `protocol`
        self.client = client
        self.version = version
        self.ticket = ticket
    }
}

/// Arch's answer to `hello`: its protocol and version, and what the connection may do. Encoded flat, as `{"protocol": 1, "version": "0.1.0", "status": "granted", "grant": {…}}` or `{…, "status": "refused", "refusal": {"reason": "outsideAccessOff", "message": "…"}}`.
public struct AgentHelloAnswer: Equatable, Sendable {
    public var `protocol`: Int
    /// Arch's version.
    public var version: String
    public var status: AgentConnectionStatus

    public init(protocol: Int = AgentControlProtocol.version, version: String, status: AgentConnectionStatus) {
        self.protocol = `protocol`
        self.version = version
        self.status = status
    }
}

public enum AgentConnectionStatus: Equatable, Sendable {
    /// The connection belongs to an in-app session, through its ticket.
    case bound
    /// An outside client with a grant.
    case granted(AgentGrantSummary)
    /// An outside client without a grant yet, encoded as `"none"`; its first `tools/call` asks the user.
    case noGrant
    /// Arch refuses the connection and closes it after this answer.
    case refused(AgentRefusal)
}

public struct AgentGrantSummary: Codable, Equatable, Sendable {
    public var level: AgentAccessLevel
    /// The name of the grant's Persona.
    public var persona: String
    public var expiry: AgentGrantExpiry

    public init(level: AgentAccessLevel, persona: String, expiry: AgentGrantExpiry) {
        self.level = level
        self.persona = persona
        self.expiry = expiry
    }
}

/// A grant's or an in-app session's access level (docs/agents.md, Permissions, approvals, and injection defenses ▸ Modes).
public enum AgentAccessLevel: String, Codable, Sendable, CaseIterable {
    case readOnly
    case askBeforeActing
    case actInAgentTabs

    public var title: String {
        switch self {
        case .readOnly: return "Read Only"
        case .askBeforeActing: return "Ask Before Acting"
        case .actInAgentTabs: return "Act in Agent Tabs"
        }
    }
}

/// When a grant ends, encoded as `"quit"`, `"revoke"`, or an ISO 8601 date.
public enum AgentGrantExpiry: Equatable, Sendable {
    case whenArchQuits
    case at(Date)
    case whenRevoked
}

extension AgentGrantExpiry: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        switch text {
        case "quit": self = .whenArchQuits
        case "revoke": self = .whenRevoked
        default:
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not a grant expiry: \(text)"))
            }
            self = .at(date)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .whenArchQuits: try container.encode("quit")
        case .whenRevoked: try container.encode("revoke")
        case .at(let date): try container.encode(ISO8601DateFormatter().string(from: date))
        }
    }
}

public struct AgentRefusal: Codable, Equatable, Sendable {
    public var reason: Reason
    /// One sentence for the user.
    public var message: String

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }

    /// A refusal's code. Codes this build does not know decode as themselves and count as a refusal of access.
    public struct Reason: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// The client's protocol version is not Arch's; the answer's `protocol` names Arch's.
        public static let protocolMismatch = Reason(rawValue: "protocol")
        /// Allow Outside Clients is off and the client presented no valid ticket.
        public static let outsideAccessOff = Reason(rawValue: "outsideAccessOff")
        /// The ticket matches no session, or the peer is not in its session's process tree.
        public static let ticket = Reason(rawValue: "ticket")
        /// Arch could not tell which program the client is, as when a process on its parent chain ended while Arch read it.
        public static let unidentified = Reason(rawValue: "unidentified")
    }
}

extension AgentHelloAnswer: Codable {
    private enum CodingKeys: String, CodingKey {
        case `protocol`, version, status, grant, refusal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        `protocol` = try container.decode(Int.self, forKey: .protocol)
        version = try container.decode(String.self, forKey: .version)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "bound": self.status = .bound
        case "granted": self.status = .granted(try container.decode(AgentGrantSummary.self, forKey: .grant))
        case "none": self.status = .noGrant
        case "refused": self.status = .refused(try container.decode(AgentRefusal.self, forKey: .refusal))
        default: throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Not a connection status: \(status)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(`protocol`, forKey: .protocol)
        try container.encode(version, forKey: .version)
        switch status {
        case .bound: try container.encode("bound", forKey: .status)
        case .granted(let grant):
            try container.encode("granted", forKey: .status)
            try container.encode(grant, forKey: .grant)
        case .noGrant: try container.encode("none", forKey: .status)
        case .refused(let refusal):
            try container.encode("refused", forKey: .status)
            try container.encode(refusal, forKey: .refusal)
        }
    }
}
