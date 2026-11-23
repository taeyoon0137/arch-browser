// The control protocol's task messages (docs/agents.md, Local control channel ▸ Framing and methods; arch-cli): an outside client whose grant has the Start Agent Tasks scope starts an in-app session with `task/start`, reads its progress as `task/event` notifications on the same connection, lists the sessions it started with `sessions/list`, and stops one with `task/stop`. Arch decides everything about the session: the client's text adds nothing to the site scope, and the mode is at most the lower of the grant's level and the Settings default.
import Foundation

/// `task/start`'s params.
public struct AgentTaskStart: Codable, Equatable, Sendable {
    /// The task in the client's words, the session's first message.
    public var task: String
    /// A space of the grant's Persona by name; nil uses the grant's space.
    public var space: String?
    /// A mode that can only lower the session's: nil starts at the lower of the grant's level and the Settings default.
    public var mode: AgentAccessLevel?
    /// A model name of the `agent` route's providers; nil uses the route.
    public var model: String?
    /// Every approval the session asks for is denied at once, without a card.
    public var deniesApprovals: Bool

    public init(task: String, space: String? = nil, mode: AgentAccessLevel? = nil, model: String? = nil, deniesApprovals: Bool = false) {
        self.task = task
        self.space = space
        self.mode = mode
        self.model = model
        self.deniesApprovals = deniesApprovals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decode(String.self, forKey: .task)
        space = try container.decodeIfPresent(String.self, forKey: .space)
        mode = try container.decodeIfPresent(AgentAccessLevel.self, forKey: .mode)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        deniesApprovals = try container.decodeIfPresent(Bool.self, forKey: .deniesApprovals) ?? false
    }
}

/// One session as `task/start` and `sessions/list` report it.
public struct AgentSessionSummary: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// `running`, `waitingForUser`, `done`, `failed`, or `stopped`.
    public var state: String
    public var mode: AgentAccessLevel
    /// "Persona / Space", as the interface names a Persona's space.
    public var place: String
    /// "Claude Code — sonnet" once a model holds the session.
    public var model: String?

    public init(id: UUID, title: String, state: String, mode: AgentAccessLevel, place: String, model: String?) {
        self.id = id
        self.title = title
        self.state = state
        self.mode = mode
        self.place = place
        self.model = model
    }
}

/// `sessions/list`'s result.
public struct AgentSessionList: Codable, Equatable, Sendable {
    public var sessions: [AgentSessionSummary]

    public init(sessions: [AgentSessionSummary]) {
        self.sessions = sessions
    }
}

/// `task/stop`'s params, and `sessions/list`'s when it asks about one session.
public struct AgentSessionReference: Codable, Equatable, Sendable {
    public var session: UUID

    public init(session: UUID) {
        self.session = session
    }
}

/// A `task/event` notification's params: what the session did, for `arch-cli task` to print.
public struct AgentTaskEvent: Codable, Equatable, Sendable {
    /// The kind of progress a task reports to its client.
    public enum Kind: String, Codable, Sendable {
        /// Part of the agent's reply.
        case text
        /// A tool step Arch performed, as the panel shows it.
        case step
        case notice
        /// The turn ended; `text` says how.
        case turnFinished
        /// The turn or the session failed; `text` is the error's sentence.
        case failed
    }

    public var session: UUID
    public var kind: Kind
    public var text: String

    public init(session: UUID, kind: Kind, text: String) {
        self.session = session
        self.kind = kind
        self.text = text
    }
}

extension AgentControlMethod {
    /// Starts an in-app session for an outside client with the Start Agent Tasks scope: params `AgentTaskStart`, answered with an `AgentSessionSummary`, after which the session's `task/event` notifications follow on the connection.
    public static let taskStart = "task/start"
    /// Stops a session the client started: params `AgentSessionReference`, answered with `{"stopped": true}` or false.
    public static let taskStop = "task/stop"
    /// The sessions the client started, answered with an `AgentSessionList`; with `AgentSessionReference` params, only that one.
    public static let sessionsList = "sessions/list"
    /// What a session the connection started did: params `AgentTaskEvent`.
    public static let taskEventNotification = "task/event"
}

extension AgentAccessLevel {
    /// Read Only is the lowest and Act in Agent Tabs the highest.
    public var rank: Int {
        switch self {
        case .readOnly: return 0
        case .askBeforeActing: return 1
        case .actInAgentTabs: return 2
        }
    }

    /// The lower of the two levels.
    public func capped(at ceiling: AgentAccessLevel) -> AgentAccessLevel {
        rank <= ceiling.rank ? self : ceiling
    }

    /// `arch-cli task --mode`'s words.
    public init?(cliWord: String) {
        switch cliWord {
        case "read": self = .readOnly
        case "ask": self = .askBeforeActing
        case "act": self = .actInAgentTabs
        default: return nil
        }
    }
}
