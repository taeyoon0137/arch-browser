// The control protocol's version, Arch's first message, `ready`, and the client's, `hello` (docs/agents.md, Local control channel ▸ Framing and methods). `ready`, `hello`, and its answer keep this shape in every protocol version, so that a client and an Arch of different versions can still name both versions.
import Foundation

public enum AgentControlProtocol {
    /// The version this build speaks. A `hello` with another version is refused, and the client exits with code 75.
    public static let version = 1
    /// The notification without params that Arch writes once its peer checks pass. The client sends nothing before it arrives.
    public static let readyMethod = "ready"
    public static let helloMethod = "hello"
    /// The environment variable that carries a shell hook run's ticket, which `arch-cli` presents in `hello` (`docs/hooks.md`, Shell scripts).
    public static let hookTicketVariable = "ARCH_HOOK_TICKET"
}

/// The methods a client calls after `hello`, and the notifications of each end (docs/agents.md, Local control channel ▸ Framing and methods). The tool messages' params and results are in `AgentToolMessages.swift`. The methods of later tasks join as they are built; Arch answers any other method with JSON-RPC error -32601.
public enum AgentControlMethod {
    /// The names of the tools the connection may call, answered with an `AgentToolList`.
    public static let toolsList = "tools/list"
    /// One tool call, params `AgentToolCall`, answered with an `AgentToolResult`. The request's ID is the call's ID.
    public static let toolsCall = "tools/call"
    /// The connection's status, as in the answer to `hello`.
    public static let grantShow = "grant/show"
    /// Gives up the client's own grant, answered with `{"released": true}` or false when it had none.
    public static let grantRelease = "grant/release"

    /// The client's notification that stops a running call and withdraws its approval: params `AgentToolCancel`.
    public static let toolsCancelNotification = "tools/cancel"
    /// A call still waits, as for the grant sheet or an approval: params `AgentToolProgress`, `{"call": <request ID>, "message": "…"}`.
    public static let progressNotification = "progress"
    /// The connection's tools changed, as after a grant or a mode change.
    public static let toolsChangedNotification = "tools/changed"
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
    /// An in-app session's ticket (`ARCH_AGENT_TICKET`), which only `arch-mcp --session` sends, or a shell hook run's (`ARCH_HOOK_TICKET`), which only `arch-cli` sends.
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
    /// The connection belongs to an in-app session or a shell hook's run, through its ticket.
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
    /// The name of the grant's space, where its agent folder goes, so that the grant reads as "Agents / Home"; nil from an Arch that does not send it.
    public var space: String?
    public var expiry: AgentGrantExpiry

    public init(level: AgentAccessLevel, persona: String, space: String? = nil, expiry: AgentGrantExpiry) {
        self.level = level
        self.persona = persona
        self.space = space
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
        /// The ticket matches no session or hook run, or the peer is not in its process tree.
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

// MARK: - Outside programs' events

/// What an outside program with Watch Browser Events reads (`docs/hooks.md`, arch-cli events): `events/subscribe` with a filter starts a subscription on the connection, whose events then come as `events/event` notifications in the outside view, and `events/unsubscribe` ends it. Arch keeps the grant's last 500 events in memory, which `after` replays.
extension AgentControlMethod {
    /// Params `AgentEventSubscribe`, answered with an `AgentEventSubscription`. Needs the grant's Watch Browser Events scope, and asks for a grant first as a tool call does.
    public static let eventsSubscribe = "events/subscribe"
    /// Params `{"subscription": <id>}`, answered with `{"unsubscribed": true}` or false.
    public static let eventsUnsubscribe = "events/unsubscribe"
    /// One event of a subscription: params `{"subscription": <id>, "event": {…}}`, the event in the outside view.
    public static let eventNotification = "events/event"
    /// Events the connection's queue of 1,000 dropped since the last it delivered: params `{"subscription": <id>, "count": <n>}`.
    public static let eventsDroppedNotification = "events/dropped"
}

/// The events an outside program asks for, by the names `arch-cli events` takes. An empty list matches every value; the Persona is always the grant's.
public struct AgentEventFilter: Codable, Equatable, Sendable {
    /// The event kinds, such as `pageLoaded` (`AgentEventFilter.kinds`).
    public var kinds: [String]
    /// Spaces of the grant's Persona by name.
    public var spaces: [String]
    /// Site patterns, such as `example.org`, which match a host and its subdomains.
    public var sites: [String]
    public var exceptSites: [String]
    /// `webkit` or `chromium`.
    public var engines: [String]
    /// `open`, `pinned`, `favorite`, `small-window`, or `agent`, the client's own agent tabs.
    public var tabKinds: [String]

    public init(kinds: [String] = [], spaces: [String] = [], sites: [String] = [], exceptSites: [String] = [], engines: [String] = [], tabKinds: [String] = []) {
        self.kinds = kinds
        self.spaces = spaces
        self.sites = sites
        self.exceptSites = exceptSites
        self.engines = engines
        self.tabKinds = tabKinds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kinds = try container.decodeIfPresent([String].self, forKey: .kinds) ?? []
        spaces = try container.decodeIfPresent([String].self, forKey: .spaces) ?? []
        sites = try container.decodeIfPresent([String].self, forKey: .sites) ?? []
        exceptSites = try container.decodeIfPresent([String].self, forKey: .exceptSites) ?? []
        engines = try container.decodeIfPresent([String].self, forKey: .engines) ?? []
        tabKinds = try container.decodeIfPresent([String].self, forKey: .tabKinds) ?? []
    }

    /// The event kinds, as Arch's bus names them.
    public static let kinds = ["tabOpened", "tabClosed", "pageLoaded", "addressChanged", "titleChanged", "tabSelected", "downloadFinished", "spaceSwitched"]
    public static let engines = ["webkit", "chromium"]
    public static let tabKinds = ["open", "pinned", "favorite", "small-window", "agent"]
}

/// `events/subscribe`'s params.
public struct AgentEventSubscribe: Codable, Equatable, Sendable {
    public var filter: AgentEventFilter
    /// Replays the grant's buffered events after this sequence before new ones; nil starts with new events.
    public var after: UInt64?

    public init(filter: AgentEventFilter = AgentEventFilter(), after: UInt64? = nil) {
        self.filter = filter
        self.after = after
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filter = try container.decodeIfPresent(AgentEventFilter.self, forKey: .filter) ?? AgentEventFilter()
        after = try container.decodeIfPresent(UInt64.self, forKey: .after)
    }
}

/// `events/subscribe`'s result: the subscription, and the sequence of the last event Arch had then.
public struct AgentEventSubscription: Codable, Equatable, Sendable {
    public var subscription: Int
    public var sequence: UInt64

    public init(subscription: Int, sequence: UInt64) {
        self.subscription = subscription
        self.sequence = sequence
    }
}

/// One event as `arch-cli events` prints it without `--json`, from its outside view: `09:30:12 pageLoaded w4 example.org (chromium, open)`. A download's name is an untrusted block, since a page or a server chose it.
public enum AgentEventLine {
    public static func text(for event: AgentJSON, timeZone: TimeZone = .current) -> String {
        var words: [String] = []
        if let date = event["date"]?.stringValue.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm:ss"
            words.append(formatter.string(from: date))
        }
        words.append(event["kind"]?.stringValue ?? "event")
        if let tab = event["tab"] {
            words.append(tab["handle"]?.stringValue ?? tab["watch"]?.stringValue ?? "tab")
            if tab["excluded"] == .bool(true) {
                words.append("(excluded site)")
            } else if let place = tab["url"]?.stringValue ?? tab["site"]?.stringValue {
                words.append(place)
            }
            let details = [tab["engine"]?.stringValue, tab["kind"]?.stringValue].compactMap { $0 }
            if !details.isEmpty { words.append("(" + details.joined(separator: ", ") + ")") }
        }
        if let download = event["download"] {
            words.append(download["tab"]?.stringValue ?? "tab")
            if download["excluded"] == .bool(true) {
                words.append("(excluded site)")
            } else {
                if let name = download["name"]?.stringValue { words.append(name) }
                if let site = download["site"]?.stringValue { words.append("from \(site)") }
            }
        }
        if let window = event["window"]?.stringValue {
            func side(_ value: AgentJSON?) -> String? {
                guard let value else { return nil }
                return value["space"]?.stringValue ?? (value["otherPersona"] == .bool(true) ? "another Persona" : nil)
            }
            words.append(window)
            if let to = side(event["to"]) { words.append((side(event["from"]).map { "\($0) \u{2192} " } ?? "\u{2192} ") + to) }
        }
        if event["byThisClient"] == .bool(true) { words.append("[this client]") }
        return words.joined(separator: " ")
    }
}

// MARK: - Outside programs' hooks

/// Hooks an outside program proposes (`docs/hooks.md`, Hooks from outside programs; arch-cli hooks): `hooks/add` shows the proposal sheet in Arch and waits for the user, and the hook takes effect only after Allow with Touch ID or the login password. `hooks/list` and `hooks/remove` reach only the hooks the client's identity added. No method edits, pauses, or resumes a hook.
extension AgentControlMethod {
    /// Answered with an `AgentHookListing` of the hooks this client's identity added.
    public static let hooksList = "hooks/list"
    /// Params `AgentHookAdd`, answered with an `AgentHookAddResult` once the user answers the proposal sheet; `progress` notifications come while it waits.
    public static let hooksAdd = "hooks/add"
    /// Params `{"hook": <id>}`, answered with `{"removed": true}`, or false for a hook this identity did not add.
    public static let hooksRemove = "hooks/remove"
}

/// `hooks/add`'s params: the hook as `arch-cli hooks add` describes it. Arch checks every member and the script's syntax before it shows the proposal sheet.
public struct AgentHookAdd: Codable, Equatable, Sendable {
    public var name: String
    /// The event kind, such as `pageLoaded` (`AgentEventFilter.kinds`).
    public var event: String
    /// For `pageLoaded`: `first`, `new`, the default, or `every`.
    public var loads: String?
    /// The places, sites, engines, and tab kinds; its kinds are the event's. Its spaces are the grant's Persona's, and none means the whole Persona.
    public var filter: AgentEventFilter
    /// The wait after the event, in milliseconds; the trigger's default when absent.
    public var delay: Int?
    /// The run's time limit in seconds; the default when absent.
    public var timeout: Int?
    /// The JavaScript script, at most 256 KB of UTF-8 text.
    public var script: String
    /// `tabs.rename` and `agent`.
    public var permissions: [String]
    /// The agent run's options with `agent`, as `arch.agent.run` takes them.
    public var agent: AgentJSON?
    /// `activity`, the default, or `session`.
    public var record: String?

    public init(name: String, event: String, loads: String? = nil, filter: AgentEventFilter = AgentEventFilter(), delay: Int? = nil, timeout: Int? = nil, script: String,
                permissions: [String] = [], agent: AgentJSON? = nil, record: String? = nil) {
        self.name = name
        self.event = event
        self.loads = loads
        self.filter = filter
        self.delay = delay
        self.timeout = timeout
        self.script = script
        self.permissions = permissions
        self.agent = agent
        self.record = record
    }

    /// The largest script `hooks add` sends, as for every JavaScript hook.
    public static let scriptBytes = 256 * 1024
    public static let permissions = ["tabs.rename", "agent"]
    public static let loads = ["first", "new", "every"]
    public static let records = ["activity", "session"]
}

/// `hooks/add`'s answer.
public struct AgentHookAddResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The user allowed the hook, which runs from now on.
        case added
        /// The user did not allow it, or the sheet closed unanswered; `arch-cli` exits 3.
        case declined
        /// A rule refused it before or after the sheet; `arch-cli` exits 4.
        case refused
    }

    public var status: Status
    public var hook: UUID?
    /// The refusal's or the decline's sentence.
    public var message: String?

    public init(status: Status, hook: UUID? = nil, message: String? = nil) {
        self.status = status
        self.hook = hook
        self.message = message
    }
}

/// One hook a client's identity added, as `hooks list` shows it.
public struct AgentHookSummary: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// The situation in words, such as "When a new tab loads its first page".
    public var trigger: String
    /// `active`, or `paused` with the reason's sentence.
    public var state: String
    /// The last run's time and outcome, when it ran.
    public var lastRun: String?

    public init(id: UUID, name: String, trigger: String, state: String, lastRun: String? = nil) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.state = state
        self.lastRun = lastRun
    }
}

/// `hooks/list`'s result.
public struct AgentHookListing: Codable, Equatable, Sendable {
    public var hooks: [AgentHookSummary]

    public init(hooks: [AgentHookSummary]) {
        self.hooks = hooks
    }
}

// MARK: - Outside programs' agent runs

extension AgentControlMethod {
    /// One agent run for a client with Start Agent Tasks (`docs/hooks.md`, arch-cli agent run and rename): params the run's options as `arch.agent.run` takes them, with `tabs` as the client's tab handles, answered with the run's result (`status`, `code`, `message`, `actions`, `reply`, `model`, and `usage`) once it ends. Inside a shell hook's run, the run uses the hook's grant, feature, and run tabs.
    public static let agentRun = "agent/run"
}
