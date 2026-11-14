// What the hook registry's tests share: a seal key in memory, a browser host and a script runner the tests drive, and a registry in a temporary folder on a service of its own, whose provider no request reaches.
import Agent
import AI
import CryptoKit
import Events
import Foundation
import Testing
@testable import Hooks

/// A seal key and its generation in memory; `failure` makes it act as a Keychain that does not give the key.
final class MemoryKeys: AgentSealKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentSealKey?
    private var _failure: String?

    var failure: String? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    var generation: Int? { lock.withLock { stored?.generation } }

    /// Forgets the key, as when the Keychain item is deleted.
    func remove() {
        lock.withLock { stored = nil }
    }

    func key() async throws -> AgentSealKey? {
        try lock.withLock {
            if let failure = _failure { throw TestKeyError(message: failure) }
            return stored
        }
    }

    func keyCreatingIfNeeded() async throws -> AgentSealKey {
        try lock.withLock {
            if let failure = _failure { throw TestKeyError(message: failure) }
            if let stored { return stored }
            let key = AgentSealKey(key: SymmetricKey(size: .bits256))
            stored = key
            return key
        }
    }

    func record(_ key: AgentSealKey) async throws {
        lock.withLock { stored = key }
    }
}

struct TestKeyError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The session's side as the tests set it: Personas and spaces, open tabs with their shown names, and the closing tab while a close is delivered.
@MainActor
final class FakeHookHost: HookBrowserHost {
    var places: [HookPersonaPlaces]
    var openTabs: [BrowserTabRef] = []
    var names: [UUID: String] = [:]
    var placesDidChange: (() -> Void)?

    init(places: [HookPersonaPlaces]) {
        self.places = places
    }

    func tab(_ id: UUID) -> BrowserTabRef? {
        openTabs.first { $0.id == id }
    }

    func tabs(inPersona id: UUID) -> [BrowserTabRef] {
        openTabs.filter { $0.personaID == id && $0.kind != .agent }
    }

    func closingTab(_ id: UUID) -> AgentRunClosedTab? {
        tab(id).map { AgentRunClosedTab(name: names[$0.id] ?? "", url: $0.url) }
    }

    /// Replaces the open tab with the same identifier, or adds it.
    func show(_ tab: BrowserTabRef) {
        openTabs.removeAll { $0.id == tab.id }
        openTabs.append(tab)
    }

    func close(_ id: UUID) {
        openTabs.removeAll { $0.id == id }
    }
}

/// Runs no script: each hook's runs do what `behaviors` says, and a held run waits until it is released or canceled. It records every invocation and the most runs at once, in all and for each hook.
@MainActor
final class FakeScriptRunner: HookScriptRunning {
    enum Behavior {
        case complete([AgentRunAction])
        case fail(String)
        /// Waits until `release` or a cancel.
        case hold
        /// Reports these ends of AI requests to the scheduler, then completes.
        case requests([AIError?])
    }

    var behaviors: [UUID: Behavior] = [:]
    /// Called as each run starts.
    var onRun: ((HookInvocation) -> Void)?
    private(set) var invocations: [HookInvocation] = []
    private(set) var cancelled: [UUID] = []
    private(set) var mostRunning = 0
    private(set) var mostRunningPerHook: [UUID: Int] = [:]
    private var running: [UUID: UUID] = [:]
    private var held: [UUID: CheckedContinuation<HookRunOutcome, Never>] = [:]

    var heldCount: Int { held.count }

    func invocations(of hook: UUID) -> [HookInvocation] {
        invocations.filter { $0.hook.id == hook }
    }

    func run(_ invocation: HookInvocation) async -> HookRunOutcome {
        invocations.append(invocation)
        running[invocation.run] = invocation.hook.id
        mostRunning = max(mostRunning, running.count)
        mostRunningPerHook[invocation.hook.id] = max(mostRunningPerHook[invocation.hook.id] ?? 0, running.values.filter { $0 == invocation.hook.id }.count)
        onRun?(invocation)
        defer { running[invocation.run] = nil }
        switch behaviors[invocation.hook.id] ?? .complete([]) {
        case .complete(let actions):
            return .completed(actions: actions, agent: nil)
        case .fail(let message):
            return .failed(code: "scriptError", message: message)
        case .hold:
            return await withCheckedContinuation { held[invocation.run] = $0 }
        case .requests(let ends):
            ends.forEach { invocation.requestDidEnd($0) }
            return .completed(actions: [], agent: nil)
        }
    }

    func cancel(run: UUID) {
        cancelled.append(run)
        held.removeValue(forKey: run)?.resume(returning: .cancelled)
    }

    /// Ends every held run with `outcome`.
    func releaseAll(_ outcome: HookRunOutcome = .completed(actions: [], agent: nil)) {
        let waiting = held
        held = [:]
        waiting.values.forEach { $0.resume(returning: outcome) }
    }
}

enum HookIDs {
    static let persona = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let otherPersona = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let work = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static let home = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    static let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!
}

/// A registry over a store in a new folder, or another harness's folder and keys for a relaunch, the session's places, a bus, and a service with one provider whose Fast tier names its model.
@MainActor
final class RegistryHarness {
    let folder: URL
    let keys: MemoryKeys
    let bus = BrowserEventBus()
    let service: AIService
    let host = FakeHookHost(places: [
        HookPersonaPlaces(id: HookIDs.persona, name: "Personal", spaces: [HookSpace(id: HookIDs.work, name: "Work"), HookSpace(id: HookIDs.home, name: "Home")]),
        HookPersonaPlaces(id: HookIDs.otherPersona, name: "Other", spaces: [HookSpace(id: HookIDs.other, name: "Other")]),
    ])
    let javaScript = FakeScriptRunner()
    let shell = FakeScriptRunner()
    let provider: AIProviderConfiguration
    /// The registry's clock, which tests move forward.
    let clock = TestClock()
    private(set) var registry: HookRegistry!

    init(folder: URL? = nil, keys: MemoryKeys? = nil) {
        self.folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("ArchHooksTests-\(UUID().uuidString)", isDirectory: true)
        self.keys = keys ?? MemoryKeys()
        service = AIService(directory: self.folder)
        provider = AIProviderConfiguration(name: "Test", kind: .http(AIHTTPConfiguration(format: .chatCompletions, baseURL: URL(string: "https://models.example.test/v1")!)),
                                           models: [AIModelConfiguration(name: "model-a")])
        service.settings.providers = [provider]
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: provider.id, model: "model-a")]), for: .tier(.fast))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    var store: HookStore { HookStore(directory: folder, keys: keys) }

    /// Makes the registry and waits until it has read `hooks.json`.
    @discardableResult
    func start(version: Int = HookStore.currentVersion, migrations: [Int: HookStore.Migration] = HookStore.migrations) async throws -> HookRegistry {
        registry = HookRegistry(store: HookStore(directory: folder, keys: keys, version: version, migrations: migrations), bus: bus, ai: service, host: host,
                                javaScript: javaScript, shell: shell, now: { [clock] in clock.now })
        try #require(await eventually { self.registry.isReady || self.registry.notice != nil })
        return registry
    }

    /// Adds a hook with a script and returns it as the registry keeps it.
    @discardableResult
    func add(_ hook: Hook, script: String = "export default () => {}") throws -> Hook {
        try registry.add(hook, script: Data(script.utf8))
        return try #require(registry.hooks.first { $0.id == hook.id })
    }

    func tab(_ path: String = "/", id: UUID = UUID(), persona: UUID = HookIDs.persona, space: UUID? = HookIDs.work, kind: BrowserTabKind = .open,
             host name: String = "example.org") -> BrowserTabRef {
        BrowserTabRef(id: id, personaID: persona, spaceID: space, kind: kind, engine: .webKit, url: URL(string: "https://\(name)\(path)"))
    }

    /// Shows the tab, then posts its first page load.
    func load(_ tab: BrowserTabRef, first: Bool = true, restore: Bool = false, cause: BrowserEventCause? = nil) {
        host.show(tab)
        bus.post(.pageLoaded(tab: tab, isRestore: restore, isFirstLoadAfterOpen: first), cause: cause)
    }

    /// Posts the close while the host still lists the tab, as the session does, then removes it.
    func close(_ tab: BrowserTabRef, reason: BrowserTabCloseReason = .user) {
        bus.post(.tabClosed(tab: tab, reason: reason))
        host.close(tab.id)
    }

    /// The run log's entries for the hook.
    func entries(of hook: UUID) -> [HookRunEntry] {
        registry.log.entries.filter { $0.hook == hook }
    }
}

/// Names in the order something happened, for closures that record from the main actor.
@MainActor
final class OrderLog {
    var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}

/// The registry's date, which a test moves forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()

    var now: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

/// A hook that runs at once for `trigger`, logged at Keep Activity Only.
func instantHook(_ name: String, _ trigger: HookTrigger, filter: BrowserEventFilter = .everything, grant: HookGrant = HookGrant(), agent: AgentRunOptions? = nil,
                 record: AgentRunRecord = .activity, timeout: Duration = .seconds(30), runsPerDay: Int = 500) -> Hook {
    Hook(name: name, trigger: trigger, filter: filter, grant: grant, agent: agent, record: record, timing: HookTiming(delay: .zero, timeout: timeout, runsPerDay: runsPerDay))
}

/// Polls the main actor until the condition holds or five seconds pass.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
