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
    /// New sessions start in: the mode of an in-app session the user starts, and the ceiling of one that `arch-cli task` starts.
    public var newSessionMode = AgentAccessLevel.askBeforeActing
    /// Let In-App Agents Search History: whether in-app sessions may call `search_history`, over the history every Persona shares.
    public var inAppAgentsSearchHistory = false
    /// Keep Codex's Copy of Agent Conversations: deleting a session then leaves its thread in Codex's folder.
    public var keepsCodexCopy = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case allowsOutsideClients, grants, agentsPersonaID, newSessionMode, inAppAgentsSearchHistory, keepsCodexCopy
    }

    /// A field that a hand-written file or an earlier build lacks takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowsOutsideClients = try container.decodeIfPresent(Bool.self, forKey: .allowsOutsideClients) ?? false
        grants = try container.decodeIfPresent([AgentGrant].self, forKey: .grants) ?? []
        agentsPersonaID = try container.decodeIfPresent(UUID.self, forKey: .agentsPersonaID)
        newSessionMode = try container.decodeIfPresent(AgentAccessLevel.self, forKey: .newSessionMode) ?? .askBeforeActing
        inAppAgentsSearchHistory = try container.decodeIfPresent(Bool.self, forKey: .inAppAgentsSearchHistory) ?? false
        keepsCodexCopy = try container.decodeIfPresent(Bool.self, forKey: .keepsCodexCopy) ?? false
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
    /// The agent runs `arch-cli agent run` may start a day under Start Agent Tasks (`docs/hooks.md`, arch-cli agent run and rename), 1 to 2,000, which the grant's row in Settings ▸ AI ▸ Agents changes. `ai-usage.json` keeps the day's count per grant.
    public var runsPerDay: Int

    /// A new grant's runs a day.
    public static let defaultRunsPerDay = 200
    public static let runsPerDayRange = 1...2_000

    public init(id: UUID = UUID(), client: AgentClientIdentity, personaID: UUID, spaceID: UUID, level: AgentAccessLevel, scopes: AgentGrantScopes, expiry: AgentGrantExpiry, grantedAt: Date, lastUsedAt: Date? = nil,
                runsPerDay: Int = AgentGrant.defaultRunsPerDay) {
        self.id = id
        self.client = client
        self.personaID = personaID
        self.spaceID = spaceID
        self.level = level
        self.scopes = scopes
        self.expiry = expiry
        self.grantedAt = grantedAt
        self.lastUsedAt = lastUsedAt
        self.runsPerDay = runsPerDay
    }

    private enum CodingKeys: String, CodingKey {
        case id, client, personaID, spaceID, level, scopes, expiry, grantedAt, lastUsedAt, runsPerDay
    }

    /// `runsPerDay` takes its default when absent, so that a grant written before it existed keeps working instead of setting the file aside.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        client = try container.decode(AgentClientIdentity.self, forKey: .client)
        personaID = try container.decode(UUID.self, forKey: .personaID)
        spaceID = try container.decode(UUID.self, forKey: .spaceID)
        level = try container.decode(AgentAccessLevel.self, forKey: .level)
        scopes = try container.decode(AgentGrantScopes.self, forKey: .scopes)
        expiry = try container.decode(AgentGrantExpiry.self, forKey: .expiry)
        grantedAt = try container.decode(Date.self, forKey: .grantedAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        runsPerDay = try container.decodeIfPresent(Int.self, forKey: .runsPerDay) ?? Self.defaultRunsPerDay
    }

    public func hasExpired(at date: Date) -> Bool {
        if case .at(let end) = expiry { return end <= date }
        return false
    }
}

/// The grant sheet's extra scopes, all off by default.
public struct AgentGrantScopes: Codable, Equatable, Sendable {
    /// `search_history`, over the history every Persona shares (Persona rule 6).
    public var searchHistory = false
    /// `task/start` and `agent/run`: in-app sessions and agent runs on the user's AI subscription.
    public var startTasks = false
    /// `events/subscribe` and `watch_events`: the grant's Persona's browser events through the outside view, with sites and never titles or pages (`docs/hooks.md`, Grants).
    public var watchEvents = false

    public init(searchHistory: Bool = false, startTasks: Bool = false, watchEvents: Bool = false) {
        self.searchHistory = searchHistory
        self.startTasks = startTasks
        self.watchEvents = watchEvents
    }

    public var isEmpty: Bool { !searchHistory && !startTasks && !watchEvents }

    private enum CodingKeys: String, CodingKey {
        case searchHistory, startTasks, watchEvents
    }

    /// A scope that an earlier build did not write is off, so that its grants keep working instead of setting the file aside.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchHistory = try container.decodeIfPresent(Bool.self, forKey: .searchHistory) ?? false
        startTasks = try container.decodeIfPresent(Bool.self, forKey: .startTasks) ?? false
        watchEvents = try container.decodeIfPresent(Bool.self, forKey: .watchEvents) ?? false
    }
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
    /// The name the executable was started with, such as `claude` for a link to a file named after its version.
    public var name: String
    public var executablePath: String
    /// The app around the client or one of its ancestors, such as Terminal, or "Arch's terminal".
    public var host: String?
    /// An interpreter such as `node` is one identity for every script it runs, which the sheet says.
    public var isInterpreter: Bool
    /// The walk reached the client through a shell, `env`, `login`, or `sudo`, or took one as the client. Every program that runs in that shell can then take `arch-cli`'s place below it with `exec` and use the client's access, which the sheet and Settings say.
    public var reachedThroughShell: Bool

    public init(key: Key, name: String, executablePath: String, host: String?, isInterpreter: Bool, reachedThroughShell: Bool = false) {
        self.key = key
        self.name = name
        self.executablePath = executablePath
        self.host = host
        self.isInterpreter = isInterpreter
        self.reachedThroughShell = reachedThroughShell
    }

    /// A field that an earlier build lacks takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(Key.self, forKey: .key)
        name = try container.decode(String.self, forKey: .name)
        executablePath = try container.decode(String.self, forKey: .executablePath)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        isInterpreter = try container.decode(Bool.self, forKey: .isInterpreter)
        reachedThroughShell = try container.decodeIfPresent(Bool.self, forKey: .reachedThroughShell) ?? false
    }

    /// What the sheet and Settings say for a client reached through a shell.
    public static let shellNote = "Every program that runs in its shell can use this access too."

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
