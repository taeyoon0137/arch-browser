// The agent run's plain values (`docs/hooks.md`, Agent run API): what a caller asks of one agent run, what its grant allows, and what the run returns. Hooks keep the options and grants in `hooks.json`, and scripts and outside programs send the options as JSON. `AgentRunner` (VII.27) runs them; nothing here runs an agent.
import AI
import Foundation

/// What a run may see of its tabs. Ordered from less to more.
public enum AgentRunTabAccess: String, Codable, Comparable, Sendable {
    /// The tab's title and reduced address in the first message.
    case title
    /// Also the read tools on the tab's page.
    case page

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .title: return 0
        case .page: return 1
        }
    }
}

/// What Arch keeps of a run (`docs/hooks.md`, Record levels). Ordered from less to more.
public enum AgentRunRecord: String, Codable, Comparable, Sendable {
    /// Keep Nothing: usage counters only.
    case none
    /// Keep Activity Only: log entries without content.
    case activity
    /// Keep the Session: also the transcript in memory as a kept run.
    case session

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .none: return 0
        case .activity: return 1
        case .session: return 2
        }
    }
}

/// A run's limits. In JSON the timeout is in seconds, `{"timeout": 20, "rounds": 1, "toolCalls": 2}`, and an omitted member takes its default.
public struct AgentRunLimits: Codable, Hashable, Sendable {
    /// 30 seconds by default; 5 seconds to 10 minutes. It covers the whole run, a CLI's start included.
    public var timeout: Duration
    /// Model requests, or a CLI's turns; 2 by default, 1 to 20.
    public var rounds: Int
    /// 5 by default, 1 to 50.
    public var toolCalls: Int

    public init(timeout: Duration = .seconds(30), rounds: Int = 2, toolCalls: Int = 5) {
        self.timeout = timeout
        self.rounds = rounds
        self.toolCalls = toolCalls
    }

    private enum CodingKeys: String, CodingKey {
        case timeout, rounds, toolCalls
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentRunLimits()
        timeout = try container.decodeIfPresent(Double.self, forKey: .timeout).map { Duration.seconds($0) } ?? defaults.timeout
        rounds = try container.decodeIfPresent(Int.self, forKey: .rounds) ?? defaults.rounds
        toolCalls = try container.decodeIfPresent(Int.self, forKey: .toolCalls) ?? defaults.toolCalls
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timeout.agentRunSeconds, forKey: .timeout)
        try container.encode(rounds, forKey: .rounds)
        try container.encode(toolCalls, forKey: .toolCalls)
    }
}

/// One run's request as its caller writes it. In JSON, `prompt`, `model`, `tabAccess`, and `tools` are required, and the rest take their defaults: Keep Nothing, the default limits, no closed tab, and no dry run. A script's options that leave out `tabAccess` or `tools` get its grant's values before they decode (VII.27).
public struct AgentRunOptions: Codable, Hashable, Sendable {
    public static let maximumPromptLength = 4_000

    /// At most `maximumPromptLength` characters.
    public var prompt: String
    public var tabAccess: AgentRunTabAccess
    public var model: AIRouteChoice
    public var record: AgentRunRecord
    /// Catalog names from the run tools (`docs/hooks.md`, Tools).
    public var tools: [String]
    public var limits: AgentRunLimits
    /// A close hook's closed tab, given to the agent as data (`docs/hooks.md`, Closed tabs).
    public var closedTab: UUID?
    /// Report the actions instead of applying them, for Test and `--dry-run`.
    public var dryRun: Bool

    public init(prompt: String, tabAccess: AgentRunTabAccess = .title, model: AIRouteChoice, record: AgentRunRecord = .none, tools: [String],
                limits: AgentRunLimits = AgentRunLimits(), closedTab: UUID? = nil, dryRun: Bool = false) {
        self.prompt = prompt
        self.tabAccess = tabAccess
        self.model = model
        self.record = record
        self.tools = tools
        self.limits = limits
        self.closedTab = closedTab
        self.dryRun = dryRun
    }

    private enum CodingKeys: String, CodingKey {
        case prompt, tabAccess, model, record, tools, limits, closedTab, dryRun
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(String.self, forKey: .prompt)
        tabAccess = try container.decode(AgentRunTabAccess.self, forKey: .tabAccess)
        model = try container.decode(AIRouteChoice.self, forKey: .model)
        record = try container.decodeIfPresent(AgentRunRecord.self, forKey: .record) ?? .none
        tools = try container.decode([String].self, forKey: .tools)
        limits = try container.decodeIfPresent(AgentRunLimits.self, forKey: .limits) ?? AgentRunLimits()
        closedTab = try container.decodeIfPresent(UUID.self, forKey: .closedTab)
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
    }
}

/// What a caller's runs may ask for: a hook's grant, or an outside client's (`arch-cli agent run`). Its tools are written sorted.
public struct AgentRunGrant: Codable, Hashable, Sendable {
    public var tools: Set<String>
    public var tabAccess: AgentRunTabAccess
    /// `activity` for outside programs, so every run and tool call is logged; `none` otherwise.
    public var minimumRecord: AgentRunRecord
    public var maximumRecord: AgentRunRecord
    /// 200 by default, 1 to 2,000.
    public var runsPerDay: Int
    /// The ceilings of each run's limits.
    public var limits: AgentRunLimits
    /// false for an outside program's hook, whose script then gets no `reply` (`docs/hooks.md`, Hooks from outside programs).
    public var returnsReply: Bool

    public init(tools: Set<String>, tabAccess: AgentRunTabAccess = .title, minimumRecord: AgentRunRecord = .none, maximumRecord: AgentRunRecord = .session,
                runsPerDay: Int = 200, limits: AgentRunLimits = AgentRunLimits(), returnsReply: Bool = true) {
        self.tools = tools
        self.tabAccess = tabAccess
        self.minimumRecord = minimumRecord
        self.maximumRecord = maximumRecord
        self.runsPerDay = runsPerDay
        self.limits = limits
        self.returnsReply = returnsReply
    }

    private enum CodingKeys: String, CodingKey {
        case tools, tabAccess, minimumRecord, maximumRecord, runsPerDay, limits, returnsReply
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tools.sorted(), forKey: .tools)
        try container.encode(tabAccess, forKey: .tabAccess)
        try container.encode(minimumRecord, forKey: .minimumRecord)
        try container.encode(maximumRecord, forKey: .maximumRecord)
        try container.encode(runsPerDay, forKey: .runsPerDay)
        try container.encode(limits, forKey: .limits)
        try container.encode(returnsReply, forKey: .returnsReply)
    }
}

/// Who asked for a run.
public enum AgentRunOrigin: Hashable, Sendable {
    case hook(UUID, run: UUID)
    /// The editor's Test or a hook row's Run on Current Tab.
    case test(hook: UUID)
    case outsideClient(grant: UUID)
}

/// Who wrote the prompt, which the first message names.
public enum AgentRunPromptSource: Hashable, Sendable {
    /// A hook the user made or a preset: "The user's instructions".
    case user
    /// An outside program's hook or `arch-cli agent run`: "Instructions from <name>, a program the user allowed".
    case program(name: String)
}

/// A closed tab's last shown name and committed address, which the hook registry keeps in memory for the close's runs only.
public struct AgentRunClosedTab: Hashable, Sendable {
    public var name: String
    public var url: URL?

    public init(name: String, url: URL?) {
        self.name = name
        self.url = url
    }
}

/// One run as the runner receives it: the options, the tabs, and what the caller may give the run.
public struct AgentRunRequest: Sendable {
    public var options: AgentRunOptions
    /// The tabs the run reads and renames (`docs/hooks.md`, Run tabs).
    public var tabs: [UUID]
    /// For a hook, the tabs it reaches, which `tabs` must stay within; nil for an outside client.
    public var allowedTabs: Set<UUID>?
    /// The document each run tab's renames belong to: the event's address for the event's tab; the runner adds the others' addresses as it writes the first message.
    public var documents: [UUID: URL]
    /// A close run's closed tab, from the registry.
    public var closedTab: AgentRunClosedTab?
    /// For a hook, the providers in `knownProviders`, by destination; a route that resolves to another provider is refused (`docs/hooks.md`, Known providers).
    public var knownProviders: [AIProviderID: String]?
    public var origin: AgentRunOrigin
    public var promptSource: AgentRunPromptSource
    /// `agentHook.<hook id>` or `agentRun`.
    public var feature: AIFeatureID
    public var grant: AgentRunGrant

    public init(options: AgentRunOptions, tabs: [UUID], allowedTabs: Set<UUID>?, documents: [UUID: URL] = [:], closedTab: AgentRunClosedTab? = nil,
                knownProviders: [AIProviderID: String]?, origin: AgentRunOrigin, promptSource: AgentRunPromptSource, feature: AIFeatureID, grant: AgentRunGrant) {
        self.options = options
        self.tabs = tabs
        self.allowedTabs = allowedTabs
        self.documents = documents
        self.closedTab = closedTab
        self.knownProviders = knownProviders
        self.origin = origin
        self.promptSource = promptSource
        self.feature = feature
        self.grant = grant
    }
}

/// A change a run made, or proposed in a dry run. In JSON, `{"renamedTab": {"tab": …, "name": …}}`.
public enum AgentRunAction: Codable, Hashable, Sendable {
    case renamedTab(tab: UUID, name: String)

    /// The action's kind as the run log counts it, such as `renameTab`.
    public var kind: String {
        switch self {
        case .renamedTab: return "renameTab"
        }
    }
}

public struct AgentRunResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case completed, failed, timedOut, cancelled, refused
    }

    public var status: Status
    /// The AI error, or the refusal's rule, such as `wouldAsk`, `notGranted`, or `unknownProvider`.
    public var code: String?
    public var message: String?
    /// Applied, or proposed in a dry run.
    public var actions: [AgentRunAction]
    /// The agent's last text, for the caller only; nil when the grant returns no reply.
    public var reply: String?
    public var model: AIModelRef?
    public var usage: AIUsage
    /// Set with Keep the Session: the kept run in memory.
    public var keptRun: UUID?

    public init(status: Status, code: String? = nil, message: String? = nil, actions: [AgentRunAction] = [], reply: String? = nil, model: AIModelRef? = nil,
                usage: AIUsage = AIUsage(inputTokens: 0, outputTokens: 0), keptRun: UUID? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.actions = actions
        self.reply = reply
        self.model = model
        self.usage = usage
        self.keptRun = keptRun
    }
}

extension AIFeatureID {
    /// The feature of a hook with `agent` (`docs/hooks.md`, Model choice and tiers): automatic and `perRequest`, named after the hook.
    public static func agentHook(_ hook: UUID) -> AIFeatureID {
        AIFeatureID(rawValue: "agentHook.\(hook.uuidString)")
    }
}

extension Duration {
    /// The duration in seconds, as run options write it.
    var agentRunSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
