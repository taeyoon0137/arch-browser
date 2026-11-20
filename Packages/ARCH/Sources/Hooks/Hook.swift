// A hook (`docs/hooks.md`, A hook; Triggers and filters): a trigger, a filter, and a script that Arch runs for each matching browser event, with its grant, timing, state, and origin. `hooks.json` keeps hooks in this shape; their scripts live in their own folders (`HookStore`).
import Agent
import AgentControl
import AI
import Events
import Foundation

/// A saved browser-event hook with its script, grant, timing, state, and origin.
public struct Hook: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var trigger: HookTrigger
    /// Also the hook's reach: its runs act only on the tabs it covers in the event's Persona (hook decision 16). Its kinds come from the trigger, and it never names agent tabs.
    public var filter: BrowserEventFilter
    public var script: HookScript
    public var grant: HookGrant
    /// The agent run that an agent hook's script starts through `event.hook.agent`, which the editor edits; nil for other hooks.
    public var agent: AgentRunOptions?
    /// What the run log keeps of this hook's runs (`docs/hooks.md`, Run log).
    public var record: AgentRunRecord
    public var timing: HookTiming
    public var state: HookState
    public var origin: HookOrigin
    public var created: Date

    public init(id: UUID = UUID(), name: String, trigger: HookTrigger, filter: BrowserEventFilter = .everything, script: HookScript = .javaScript(digest: "", generated: false),
                grant: HookGrant = HookGrant(), agent: AgentRunOptions? = nil, record: AgentRunRecord = .activity, timing: HookTiming? = nil, state: HookState = .active,
                origin: HookOrigin = .user, created: Date = Date()) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.filter = filter
        self.script = script
        self.grant = grant
        self.agent = agent
        self.record = record
        self.timing = timing ?? HookTiming(for: trigger)
        self.state = state
        self.origin = origin
        self.created = created
    }

    /// Named, so the store can keep the members a later build adds to a hook.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, trigger, filter, script, grant, agent, record, timing, state, origin, created
    }

    /// Whether the hook may reach a model: its runs then get no event from a site excluded from AI (hook decision 14), and it has its own AI feature.
    public var usesAgent: Bool { grant.permissions.contains(.agent) }

    /// The scheduler's owner of the hook's steps.
    public var owner: String { Self.owner(of: id) }

    /// The scheduler's owner of the steps of the hook with the identifier.
    public static func owner(of id: UUID) -> String { "hook.\(id.uuidString)" }
}

/// The event and optional conditions that start a hook run.
public enum HookTrigger: Codable, Hashable, Sendable {
    case tabOpened
    /// Empty matches every reason.
    case tabClosed(reasons: Set<BrowserTabCloseReason>)
    case pageLoaded(loads: HookPageLoads, includesRestoredTabs: Bool)
    case addressChanged(changes: HookAddressChanges)
    /// `[.page]` by default, so names that code gives start nothing.
    case titleChanged(sources: Set<BrowserTitleSource>)
    case tabSelected
    case downloadFinished
    case spaceSwitched(personaChangesOnly: Bool)

    public var kind: BrowserEventKind {
        switch self {
        case .tabOpened: return .tabOpened
        case .tabClosed: return .tabClosed
        case .pageLoaded: return .pageLoaded
        case .addressChanged: return .addressChanged
        case .titleChanged: return .titleChanged
        case .tabSelected: return .tabSelected
        case .downloadFinished: return .downloadFinished
        case .spaceSwitched: return .spaceSwitched
        }
    }

    /// Whether the event meets the trigger's options; the filter is checked apart. `previousDocument` is the address of the tab's previous page load, which `newAddress` compares, and `carriesFirstLoad` says that a `firstAfterOpen` run for the tab ended before it completed, so the tab's next load counts as its first (`docs/hooks.md`, Running).
    public func matches(_ event: BrowserEvent, previousDocument: URL? = nil, carriesFirstLoad: Bool = false) -> Bool {
        switch (self, event.payload) {
        case (.tabOpened, .tabOpened), (.tabSelected, .tabSelected), (.downloadFinished, .downloadFinished):
            return true
        case let (.tabClosed(reasons), .tabClosed(_, reason)):
            return reasons.isEmpty || reasons.contains(reason)
        case let (.pageLoaded(loads, includesRestoredTabs), .pageLoaded(tab, isRestore, isFirstLoadAfterOpen)):
            if isRestore && !includesRestoredTabs { return false }
            switch loads {
            case .firstAfterOpen: return isFirstLoadAfterOpen || carriesFirstLoad
            case .newAddress: return previousDocument.map { $0.hookDocument != tab.url?.hookDocument } ?? true
            case .every: return true
            }
        case let (.addressChanged(changes), .addressChanged(tab, previousURL)):
            switch changes {
            case .newHost: return tab.url?.host?.lowercased() != previousURL?.host?.lowercased()
            case .any: return true
            }
        case let (.titleChanged(sources), .titleChanged(_, source)):
            return sources.contains(source)
        case let (.spaceSwitched(personaChangesOnly), .spaceSwitched(_, _, personaID, _, previousPersonaID)):
            return !personaChangesOnly || personaID != previousPersonaID
        default:
            return false
        }
    }
}

/// Which page loads start a hook.
public enum HookPageLoads: String, Codable, Hashable, Sendable {
    /// The tab's first page after it opened in this launch (`isFirstLoadAfterOpen`).
    case firstAfterOpen
    /// A load whose address, without the fragment, differs from that of the tab's previous document. The default.
    case newAddress
    case every
}

/// Which address changes start a hook.
public enum HookAddressChanges: String, Codable, Hashable, Sendable {
    /// The default, so that a single-page site's own address changes start nothing.
    case newHost
    case any
}

/// A JavaScript or trusted shell script stored for a hook.
public enum HookScript: Codable, Hashable, Sendable {
    /// `Hooks/<hook id>/hook.js`. `generated`: the editor's template, which the editor writes again when `agent` changes.
    case javaScript(digest: String, generated: Bool)
    /// The file the user trusted, copied to `Hooks/<hook id>/hook.sh` (`docs/hooks.md`, Shell scripts); `source` is where the user keeps it, and `interpreter` the program its first line resolved to when the user trusted it.
    case shell(source: String, digest: String, interpreter: HookInterpreter)

    /// The SHA-256 of the script's bytes, as `sha256:<hex>`.
    public var digest: String {
        switch self {
        case .javaScript(let digest, _), .shell(_, let digest, _): return digest
        }
    }

    public var isShell: Bool {
        if case .shell = self { return true }
        return false
    }

    /// The same script with another digest.
    func withDigest(_ digest: String) -> HookScript {
        switch self {
        case .javaScript(_, let generated): return .javaScript(digest: digest, generated: generated)
        case .shell(let source, _, let interpreter): return .shell(source: source, digest: digest, interpreter: interpreter)
        }
    }
}

/// The resolved path and digest of a trusted shell script's interpreter.
public struct HookInterpreter: Codable, Hashable, Sendable {
    /// Absolute, with links resolved.
    public var path: String
    /// SHA-256 of the executable file.
    public var digest: String

    public init(path: String, digest: String) {
        self.path = path
        self.digest = digest
    }
}

/// The tab and agent abilities a hook may receive in its grant.
public enum HookPermission: String, Codable, Hashable, Sendable, CaseIterable {
    /// Titles and addresses of the tabs the hook's filter covers in the event's Persona (Run tabs).
    case tabs
    /// Names tabs; the user's own name always wins (hook decision 13).
    case tabsRename = "tabs.rename"
    /// Agent runs within `HookGrant.agent`, whose tab access says whether they read page text.
    case agent
}

/// A hook's permissions and optional ceiling for agent runs.
public struct HookGrant: Codable, Hashable, Sendable {
    public var permissions: Set<HookPermission>
    /// The ceiling of the script's agent runs; nil without `agent`.
    public var agent: AgentRunGrant?

    public init(permissions: Set<HookPermission> = [], agent: AgentRunGrant? = nil) {
        self.permissions = permissions
        self.agent = agent
    }
}

/// In JSON the durations are in seconds: `{"delay": 1.5, "timeout": 25, "runsPerDay": 300}`.
public struct HookTiming: Codable, Hashable, Sendable {
    /// 0 to 60 seconds; 1.5 seconds by default for `pageLoaded` and 1 second for `addressChanged` and `titleChanged`. A newer event of the same kind for the same subject during the wait replaces the waiting run.
    public var delay: Duration
    /// 1 second to 10 minutes, 30 seconds by default; for an agent hook, the agent run's time limit and 5 seconds.
    public var timeout: Duration
    /// 500 by default.
    public var runsPerDay: Int

    public init(delay: Duration, timeout: Duration = .seconds(30), runsPerDay: Int = 500) {
        self.delay = delay
        self.timeout = timeout
        self.runsPerDay = runsPerDay
    }

    /// The defaults for a trigger.
    public init(for trigger: HookTrigger) {
        switch trigger.kind {
        case .pageLoaded: self.init(delay: .milliseconds(1_500))
        case .addressChanged, .titleChanged: self.init(delay: .seconds(1))
        default: self.init(delay: .zero)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case delay, timeout, runsPerDay
    }

    /// Decodes the delay and timeout in seconds from stored hook timing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delay = .seconds(try container.decode(Double.self, forKey: .delay))
        timeout = .seconds(try container.decode(Double.self, forKey: .timeout))
        runsPerDay = try container.decode(Int.self, forKey: .runsPerDay)
    }

    /// Encodes the delay and timeout in seconds for storage.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(delay.hookSeconds, forKey: .delay)
        try container.encode(timeout.hookSeconds, forKey: .timeout)
        try container.encode(runsPerDay, forKey: .runsPerDay)
    }
}

/// In JSON, `"active"` or `{"paused": "<reason>"}`.
public enum HookState: Codable, Hashable, Sendable {
    case active
    case paused(HookPauseReason)

    private enum CodingKeys: String, CodingKey {
        case paused
    }

    /// Decodes the active marker or a paused state with its reason.
    public init(from decoder: any Decoder) throws {
        if let word = try? decoder.singleValueContainer().decode(String.self) {
            guard word == "active" else { throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown state \(word)")) }
            self = .active
        } else {
            self = .paused(try decoder.container(keyedBy: CodingKeys.self).decode(HookPauseReason.self, forKey: .paused))
        }
    }

    /// Encodes the active marker or the paused reason.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .active:
            var container = encoder.singleValueContainer()
            try container.encode("active")
        case .paused(let reason):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(reason, forKey: .paused)
        }
    }

    public var pauseReason: HookPauseReason? {
        if case .paused(let reason) = self { return reason }
        return nil
    }
}

/// The reason a hook remains paused until its owner or settings change.
public enum HookPauseReason: String, Codable, Hashable, Sendable {
    /// `failures` covers three failed or timed-out runs in a row; `providerErrors` the scheduler's pause after three authentication or provider errors, which a change to the hook's tier route lifts; `scriptChanged` a shell hook's interpreter too; `grantEnded` an outside program's hook whose grant ended; `unknownProvider` a run that would reach a provider Arch did not see the user set up (Known providers).
    case user, failures, providerErrors, ranTooOften, stopAllAgents, placeDeleted, scriptChanged, shellScriptsOff, needsNewerArch, grantEnded, unknownProvider
}

/// In JSON, `"user"`, `{"preset": "<name>"}`, or `{"outsideClient": {"key": …, "name": …}}`.
public enum HookOrigin: Codable, Hashable, Sendable {
    case user
    case preset(String)
    /// Added with `arch-cli hooks add` after the user allowed it.
    case outsideClient(AgentClientIdentity.Key, name: String)

    private enum CodingKeys: String, CodingKey {
        case preset, outsideClient
    }

    private struct Client: Codable {
        var key: AgentClientIdentity.Key
        var name: String
    }

    /// Decodes a user, preset, or outside-client origin.
    public init(from decoder: any Decoder) throws {
        if let word = try? decoder.singleValueContainer().decode(String.self) {
            guard word == "user" else { throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown origin \(word)")) }
            self = .user
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let preset = try container.decodeIfPresent(String.self, forKey: .preset) {
            self = .preset(preset)
        } else {
            let client = try container.decode(Client.self, forKey: .outsideClient)
            self = .outsideClient(client.key, name: client.name)
        }
    }

    /// Encodes the origin in its stored tagged form.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .user:
            var container = encoder.singleValueContainer()
            try container.encode("user")
        case .preset(let name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .preset)
        case .outsideClient(let key, let name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Client(key: key, name: name), forKey: .outsideClient)
        }
    }
}

extension Duration {
    /// The duration in seconds, as `hooks.json` writes it.
    var hookSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

extension URL {
    /// The document an address shows: the address without its fragment, which changes no document.
    var hookDocument: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false), components.fragment != nil else { return self }
        components.fragment = nil
        return components.url ?? self
    }
}
