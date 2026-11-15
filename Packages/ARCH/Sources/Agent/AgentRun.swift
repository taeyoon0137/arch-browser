// The agent run's plain values (`docs/hooks.md`, Agent run API): what a caller asks of one agent run, what its grant allows, and what the run returns. Hooks keep the options and grants in `hooks.json`, and scripts and outside programs send the options as JSON. `AgentRunner` (VII.27) runs them; nothing here runs an agent.
import AgentControl
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
        if let seconds = try container.decodeIfPresent(Double.self, forKey: .timeout) {
            guard seconds.isFinite, abs(seconds) < Double(Int64.max) else {
                throw DecodingError.dataCorruptedError(forKey: .timeout, in: container, debugDescription: "The timeout is out of range.")
            }
            timeout = .seconds(seconds)
        } else {
            timeout = defaults.timeout
        }
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

    /// Why the requested run exceeds its grant or Arch's run limits. The editor and the runner use the same check.
    public func refusal(for options: AgentRunOptions) -> String? {
        guard !options.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              options.prompt.count <= AgentRunOptions.maximumPromptLength else { return "The prompt must contain 1 to 4,000 characters." }
        guard options.tabAccess <= tabAccess else { return "The grant does not allow this tab access." }
        guard minimumRecord <= options.record, options.record <= maximumRecord else { return "The record level is outside the grant." }
        let permittedTools: Set<String> = options.tabAccess == .page ? ["rename_tab", "read_text", "snapshot"] : ["rename_tab"]
        guard options.tools.allSatisfy({ tools.contains($0) && permittedTools.contains($0) }) else { return "The run asks for a tool outside its grant or tab access." }
        guard (1...2_000).contains(runsPerDay) else { return "The daily run limit must be from 1 to 2,000." }
        let request = options.limits
        guard (.seconds(5)...Duration.seconds(600)).contains(request.timeout), request.timeout <= limits.timeout else { return "The timeout exceeds the allowed range." }
        guard (1...20).contains(request.rounds), request.rounds <= limits.rounds else { return "The number of model rounds exceeds the allowed range." }
        guard (1...50).contains(request.toolCalls), request.toolCalls <= limits.toolCalls else { return "The number of tool calls exceeds the allowed range." }
        return nil
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
    /// The editor's Test or a hook row's Run on Current Tab, with the test's hook run.
    case test(hook: UUID, run: UUID)
    /// An outside client's `agent/run`, with the run's ID, which the run's activity entries carry.
    case outsideClient(grant: UUID, run: UUID)
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
    /// The tabs the caller reaches, which `tabs` must stay within: a hook's, or an outside client's agent tabs and the tabs shared with it.
    public var allowedTabs: Set<UUID>?
    /// The document each run tab's renames belong to: the event's address for the event's tab; the runner adds the others' addresses as it writes the first message.
    public var documents: [UUID: URL]
    /// Live document identities when the hook captured its tabs. Never sent to the provider.
    public var documentIDs: [UUID: UUID]
    /// A close run's closed tab, from the registry.
    public var closedTab: AgentRunClosedTab?
    /// For a hook, the providers in `knownProviders`, by `AIProviderConfiguration.hookDestination`; a route that resolves to another provider, or to one whose destination changed, is refused (`docs/hooks.md`, Known providers).
    public var knownProviders: [AIProviderID: String]?
    public var origin: AgentRunOrigin
    public var promptSource: AgentRunPromptSource
    /// `agentHook.<hook id>` or `agentRun`.
    public var feature: AIFeatureID
    public var grant: AgentRunGrant
    /// For an outside client's run, the run tabs the user shared with the client; the others are its agent tabs.
    public var sharedTabs: Set<UUID> = []
    /// The shared run tabs the user let the client rename on P19's card, which the run renames without asking.
    public var renamingSharedTabs: Set<UUID> = []

    public init(options: AgentRunOptions, tabs: [UUID], allowedTabs: Set<UUID>?, documents: [UUID: URL] = [:], documentIDs: [UUID: UUID] = [:], closedTab: AgentRunClosedTab? = nil,
                knownProviders: [AIProviderID: String]?, origin: AgentRunOrigin, promptSource: AgentRunPromptSource, feature: AIFeatureID, grant: AgentRunGrant) {
        self.options = options
        self.tabs = tabs
        self.allowedTabs = allowedTabs
        self.documents = documents
        self.documentIDs = documentIDs
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

    /// Agent Runs from Programs: the runs outside programs start with `arch-cli agent run` (`docs/hooks.md`, Model choice and tiers).
    public static let agentRun = AIFeatureID(rawValue: "agentRun")

    /// The key of one grant's runs today in `ai-usage.json`, which its runs a day bound; no request names it as its feature.
    public static func agentRun(grant: UUID) -> AIFeatureID {
        AIFeatureID(rawValue: "agentRun.\(grant.uuidString)")
    }
}

extension AIFeature {
    /// Agent Runs from Programs: automatic and `perRequest`, since each run names its tier or models, and requiring `agent`.
    public static let agentRun = AIFeature(id: .agentRun, name: "Agent Runs from Programs",
                                           summary: "Runs one agent for a program you allowed, on the tabs it opened or you shared with it, within its grant.",
                                           trigger: .automatic, data: AIDataScope(kinds: [.page]), requirements: [.agent], routing: .perRequest)
}

extension AgentRunGrant {
    /// The run grant of an outside client with Start Agent Tasks (`docs/hooks.md`, arch-cli agent run and rename): `read_text` and `snapshot`, which the client could call itself at every level, and `rename_tab` for its own agent tabs (P19); page access; Keep Activity Only to Keep the Session; the ceilings of 10 minutes, 20 rounds, and 50 tool calls; the grant's runs a day; and the reply, since the client asked.
    public static func forClient(_ grant: AgentGrant) -> AgentRunGrant {
        AgentRunGrant(tools: [AgentToolCatalog.renameTab.name, "read_text", "snapshot"], tabAccess: .page, minimumRecord: .activity, maximumRecord: .session,
                      runsPerDay: grant.runsPerDay, limits: AgentRunLimits(timeout: .seconds(600), rounds: 20, toolCalls: 50), returnsReply: true)
    }
}

extension Duration {
    /// The duration in seconds, as run options write it.
    var agentRunSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

extension AgentPolicy {
    /// What a run says when a step would ask the user, who is not there (hook decision 5).
    public static let wouldAskSentence = "This run cannot ask the user, so Arch refused the step."
    public static let wouldAskCode = "wouldAsk"

    /// A run's decision from an outside client's: P16, P17, and the other refusals stand, and every card becomes a refusal with `wouldAsk`.
    static func runDecision(_ decision: AgentDecision) -> AgentDecision {
        if case .ask = decision { return .refuse(nil, wouldAskSentence) }
        return decision
    }

}

/// Suggested names for agent tabs, which `BrowserAgentHost` gives under the AI hooks' rules (hook decision 13) for `rename_tab` from outside clients and their runs. A protocol beside `AgentBrowserHost`, so that a host without it gives no names and the tool refuses.
@MainActor
public protocol AgentTabNaming: AnyObject {
    /// Suggests a name for the tab while it shows `document`, ignoring the fragment, inside `withCause` with the grant's cause; nil removes a suggested name. False when the tab no longer shows that document or the user's name or refusal keeps its name.
    func suggestName(_ name: String?, forTab id: UUID, showing document: URL, byGrant grant: UUID, applying: Bool) -> Bool
    /// The address the tab has committed, which names belong to, while its shown address may still be loading; nil before its first commit.
    func committedAddress(ofTab id: UUID) -> URL?
}
