// The `ai` permission and plugin hooks (`docs/plugins.md`, AI hooks and plugins that AI writes; `docs/hooks.md`, Plugins): a manifest's `ai`; the feature `plugin.<id>` that each enabled plugin with it registers, automatic when the plugin lists events and shared by the Personas that hold the plugin, also while only another Persona's version lists events; the context's AI under that feature and its route only; nothing of a tab, a page, or a command's click on a site excluded from AI for a plugin with `ai`; `arch.ai.reply` with the time it waits not counted toward the hang limit, which refused and failed calls do not stretch; `arch.ai.stream` handing on the reply's text as it arrives, stopped when its listener throws, and ending as `AIClient.reply(_:)` does; a panel's requests, renames, closes, selections, and moves outside the plugin's hook steps, and its requests stopped when it closes; and the events of a plugin with `ai` running one at a time as steps of the shared hook scheduler once the feature has a model of its own, not after a stop that came while the plugin started, with the step's requests ending when the scheduler stops it, as at a close or a route change, and later ones never going out, three provider errors pausing the plugin, and the step's renames bound to its event's document and its closes, selections, and moves of its event's tab refused once it stops; and the setting changes of such a plugin reaching it outside the scheduler, also before its feature has a model.
import AI
import ARCHEngine
import Events
import Foundation
import Testing
import WebKit
@testable import Plugins

/// What the built-in test plugins saw and did.
@MainActor
private final class AIRecorder {
    static var shared = AIRecorder()
    /// The kinds of the events that reached the hook plugin, and of those that reached the plugin without `ai`.
    var hookEvents: [BrowserEventKind?] = []
    var plainEvents: [BrowserEventKind?] = []
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

/// Asks for `ai` and `tabs.rename` and listens for page loads, so its listeners run as hooks, and for its setting changes, which do not.
@MainActor
private final class AIHookPlugin: BuiltInPlugin {
    static let id = PluginID(rawValue: "org.example.ai-hook")!
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "AI Hook", version: "1", summary: "", permissions: [.ai, .renameTabs],
                       contributions: PluginContributions(settings: [PluginSetting(key: "tone", title: "Tone", kind: .text(default: ""))]),
                       events: [.pageLoaded], receivesSettingChanges: true)
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

/// The Persona's tabs, which the tests set, and the renames that reached them, each with the document it was for, and the closes and selections.
@MainActor
private final class RecordingHost: PluginBrowserHost {
    var tabs: [PluginTab] = []
    var renames: [(tab: UUID, name: String?, document: URL?)] = []
    var changes: [String] = []

    func tabs(in persona: PersonaID) -> [PluginTab] { tabs }

    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool {
        renames.append((id, name, document))
        return true
    }

    func webContents(forTab id: UUID) -> (any EngineWebContents)? { nil }
    func selectedTab(in persona: PersonaID) -> UUID? { nil }
    func openTab(_ url: URL, _ options: PluginOpenTabOptions, in persona: PersonaID, cause: BrowserEventCause) throws -> UUID { throw PluginError.closed }
    func closeTab(_ id: UUID, cause: BrowserEventCause) { changes.append("close \(id)") }
    func selectTab(_ id: UUID, cause: BrowserEventCause) { changes.append("select \(id)") }

    func moveTab(_ id: UUID, to place: PluginTabPlace, cause: BrowserEventCause) throws -> Bool {
        changes.append("move \(id)")
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

    /// A plugin whose page loads run as hooks hears of its setting changes outside the scheduler, so they reach it while the scheduler skips its page loads for want of a model.
    @Test func anAIPluginHearsOfItsSettingChangesWithoutAModelOfItsOwn() async throws {
        let manager = manager(builtIns: [AIHookPlugin.self], ai: service())
        defer { manager.close() }
        let installed = try #require(manager.plugins.first)
        #expect(installed.runsHooks)
        bus.post(.pageLoaded(tab: tab(), isRestore: false, isFirstLoadAfterOpen: true))
        try manager.setValue(.string("Short"), of: installed.manifest.contributions.settings[0], for: installed.id)
        #expect(await eventually { AIRecorder.shared.hookEvents == [nil] })
        try await Task.sleep(for: .milliseconds(300))
        #expect(AIRecorder.shared.hookEvents == [nil])
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

extension PluginAITests {
    /// A command-line tool that reads the request and prints its reply in two lines, `seconds` apart.
    private static func streamingTool(pause seconds: Double) -> AIProviderConfiguration {
        AIProviderConfiguration(name: "Streaming", kind: .commandLine(AICommandLineConfiguration(executable: URL(fileURLWithPath: "/bin/sh"),
                                                                                                 arguments: ["-c", "cat > /dev/null; printf 'Short\\n'; sleep \(seconds); printf 'answer\\n'"],
                                                                                                 environment: ["PATH": "/usr/bin:/bin"])),
                                models: [AIModelConfiguration(name: "")], limits: .commandLine)
    }

    /// The stream's listener gets each piece of the reply as it arrives, and waiting for the next piece does not count toward the hang limit. A listener that throws stops the request.
    @Test func aScriptPluginStreamsAReplyAsItArrives() async throws {
        let manifest = #"{"id": "org.example.ai-stream", "name": "AI Stream", "version": "1", "apiVersion": 1, "summary": "Streams.", "permissions": ["ai"], "background": "b.js", "contributes": {"commands": [{"id": "stream", "title": "Stream"}, {"id": "stop", "title": "Stop"}]}}"#
        let background = """
        const request = { messages: [{ role: "user", text: "Hi" }] };
        arch.commands.onRun("stream", async () => {
          const pieces = [];
          const reply = await arch.ai.stream(request, (text) => { pieces.push(text); });
          await arch.storage.set("streamed", { pieces, reply });
          await arch.storage.set("withoutListener", await arch.ai.stream(request).catch((error) => error.message));
        });
        arch.commands.onRun("stop", async () => {
          try {
            await arch.ai.stream(request, () => { throw new Error("Enough"); });
          } catch (error) {
            await arch.storage.set("stopped", error.message);
          }
        });
        """
        let feature = AIFeatureID.plugin("org.example.ai-stream")
        let service = service()
        let tool = Self.streamingTool(pause: 3)
        service.settings.providers = [tool]
        service.settings.setRoute(AIRoute(isEnabled: true, models: [Self.model(of: tool)]), for: feature)
        let manager = manager(ai: service, hang: 1.5)
        defer { manager.close() }
        let package = try await manager.stage(try writePackage(["plugin.json": manifest, "b.js": background]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let storage = manager.makeContext(for: try #require(manager.plugins.first)).storage

        await manager.run(PluginCommandRef(plugin: package.manifest.id, command: "stream"), PluginInvocation(tab: nil))
        guard case let .object(streamed)? = storage.value(forKey: "streamed"), case let .array(pieces)? = streamed["pieces"],
              case let .object(reply)? = streamed["reply"], case let .string(text)? = reply["text"] else {
            Issue.record("The stream did not finish: \(String(describing: storage.value(forKey: "streamed")))")
            return
        }
        #expect(pieces.count == 2 && pieces.map { if case let .string(piece) = $0 { piece } else { "" } }.joined() == text)
        #expect(text.hasPrefix("Short") && text.hasSuffix("answer") && reply["finishReason"] == .string("completed"))
        #expect(storage.value(forKey: "withoutListener") == .string("invalidCall") && manager.plugins.first?.failure == nil)

        let started = ContinuousClock.now
        await manager.run(PluginCommandRef(plugin: package.manifest.id, command: "stop"), PluginInvocation(tab: nil))
        #expect(storage.value(forKey: "stopped") == .string("Enough"))
        #expect(await eventually {
            if case .cancelled? = service.activity.last?.result { return true }
            return false
        })
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    /// A panel's request belongs to no hook step, so stopping the step that runs meanwhile leaves it running.
    @Test func aPanelsRequestsStayOutOfThePluginsHookSteps() async throws {
        let manifest = #"{"id": "org.example.ai-panel", "name": "AI Panel", "version": "1", "apiVersion": 1, "summary": "Asks.", "permissions": ["ai"], "events": ["pageLoaded"], "background": "b.js", "contributes": {"sidebarItems": [{"id": "panel", "title": "Ask", "symbol": "sparkles", "panel": "panel.html"}]}}"#
        let background = """
        arch.events.on("pageLoaded", async () => {
          try {
            await arch.storage.set("step", (await arch.ai.reply({ messages: [{ role: "user", text: "Name it" }] })).text);
          } catch (error) {
            await arch.storage.set("step", error.message);
          }
        });
        """
        let panelScript = #"arch.ai.reply({ messages: [{ role: "user", text: "Hi" }] }).then((reply) => arch.storage.set("panel", reply.text), (error) => arch.storage.set("panel", error.message));"#
        let feature = AIFeatureID.plugin("org.example.ai-panel")
        let service = service(answeringAfter: 3, for: [feature])
        let manager = manager(ai: service)
        defer { manager.close() }
        let package = try await manager.stage(try writePackage([
            "plugin.json": manifest, "b.js": background, "panel.html": #"<!doctype html><script src="panel.js"></script>"#, "panel.js": panelScript,
        ]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let storage = manager.makeContext(for: try #require(manager.plugins.first)).storage

        let page = tab()
        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: true))
        try await Task.sleep(for: .seconds(1))
        let item = try #require(manager.contributions.sidebarItems.first)
        let panel = try #require(await manager.panel(for: item))
        _ = panel.view
        panel.viewWillAppear()
        defer { panel.viewDidDisappear() }
        try await Task.sleep(for: .milliseconds(500))
        service.hooks.scheduler.cancel(subject: page.id)
        #expect(await eventually { storage.value(forKey: "step") == .string("cancelled") })
        #expect(await eventually { storage.value(forKey: "panel") == .string("Short answer") })
    }

    /// A panel's rename belongs to no hook step: it is for the document the tab shows, both while a step runs for the tab and once the scheduler has stopped that step, whose listener still runs.
    @Test func aPanelsRenamesStayOutOfThePluginsHookSteps() async throws {
        let manifest = #"{"id": "org.example.rename-panel", "name": "Rename Panel", "version": "1", "apiVersion": 1, "summary": "Renames.", "permissions": ["ai", "tabs.rename"], "events": ["pageLoaded"], "background": "b.js", "contributes": {"sidebarItems": [{"id": "panel", "title": "Rename", "symbol": "pencil", "panel": "panel.html"}]}}"#
        // The listener runs on for a while after the scheduler stops its step.
        let background = """
        arch.events.on("pageLoaded", async (event) => {
          await arch.storage.set("asking", true);
          await arch.ai.reply({ messages: [{ role: "user", text: "Name it" }] }).catch(() => {});
          await arch.storage.set("stepRenamed", await arch.tabs.rename(event.tab.id, "Step"));
          await new Promise((resolve) => setTimeout(resolve, 3000));
        });
        """
        let feature = AIFeatureID.plugin("org.example.rename-panel")
        let service = service(answeringAfter: 5, for: [feature])
        let manager = manager(ai: service)
        defer { manager.close() }
        let package = try await manager.stage(try writePackage([
            "plugin.json": manifest, "b.js": background, "panel.html": #"<!doctype html><script src="panel.js"></script>"#, "panel.js": #"arch.storage.set("ready", true);"#,
        ]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let storage = manager.makeContext(for: try #require(manager.plugins.first)).storage
        let page = tab("/page")
        host.tabs = [pluginTab("https://example.org/page", title: "Page", id: page.id)]

        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: true))
        #expect(await eventually { storage.value(forKey: "asking") == .bool(true) })
        let item = try #require(manager.contributions.sidebarItems.first)
        let panel = try #require(await manager.panel(for: item))
        let webView = try #require(panel.view as? WKWebView)
        panel.viewWillAppear()
        defer { panel.viewDidDisappear() }
        #expect(await eventually { storage.value(forKey: "ready") == .bool(true) })
        func rename(to name: String) async throws -> Bool? {
            try await webView.callAsyncJavaScript("return await arch.tabs.rename(id, name);", arguments: ["id": page.id.uuidString, "name": name], contentWorld: .page) as? Bool
        }

        #expect(try await rename(to: "During") == true)
        #expect(host.renames.last?.name == "During" && host.renames.last?.document == nil)
        service.hooks.scheduler.cancel(subject: page.id)
        #expect(await eventually { storage.value(forKey: "stepRenamed") == .bool(false) })
        #expect(try await rename(to: "After") == true)
        #expect(host.renames.map(\.name) == ["During", "After"] && host.renames.last?.document == nil)
    }

    /// Once the scheduler stops a step, whose listener still runs, the listener closes, selects, and moves the step's tab no more, since the tab can show the user's next document by then, while it still reaches another tab and a panel reaches the step's tab.
    @Test func aStoppedStepClosesSelectsAndMovesItsTabNoMore() async throws {
        let manifest = #"{"id": "org.example.close-panel", "name": "Close Panel", "version": "1", "apiVersion": 1, "summary": "Closes.", "permissions": ["ai", "tabs.manage"], "events": ["pageLoaded"], "background": "b.js", "contributes": {"sidebarItems": [{"id": "panel", "title": "Close", "symbol": "xmark", "panel": "panel.html"}]}}"#
        let background = """
        arch.events.on("pageLoaded", async (event) => {
          await arch.storage.set("asking", true);
          await arch.ai.reply({ messages: [{ role: "user", text: "Close it?" }] }).catch(() => {});
          const fail = async (call) => { try { await call(); return "resolved"; } catch (error) { return error.message; } };
          const other = (await arch.tabs.list()).find((tab) => tab.id !== event.tab.id).id;
          await arch.storage.set("step", {
            select: await fail(() => arch.tabs.select(event.tab.id)), move: await fail(() => arch.tabs.move(event.tab.id)), close: await fail(() => arch.tabs.close(event.tab.id)),
            other: await fail(() => arch.tabs.select(other)),
          });
          await new Promise((resolve) => setTimeout(resolve, 3000));
        });
        """
        let feature = AIFeatureID.plugin("org.example.close-panel")
        let service = service(answeringAfter: 5, for: [feature])
        let manager = manager(ai: service)
        defer { manager.close() }
        let package = try await manager.stage(try writePackage([
            "plugin.json": manifest, "b.js": background, "panel.html": #"<!doctype html><script src="panel.js"></script>"#, "panel.js": #"arch.storage.set("ready", true);"#,
        ]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let storage = manager.makeContext(for: try #require(manager.plugins.first)).storage
        let page = tab("/page")
        let other = pluginTab("https://example.org/other", title: "Other")
        host.tabs = [pluginTab("https://example.org/page", title: "Page", id: page.id), other]

        bus.post(.pageLoaded(tab: page, isRestore: false, isFirstLoadAfterOpen: true))
        #expect(await eventually { storage.value(forKey: "asking") == .bool(true) })
        let item = try #require(manager.contributions.sidebarItems.first)
        let panel = try #require(await manager.panel(for: item))
        let webView = try #require(panel.view as? WKWebView)
        panel.viewWillAppear()
        defer { panel.viewDidDisappear() }
        #expect(await eventually { storage.value(forKey: "ready") == .bool(true) })
        service.hooks.scheduler.cancel(subject: page.id)
        #expect(await eventually { storage.value(forKey: "step") != nil })
        #expect(storage.value(forKey: "step") == .object(["select": .string("stopped"), "move": .string("stopped"), "close": .string("stopped"), "other": .string("resolved")]))
        #expect(host.changes == ["select \(other.id)"])
        // The listener still runs, and the panel's calls belong to no step.
        let moved = try await webView.callAsyncJavaScript("await arch.tabs.select(id); const moved = await arch.tabs.move(id); await arch.tabs.close(id); return moved;",
                                                          arguments: ["id": page.id.uuidString], contentWorld: .page)
        #expect(moved as? Bool == true)
        #expect(host.changes == ["select \(other.id)", "select \(page.id)", "move \(page.id)", "close \(page.id)"])
    }

    /// Closing a panel stops the requests of its document.
    @Test func closingAPanelStopsItsRequests() async throws {
        let manifest = #"{"id": "org.example.ask-panel", "name": "Ask Panel", "version": "1", "apiVersion": 1, "summary": "Asks.", "permissions": ["ai"], "contributes": {"sidebarItems": [{"id": "panel", "title": "Ask", "symbol": "sparkles", "panel": "panel.html"}]}}"#
        let panelScript = #"arch.storage.set("asking", true).then(() => arch.ai.reply({ messages: [{ role: "user", text: "Hi" }] }));"#
        let feature = AIFeatureID.plugin("org.example.ask-panel")
        let service = service(answeringAfter: 5, for: [feature])
        let manager = manager(ai: service)
        defer { manager.close() }
        let package = try await manager.stage(try writePackage([
            "plugin.json": manifest, "panel.html": #"<!doctype html><script src="panel.js"></script>"#, "panel.js": panelScript,
        ]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let storage = manager.makeContext(for: try #require(manager.plugins.first)).storage
        let item = try #require(manager.contributions.sidebarItems.first)
        let panel = try #require(await manager.panel(for: item))
        _ = panel.view
        panel.viewWillAppear()
        #expect(await eventually { storage.value(forKey: "asking") == .bool(true) })
        try await Task.sleep(for: .milliseconds(500))
        let closed = ContinuousClock.now
        panel.viewDidDisappear()
        #expect(await eventually {
            if case .cancelled? = service.activity.last?.result { return true }
            return false
        })
        #expect(service.activity.count == 1 && service.activity.last?.feature == feature && ContinuousClock.now - closed < .seconds(3))
    }

    /// The `ai` permission can list the data kinds beyond text that the plugin's requests carry: `page` and `selection`, whose content a plugin reaches.
    @Test func theAIPermissionMayListDataKinds() async throws {
        let manager = manager(ai: nil)
        func stage(_ permissions: String) async throws -> PluginPackage {
            try await manager.stage(try writePackage([
                "plugin.json": #"{"id": "org.example.ai-data", "name": "AI Data", "version": "1", "apiVersion": 1, "summary": "Asks.", "permissions": \#(permissions), "sites": ["https://example.org/*"]}"#,
            ]))
        }
        let package = try await stage(#"["tabs", {"ai": ["page", "selection"]}]"#)
        #expect(package.manifest.permissions == [.tabs, .ai] && package.manifest.aiDataKinds == [.page, .selection])
        // The list joins as the locale joins lists, "the text of pages and selected text" in English.
        let sentence = "Send \(ListFormatter.localizedString(byJoining: ["the text of pages", "selected text"])) to the AI models you connected"
        #expect(package.manifest.aiDataSummary == sentence)
        let id = try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: false)
        let installed = try #require(manager.plugins.first { $0.id == id })
        #expect(installed.aiDataKinds == [.page, .selection])
        // Settings states the kinds right after the permissions and before the sites, as the install sheet does.
        let site = "Run scripts on pages from example.org"
        #expect(installed.accessSummaries == ["Read the titles and addresses of your tabs", "Send text to the AI models you connected", sentence, site])
        // Without `ai` in the grant, the kinds do not come with it.
        var withoutAI = installed
        withoutAI.grant.permissions = [.tabs]
        #expect(withoutAI.aiDataKinds.isEmpty && withoutAI.accessSummaries == ["Read the titles and addresses of your tabs", site])
        let textOnly = try await stage(#"["ai"]"#)
        #expect(textOnly.manifest.aiDataKinds.isEmpty && textOnly.manifest.aiDataSummary == nil)

        let malformed = #"plugin.json: permissions must be an array of permission names, with ai also as an object such as {"ai": ["page"]}."#
        let refusals = [
            (#"[{"ai": ["file"]}]"#, "plugin.json: permissions lists ai with \u{201C}file\u{201D}, which is not page or selection."),
            (#"[{"tabs": ["page"]}]"#, malformed),
            (#"[{"ai": "page"}]"#, malformed),
            (#"[{"ai": [1]}]"#, malformed),
            (#"[{"ai": ["page"], "tabs": []}]"#, malformed),
            (#""ai""#, malformed),
        ]
        for (permissions, reason) in refusals {
            await #expect(throws: PluginError.invalidPackage(reason), "\(permissions)") { _ = try await stage(permissions) }
        }
    }

    /// An update that lists other data kinds changes the kinds that the plugin's feature declares, with neither its name nor its trigger changing.
    @Test func anUpdateChangesTheKindsTheFeatureDeclares() async throws {
        let service = service()
        let manager = manager(ai: service)
        defer { manager.close() }
        let id = AIFeatureID.plugin("org.example.ai-kinds")
        func install(_ permissions: String) async throws -> Set<AIDataKind>? {
            let package = try await manager.stage(try writePackage([
                "plugin.json": #"{"id": "org.example.ai-kinds", "name": "AI Kinds", "version": "1", "apiVersion": 1, "summary": "Asks.", "permissions": \#(permissions)}"#,
            ]))
            _ = try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
            return service.features.first { $0.id == id }?.data.kinds
        }
        #expect(try await install(#"["ai"]"#) == [])
        #expect(try await install(#"[{"ai": ["page", "selection"]}]"#) == [.page, .selection])
        #expect(try await install(#"[{"ai": ["page"]}]"#) == [.page])
        #expect(try await install(#"["ai"]"#) == [])
        #expect(service.features.first { $0.id == id }?.name == "AI Kinds" && manager.plugins.count == 1)
    }

    /// Plugins with one identifier in several Personas share the feature, which declares the kinds that any of them lists, while each one's requests carry only its own.
    @Test func theFeatureDeclaresTheListedKindsAndEachPluginSendsOnlyItsOwn() async throws {
        let service = service()
        let id = AIFeatureID.plugin("org.example.ai-data")
        let tool = AIProviderConfiguration(name: "Echo", kind: .commandLine(AICommandLineConfiguration(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat"],
                                                                                                       environment: ["PATH": "/usr/bin:/bin"], runsWithoutTools: true)),
                                           models: [AIModelConfiguration(name: "")], limits: .commandLine)
        service.settings.providers = [tool]
        service.settings.setRoute(AIRoute(isEnabled: true, models: [Self.model(of: tool)]), for: id)
        func install(_ permissions: String, in manager: PluginManager) async throws -> ScopedPluginContext {
            let package = try await manager.stage(try writePackage([
                "plugin.json": #"{"id": "org.example.ai-data", "name": "AI Data", "version": "1", "apiVersion": 1, "summary": "Asks.", "permissions": \#(permissions)}"#,
            ]))
            try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
            return manager.makeContext(for: try #require(manager.plugins.first))
        }
        let pages = manager(ai: service)
        let text = manager(persona: UUID(), ai: service)
        defer {
            pages.close()
            text.close()
        }
        let withPages = try await install(#"[{"ai": ["page"]}]"#, in: pages)
        let textOnly = try await install(#"["ai"]"#, in: text)
        #expect(service.features.first { $0.id == id }?.data.kinds == [.page])

        let page = AIPart.page(AIPageContent(url: URL(string: "https://example.org/a")!, title: "A", text: "The page's body"))
        let request = AIRequest(feature: id, messages: [AIMessage(role: .user, parts: [page, .text("Sum it up")])])
        let reply = try await withPages.ai().reply(request).text
        #expect(reply.contains(#"<page url="https://example.org/a""#) && reply.contains("The page's body"))
        func refusesUndeclared(_ kind: AIDataKind) -> (any Error) -> Bool {
            { error in
                guard case .blockedByPolicy(.dataNotDeclared(let refused))? = error as? AIError else { return false }
                return refused == kind
            }
        }
        await #expect { _ = try await textOnly.ai().reply(request) } throws: { refusesUndeclared(.page)($0) }
        let selection = AIRequest(feature: id, messages: [AIMessage(role: .user, parts: [.selection(AISelection(pageURL: URL(string: "https://example.org/a")!, pageTitle: "A", text: "Picked"))])])
        await #expect { _ = try await withPages.ai().reply(selection) } throws: { refusesUndeclared(.selection)($0) }

        // Once no plugin lists a kind, the feature declares none.
        pages.setEnabled(false, for: try #require(pages.plugins.first?.id))
        #expect(service.features.first { $0.id == id }?.data.kinds == [])
    }

    /// A script's request can carry page and selection parts of the kinds its `ai` permission lists.
    @Test func aScriptPluginSendsTheDataKindsItLists() async throws {
        let manifest = #"{"id": "org.example.ai-parts", "name": "AI Parts", "version": "1", "apiVersion": 1, "summary": "Sends.", "permissions": [{"ai": ["page"]}], "background": "b.js", "contributes": {"commands": [{"id": "send", "title": "Send"}]}}"#
        let background = """
        const outcome = (request) => arch.ai.reply(request).then((reply) => reply.text, (error) => error.message);
        const ask = (parts) => outcome({ messages: [{ role: "user", parts }] });
        arch.commands.onRun("send", async () => {
          await arch.storage.set("sent", {
            page: await ask([{ type: "page", url: "https://example.org/a", title: "A", text: "The page's body" }, { type: "text", text: "Sum it up" }]),
            selection: await ask([{ type: "selection", url: "https://example.org/a", title: "A", text: "Picked" }]),
            unknown: await ask([{ type: "file", text: "x" }]),
            extra: await ask([{ type: "text", text: "x", url: "https://example.org/" }]),
            empty: await ask([]),
            both: await outcome({ messages: [{ role: "user", text: "x", parts: [{ type: "text", text: "x" }] }] }),
          });
        });
        """
        let feature = AIFeatureID.plugin("org.example.ai-parts")
        let service = service()
        let tool = AIProviderConfiguration(name: "Echo", kind: .commandLine(AICommandLineConfiguration(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat"],
                                                                                                       environment: ["PATH": "/usr/bin:/bin"], runsWithoutTools: true)),
                                           models: [AIModelConfiguration(name: "")], limits: .commandLine)
        service.settings.providers = [tool]
        service.settings.setRoute(AIRoute(isEnabled: true, models: [Self.model(of: tool)]), for: feature)
        let manager = manager(ai: service)
        defer { manager.close() }
        let package = try await manager.stage(try writePackage(["plugin.json": manifest, "b.js": background]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        await manager.run(PluginCommandRef(plugin: package.manifest.id, command: "send"), PluginInvocation(tab: nil))
        guard case let .object(sent)? = manager.makeContext(for: try #require(manager.plugins.first)).storage.value(forKey: "sent"),
              case let .string(page)? = sent["page"] else {
            Issue.record("The command stored nothing.")
            return
        }
        #expect(page.contains(#"<page url="https://example.org/a""#) && page.contains("The page's body") && page.contains("Sum it up"))
        #expect(sent["selection"] == .string("blockedByPolicy"))
        for key in ["unknown", "extra", "empty", "both"] {
            #expect(sent[key] == .string("invalidCall"), "\(key)")
        }
    }

    /// `arch.ai.stream` reads a reply by the rules of `AIClient.reply(_:)`, which `arch.ai.reply` follows: the same events end it with the same reason or error and hand on the same text.
    @Test func aStreamEndsAsAReplyDoes() async {
        let model = AIModelRef(provider: AIProviderID(), model: "")
        let json = AIOutputFormat.json(schema: Data(#"{"type": "object"}"#.utf8))
        let cases: [(output: AIOutputFormat, events: [AIEvent], error: AIError?)] = [
            (.text, [.waiting(.queued), .started(model), .text("Short "), .text(""), .text("answer"), .finished(.completed)], nil),
            (.text, [.started(model), .text("Cut"), .finished(.lengthLimit)], nil),
            (.text, [.started(model), .text("Short")], nil),
            (.text, [.text("Short"), .finished(.completed)], nil),
            (.text, [.started(model), .text("Short")], .authentication(model.provider)),
            (json, [.started(model), .text(#"{"a": "#), .text("1}"), .finished(.completed)], nil),
            (json, [.started(model), .text("Short answer"), .finished(.completed)], nil),
            (json, [.started(model), .text(#"{"a": "#), .finished(.lengthLimit)], nil),
        ]
        for (output, events, error) in cases {
            let client = ScriptedClient(events: events, error: error)
            let request = AIRequest(feature: .plugin("org.example.stream"), messages: [AIMessage(role: .user, parts: [.text("Hi")])], output: output)
            let replied: String
            var repliedText: String?
            do {
                let reply = try await client.reply(request)
                replied = "\(reply.finishReason)"
                repliedText = reply.text
            } catch {
                replied = "\(error)"
            }
            var streamedText = ""
            let streamed: String
            switch await ScriptPluginBridge.read(client.stream(request), output: output, receive: { streamedText += $0 }) {
            case let .success(reason): streamed = "\(reason)"
            case let .failure(error): streamed = "\(error)"
            }
            #expect(streamed == replied, "\(events)")
            if let repliedText { #expect(streamedText == repliedText, "\(events)") }
        }
    }
}

/// A client that answers every request with the same events, then ends, with `error` if any.
private struct ScriptedClient: AIClient {
    let events: [AIEvent]
    let error: AIError?

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish(throwing: error)
        }
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
