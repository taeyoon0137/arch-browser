// The hook registry (`docs/hooks.md`, Hook registry): keeps the hooks of `hooks.json`, matches each browser event to them, and runs each match as a step of the shared hook scheduler, after the AI hook center's hooks for the same event, with the registry's own rules: concurrency caps, loop protection, rate and daily limits, pausing, and the run log. A step runs the hook's script through a `HookScriptRunning`; the registry never runs an agent itself.
import Agent
import AgentControl
import AI
import Combine
import Events
import Foundation

// MARK: - The browser side and the runners

/// The browser side the registry needs, which `Browsing` provides.
@MainActor
public protocol HookBrowserHost: AnyObject {
    /// Every Persona with its spaces, in the session's order, for filters and their names.
    var places: [HookPersonaPlaces] { get }
    /// The tab as the bus would describe it now, or nil once it is gone.
    func tab(_ id: UUID) -> BrowserTabRef?
    /// The Persona's open tabs in sidebar order, never agent tabs. A run's tabs are those of them its hook's filter covers (`docs/hooks.md`, Run tabs).
    func tabs(inPersona id: UUID) -> [BrowserTabRef]
    /// A listed tab's shown name and committed address, which while its `tabClosed` is delivered are the closing tab's last ones; nil once the tab is gone. The registry asks only at a close and for a test that treats an open tab as closed.
    func closingTab(_ id: UUID) -> AgentRunClosedTab?
    /// Set by the registry; called after Personas or spaces change.
    var placesDidChange: (() -> Void)? { get set }
}

/// A Persona and its spaces, which filters name as "Persona" and "Persona / Space".
public struct HookPersonaPlaces: Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var spaces: [HookSpace]

    public init(id: UUID, name: String, spaces: [HookSpace]) {
        self.id = id
        self.name = name
        self.spaces = spaces
    }
}

public struct HookSpace: Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Runs one script for one event. The JavaScript and shell runners conform, and the tests use a fake.
@MainActor
public protocol HookScriptRunning: AnyObject {
    /// Runs the invocation's script until it ends, its deadline passes, or `cancel(run:)` stops it.
    func run(_ invocation: HookInvocation) async -> HookRunOutcome
    func cancel(run: UUID)
}

/// One run of a hook's script.
public struct HookInvocation: Sendable {
    public var hook: Hook
    public var run: UUID
    /// The event's Persona, whose tabs the run reaches.
    public var personaID: UUID
    /// The event in the hook's script view: addresses and download details with `tabs`, nothing from a site excluded from AI for a hook with `agent`.
    public var event: BrowserEventScriptView
    /// What the run's actions carry: the run, and the triggering event's hook chain followed by the hook (Loop protection).
    public var cause: BrowserEventCause
    /// The hook's timeout from the run's start; the scheduler cancels the run then.
    public var deadline: ContinuousClock.Instant
    /// An editor test can either preview actions or apply them.
    public var isTest = false
    /// False for a test without Apply Changes.
    public var appliesActions: Bool
    /// The script's bytes, checked against the digest in `hooks.json`.
    public var script: Data
    /// The run's tabs: the open tabs the hook's filter covers in the event's Persona, or the event's tab alone for an outside program's hook (`docs/hooks.md`, Run tabs).
    public var tabs: Set<UUID>
    /// The event's tab among the run's tabs: a tab event's tab, or a finished download's tab while it is open; nil for a close and a space switch.
    public var eventTab: UUID?
    /// The document each run tab's renames belong to: the event's address for the event's tab of a page, address, or title event, and each other run tab's committed address as the run starts. A tab without a committed address has none and takes no name.
    public var documents: [UUID: URL]
    /// A close run's closed tab, kept in memory only.
    public var closedTab: AgentRunClosedTab?
    /// `knownProviders` by provider, for the run's agent runs (`docs/hooks.md`, Known providers).
    public var knownProviders: [AIProviderID: String]
    /// Reports each AI request's end, nil for a reply, so the scheduler can pause the hook after consecutive authentication or provider errors.
    public var requestDidEnd: @MainActor @Sendable ((any Error)?) -> Void
}

/// How a script's run ended.
public enum HookRunOutcome: Sendable {
    /// With the actions applied or, in a test, proposed, and the run's agent use.
    case completed(actions: [AgentRunAction], agent: HookAgentUse?)
    /// With a code and a sentence, such as a thrown error's message.
    case failed(code: String, message: String)
    case timedOut
    case cancelled
}

/// The model of a run's last agent run and the tokens of all of them.
public struct HookAgentUse: Equatable, Sendable {
    public var model: AIModelRef?
    public var usage: AIUsage
    /// Shown only in the editor for its own explicit test.
    public var reply: String? = nil

    public init(model: AIModelRef?, usage: AIUsage) {
        self.model = model
        self.usage = usage
    }
}

/// What a test run gives the editor.
public enum HookRunResult: Sendable {
    case finished(HookRunOutcome)
    /// The test could not start, with the sentence the editor shows.
    case notRun(String)
}

/// A hook's script file as it is now.
public struct HookScriptFile: Equatable, Sendable {
    public var contents: Data
    /// false for a file changed outside Arch, which the editor opens only for review and no copy takes (hook decision 8).
    public var matchesDigest: Bool

    public init(contents: Data, matchesDigest: Bool) {
        self.contents = contents
        self.matchesDigest = matchesDigest
    }
}

/// A run as a hook's row shows it, in memory only.
public struct HookRunSummary: Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var outcome: HookRunEntry.Outcome
    public var code: String?
    public var reason: HookRunEntry.SkipReason?
    /// In seconds.
    public var duration: Double?
    public var actions: [String: Int]?
    /// A failed run's message, its first 200 characters; never on disk, and nil at Keep Nothing.
    public var message: String?
    public var test: Bool

    init(_ entry: HookRunEntry, message: String?) {
        id = entry.id
        date = entry.date
        outcome = entry.outcome
        code = entry.code
        reason = entry.reason
        duration = entry.duration
        actions = entry.actions
        self.message = message
        test = entry.test
    }

    /// What Keep Nothing keeps of the last run: its time and outcome.
    var reduced: HookRunSummary {
        var summary = self
        summary.code = nil
        summary.reason = nil
        summary.duration = nil
        summary.actions = nil
        summary.message = nil
        return summary
    }
}

/// A hook's runs and failures on one day, which its row shows and its daily count limits.
public struct HookDayCount: Hashable, Sendable {
    /// The day's start.
    public var day: Date
    public var runs: Int
    public var failures: Int
}

public enum HookRegistryError: LocalizedError, Equatable {
    case duplicate
    case unknownHook
    /// Hooks never see agent tabs, so a filter may not name them.
    case namesAgentTabs
    case invalidAgentOptions(String)

    public var errorDescription: String? {
        switch self {
        case .duplicate: return "A hook with this identifier exists already."
        case .unknownHook: return "Arch has no hook it can change with this identifier."
        case .namesAgentTabs: return "Hooks cannot run for agent tabs."
        case .invalidAgentOptions(let reason): return reason
        }
    }
}

/// Stands in for a runner Arch does not have yet, the shell runner until VII.31. Every run fails with `runnerMissing`.
public final class UnavailableHookScriptRunner: HookScriptRunning {
    public init() {}

    public func run(_ invocation: HookInvocation) async -> HookRunOutcome {
        .failed(code: "runnerMissing", message: "This version of Arch cannot run this kind of script.")
    }

    public func cancel(run: UUID) {}
}

// MARK: - Registry

@MainActor
public final class HookRegistry: ObservableObject {
    /// Registry runs at once, in all and for one hook; steps beyond them wait in arrival order, at most `maximumWaiting`.
    public static let maximumRunning = 4
    public static let maximumRunningPerHook = 2
    public static let maximumWaiting = 100
    /// Consecutive failed or timed-out runs that pause a hook.
    public static let failuresBeforePause = 3
    /// An event whose hook chain holds this many hooks reaches none.
    public static let maximumHookChain = 3
    /// The runs each hook's row keeps.
    public static let keptRunSummaries = 20
    /// The registry's steps run after built-in hooks (100) and plugin hooks (200), at this order plus their place in the list.
    public static let firstOrder = 1_000

    /// In run order.
    @Published public private(set) var hooks: [Hook] = []
    /// Settings ▸ AI ▸ Agent Hooks ▸ Run Hooks. While it is off, no event reaches a hook; turning it off stops running runs without changing the hooks' states.
    @Published public var runsHooks = true {
        didSet { runsHooksDidChange(from: oldValue) }
    }
    /// The last runs of each hook, newest last, in memory (`docs/hooks.md`, Run log).
    @Published public private(set) var lastRuns: [UUID: [HookRunSummary]] = [:]
    /// Each hook's runs and failures today.
    @Published public private(set) var dayCounts: [UUID: HookDayCount] = [:]
    /// A file set aside, a key the Keychain did not give, a file from a newer Arch, or a change not written, for Settings.
    @Published public private(set) var notice: HookStoreNotice?
    /// Whether `hooks.json` has been read. Until then no event reaches a hook and no change is accepted.
    @Published public private(set) var isReady = false
    public let log: HookRunLog

    private let store: HookStore
    private let ai: AIService
    private let scheduler: AIHookScheduler
    private let host: any HookBrowserHost
    private let javaScript: any HookScriptRunning
    private let shell: any HookScriptRunning
    private let now: () -> Date
    private var allowsShellScripts = false
    private var knownProviders: [HookKnownProvider] = []
    /// Each provider's destination as last seen, from launch on: one that differs when `ai.json` changes is one the user set up in Arch.
    private var seenProviders: [AIProviderID: String]
    private var subscription: BrowserEventSubscription?
    private var cancellables: Set<AnyCancellable> = []
    private var limiter = BrowserEventRateLimiter()
    private let slots = HookRunSlots(total: HookRegistry.maximumRunning, perHook: HookRegistry.maximumRunningPerHook, waiting: HookRegistry.maximumWaiting)
    private var failureCounts: [UUID: Int] = [:]
    /// The edited hook for each draft test, so changing its grant also ends its preview.
    private var draftOwner: [UUID: UUID] = [:]
    /// Scripts that must stop immediately when their grant changes, including tests outside the scheduler.
    private var activeRuns: [UUID: HookRun] = [:]
    /// Each tab's last loaded document, which `newAddress` compares.
    private var lastDocuments: [UUID: URL] = [:]
    /// The `firstAfterOpen` hooks of each tab whose run has not completed: a new document or a newer load that ended it lets the tab's next load count as its first.
    private var firstLoadCarryOvers: [UUID: Set<UUID>] = [:]
    /// The routes in `ai.json` as last seen, to notice the tier routes the user changes.
    private var seenRoutes: [String: AIRoute]
    /// When each hook last logged a skip for each limit, so a hook past a limit logs one skip a minute, or a day for its daily count.
    private var loggedSkips: [UUID: [HookRunEntry.SkipReason: Date]] = [:]
    private var isLoading = false
    private var isApplyingSettings = false
    private var isPreparingKey = false

    /// The app's registry: `hooks.json` and the scripts in `directory`, the session's bus and host, and the shared AI service, whose hook scheduler the AI hook center's hooks run on too.
    public convenience init(directory: URL, bus: BrowserEventBus, host: any HookBrowserHost, javaScript: any HookScriptRunning, shell: any HookScriptRunning) {
        self.init(store: HookStore(directory: directory), bus: bus, ai: .shared, host: host, javaScript: javaScript, shell: shell)
    }

    /// A registry on `ai`'s hook scheduler; tests give their own store, service, and clock.
    public init(store: HookStore, bus: BrowserEventBus, ai: AIService, host: any HookBrowserHost,
                javaScript: any HookScriptRunning, shell: any HookScriptRunning, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.ai = ai
        scheduler = ai.hooks.scheduler
        self.host = host
        self.javaScript = javaScript
        self.shell = shell
        self.now = now
        log = HookRunLog(fileURL: store.directory.appendingPathComponent("hooks-activity.json"), now: now)
        seenProviders = Self.destinations(of: ai.settings.providers)
        seenRoutes = ai.settings.routes
        subscription = bus.subscribe(.everything) { [weak self] event in self?.handle(event) }
        host.placesDidChange = { [weak self] in self?.placesDidChange() }
        // A published value reaches its subscribers before the store holds it, so each change comes with its new value.
        ai.settings.$providers.dropFirst()
            .sink { [weak self] providers in MainActor.assumeIsolated { self?.providersDidChange(providers) } }
            .store(in: &cancellables)
        ai.settings.$routes.dropFirst()
            .sink { [weak self] routes in MainActor.assumeIsolated { self?.routesDidChange(routes) } }
            .store(in: &cancellables)
        scheduler.$pausedOwners
            .sink { [weak self] owners in MainActor.assumeIsolated { self?.schedulerPausesDidChange(owners) } }
            .store(in: &cancellables)
        Task { await load() }
    }

    // MARK: Loading and saving

    /// Settings' Try Again after the Keychain did not give the key.
    public func retryLoading() {
        guard !isReady else { return }
        Task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let settings = await store.load() else {
            notice = store.notice
            return
        }
        isApplyingSettings = true
        runsHooks = settings.runsHooks
        isApplyingSettings = false
        allowsShellScripts = settings.allowsShellScripts
        knownProviders = settings.knownProviders
        hooks = settings.hooks
        notice = store.notice
        isReady = true
        hooks.forEach(register)
        lastRuns = Self.summaries(of: log.entries, for: hooks)
        var changed = recordProviders(ai.settings.providers)
        changed = pauseChangedScripts() || changed
        changed = applyPlaces() || changed
        if changed, store.hasFile { persist() }
    }

    /// Writes `hooks.json` now when the key is in, or once the Keychain gives it.
    private func persist() {
        guard store.isReady else { return }
        if store.hasKey { return write() }
        guard !isPreparingKey else { return }
        isPreparingKey = true
        Task {
            defer { isPreparingKey = false }
            do {
                try await store.prepareKey()
                write()
            } catch {
                store.didNotSave(error.localizedDescription)
                notice = store.notice
            }
        }
    }

    /// The first write records the providers `ai.json` holds then (`docs/hooks.md`, Known providers).
    private func write() {
        if !store.hasFile {
            knownProviders = ai.settings.providers.map(HookKnownProvider.init)
        }
        var settings = HookSettings()
        settings.runsHooks = runsHooks
        settings.allowsShellScripts = allowsShellScripts
        settings.knownProviders = knownProviders
        settings.hooks = hooks
        do {
            let record = try store.save(settings)
            notice = store.notice
            Task {
                do {
                    try await record.value
                } catch {
                    store.didNotSave("The Keychain did not record this change, so an earlier copy of hooks.json would still open: \(error.localizedDescription)")
                    notice = store.notice
                }
            }
        } catch {
            store.didNotSave(error.localizedDescription)
            notice = store.notice
        }
    }

    // MARK: Changes

    /// Adds the hook at the end of the list with its script, whose digest the registry records. Its filter's kinds become its trigger's.
    public func add(_ hook: Hook, script: Data) throws {
        guard isReady else { throw HookStoreError.notReady }
        guard index(of: hook.id) == nil else { throw HookRegistryError.duplicate }
        var added = try Self.checked(hook)
        added.script = try store.writeScript(script, for: added)
        hooks.append(added)
        register(added)
        persist()
    }

    /// Replaces the hook's settings, and its script when `script` is given; the hook keeps its origin, creation date, state, and, without a script, its recorded script. Only `pause(_:)`, `resume(_:)`, and the registry's own pauses change a hook's state.
    public func update(_ hook: Hook, script: Data?) throws {
        guard isReady else { throw HookStoreError.notReady }
        guard let index = index(of: hook.id), !store.isUnreadable(hook.id) else { throw HookRegistryError.unknownHook }
        let stored = hooks[index]
        var updated = try Self.checked(hook)
        updated.origin = stored.origin
        updated.created = stored.created
        updated.state = stored.state
        updated.script = try script.map { try store.writeScript($0, for: updated) } ?? stored.script
        hooks[index] = updated
        register(updated)
        if updated.state != .active || updated.usesAgent || stored.usesAgent { cancelRuns(of: updated) }
        persist()
    }

    /// Removes the hook, its folder, and its feature; usage totals stay under the feature's identifier.
    public func remove(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let hook = hooks.remove(at: index)
        cancelRuns(of: hook)
        store.removeScripts(of: id)
        ai.unregister(.agentHook(id))
        lastRuns[id] = nil
        dayCounts[id] = nil
        failureCounts[id] = nil
        loggedSkips[id] = nil
        limiter.reset(hook.owner)
        for tab in firstLoadCarryOvers.keys { firstLoadCarryOvers[tab]?.remove(id) }
        persist()
    }

    public func move(_ id: UUID, to index: Int) {
        guard let from = self.index(of: id) else { return }
        let hook = hooks.remove(at: from)
        hooks.insert(hook, at: min(max(index, 0), hooks.count))
        persist()
    }

    /// Every Persona with its spaces, in the session's order, for filters and the names Settings gives them.
    public var places: [HookPersonaPlaces] { host.places }

    /// The hook's script file as it is now, also when it no longer matches its digest, for the editor's Edit, Review, and Duplicate; nil when the file is missing. An active hook whose file no longer matches pauses with `scriptChanged`, as its next run would, so that its row offers Review.
    public func scriptFile(of id: UUID) -> HookScriptFile? {
        guard let hook = hook(withID: id), let contents = try? Data(contentsOf: store.scriptURL(of: hook)) else { return nil }
        let matchesDigest = HookStore.digest(of: contents) == hook.script.digest
        if !matchesDigest { pauseHook(id, .scriptChanged) }
        return HookScriptFile(contents: contents, matchesDigest: matchesDigest)
    }

    /// The scheduler owns event runs. The registry owns the editor’s test runs.
    private func cancelRuns(of hook: Hook) {
        for run in activeRuns.values where run.hookID == hook.id || draftOwner[run.hookID] == hook.id { run.cancelScript() }
        scheduler.cancel(owner: hook.owner)
    }

    /// Provider destinations on this paused hook’s current route that the user has not yet approved.
    public func providersForReview(of id: UUID) -> [HookKnownProvider] {
        guard let hook = hook(withID: id), hook.state == .paused(.unknownProvider), let route = hook.agent?.model,
              let models = try? ai.resolvedModels(for: .agentHook(id), route: route) else { return [] }
        let ids = Set(models.map(\.provider))
        return ai.settings.providers.filter { ids.contains($0.id) }.map(HookKnownProvider.init).filter { !knownProviders.contains($0) }
    }

    /// Records only destinations that still match the review the user just confirmed.
    public func approveProviders(_ reviewed: [HookKnownProvider], for id: UUID) {
        guard isReady, !reviewed.isEmpty, providersForReview(of: id) == reviewed else { return }
        let ids = Set(reviewed.map(\.id))
        knownProviders.removeAll { ids.contains($0.id) }
        knownProviders += reviewed
        resume(id)
    }

    /// A paused hook stops its runs and skips waiting events.
    public func pause(_ id: UUID) {
        guard let index = index(of: id), hooks[index].state == .active else { return }
        hooks[index].state = .paused(.user)
        cancelRuns(of: hooks[index])
        persist()
    }

    /// Resumes a paused hook and clears its failure and rate counts. A hook from a newer Arch, one whose script still differs from its digest, one with no place left, and a shell hook while shell scripts are off stay paused.
    public func resume(_ id: UUID) {
        guard let index = index(of: id), let reason = hooks[index].state.pauseReason, mayResume(hooks[index], from: reason) else { return }
        hooks[index].state = .active
        failureCounts[id] = nil
        limiter.reset(hooks[index].owner)
        scheduler.resume(owner: hooks[index].owner)
        persist()
    }

    /// Stop All Agents: stops the running runs of every hook with `agent` and pauses each active one until the user resumes it.
    public func stopAgentHooks() {
        for run in activeRuns.values {
            if let owner = draftOwner[run.hookID], hook(withID: owner)?.usesAgent != true { run.cancelScript() }
        }
        var changed = false
        for index in hooks.indices where hooks[index].usesAgent {
            cancelRuns(of: hooks[index])
            if hooks[index].state == .active {
                hooks[index].state = .paused(.stopAllAgents)
                changed = true
            }
        }
        if changed { persist() }
    }

    private func mayResume(_ hook: Hook, from reason: HookPauseReason) -> Bool {
        if case .places(let places) = hook.filter.scope, places.isEmpty { return false }
        switch reason {
        case .needsNewerArch: return false
        case .unknownProvider: return providersForReview(of: hook.id).isEmpty && !store.isUnreadable(hook.id)
        case .scriptChanged: return store.script(for: hook) != nil
        case .shellScriptsOff: return allowsShellScripts
        default: return !store.isUnreadable(hook.id)
        }
    }

    /// Pauses an active hook for a reason Arch found. Its waiting runs then decline; `stopping` also stops its running run.
    private func pauseHook(_ id: UUID, _ reason: HookPauseReason, stopping: Bool = false) {
        guard let index = index(of: id), hooks[index].state == .active else { return }
        hooks[index].state = .paused(reason)
        if stopping { cancelRuns(of: hooks[index]) }
        persist()
    }

    private func runsHooksDidChange(from wasOn: Bool) {
        guard !isApplyingSettings, runsHooks != wasOn else { return }
        if !runsHooks {
            for hook in hooks { cancelRuns(of: hook) }
        }
        persist()
    }

    /// The hook as the registry keeps it: its filter's kinds are its trigger's, and its filter names no agent tabs.
    static func checked(_ hook: Hook) throws -> Hook {
        guard !hook.filter.tabKinds.contains(.agent) else { throw HookRegistryError.namesAgentTabs }
        if let options = hook.agent {
            guard hook.usesAgent, let grant = hook.grant.agent else { throw HookRegistryError.invalidAgentOptions("Agent options need an agent grant.") }
            if let reason = grant.refusal(for: options) { throw HookRegistryError.invalidAgentOptions(reason) }
        }
        var checked = hook
        checked.filter.kinds = [hook.trigger.kind]
        return checked
    }

    private func index(of id: UUID) -> Int? {
        hooks.firstIndex { $0.id == id }
    }

    private func hook(withID id: UUID) -> Hook? {
        hooks.first { $0.id == id }
    }

    /// A hook with `agent` has the automatic, `perRequest` feature `agentHook.<id>`, named after it, whose page data carries no text unless its grant reads pages.
    private func register(_ hook: Hook) {
        let id = AIFeatureID.agentHook(hook.id)
        guard hook.usesAgent else { return ai.unregister(id) }
        let readsPages = hook.grant.agent?.tabAccess == .page
        ai.register(AIFeature(id: id, name: hook.name,
                              summary: readsPages ? "Runs an agent for this hook with the titles, addresses, and text of the tabs it reaches."
                                                  : "Runs an agent for this hook with the titles and addresses of the tabs it reaches.",
                              trigger: .automatic, data: AIDataScope(kinds: [.page], pageTextLimit: readsPages ? nil : 0), requirements: [.agent], routing: .perRequest))
    }

    // MARK: Places, scripts, providers, and the scheduler's pauses

    private func placesDidChange() {
        guard isReady, applyPlaces() else { return }
        persist()
    }

    /// Removes deleted Personas and spaces from every filter; a hook left with no place pauses with `placeDeleted`.
    private func applyPlaces() -> Bool {
        let places = host.places
        // The session always has a Persona, so an empty list is no deletion.
        guard !places.isEmpty else { return false }
        let personas = Set(places.map(\.id))
        let spaces = Set(places.flatMap { $0.spaces.map(\.id) })
        var changed = false
        for index in hooks.indices where !store.isUnreadable(hooks[index].id) {
            guard case .places(let scope) = hooks[index].filter.scope else { continue }
            let kept = scope.filter { place in
                switch place {
                case .persona(let id): return personas.contains(id)
                case .space(let id): return spaces.contains(id)
                }
            }
            guard kept.count != scope.count else { continue }
            hooks[index].filter.scope = .places(kept)
            if kept.isEmpty, hooks[index].state == .active {
                hooks[index].state = .paused(.placeDeleted)
                cancelRuns(of: hooks[index])
            }
            changed = true
        }
        return changed
    }

    /// Pauses each active hook whose script no longer matches its digest, as after an edit outside Arch.
    private func pauseChangedScripts() -> Bool {
        var changed = false
        for index in hooks.indices where hooks[index].state == .active && store.script(for: hooks[index]) == nil {
            hooks[index].state = .paused(.scriptChanged)
            changed = true
        }
        return changed
    }

    private func providersDidChange(_ providers: [AIProviderConfiguration]) {
        // The launch's load records the changes made before it.
        guard isReady else { return }
        if recordProviders(providers), store.hasFile { persist() }
    }

    /// Records each provider whose destination differs from the one last seen: `ai.json` is read only at launch, so such a change is one the user made in Settings ▸ AI ▸ Providers.
    private func recordProviders(_ providers: [AIProviderConfiguration]) -> Bool {
        var changed = false
        for provider in providers.map(HookKnownProvider.init) where seenProviders[provider.id] != provider.destination {
            seenProviders[provider.id] = provider.destination
            if let index = knownProviders.firstIndex(where: { $0.id == provider.id }) {
                guard knownProviders[index] != provider else { continue }
                knownProviders[index] = provider
            } else {
                knownProviders.append(provider)
            }
            changed = true
        }
        return changed
    }

    private static func destinations(of providers: [AIProviderConfiguration]) -> [AIProviderID: String] {
        Dictionary(providers.map { ($0.id, HookKnownProvider($0).destination) }, uniquingKeysWith: { first, _ in first })
    }

    /// The scheduler pauses an owner after consecutive authentication or provider errors; the hook follows with `providerErrors`, which `hooks.json` keeps, so that a change to its tier's route resumes it also after a relaunch, when the scheduler no longer holds the pause.
    private func schedulerPausesDidChange(_ owners: Set<String>) {
        var changed = false
        for index in hooks.indices where owners.contains(hooks[index].owner) && hooks[index].state == .active {
            hooks[index].state = .paused(.providerErrors)
            changed = true
        }
        if changed { persist() }
    }

    /// Resumes each hook paused with `providerErrors` whose agent options name a tier whose route changed, as the scheduler resumes its owner.
    private func routesDidChange(_ newRoutes: [String: AIRoute]) {
        let changed = Set(seenRoutes.keys).union(newRoutes.keys).filter { seenRoutes[$0] != newRoutes[$0] }
        seenRoutes = newRoutes
        guard isReady, !changed.isEmpty else { return }
        for hook in hooks where hook.state == .paused(.providerErrors) && !Self.routes(of: hook).isDisjoint(with: changed) {
            resume(hook.id)
        }
    }

    /// The tier route in `ai.json` that an agent hook's route resolves through.
    static func routes(of hook: Hook) -> Set<String> {
        guard hook.usesAgent, case .tier(let tier)? = hook.agent?.model else { return [] }
        return [AIFeatureID.tier(tier).rawValue]
    }

    // MARK: Matching

    /// Matches the event to the active hooks in list order and posts one step for each to the event's chain. A close and a new document end the tab's other chains, as `BrowserHooks` does for every owner, so the registry's runs end without it too.
    private func handle(_ event: BrowserEvent) {
        let previousDocument = event.tab.flatMap { lastDocuments[$0.id] }
        let carryOvers = event.tab.flatMap { firstLoadCarryOvers[$0.id] } ?? []
        let closedTab = event.kind == .tabClosed ? host.closingTab(event.subject) : nil
        switch event.payload {
        case .pageLoaded(let tab, _, _):
            lastDocuments[tab.id] = tab.url
        case .addressChanged(let tab, _):
            scheduler.cancel(subject: tab.id, otherThan: tab.url)
        case .tabClosed(let tab, _):
            lastDocuments[tab.id] = nil
            firstLoadCarryOvers[tab.id] = nil
            scheduler.cancel(subject: tab.id, except: event.id)
        default:
            break
        }
        guard isReady, runsHooks else { return }
        var steps: [AIHookStep] = []
        for (index, hook) in hooks.enumerated() where hook.state == .active && hook.trigger.kind == event.kind {
            guard hook.filter.matches(event),
                  hook.trigger.matches(event, previousDocument: previousDocument, carriesFirstLoad: carryOvers.contains(hook.id)) else { continue }
            // A hook that may reach a model gets nothing from a site excluded from AI, which its log therefore does not name either.
            if hook.usesAgent, !event.urls.allSatisfy(ai.settings.allowsAI(on:)) { continue }
            let chain = event.cause?.hookChain ?? []
            if chain.contains(hook.id) || chain.count >= Self.maximumHookChain {
                recordSkip(of: hook, event: event, .loop)
                continue
            }
            switch limiter.admit(hook.owner, subject: event.subject, at: now()) {
            case .allowed:
                break
            case .overSubject:
                // A page that changes its own title after each rename keeps such a hook running without a cause.
                if hook.trigger.kind == .titleChanged { pauseHook(hook.id, .ranTooOften) }
                recordSkip(of: hook, event: event, .rateLimit)
                continue
            case .overOwner:
                recordSkip(of: hook, event: event, .rateLimit)
                continue
            }
            if case .pageLoaded(.firstAfterOpen, _) = hook.trigger, let tab = event.tab {
                firstLoadCarryOvers[tab.id, default: []].insert(hook.id)
            }
            steps.append(step(for: hook, at: index, event: event, closedTab: closedTab))
        }
        guard !steps.isEmpty else { return }
        // The effect of a running hook's own run, such as its rename's title change, joins that run's chain rather than stopping the run.
        let causes = Set((event.cause?.hookChain ?? []).map(Hook.owner(of:)))
        scheduler.post(steps, kind: event.kind.rawValue, subject: event.subject, event: event.id, document: Self.document(of: event), urls: event.urls, causes: causes)
    }

    /// The address a page, address, or title event belongs to, whose chain ends when the tab commits another document.
    static func document(of event: BrowserEvent) -> URL? {
        switch event.payload {
        case .pageLoaded(let tab, _, _), .addressChanged(let tab, _), .titleChanged(let tab, _): return tab.url
        default: return nil
        }
    }

    /// A hook with agent options names its feature, its route, and the tier route in `ai.json` that its route resolves through, so the scheduler applies the feature's checks and pauses.
    private func step(for hook: Hook, at index: Int, event: BrowserEvent, closedTab: AgentRunClosedTab?) -> AIHookStep {
        let run = HookRun(hookID: hook.id, event: event, closedTab: closedTab, isTest: false)
        let route = hook.usesAgent ? hook.agent?.model : nil
        return AIHookStep(owner: hook.owner, order: Self.firstOrder + index, feature: route == nil ? nil : .agentHook(hook.id), routes: Self.routes(of: hook), route: route,
                          delay: hook.timing.delay, timeout: hook.timing.timeout,
                          mayRun: { [weak self] in self?.mayStart(run) ?? false },
                          run: { [weak self] requestDidEnd in await self?.execute(run, requestDidEnd: requestDidEnd) },
                          didEnd: { [weak self] outcome in self?.runDidEnd(run, outcome) })
    }

    // MARK: Running

    /// The registry's checks after the delay (`docs/hooks.md`, Running, step 6).
    private func mayStart(_ run: HookRun) -> Bool {
        guard isReady, runsHooks, let hook = hook(withID: run.hookID), hook.state == .active, !hook.script.isShell || allowsShellScripts else {
            return decline(run, .inactive)
        }
        guard dayCount(of: hook.id).runs < hook.timing.runsPerDay else { return decline(run, .dailyLimit) }
        let event = run.event
        // A close's subject is gone by design.
        if let tab = event.tab, event.kind != .tabClosed {
            guard let current = host.tab(tab.id) else { return decline(run, .subjectGone) }
            if let document = Self.document(of: event), current.url?.hookDocument != document.hookDocument { return decline(run, .documentChanged) }
        }
        if hook.usesAgent, !event.urls.allSatisfy(ai.settings.allowsAI(on:)) { return decline(run, .excludedSite) }
        return true
    }

    private func decline(_ run: HookRun, _ reason: HookRun.Decline) -> Bool {
        run.declined = reason
        return false
    }

    /// Waits for a slot, checks the daily count and the script against its digest, and runs it. The scheduler's timeout covers the wait.
    private func execute(_ run: HookRun, requestDidEnd: @escaping @MainActor @Sendable ((any Error)?) -> Void) async {
        guard let hook = hook(withID: run.hookID) else { return }
        let deadline = ContinuousClock.now + hook.timing.timeout
        do {
            try await slots.acquire(run: run.id, hook: hook.id)
        } catch is HookRunSlots.Dropped {
            run.wasDropped = true
            return
        } catch {
            return
        }
        defer { slots.release(run: run.id) }
        guard !Task.isCancelled, let current = self.hook(withID: run.hookID), current.state == .active else { return }
        // Runs that passed the check after their delay may have waited together, so the count is checked again where it grows.
        guard dayCount(of: current.id).runs < current.timing.runsPerDay else {
            run.declined = .dailyLimit
            return
        }
        run.startedAt = .now
        countRun(of: current.id)
        guard let script = store.script(for: current) else {
            pauseHook(current.id, .scriptChanged)
            run.outcome = .failed(code: "scriptChanged", message: "Its script changed outside Arch.")
            return
        }
        guard let invocation = invocation(for: current, run: run, script: script, deadline: deadline, applying: true, requestDidEnd: requestDidEnd) else { return }
        run.outcome = await perform(invocation, run: run, on: runner(for: current))
    }

    private func runner(for hook: Hook) -> any HookScriptRunning {
        hook.script.isShell ? shell : javaScript
    }

    /// Runs the script, canceling it in its runner when the step's task is canceled, as at a timeout, a newer event, or a close.
    private func perform(_ invocation: HookInvocation, run: HookRun, on runner: any HookScriptRunning) async -> HookRunOutcome {
        run.runner = runner
        activeRuns[run.id] = run
        defer { activeRuns[run.id] = nil }
        return await withTaskCancellationHandler {
            await runner.run(invocation)
        } onCancel: {
            Task { @MainActor in run.cancelScript() }
        }
    }

    /// The run's invocation, or nil when the event no longer reaches the hook in its script view.
    private func invocation(for hook: Hook, run: HookRun, script: Data, deadline: ContinuousClock.Instant, applying: Bool,
                            requestDidEnd: @escaping @MainActor @Sendable ((any Error)?) -> Void) -> HookInvocation? {
        let event = run.event
        let settings = ai.settings
        let access = BrowserEventScriptAccess.hook(tabs: hook.grant.permissions.contains(.tabs), allowsAI: hook.usesAgent ? { settings.allowsAI(on: $0) } : nil)
        guard let view = event.view(access) else { return nil }
        // A close's own tab is gone, and a test treats it as closed.
        let closedID = event.kind == .tabClosed ? event.subject : nil
        let covered = host.tabs(inPersona: event.personaID).filter { $0.id != closedID && Self.covers(hook.filter, $0) }
        var tabs = covered.map(\.id)
        var eventTab: UUID?
        switch event.payload {
        case .downloadFinished(let download): eventTab = download.tabID
        case .tabClosed, .spaceSwitched: eventTab = nil
        default: eventTab = event.tab?.id
        }
        if case .outsideClient = hook.origin { tabs = tabs.filter { $0 == eventTab } }
        let runTabs = Set(tabs)
        if let id = eventTab, !runTabs.contains(id) { eventTab = nil }
        var documents: [UUID: URL] = [:]
        for tab in covered where runTabs.contains(tab.id) { documents[tab.id] = tab.url }
        if let id = eventTab, let document = Self.document(of: event) { documents[id] = document }
        let chain = Array(((event.cause?.hookChain ?? []) + [hook.id]).suffix(Self.maximumHookChain))
        return HookInvocation(hook: hook, run: run.id, personaID: event.personaID, event: view, cause: BrowserEventCause(origin: .hookRun(hook: hook.id, run: run.id), hookChain: chain),
                              deadline: deadline, isTest: run.isTest, appliesActions: applying, script: script, tabs: runTabs, eventTab: eventTab, documents: documents,
                              closedTab: run.closedTab, knownProviders: Dictionary(knownProviders.map { ($0.id, $0.destination) }, uniquingKeysWith: { first, _ in first }),
                              requestDidEnd: requestDidEnd)
    }

    /// Whether the filter covers the tab: its places, sites, engines, and tab kinds, applied to the tab as to an event about it.
    static func covers(_ filter: BrowserEventFilter, _ tab: BrowserTabRef) -> Bool {
        var reach = filter
        reach.kinds = []
        return reach.matches(BrowserEvent(id: UUID(), sequence: 0, date: .distantPast, payload: .tabOpened(tab: tab, openerTabID: nil), cause: nil))
    }

    /// Logs the step's end and counts it toward the hook's failures. A run that never started is logged only when a limit stopped it, and a new document or a newer load keeps a `firstAfterOpen` hook's carry-over.
    private func runDidEnd(_ run: HookRun, _ outcome: AIHookStepOutcome) {
        var keepsCarryOver = false
        switch outcome {
        case .finished:
            if let result = run.outcome {
                record(result, of: run)
            } else if run.wasDropped {
                recordSkip(of: run, .dropped)
            } else if run.declined == .dailyLimit {
                recordSkip(of: run, .dailyLimit)
            }
        case .failed(let error):
            record(.failed(code: "error", message: error.localizedDescription), of: run)
        case .timedOut:
            // A run whose time passed while it waited for a slot never started, which is no failure of its script.
            if run.startedAt == nil { recordSkip(of: run, .dropped) } else { record(.timedOut, of: run) }
        case .stopped:
            if run.startedAt != nil { record(.cancelled, of: run) }
            keepsCarryOver = true
        case .skipped(let reason):
            switch reason {
            case .canceled:
                keepsCarryOver = true
            case .declinedByOwner:
                if run.declined == .dailyLimit { recordSkip(of: run, .dailyLimit) }
                keepsCarryOver = run.declined == .documentChanged
            case .budgetReached:
                recordSkip(of: run, .budget)
            case .unavailable:
                // As an empty tier: the hook's row shows the sentence, which no setting of the hook's own changes, so it counts toward no pause.
                record(.failed(code: "notConfigured", message: unavailableMessage(for: run)), of: run, countsAsFailure: false)
            case .paused, .excludedSite:
                break
            }
        }
        if !keepsCarryOver, let tab = run.event.tab { firstLoadCarryOvers[tab.id]?.remove(run.hookID) }
    }

    private func unavailableMessage(for run: HookRun) -> String {
        guard let hook = hook(withID: run.hookID) else { return "" }
        do {
            _ = try ai.resolvedModels(for: .agentHook(hook.id), route: hook.agent?.model)
            return "This hook's model is not available."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Test

    /// Runs the hook once for the tab as if its event had happened: the editor's Test and a row's Run on Current Tab. A tab the hook's filter does not cover, such as an agent tab, is not run. Without `applying`, actions are reported, not applied. A close hook treats the tab as closed without closing it, with the rest of the tabs it reaches as the run's tabs (`docs/hooks.md`, Closed tabs). A test runs at once, outside the scheduler, within the hook's timeout, and counts toward neither the daily count nor the failures; it is logged with `test` at the first two record levels.
    public func test(_ id: UUID, onTab tabID: UUID, applying: Bool) async -> HookRunResult {
        guard isReady, let hook = hook(withID: id), !store.isUnreadable(id) else { return .notRun("Arch cannot run this hook.") }
        guard !hook.script.isShell || allowsShellScripts else { return .notRun("Shell scripts are off.") }
        guard let script = store.script(for: hook) else {
            pauseHook(id, .scriptChanged)
            return .notRun("Its script changed outside Arch.")
        }
        return await test(hook, script: script, onTab: tabID, applying: applying)
    }

    /// Runs the editor's checked bytes in memory. A separate ID gives the draft its own AI scope while a saved hook remains active.
    public func testDraft(_ draft: Hook, script: Data, onTab tabID: UUID, applying: Bool) async -> HookRunResult {
        guard isReady, case .javaScript = draft.script, draft.usesAgent, draft.agent != nil else { return .notRun("Choose an agent model first.") }
        if case .outsideClient = draft.origin { return .notRun("This editor tests only your own hooks.") }
        var preview = draft
        if hook(withID: preview.id) != nil { preview.id = UUID() }
        guard draftOwner[preview.id] == nil else { return .notRun("This draft is already running a test.") }
        preview.script = preview.script.withDigest(HookStore.digest(of: script))
        do { preview = try Self.checked(preview) } catch { return .notRun(error.localizedDescription) }
        register(preview)
        draftOwner[preview.id] = draft.id
        defer {
            draftOwner[preview.id] = nil
            if let saved = hook(withID: preview.id) { register(saved) } else { ai.unregister(.agentHook(preview.id)) }
        }
        return await test(preview, script: script, onTab: tabID, applying: applying)
    }

    private func test(_ hook: Hook, script: Data, onTab tabID: UUID, applying: Bool) async -> HookRunResult {
        let id = hook.id
        guard let tab = host.tab(tabID) else { return .notRun("The tab is no longer open.") }
        // As for its events, a hook reaches only the tabs its filter covers, never an agent tab (hook decision 16).
        guard Self.covers(hook.filter, tab) else { return .notRun("This hook's filter does not cover this tab.") }
        guard let event = Self.testEvent(for: hook.trigger, tab: tab) else { return .notRun("A test on a tab cannot stand in for a finished download.") }
        let run = HookRun(hookID: id, event: event, closedTab: hook.trigger.kind == .tabClosed ? host.closingTab(tabID) : nil, isTest: true)
        let deadline = ContinuousClock.now + hook.timing.timeout
        guard var invocation = invocation(for: hook, run: run, script: script, deadline: deadline, applying: applying, requestDidEnd: { _ in }) else {
            return .notRun("This hook gets no events from this site, since the site is excluded from AI.")
        }
        if draftOwner[id] != nil, !store.hasFile {
            invocation.knownProviders = Dictionary(ai.settings.providers.map { ($0.id, HookKnownProvider($0).destination) }, uniquingKeysWith: { first, _ in first })
        }
        let runner = runner(for: hook)
        run.startedAt = .now
        run.runner = runner
        let watchdog = Task { @MainActor in
            try await Task.sleep(until: deadline, clock: .continuous)
            run.didTimeOut = true
            run.cancelScript()
        }
        let ended = await perform(invocation, run: run, on: runner)
        watchdog.cancel()
        let outcome = run.didTimeOut ? .timedOut : ended
        record(outcome, of: run)
        return .finished(outcome)
    }

    /// The event a test stands in for; nil for a download hook, which needs a download. A selection's and a space switch's window is a new identifier.
    static func testEvent(for trigger: HookTrigger, tab: BrowserTabRef) -> BrowserEvent? {
        let payload: BrowserEventPayload
        switch trigger {
        case .tabOpened: payload = .tabOpened(tab: tab, openerTabID: nil)
        case .tabClosed: payload = .tabClosed(tab: tab, reason: .user)
        case .pageLoaded: payload = .pageLoaded(tab: tab, isRestore: false, isFirstLoadAfterOpen: true)
        case .addressChanged: payload = .addressChanged(tab: tab, previousURL: nil)
        case .titleChanged: payload = .titleChanged(tab: tab, source: .page)
        case .tabSelected: payload = .tabSelected(tab: tab, windowID: UUID())
        case .downloadFinished: return nil
        case .spaceSwitched:
            guard let spaceID = tab.spaceID else { return nil }
            payload = .spaceSwitched(windowID: UUID(), spaceID: spaceID, personaID: tab.personaID, previousSpaceID: nil, previousPersonaID: nil)
        }
        return BrowserEvent(id: UUID(), sequence: 0, date: Date(), payload: payload, cause: nil)
    }

    // MARK: Records

    private func record(_ outcome: HookRunOutcome, of run: HookRun, countsAsFailure: Bool = true) {
        guard let hook = hook(withID: run.hookID) else { return }
        var entry = Self.entry(for: hook, event: run.event, outcome: .completed, date: now(), isTest: run.isTest)
        entry.duration = run.startedAt.map { (ContinuousClock.now - $0).hookSeconds }
        var message: String?
        var failed = false
        switch outcome {
        case .completed(let actions, let agent):
            entry.actions = actions.isEmpty ? nil : actions.reduce(into: [:]) { counts, action in counts[action.kind, default: 0] += 1 }
            if let agent, let model = agent.model {
                entry.agent = HookRunEntry.AgentUse(provider: model.provider, model: model.model, inputTokens: agent.usage.inputTokens, outputTokens: agent.usage.outputTokens)
            }
            if !run.isTest { failureCounts[hook.id] = nil }
        case .failed(let code, let text):
            entry.outcome = .failed
            entry.code = code
            message = String(text.prefix(200))
            failed = true
        case .timedOut:
            entry.outcome = .timedOut
            failed = true
        case .cancelled:
            entry.outcome = .cancelled
        }
        note(entry, message: message, of: hook)
        guard failed, !run.isTest else { return }
        dayCounts[hook.id] = dayCount(of: hook.id).adding(failures: 1)
        if entry.code == "unknownProvider" {
            pauseHook(hook.id, .unknownProvider, stopping: true)
            return
        }
        guard countsAsFailure else { return }
        let count = (failureCounts[hook.id] ?? 0) + 1
        failureCounts[hook.id] = count
        if count >= Self.failuresBeforePause { pauseHook(hook.id, .failures) }
    }

    private func recordSkip(of run: HookRun, _ reason: HookRunEntry.SkipReason) {
        guard let hook = hook(withID: run.hookID) else { return }
        recordSkip(of: hook, event: run.event, reason)
    }

    /// A skip is no run, so Keep Nothing keeps no trace of it. A hook past a limit logs one skip of it a minute, or a day for its daily count, since a page that reloads itself would otherwise log one at each load.
    private func recordSkip(of hook: Hook, event: BrowserEvent, _ reason: HookRunEntry.SkipReason) {
        guard hook.record != .none else { return }
        let date = now()
        switch reason {
        case .rateLimit, .budget:
            if let last = loggedSkips[hook.id]?[reason], date.timeIntervalSince(last) < BrowserEventRateLimiter.window { return }
        case .dailyLimit:
            if let last = loggedSkips[hook.id]?[reason], Calendar.current.isDate(last, inSameDayAs: date) { return }
        case .loop, .dropped:
            break
        }
        loggedSkips[hook.id, default: [:]][reason] = date
        var entry = Self.entry(for: hook, event: event, outcome: .skipped, date: date, isTest: false)
        entry.reason = reason
        note(entry, message: nil, of: hook)
    }

    /// Keep the Session and Keep Activity Only log the entry and keep it in the hook's last runs; Keep Nothing keeps the last run's time and outcome in memory only.
    private func note(_ entry: HookRunEntry, message: String?, of hook: Hook) {
        let summary = HookRunSummary(entry, message: message)
        if hook.record == .none {
            lastRuns[hook.id] = [summary.reduced]
            return
        }
        log.record(entry)
        lastRuns[hook.id] = Array(((lastRuns[hook.id] ?? []) + [summary]).suffix(Self.keptRunSummaries))
    }

    /// The entry's event, subject, site, and Persona; never a title, a name, a path, or a query.
    static func entry(for hook: Hook, event: BrowserEvent, outcome: HookRunEntry.Outcome, date: Date, isTest: Bool) -> HookRunEntry {
        HookRunEntry(date: date, hook: hook.id, event: event.kind, subject: HookRunEntry.subject(of: event), site: event.urls.first.flatMap(AgentActivityEntry.site(of:)),
                     persona: event.personaID, outcome: outcome, test: isTest)
    }

    /// The last runs that the run log holds for hooks at the first two record levels.
    private static func summaries(of entries: [HookRunEntry], for hooks: [Hook]) -> [UUID: [HookRunSummary]] {
        let logged = Set(hooks.filter { $0.record != .none }.map(\.id))
        var summaries: [UUID: [HookRunSummary]] = [:]
        for entry in entries where logged.contains(entry.hook) {
            summaries[entry.hook, default: []].append(HookRunSummary(entry, message: nil))
        }
        return summaries.mapValues { Array($0.suffix(keptRunSummaries)) }
    }

    private func dayCount(of id: UUID) -> HookDayCount {
        let today = Calendar.current.startOfDay(for: now())
        guard let count = dayCounts[id], count.day == today else { return HookDayCount(day: today, runs: 0, failures: 0) }
        return count
    }

    private func countRun(of id: UUID) {
        dayCounts[id] = dayCount(of: id).adding(runs: 1)
    }
}

extension HookDayCount {
    func adding(runs: Int = 0, failures: Int = 0) -> HookDayCount {
        HookDayCount(day: day, runs: self.runs + runs, failures: self.failures + failures)
    }
}

// MARK: - Runs

/// One match of a hook to an event, from its step's post to its end.
@MainActor
final class HookRun {
    /// Why the registry's own checks declined the run after its delay.
    enum Decline {
        case inactive, dailyLimit, subjectGone, documentChanged, excludedSite
    }

    let id = UUID()
    let hookID: UUID
    let event: BrowserEvent
    let closedTab: AgentRunClosedTab?
    let isTest: Bool
    var declined: Decline?
    /// The run waited for a slot among more than the registry keeps waiting.
    var wasDropped = false
    /// When its script started, after its slot.
    var startedAt: ContinuousClock.Instant?
    var outcome: HookRunOutcome?
    var runner: (any HookScriptRunning)?
    var didTimeOut = false

    init(hookID: UUID, event: BrowserEvent, closedTab: AgentRunClosedTab?, isTest: Bool) {
        self.hookID = hookID
        self.event = event
        self.closedTab = closedTab
        self.isTest = isTest
    }

    func cancelScript() {
        runner?.cancel(run: id)
        runner = nil
    }
}

// MARK: - Limits

/// The registry's concurrency (`docs/hooks.md`, Running, step 5): at most `total` runs at once and `perHook` for one hook. Waiting runs start in arrival order as slots free, a run blocked by its hook's cap letting later ones pass; beyond `waiting` waiting runs, the oldest is dropped.
@MainActor
final class HookRunSlots {
    struct Dropped: Error {}

    private struct Waiter {
        let run: UUID
        let hook: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    let total: Int
    let perHook: Int
    let waiting: Int
    /// Each running run's hook.
    private var running: [UUID: UUID] = [:]
    private var waiters: [Waiter] = []

    init(total: Int, perHook: Int, waiting: Int) {
        self.total = total
        self.perHook = perHook
        self.waiting = waiting
    }

    var runningCount: Int { running.count }
    var waitingCount: Int { waiters.count }

    /// Returns once the run holds a slot, which `release(run:)` frees. Throws `Dropped` when the run is dropped from the wait, or `CancellationError` when its task is canceled while it waits.
    func acquire(run: UUID, hook: UUID) async throws {
        try Task.checkCancellation()
        // Every release grants the waiting runs it can, so no waiting run could take a slot this one can.
        if canStart(hook) {
            running[run] = hook
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(run: run, hook: hook, continuation: continuation))
                if waiters.count > waiting { waiters.removeFirst().continuation.resume(throwing: Dropped()) }
            }
        } onCancel: {
            Task { @MainActor in self.withdraw(run) }
        }
    }

    func release(run: UUID) {
        guard running.removeValue(forKey: run) != nil else { return }
        var index = 0
        while index < waiters.count, running.count < total {
            if canStart(waiters[index].hook) {
                let waiter = waiters.remove(at: index)
                running[waiter.run] = waiter.hook
                waiter.continuation.resume()
            } else {
                index += 1
            }
        }
    }

    private func withdraw(_ run: UUID) {
        guard let index = waiters.firstIndex(where: { $0.run == run }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func canStart(_ hook: UUID) -> Bool {
        running.count < total && running.values.filter { $0 == hook }.count < perHook
    }
}
