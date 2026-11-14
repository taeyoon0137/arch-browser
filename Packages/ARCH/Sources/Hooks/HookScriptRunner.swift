// The JavaScript hook runner (`docs/hooks.md`, JavaScript scripts): runs a hook's `hook.js` in `Plugins`' script runtime, a `ScriptPlugin` in the plugin sandbox, from a package it makes in memory with the checked bytes, so the script that runs is the one whose digest the registry checked. The script sets its listener with `arch.events.on(kind, listener)` when it loads, and a run ends when the listener's promise settles. Each hook keeps at most two instances per Persona, each running one run at a time, which stop after 30 seconds without a run; the hook's timeout takes the place of the plugins' hang limit and ends the instance, as a cancel does.
import Agent
import AI
import Events
import Foundation
import Plugins

@MainActor
public final class HookScriptRunner: HookScriptRunning {
    /// The largest script the runner runs.
    public nonisolated static let maximumScriptSize = 256 * 1024
    /// The instances a hook keeps in one Persona.
    public static let instancesPerHook = 2

    public typealias AgentCall = @MainActor (AgentRunRequest, HookInvocation) async -> AgentRunResult
    private let runAgent: AgentCall?
    private let host: any PluginBrowserHost
    private let allowsAI: (URL) -> Bool
    private let idleLimit: TimeInterval
    /// The kept instances of each hook in each Persona.
    private var instances: [InstanceKey: [Instance]] = [:]
    /// The instance each run uses, from its start until it ends.
    private var running: [UUID: Instance] = [:]
    /// The digests of scripts that passed the check, which a script's next runs need not parse again.
    private var parsedDigests: Set<String> = []

    /// `host` reaches the tabs, and `allowsAI` is the AI interface's site check, which a hook with `agent` applies to the titles and addresses it lists. Tests give a shorter `idleLimit`.
    public init(host: any PluginBrowserHost, allowsAI: @escaping (URL) -> Bool, idleLimit: TimeInterval = 30, runAgent: AgentCall? = nil) {
        self.runAgent = runAgent
        self.host = host
        self.allowsAI = allowsAI
        self.idleLimit = idleLimit
    }

    /// Why the runner would not run `script`, as a sentence, or nil when it would: a classic script of at most 256 KB of UTF-8 text that parses, which JavaScriptCore checks without running any of it. The editor checks a script with it when the user saves one.
    public nonisolated static func problem(in script: Data) -> String? {
        guard script.count <= maximumScriptSize else { return "The script is larger than \(maximumScriptSize / 1024) KB." }
        guard let source = String(data: script, encoding: .utf8) else { return "The script is not UTF-8 text." }
        return ScriptPlugin.syntaxError(in: source).map { "The script does not parse: \($0)." }
    }

    public func run(_ invocation: HookInvocation) async -> HookRunOutcome {
        if !parsedDigests.contains(invocation.hook.script.digest) {
            if let problem = Self.problem(in: invocation.script) { return .failed(code: "invalidScript", message: problem) }
            parsedDigests.insert(invocation.hook.script.digest)
        }
        let instance = instance(for: invocation)
        running[invocation.run] = instance
        let watchdog = Task { [weak self] in
            try await Task.sleep(until: invocation.deadline, clock: .continuous)
            self?.end(run: invocation.run, as: .timedOut)
        }
        defer {
            watchdog.cancel()
            running[invocation.run] = nil
        }
        do {
            try await instance.activate()
        } catch {
            if let reason = instance.endReason { return reason.outcome }
            // The background document did not load; the instance is of no use.
            end(instance, as: .failed(error.localizedDescription))
            return .failed(code: "loadFailed", message: "The script did not load: \(error.localizedDescription)")
        }
        if let reason = instance.endReason { return reason.outcome }
        instance.context.begin(invocation)
        do {
            try await instance.plugin.handle(.browser(invocation.event, extra: ["hook": Self.hookValue(of: invocation.hook)]))
            let outcome = instance.context.finish()
            release(instance)
            return outcome
        } catch {
            let agentOutcome = instance.context.finish()
            // A call the script left unanswered past the hang limit, which backs up the watchdog.
            if case PluginError.timedOut = error {
                end(instance, as: .timedOut)
                return .timedOut
            }
            if let reason = instance.endReason { return reason.outcome }
            release(instance)
            if case .failed("unknownProvider", _) = agentOutcome { return agentOutcome }
            return Self.outcome(of: error, kind: invocation.event.kind)
        }
    }

    /// Ends the run's instance, which stops its script; the run ends `cancelled`.
    public func cancel(run: UUID) {
        end(run: run, as: .cancelled)
    }

    // MARK: Instances

    private struct InstanceKey: Hashable {
        let hook: UUID
        let persona: UUID
    }

    /// What an instance was made from; a hook whose script or settings changed gets new instances.
    private struct Configuration: Equatable {
        let digest: String
        let name: String
        let kind: BrowserEventKind
        let permissions: Set<HookPermission>
        let timeout: Duration

        init(_ hook: Hook) {
            digest = hook.script.digest
            name = hook.name
            kind = hook.trigger.kind
            permissions = hook.grant.permissions
            timeout = hook.timing.timeout
        }
    }

    /// An idle kept instance of the run's hook and Persona with its configuration, or a new one: kept while the hook has fewer than two, otherwise, for a test that comes while both run, one that ends with the run. Kept instances of an older configuration end, once their runs end for those that run. The instance is held until the run ends, so its idle stop cannot end it before the event reaches it.
    private func instance(for invocation: HookInvocation) -> Instance {
        let key = InstanceKey(hook: invocation.hook.id, persona: invocation.personaID)
        let configuration = Configuration(invocation.hook)
        for old in instances[key] ?? [] where old.configuration != configuration {
            old.isRetired = true
            if old.run == nil { end(old, as: nil) }
        }
        if let idle = instances[key]?.first(where: { $0.run == nil && !$0.isRetired }) {
            idle.run = invocation.run
            idle.plugin.isHeld = true
            return idle
        }
        let instance = makeInstance(for: invocation, key: key, configuration: configuration)
        instance.run = invocation.run
        instance.plugin.isHeld = true
        // An agent-capable script gets its own lifetime, so a delayed callback cannot spend the next invocation’s grant.
        if !invocation.hook.usesAgent, (instances[key]?.count ?? 0) < Self.instancesPerHook {
            instances[key, default: []].append(instance)
        } else {
            instance.isRetired = true
        }
        return instance
    }

    private func makeInstance(for invocation: HookInvocation, key: InstanceKey, configuration: Configuration) -> Instance {
        let hook = invocation.hook
        let id = HookScriptContext.pluginID(of: hook.id)
        let manifest = PluginManifest(id: id, name: hook.name, version: "1", summary: "The script of the hook \u{201C}\(hook.name)\u{201D}.",
                                      permissions: HookScriptContext.permissions(of: hook.grant), contributions: PluginContributions(), events: [hook.trigger.kind])
        let package = PluginPackage(manifest: manifest, background: "hook.js", source: invocation.script, rootURL: URL(string: "arch-plugin://\(id.rawValue)/")!)
        // The runner's watchdog ends a run at the hook's timeout; the hang limit only backs it up.
        let plugin = ScriptPlugin(package: package, limits: ScriptPluginLimits(hang: hook.timing.timeout.hookSeconds + 1, idle: idleLimit))
        let context = HookScriptContext(hook: hook, personaID: invocation.personaID, host: host, allowsAI: allowsAI, runAgent: runAgent)
        let instance = Instance(key: key, configuration: configuration, plugin: plugin, context: context)
        plugin.onStop = { [weak self, weak instance] reason in
            guard let self, let instance else { return }
            switch reason {
            case .idle: self.drop(instance)
            case .failed(let sentence): self.end(instance, as: .failed(sentence))
            }
        }
        return instance
    }

    /// A run that ended normally leaves its instance idle, where its idle stop counts again, or ends it when it was retired or kept for that run only.
    private func release(_ instance: Instance) {
        instance.run = nil
        instance.plugin.isHeld = false
        if instance.isRetired { end(instance, as: nil) }
    }

    private func end(run: UUID, as reason: Instance.EndReason) {
        guard let instance = running[run], instance.run == run else { return }
        end(instance, as: reason)
    }

    /// Stops the instance's script and drops it; its waiting calls throw, and its run, if any, ends for `reason`.
    private func end(_ instance: Instance, as reason: Instance.EndReason?) {
        if instance.endReason == nil { instance.endReason = reason ?? .retired }
        instance.context.end()
        drop(instance)
        Task { await instance.plugin.deactivate() }
    }

    private func drop(_ instance: Instance) {
        instances[instance.key]?.removeAll { $0 === instance }
        if instances[instance.key]?.isEmpty == true { instances[instance.key] = nil }
    }

    /// The instances kept for each hook, for the tests.
    var keptInstanceCount: Int { instances.values.reduce(0) { $0 + $1.count } }

    /// One instance of a hook's script in one Persona.
    @MainActor
    private final class Instance {
        enum EndReason {
            case cancelled, timedOut, retired
            case failed(String)

            var outcome: HookRunOutcome {
                switch self {
                case .cancelled, .retired: return .cancelled
                case .timedOut: return .timedOut
                case .failed(let sentence): return .failed(code: "stopped", message: sentence)
                }
            }
        }

        let key: InstanceKey
        let configuration: Configuration
        let plugin: ScriptPlugin
        let context: HookScriptContext
        /// The run it serves now.
        var run: UUID?
        /// It ends once its run ends: its hook changed, or it served one run only.
        var isRetired = false
        /// Why it ended, once it did.
        var endReason: EndReason?
        private var activation: Task<Void, any Error>?

        init(key: InstanceKey, configuration: Configuration, plugin: ScriptPlugin, context: HookScriptContext) {
            self.key = key
            self.configuration = configuration
            self.plugin = plugin
            self.context = context
        }

        /// Loads the background document once; later runs reuse it.
        func activate() async throws {
            if activation == nil {
                activation = Task { [plugin, context] in try await plugin.activate(in: context) }
            }
            try await activation?.value
        }
    }

    // MARK: Values

    /// `{id, name, agent}`: the agent run options of an agent hook's editor, or null.
    static func hookValue(of hook: Hook) -> PluginValue {
        let agent = hook.agent.flatMap { options in (try? JSONEncoder().encode(options)).flatMap { try? JSONDecoder().decode(PluginValue.self, from: $0) } }
        return .object(["id": .string(hook.id.uuidString), "name": .string(hook.name), "agent": agent ?? .null])
    }

    /// A failed run: a script that set no listener for the kind, a listener that threw or rejected, with what it threw, or another error of the delivery, with its description.
    static func outcome(of error: any Error, kind: BrowserEventKind) -> HookRunOutcome {
        switch error as? PluginError {
        case .noListener?: return .failed(code: "noListener", message: "The script set no listener for \(kind.rawValue) with arch.events.on.")
        case .listenerFailed(let message)?: return .failed(code: "scriptError", message: message)
        default: return .failed(code: "scriptError", message: error.localizedDescription)
        }
    }
}
