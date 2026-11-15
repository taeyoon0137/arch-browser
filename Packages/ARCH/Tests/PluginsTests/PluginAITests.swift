// The `ai` permission and plugin hooks (`docs/plugins.md`, AI hooks and plugins that AI writes; `docs/hooks.md`, Plugins): a manifest's `ai`; the feature `plugin.<id>` that each enabled plugin with it registers, automatic when the plugin lists events and shared by the Personas that hold the plugin, also while only another Persona's version lists events; the context's AI under that feature and its route only; nothing of a tab, a page, or a command's click on a site excluded from AI for a plugin with `ai`; `arch.ai.reply` with the time it waits not counted toward the hang limit, which refused and failed calls do not stretch; and the events of a plugin with `ai` running one at a time as steps of the shared hook scheduler once the feature has a model of its own, not after a stop that came while the plugin started, with the step's requests ending when the scheduler stops it, as at a close or a route change, and later ones never going out, three provider errors pausing the plugin, and the step's renames bound to its event's document.
import AI
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Plugins

/// What the built-in test plugins saw and did.
@MainActor
private final class AIRecorder {
    static var shared = AIRecorder()
    /// The events that reached the hook plugin, and those that reached the plugin without `ai`.
    var hookEvents: [BrowserEventKind] = []
    var plainEvents: [BrowserEventKind] = []
    /// How many of the hook plugin's listeners run at once, and the most that ever did.
    var running = 0
    var mostRunning = 0
    /// How long the hook plugin's activation and each of its listeners take.
    var activation: Duration = .zero
    var pause: Duration = .zero
    /// Whether the hook plugin's listener waits for `release()` after its pause, sends a request, and renames its event's tab, and what came of it.
    var holds = false
    var asks = false
    var renames = false
    var replies: [String] = []
    var failures: [String] = []
    var renamed: [Bool] = []
    /// The invocations that reached the tab plugins' commands, by plugin.
    var invocations: [PluginID: [PluginInvocation]] = [:]
    var contexts: [any PluginContext] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        await withCheckedContinuation { held.append($0) }
    }

    var isHolding: Bool { !held.isEmpty }

    func release() {
        held.forEach { $0.resume() }
        held = []
    }
}

/// Asks for `ai` and `tabs.rename` and listens for page loads, so its listeners run as hooks.
@MainActor
private final class AIHookPlugin: BuiltInPlugin {
    static let id = PluginID(rawValue: "org.example.ai-hook")!
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "AI Hook", version: "1", summary: "", permissions: [.ai, .renameTabs], contributions: PluginContributions(), events: [.pageLoaded])
    }

    static var isOnByDefault: Bool { true }

    private var context: (any PluginContext)?

    init() {}

    func activate(in context: any PluginContext) async throws {
        self.context = context
        AIRecorder.shared.contexts.append(context)
        try await Task.sleep(for: AIRecorder.shared.activation)
    }

    func run(_ command: String, _ invocation: PluginInvocation) async throws {}

    func handle(_ event: PluginEvent) async throws {
        let recorder = AIRecorder.shared
        recorder.hookEvents.append(event.kind)
        recorder.running += 1
        recorder.mostRunning = max(recorder.mostRunning, recorder.running)
        defer { recorder.running -= 1 }
        try await Task.sleep(for: recorder.pause)
        if recorder.holds { await recorder.hold() }
        guard let context else { return }
        if recorder.asks {
            do {
                recorder.replies.append(try await context.ai().reply(AIRequest(feature: .pageReader, messages: [AIMessage(role: .user, parts: [.text("Name it")])])).text)
            } catch {
                recorder.failures.append("\(error)")
            }
        }
        if recorder.renames, case let .browser(view, _) = event, let tab = view.tab?.id {
            recorder.renamed.append(try context.renameTab(tab, to: "Named"))
        }
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

/// Answers each page script value with the value, on every website; `PageAIPlugin` also asks for `ai`.
@MainActor
private class PagePlugin: BuiltInPlugin {
    class var id: PluginID { PluginID(rawValue: "org.example.page")! }
    class var permissions: Set<PluginPermission> { [] }
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "Page", version: "1", summary: "", permissions: permissions, sites: [try! MatchPattern("http://*/*"), try! MatchPattern("https://*/*")],
                       contributions: PluginContributions())
    }

    static var isOnByDefault: Bool { true }

    required init() {}

    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}

    func receive(_ message: PluginPageMessage) async throws -> PluginValue? {
        message.body
    }
}

@MainActor
private final class PageAIPlugin: PagePlugin {
    override class var id: PluginID { PluginID(rawValue: "org.example.page-ai")! }
    override class var permissions: Set<PluginPermission> { [.ai] }
}

/// Reads tabs and records its command's invocations; `TabsAIPlugin` also asks for `ai`.
@MainActor
private class TabsPlugin: BuiltInPlugin {
    class var id: PluginID { PluginID(rawValue: "org.example.tabs")! }
    class var permissions: Set<PluginPermission> { [.tabs] }
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "Tabs", version: "1", summary: "", permissions: permissions, contributions: PluginContributions(commands: [PluginCommand(id: "look", title: "Look")]))
    }

    static var isOnByDefault: Bool { true }

    required init() {}

    func activate(in context: any PluginContext) async throws {
        AIRecorder.shared.contexts.append(context)
    }

    func run(_ command: String, _ invocation: PluginInvocation) async throws {
        AIRecorder.shared.invocations[Self.id, default: []].append(invocation)
    }
}

@MainActor
private final class TabsAIPlugin: TabsPlugin {
    override class var id: PluginID { PluginID(rawValue: "org.example.tabs-ai")! }
    override class var permissions: Set<PluginPermission> { [.tabs, .ai] }
}

/// The Persona's tabs, which the tests set, and the renames that reached them, each with the document it was for.
@MainActor
private final class RecordingHost: PluginBrowserHost {
    var tabs: [PluginTab] = []
    var renames: [(tab: UUID, name: String?, document: URL?)] = []

    func tabs(in persona: PersonaID) -> [PluginTab] { tabs }

    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool {
        renames.append((id, name, document))
        return true
    }
}

@MainActor
@Suite(.serialized) struct PluginAITests {
    private let folder = TemporaryFolder()
    private let persona = UUID()
    private let bus = BrowserEventBus()
    private let host = RecordingHost()

    init() {
        AIRecorder.shared = AIRecorder()
    }

    /// A command-line tool that reads the request and answers after `seconds`, or fails at once with `failing`.
    private static func tool(_ name: String = "Tool", answeringAfter seconds: Double = 0, failing: Bool = false) -> AIProviderConfiguration {
        let script = failing ? "cat > /dev/null; echo 'Signed out' >&2; exit 1" : "cat > /dev/null; sleep \(seconds); printf 'Short answer'"
        return AIProviderConfiguration(name: name, kind: .commandLine(AICommandLineConfiguration(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                                                                                 environment: ["PATH": "/usr/bin:/bin"])),
                                       models: [AIModelConfiguration(name: "")], limits: .commandLine)
    }

    private static func model(of tool: AIProviderConfiguration) -> AIModelRef {
        AIModelRef(provider: tool.id, model: "")
    }

    private func service(answeringAfter seconds: Double? = nil, for features: [AIFeatureID] = []) -> AIService {
        let service = AIService(directory: folder.url.appendingPathComponent("AI", isDirectory: true))
        if let seconds {
            let tool = Self.tool(answeringAfter: seconds)
            service.settings.providers = [tool]
            for feature in features {
                service.settings.setRoute(AIRoute(isEnabled: true, models: [Self.model(of: tool)]), for: feature)
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

    private func pluginTab(_ address: String, title: String, id: UUID = UUID()) -> PluginTab {
        PluginTab(id: id, spaceID: nil, title: title, url: URL(string: address)!, engine: .webKit, isPinned: false, isSelected: true)
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

    @Test func theContextSendsUnderThePluginsOwnFeatureAndRouteOnlyWithTheGrant() async throws {
        let service = service()
        service.register(AIFeature(id: .pageReader, name: "Page Reader", summary: "", trigger: .user, data: AIDataScope(kinds: [.page])))
        let manager = manager(builtIns: [AskingPlugin.self], ai: service)
        defer { manager.close() }
        let installed = try #require(manager.plugins.first)
        let id = AIFeatureID.plugin(AskingPlugin.id.rawValue)
        let feature = try #require(service.features.first { $0.id == id })
        #expect(feature.trigger == .user && feature.data.kinds.isEmpty && feature.name == "Asking")

        // Whatever feature a request names, it goes out under the plugin's feature, which has no model yet.
        let context = manager.makeContext(for: installed)
        let client = try context.ai()
        await #expect(throws: AIError.self) { _ = try await client.reply(request) }
        #expect(service.activity.last?.feature == id)

        // Whatever route or model it names, it goes out on the feature's route.
        let routed = Self.tool("Routed")
        let named = Self.tool("Named")
        service.settings.providers = [named, routed]
        service.settings.setRoute(AIRoute(isEnabled: true, models: [Self.model(of: routed)]), for: id)
        var elsewhere = request
        elsewhere.pinnedModel = Self.model(of: named)
        elsewhere.route = .models([Self.model(of: named)])
        #expect(try await client.reply(elsewhere).text == "Short answer")
        #expect(service.activity.last?.feature == id && service.activity.last?.model == Self.model(of: routed))

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

    /// One Persona's version of a plugin lists events and another's does not: the shared feature is automatic while the version with events is enabled.
    @Test func theSharedFeatureIsAutomaticWhileOneVersionRunsHooks() async throws {
        let service = service()
        let id = AIFeatureID.plugin("org.example.shared")
        func install(_ events: String, in manager: PluginManager) async throws {
            let manifest = #"{"id": "org.example.shared", "name": "Shared", "version": "1", "apiVersion": 1, "summary": "Asks.", "permissions": ["ai"]\#(events)}"#
            let package = try await manager.stage(try writePackage(events.isEmpty ? ["plugin.json": manifest] : ["plugin.json": manifest, "b.js": ""]))
            try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        }
        let hooks = manager(ai: service)
        let asks = manager(persona: UUID(), ai: service)
        defer {
            hooks.close()
            asks.close()
        }
        try await install(#", "events": ["pageLoaded"], "background": "b.js""#, in: hooks)
        try await install("", in: asks)
        #expect(service.features.first { $0.id == id }?.trigger == .automatic)
        hooks.setEnabled(false, for: try #require(PluginID(rawValue: "org.example.shared")))
        #expect(service.features.first { $0.id == id }?.trigger == .user)
        hooks.setEnabled(true, for: try #require(PluginID(rawValue: "org.example.shared")))
        asks.setEnabled(false, for: try #require(PluginID(rawValue: "org.example.shared")))
        #expect(service.features.first { $0.id == id }?.trigger == .automatic)
    }

    /// A page script could read a page that AI may not see, and the plugin send it to a model as text.
    @Test func aPluginWithAIGetsNoPageValuesFromSitesExcludedFromAI() async throws {
        let manager = manager(builtIns: [PageAIPlugin.self, PagePlugin.self], ai: service())
        defer { manager.close() }
        func send(to id: PluginID, from frame: String, in page: String? = nil) async -> String? {
            let url = URL(string: frame)!
            return await manager.receive(EnginePageScriptMessage(world: id.pageScriptWorld, frameURL: url, isMainFrame: page == nil, json: #""text""#),
                                         from: pluginTab(page ?? frame, title: "Page"))
        }
        #expect(await send(to: PageAIPlugin.id, from: "https://example.org/") == #""text""#)
        // New settings exclude the local network, for the frame or for the tab's page.
        #expect(await send(to: PageAIPlugin.id, from: "http://localhost:8080/") == nil)
        #expect(await send(to: PageAIPlugin.id, from: "https://example.org/", in: "http://localhost:8080/") == nil)
        // A plugin without `ai` reaches no model, so it gets the values.
        #expect(await send(to: PagePlugin.id, from: "http://localhost:8080/") == #""text""#)
        #expect(await send(to: PagePlugin.id, from: "https://example.org/", in: "http://localhost:8080/") == #""text""#)
    }

    /// A plugin with `ai` could send a tab's title and address, or what the user clicked on, to a model as text.
    @Test func aPluginWithAISeesNothingOfTabsAndClicksOnSitesExcludedFromAI() async throws {
        let open = pluginTab("https://example.org/a", title: "Open")
        let local = pluginTab("http://localhost:8080/", title: "Local")
        // A tab that leaves a page shows the next address before that document commits, with the page's title.
        var leaving = pluginTab("https://example.org/c", title: "Local")
        leaving.documentURL = local.url
        host.tabs = [open, local, leaving]
        let manager = manager(builtIns: [TabsAIPlugin.self, TabsPlugin.self], ai: service())
        defer { manager.close() }
        let withAI = manager.makeContext(for: try #require(manager.plugins.first { $0.id == TabsAIPlugin.id }))
        let withoutAI = manager.makeContext(for: try #require(manager.plugins.first { $0.id == TabsPlugin.id }))
        #expect(try withAI.tabs().map(\.title) == ["Open", nil, nil] && withAI.tabs().map(\.url) == [open.url, nil, nil])
        #expect(try withAI.tab(local.id)?.title == nil && withAI.tab(open.id)?.title == "Open")
        #expect(try withoutAI.tabs().map(\.title) == ["Open", "Local", "Local"])

        let localLink = URL(string: "http://localhost:8080/admin")!
        let openLink = URL(string: "https://example.org/b")!
        for plugin in [TabsAIPlugin.id, TabsPlugin.id] {
            await manager.run(PluginCommandRef(plugin: plugin, command: "look"), PluginInvocation(tab: local, linkURL: openLink, imageURL: openLink, selection: "Secret"))
            await manager.run(PluginCommandRef(plugin: plugin, command: "look"), PluginInvocation(tab: open, linkURL: localLink, imageURL: openLink, selection: "Text"))
        }
        let excluded = try #require(AIRecorder.shared.invocations[TabsAIPlugin.id]?.first)
        #expect(excluded.tab?.title == nil && excluded.tab?.url == nil && excluded.linkURL == nil && excluded.imageURL == nil && excluded.selection == nil)
        let allowed = try #require(AIRecorder.shared.invocations[TabsAIPlugin.id]?.last)
        #expect(allowed.tab?.title == "Open" && allowed.linkURL == nil && allowed.imageURL == openLink && allowed.selection == "Text")
        let plain = try #require(AIRecorder.shared.invocations[TabsPlugin.id])
        #expect(plain.map(\.tab?.title) == ["Local", "Open"] && plain.map(\.linkURL) == [openLink, localLink] && plain.first?.selection == "Secret")
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

        let tool = Self.tool()
        service.settings.providers = [tool]
        service.settings.setRoute(AIRoute(isEnabled: true, models: [Self.model(of: tool)]), for: .plugin(AIHookPlugin.id.rawValue))
        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: false))
        #expect(await eventually { AIRecorder.shared.hookEvents == [.pageLoaded] })

        // Another tab's chain runs at the same time, but the plugin's steps wait for each other.
        AIRecorder.shared.pause = .milliseconds(200)
        bus.post(.pageLoaded(tab: tab("/a"), isRestore: false, isFirstLoadAfterOpen: true))
        bus.post(.pageLoaded(tab: tab("/b"), isRestore: false, isFirstLoadAfterOpen: true))
        #expect(await eventually { AIRecorder.shared.hookEvents.count == 3 && AIRecorder.shared.running == 0 })
        #expect(AIRecorder.shared.mostRunning == 1)
    }

    /// The scheduler stops the step while the plugin activates, so the event never reaches it.
    @Test func aStepStoppedWhileThePluginStartsDeliversNothing() async throws {
        let feature = AIFeatureID.plugin(AIHookPlugin.id.rawValue)
        let service = service(answeringAfter: 0, for: [feature])
        AIRecorder.shared.activation = .milliseconds(600)
        let manager = manager(builtIns: [AIHookPlugin.self], ai: service)
        defer { manager.close() }
        let page = tab()
        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: true))
        #expect(await eventually { !AIRecorder.shared.contexts.isEmpty })
        service.hooks.scheduler.cancel(subject: page.id)
        try await Task.sleep(for: .seconds(1))
        #expect(AIRecorder.shared.hookEvents.isEmpty)
        bus.post(.pageLoaded(tab: tab("/next"), isRestore: false, isFirstLoadAfterOpen: true))
        #expect(await eventually { AIRecorder.shared.hookEvents == [.pageLoaded] })
    }

    /// A step's rename is for its event's document, and a stopped step renames nothing.
    @Test func aStepsRenamesAreForItsEventsDocumentUntilItStops() async throws {
        let feature = AIFeatureID.plugin(AIHookPlugin.id.rawValue)
        let service = service(answeringAfter: 0, for: [feature])
        AIRecorder.shared.renames = true
        let manager = manager(builtIns: [AIHookPlugin.self], ai: service)
        defer { manager.close() }
        let page = tab("/page")
        host.tabs = [pluginTab("https://example.org/next", title: "Next", id: page.id)]
        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: true))
        #expect(await eventually { AIRecorder.shared.renamed == [true] })
        #expect(host.renames.map(\.document) == [page.url])
        // Outside a step, a rename is for the document the tab shows.
        let context = try #require(AIRecorder.shared.contexts.first)
        #expect(try context.renameTab(page.id, to: "Later"))
        #expect(host.renames.count == 2 && host.renames.last?.document == nil)

        AIRecorder.shared.holds = true
        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: false))
        #expect(await eventually { AIRecorder.shared.isHolding })
        service.hooks.scheduler.cancel(subject: page.id)
        try await Task.sleep(for: .milliseconds(100))
        AIRecorder.shared.release()
        #expect(await eventually { AIRecorder.shared.renamed == [true, false] })
        #expect(host.renames.count == 2)
    }

    /// Consecutive provider errors of a plugin's hook requests pause the plugin's hooks.
    @Test func threeProviderErrorsInARowPauseThePluginsHooks() async throws {
        let feature = AIFeatureID.plugin(AIHookPlugin.id.rawValue)
        let service = service()
        let failing = Self.tool(failing: true)
        service.settings.providers = [failing]
        service.settings.setRoute(AIRoute(isEnabled: true, models: [Self.model(of: failing)]), for: feature)
        AIRecorder.shared.asks = true
        let manager = manager(builtIns: [AIHookPlugin.self], ai: service)
        defer { manager.close() }
        for path in ["/a", "/b", "/c"] {
            bus.post(.pageLoaded(tab: tab(path), isRestore: false, isFirstLoadAfterOpen: true))
        }
        #expect(await eventually { AIRecorder.shared.failures.count == 3 })
        #expect(service.hooks.scheduler.pausedOwners == [feature.rawValue])
        bus.post(.pageLoaded(tab: tab("/d"), isRestore: false, isFirstLoadAfterOpen: true))
        try await Task.sleep(for: .milliseconds(300))
        #expect(AIRecorder.shared.hookEvents.count == 3)
    }

    @Test func aScriptPluginsReplyWaitsBeyondTheHangLimitAndAStoppedStepsRequestsEnd() async throws {
        let manifest = #"{"id": "org.example.ai-script", "name": "AI Script", "version": "1", "apiVersion": 1, "summary": "Asks.", "permissions": ["ai"], "events": ["pageLoaded"], "background": "b.js", "contributes": {"commands": [{"id": "ask", "title": "Ask"}]}}"#
        let background = """
        const ask = () => arch.ai.reply({ instructions: "Be brief.", messages: [{ role: "user", text: "Hi" }], maxOutputTokens: 20 });
        arch.commands.onRun("ask", async () => {
          try {
            await arch.storage.set("result", await ask());
          } catch (error) {
            await arch.storage.set("result", error.message);
          }
        });
        arch.events.on("pageLoaded", async () => {
          try {
            await arch.storage.set("result", await ask());
          } catch (error) {
            await arch.storage.set("result", error.message);
            // A stopped step's later request never goes out.
            try {
              await arch.storage.set("again", await ask());
            } catch (error) {
              await arch.storage.set("again", error.message);
            }
          }
        });
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

        // A tab that closes while its hook step waits for a reply stops the step's request, and the step's next request ends at once.
        service.settings.providers = [Self.tool(answeringAfter: 8)]
        let tool = try #require(service.settings.providers.first)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [Self.model(of: tool)]), for: feature)
        try storage.setValue(nil, forKey: "result")
        let page = tab()
        let started = ContinuousClock.now
        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: true))
        try await Task.sleep(for: .seconds(1))
        service.hooks.scheduler.cancel(subject: page.id)
        #expect(await eventually { storage.value(forKey: "again") == .string("cancelled") })
        #expect(storage.value(forKey: "result") == .string("cancelled"))
        #expect(ContinuousClock.now - started < .seconds(4))

        // A change to the plugin's route stops its running step's request.
        try storage.setValue(nil, forKey: "result")
        try storage.setValue(nil, forKey: "again")
        bus.post(.pageLoaded(tab: tab("/other"), isRestore: false, isFirstLoadAfterOpen: true))
        try await Task.sleep(for: .seconds(1))
        service.settings.setRoute(AIRoute(isEnabled: true, models: [Self.model(of: tool), AIModelRef(provider: tool.id, model: "other")]), for: feature)
        #expect(await eventually { storage.value(forKey: "again") == .string("cancelled") })
        #expect(storage.value(forKey: "result") == .string("cancelled"))

        // Without the grant, the call is refused.
        try storage.setValue(nil, forKey: "result")
        manager.setEnabled(false, for: installed.id)
        let refused = try await manager.stage(try writePackage(["plugin.json": manifest.replacingOccurrences(of: #""permissions": ["ai"], "#, with: ""), "b.js": background]))
        try manager.install(refused, grant: PluginGrant(requestedBy: refused.manifest), isEnabled: true)
        await manager.run(PluginCommandRef(plugin: installed.id, command: "ask"), PluginInvocation(tab: nil))
        #expect(manager.makeContext(for: try #require(manager.plugins.first)).storage.value(forKey: "result") == .string("permissionDenied"))
    }

    /// Calls that the bridge refuses or that fail at once take no time of Arch's, so a script that makes them while it leaves a call unanswered still hangs.
    @Test func refusedAndFailedAIRequestsDoNotStretchTheHangLimit() async throws {
        let manifest = #"{"id": "org.example.ai-hang", "name": "AI Hang", "version": "1", "apiVersion": 1, "summary": "Hangs.", "permissions": ["ai"], "background": "b.js", "contributes": {"commands": [{"id": "hang", "title": "Hang"}]}}"#
        let background = """
        // A promise that nothing can settle any more fails at once, so the script keeps its resolver.
        let settle;
        arch.commands.onRun("hang", () => {
          (async () => {
            for (;;) {
              await arch.ai.reply({}).catch(() => {});
              await arch.ai.reply({ messages: [{ role: "user", text: "Hi" }] }).catch(() => {});
            }
          })();
          return new Promise((resolve) => { settle = resolve; });
        });
        """
        // Without a provider, every request fails at once.
        let manager = manager(ai: service(), hang: 1)
        defer { manager.close() }
        let package = try await manager.stage(try writePackage(["plugin.json": manifest, "b.js": background]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let started = ContinuousClock.now
        await manager.run(PluginCommandRef(plugin: package.manifest.id, command: "hang"), PluginInvocation(tab: nil))
        #expect(ContinuousClock.now - started < .seconds(8))
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
