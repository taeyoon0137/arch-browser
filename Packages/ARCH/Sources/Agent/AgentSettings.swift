// What `agent.json` keeps (docs/agents.md, Storage; Outside clients: identity, grants, revocation): Settings ▸ AI ▸ Agents, the grants that outlive a launch, and the Agents Persona's ID. Grants until Arch quits stay in memory. The file holds no secrets and is sealed (`AgentSettingsFile`).
import AgentControl
import Foundation

public struct AgentSettings: Codable, Equatable, Sendable {
    /// Allow Outside Clients: whether `arch-cli` and `arch-mcp` may ask for grants. Off until the user turns it on.
    public var allowsOutsideClients = false
    /// Grants for 24 hours or until the user revokes them, oldest first.
    public var grants: [AgentGrant] = []
    /// The Persona Arch created for outside clients, which stays agent-only (agent decision 9) while this file names it.
    public var agentsPersonaID: UUID?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case allowsOutsideClients, grants, agentsPersonaID
    }

    /// A field that a hand-written file or an earlier build lacks takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowsOutsideClients = try container.decodeIfPresent(Bool.self, forKey: .allowsOutsideClients) ?? false
        grants = try container.decodeIfPresent([AgentGrant].self, forKey: .grants) ?? []
        agentsPersonaID = try container.decodeIfPresent(UUID.self, forKey: .agentsPersonaID)
    }
}

/// Access the user gave one outside client: a ceiling for its calls, never an approval (docs/agents.md, Outside clients: identity, grants, revocation).
public struct AgentGrant: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var client: AgentClientIdentity
    public var personaID: UUID
    /// The space where the client's agent folder goes. A space that is gone falls back to the Persona's first.
    public var spaceID: UUID
    public var level: AgentAccessLevel
    public var scopes: AgentGrantScopes
    public var expiry: AgentGrantExpiry
    public var grantedAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), client: AgentClientIdentity, personaID: UUID, spaceID: UUID, level: AgentAccessLevel, scopes: AgentGrantScopes, expiry: AgentGrantExpiry, grantedAt: Date, lastUsedAt: Date? = nil) {
        self.id = id
        self.client = client
        self.personaID = personaID
        self.spaceID = spaceID
        self.level = level
        self.scopes = scopes
        self.expiry = expiry
        self.grantedAt = grantedAt
        self.lastUsedAt = lastUsedAt
    }

    public func hasExpired(at date: Date) -> Bool {
        if case .at(let end) = expiry { return end <= date }
        return false
    }
}

/// The grant sheet's extra scopes, both off by default.
public struct AgentGrantScopes: Codable, Equatable, Sendable {
    /// `search_history`, over the history every Persona shares (Persona rule 6).
    public var searchHistory = false
    /// `task/start`: in-app sessions on the user's AI subscription.
    public var startTasks = false

    public init(searchHistory: Bool = false, startTasks: Bool = false) {
        self.searchHistory = searchHistory
        self.startTasks = startTasks
    }

    public var isEmpty: Bool { !searchHistory && !startTasks }
}

/// Who an outside client is, from its process ancestry and signature (`AgentClientIdentifier`). Two connections share a grant when their keys are equal; the other fields describe the client.
public struct AgentClientIdentity: Codable, Equatable, Sendable {
    public enum Key: Codable, Hashable, Sendable {
        /// Code signed with a team: its signing identifier and team, which stay across updates.
        case signed(identifier: String, team: String)
        /// Any other signature, ad hoc ones included: the executable's path and code directory hash, which change with each update.
        case unsigned(path: String, codeHash: String)
        /// A process the walk took because launchd or Arch was next: also its process ID and start time, so that its grant ends with it.
        case process(path: String, codeHash: String, processID: Int32, start: AgentProcessStart)
    }

    public var key: Key
    /// The executable's name, such as `claude`.
    public var name: String
    public var executablePath: String
    /// The app around the client or one of its ancestors, such as Terminal, or "Arch's terminal".
    public var host: String?
    /// An interpreter such as `node` is one identity for every script it runs, which the sheet says.
    public var isInterpreter: Bool

    public init(key: Key, name: String, executablePath: String, host: String?, isInterpreter: Bool) {
        self.key = key
        self.name = name
        self.executablePath = executablePath
        self.host = host
        self.isInterpreter = isInterpreter
    }

    /// "claude in Terminal", as the sheet and Settings name the client.
    public var displayName: String {
        host.map { "\(name) in \($0)" } ?? name
    }

    /// Whether the grant ends with one process.
    public var isBoundToProcess: Bool {
        if case .process = key { return true }
        return false
    }
}

/// A process's start time as the kernel keeps it (`kp_proc.p_starttime`), which with the process ID tells a process from a later one that reused its ID.
public struct AgentProcessStart: Codable, Hashable, Sendable {
    public var seconds: Int
    public var microseconds: Int32

    public init(seconds: Int, microseconds: Int32) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}
