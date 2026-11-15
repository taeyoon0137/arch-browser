// The `ai` permission and plugin hooks (`docs/plugins.md`, AI hooks and plugins that AI writes; `docs/hooks.md`, Plugins): a manifest's `ai`, the feature `plugin.<id>` that each enabled plugin with it registers, automatic when the plugin lists events and shared by the Personas that hold the plugin, the context's AI under that feature only, `arch.ai.reply` with the time it waits not counted toward the hang limit, and the events of a plugin with `ai` running one at a time as steps of the shared hook scheduler, once the feature has a model of its own, with their requests stopping when the scheduler stops the step.
import AI
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Plugins

/// What the built-in test plugins saw.
@MainActor
private final class AIRecorder {
    static var shared = AIRecorder()
    /// The events that reached the hook plugin, and those that reached the plugin without `ai`.
    var hookEvents: [BrowserEventKind] = []
    var plainEvents: [BrowserEventKind] = []
    /// How many of the hook plugin's listeners run at once, and the most that ever did.
    var running = 0
    var mostRunning = 0
    /// How long each of the hook plugin's listeners takes.
    var pause: Duration = .zero
    var contexts: [any PluginContext] = []
}

/// Asks for `ai` and listens for page loads, so its listeners run as hooks.
@MainActor
private final class AIHookPlugin: BuiltInPlugin {
    static let id = PluginID(rawValue: "org.example.ai-hook")!
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "AI Hook", version: "1", summary: "", permissions: [.ai], contributions: PluginContributions(), events: [.pageLoaded])
    }

    static var isOnByDefault: Bool { true }

    init() {}

    func activate(in context: any PluginContext) async throws {
        AIRecorder.shared.contexts.append(context)
    }

    func run(_ command: String, _ invocation: PluginInvocation) async throws {}

    func handle(_ event: PluginEvent) async throws {
        let recorder = AIRecorder.shared
        recorder.hookEvents.append(event.kind)
        recorder.running += 1
        recorder.mostRunning = max(recorder.mostRunning, recorder.running)
        defer { recorder.running -= 1 }
        try await Task.sleep(for: recorder.pause)
    }
}

/// Asks for `ai` without events, so the user starts its requests.
@MainActor
private final class AskingPlugin: BuiltInPlugin {
    static let id = PluginID(rawValue: "org.example.asking")!
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "Asking", version: "1", summary: "", permissions: [.ai], contributions: PluginContributions())
    }

    static var isOnByDefault: Bool { true }

    init() {}

    func activate(in context: any PluginContext) async throws {
        AIRecorder.shared.contexts.append(context)
    }

    func run(_ command: String, _ invocation: PluginInvocation) async throws {}
}

/// Listens for page loads without `ai`, so its events arrive as they come.
@MainActor
private final class PlainEventsPlugin: BuiltInPlugin {
    static var manifest: PluginManifest {
        PluginManifest(id: PluginID(rawValue: "org.example.plain-events")!, name: "Plain Events", version: "1", summary: "", contributions: PluginContributions(), events: [.pageLoaded])
    }

    static var isOnByDefault: Bool { true }

    init() {}

    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}

    func handle(_ event: PluginEvent) async throws {
        AIRecorder.shared.plainEvents.append(event.kind)
    }
}

/// Asks for `ai` on every website and answers each page script value with the value.
@MainActor
private final class PageAIPlugin: BuiltInPlugin {
    static let id = PluginID(rawValue: "org.example.page-ai")!
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "Page AI", version: "1", summary: "", permissions: [.ai], sites: [try! MatchPattern("http://*/*"), try! MatchPattern("https://*/*")],
                       contributions: PluginContributions())
    }

    static var isOnByDefault: Bool { true }

    init() {}

    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}

    func receive(_ message: PluginPageMessage) async throws -> PluginValue? {
        message.body
    }
}

/// The tabs of the Persona, which the tests do not rename.
@MainActor
private final class NoTabsHost: PluginBrowserHost {
    func tabs(in persona: PersonaID) -> [PluginTab] { [] }
    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool { false }
}

@MainActor
@Suite(.serialized) struct PluginAITests {
    private let folder = TemporaryFolder()
    private let persona = UUID()
    private let bus = BrowserEventBus()
    private let host = NoTabsHost()

    init() {
        AIRecorder.shared = AIRecorder()
    }

    /// A command-line tool that reads the request and answers after `seconds`.
    private static func tool(answeringAfter seconds: Double) -> AIProviderConfiguration {
        AIProviderConfiguration(name: "Tool", kind: .commandLine(AICommandLineConfiguration(executable: URL(fileURLWithPath: "/bin/sh"),
                                                                                           arguments: ["-c", "cat > /dev/null; sleep \(seconds); printf 'Short answer'"],
                                                                                           environment: ["PATH": "/usr/bin:/bin"])),
                                models: [AIModelConfiguration(name: "")], limits: .commandLine)
    }

    private func service(answeringAfter seconds: Double? = nil, for features: [AIFeatureID] = []) -> AIService {
        let service = AIService(directory: folder.url.appendingPathComponent("AI", isDirectory: true))
        if let seconds {
            let tool = Self.tool(answeringAfter: seconds)
            service.settings.providers = [tool]
            for feature in features {
                service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: tool.id, model: "")]), for: feature)
            }
        }
        return service
    }

    private func manager(persona: PersonaID? = nil, builtIns: [any BuiltInPlugin.Type] = [], ai: AIService?, hang: TimeInterval = 10) -> PluginManager {
        PluginManager(persona: persona ?? self.persona, directory: folder.url, builtIns: builtIns, secretStore: MemorySecretStore(),
                      scriptLimits: ScriptPluginLimits(hang: hang, idle: 30), events: bus, browserHost: host, ai: ai)
    }

    private func writePackage(_ files: [String: String]) throws -> URL {
        let root = folder.url.appendingPathComponent("Packages/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    private func tab(_ path: String = "/") -> BrowserTabRef {
        BrowserTabRef(id: UUID(), personaID: persona, spaceID: UUID(), kind: .open, engine: .webKit, url: URL(string: "https://example.org\(path)"))
    }

    private let request = AIRequest(feature: .pageReader, messages: [AIMessage(role: .user, parts: [.text("Hi")])], pinnedModel: AIModelRef(provider: AIProviderID(), model: "other"))

    @Test func aManifestMayAskForAI() async throws {
        let manager = manager(ai: nil)
        let package = try await manager.stage(try writePackage([
            "plugin.json": #"{"id": "org.example.ai", "name": "AI", "version": "1", "apiVersion": 1, "summary": "Asks.", "permissions": ["ai"]}"#,
        ]))
        #expect(package.manifest.permissions == [.ai])
        #expect(PluginGrant(requestedBy: package.manifest).summaries == ["Send text to the AI models you connected"])
        #expect(PluginError.permissionDenied(.ai).localizedDescription == "The plugin may not send text to the AI models you connected.")
    }

    @Test func theContextSendsUnderThePluginsOwnFeatureOnlyWithTheGrant() async throws {
        let service = service()
        service.register(AIFeature(id: .pageReader, name: "Page Reader", summary: "", trigger: .user, data: AIDataScope(kinds: [.page])))
        let manager = manager(builtIns: [AskingPlugin.self], ai: service)
        defer { manager.close() }
        let installed = try #require(manager.plugins.first)
        let feature = try #require(service.features.first { $0.id == .plugin(AskingPlugin.id.rawValue) })
        #expect(feature.trigger == .user && feature.data.kinds.isEmpty && feature.name == "Asking")

        // Whatever feature, route, or model a request names, it goes out under the plugin's feature, which has no model yet.
        let context = manager.makeContext(for: installed)
        let client = try context.ai()
        await #expect(throws: AIError.self) { _ = try await client.reply(request) }
        #expect(service.activity.last?.feature == .plugin(AskingPlugin.id.rawValue))

        var withoutAI = installed
        withoutAI.grant.permissions = []
        #expect(throws: PluginError.permissionDenied(.ai)) { _ = try manager.makeContext(for: withoutAI).ai() }
        #expect(throws: PluginError.permissionDenied(.ai)) { _ = try self.manager(persona: UUID(), builtIns: [AskingPlugin.self], ai: nil).makeContext(for: installed).ai() }
        context.end()
        #expect(throws: PluginError.stopped) { _ = try context.ai() }
        await #expect(throws: PluginError.stopped) { _ = try await client.reply(request) }
    }

    @Test func eachPersonasPluginsShareTheFeatureWhichListedEventsMakeAutomatic() throws {
        let service = service()
        let id = AIFeatureID.plugin(AIHookPlugin.id.rawValue)
        let first = manager(builtIns: [AIHookPlugin.self, AskingPlugin.self], ai: service)
        let second = manager(persona: UUID(), builtIns: [AIHookPlugin.self], ai: service)
        #expect(service.features.first { $0.id == id }?.trigger == .automatic)
        #expect(service.features.contains { $0.id == .plugin(AskingPlugin.id.rawValue) })

        first.setEnabled(false, for: AIHookPlugin.id)
        #expect(service.features.contains { $0.id == id })
        second.setEnabled(false, for: AIHookPlugin.id)
        #expect(!service.features.contains { $0.id == id })
        first.setEnabled(true, for: AIHookPlugin.id)
        #expect(service.features.contains { $0.id == id })
        first.close()
        second.close()
        #expect(!service.features.contains { $0.id == id || $0.id == .plugin(AskingPlugin.id.rawValue) })
    }

    /// A page script could read a page that AI may not see, and the plugin send it to a model as text.
    @Test func aPluginWithAIGetsNoPageValuesFromSitesExcludedFromAI() async throws {
        let manager = manager(builtIns: [PageAIPlugin.self], ai: service())
        defer { manager.close() }
        func send(from address: String) async -> String? {
            let url = URL(string: address)!
            return await manager.receive(EnginePageScriptMessage(world: PageAIPlugin.id.pageScriptWorld, frameURL: url, isMainFrame: true, json: #""text""#),
                                         from: PluginTab(id: UUID(), spaceID: nil, title: "Page", url: url, engine: .webKit, isPinned: false, isSelected: true))
        }
        #expect(await send(from: "https://example.org/") == #""text""#)
        // New settings exclude the local network.
        #expect(await send(from: "http://localhost:8080/") == nil)
    }

    @Test func anAIPluginsEventsRunAsHooksOnceItsFeatureHasAModelOfItsOwn() async throws {
        let service = service()
        let manager = manager(builtIns: [AIHookPlugin.self, PlainEventsPlugin.self], ai: service)
        defer { manager.close() }
        let page = tab()
        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: true))
        // Without a model of its own the hook skips, while a plugin without `ai` gets the event as it arrives.
        #expect(await eventually { AIRecorder.shared.plainEvents == [.pageLoaded] })
        try await Task.sleep(for: .milliseconds(300))
        #expect(AIRecorder.shared.hookEvents.isEmpty)

        let tool = Self.tool(answeringAfter: 0)
        service.settings.providers = [tool]
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: tool.id, model: "")]), for: .plugin(AIHookPlugin.id.rawValue))
        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: false))
        #expect(await eventually { AIRecorder.shared.hookEvents == [.pageLoaded] })

        // Another tab's chain runs at the same time, but the plugin's steps wait for each other.
        AIRecorder.shared.pause = .milliseconds(200)
        bus.post(.pageLoaded(tab: tab("/a"), isRestore: false, isFirstLoadAfterOpen: true))
        bus.post(.pageLoaded(tab: tab("/b"), isRestore: false, isFirstLoadAfterOpen: true))
        #expect(await eventually { AIRecorder.shared.hookEvents.count == 3 && AIRecorder.shared.running == 0 })
        #expect(AIRecorder.shared.mostRunning == 1)
    }

    @Test func aScriptPluginsReplyWaitsBeyondTheHangLimitAndAHookStepsRequestStopsWithTheStep() async throws {
        let manifest = #"{"id": "org.example.ai-script", "name": "AI Script", "version": "1", "apiVersion": 1, "summary": "Asks.", "permissions": ["ai"], "events": ["pageLoaded"], "background": "b.js", "contributes": {"commands": [{"id": "ask", "title": "Ask"}]}}"#
        let background = """
        const ask = async () => {
          try {
            await arch.storage.set("result", await arch.ai.reply({ instructions: "Be brief.", messages: [{ role: "user", text: "Hi" }], maxOutputTokens: 20 }));
          } catch (error) {
            await arch.storage.set("result", error.message);
          }
        };
        arch.commands.onRun("ask", ask);
        arch.events.on("pageLoaded", ask);
        """
        let feature = AIFeatureID.plugin("org.example.ai-script")
        let service = service(answeringAfter: 3, for: [feature])
        let manager = manager(ai: service, hang: 1.5)
        defer { manager.close() }
        let package = try await manager.stage(try writePackage(["plugin.json": manifest, "b.js": background]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let installed = try #require(manager.plugins.first)
        let storage = manager.makeContext(for: installed).storage

        // The reply comes after the hang limit, which the wait for it does not count toward.
        await manager.run(PluginCommandRef(plugin: installed.id, command: "ask"), PluginInvocation(tab: nil))
        #expect(storage.value(forKey: "result") == .object(["text": .string("Short answer"), "finishReason": .string("completed")]))
        #expect(manager.plugins.first?.failure == nil && service.activity.last?.feature == feature)

        // A tab that closes while its hook step waits for a reply stops the step's request.
        service.settings.providers = [Self.tool(answeringAfter: 8)]
        let tool = try #require(service.settings.providers.first)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: tool.id, model: "")]), for: feature)
        try storage.setValue(nil, forKey: "result")
        let page = tab()
        let started = ContinuousClock.now
        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: true))
        try await Task.sleep(for: .seconds(1))
        service.hooks.scheduler.cancel(subject: page.id)
        #expect(await eventually { storage.value(forKey: "result") == .string("cancelled") })
        #expect(ContinuousClock.now - started < .seconds(6))

        // Without the grant, the call is refused.
        try storage.setValue(nil, forKey: "result")
        manager.setEnabled(false, for: installed.id)
        let refused = try await manager.stage(try writePackage(["plugin.json": manifest.replacingOccurrences(of: #""permissions": ["ai"], "#, with: ""), "b.js": background]))
        try manager.install(refused, grant: PluginGrant(requestedBy: refused.manifest), isEnabled: true)
        await manager.run(PluginCommandRef(plugin: installed.id, command: "ask"), PluginInvocation(tab: nil))
        #expect(manager.makeContext(for: try #require(manager.plugins.first)).storage.value(forKey: "result") == .string("permissionDenied"))
    }
}

/// Polls the main actor until the condition holds or ten seconds pass.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
