// Plugin events and tab calls (`docs/plugins.md`, Values, events, and storage; `docs/hooks.md`, Plugins): a manifest's `events` and `tabs.rename`, the bus's events of the manager's Persona reaching an enabled script plugin's `arch.events.on` in the script view its grant allows, only for the kinds it lists, never for the plugin's own renames and at most 10 for one tab a minute, the user's setting changes reaching a plugin that asks for them once they settle, each save of a secret among them, and none once the plugin is switched off, updated without the setting or the event, or removed, or its manager closes, and the context's tabs and renames through the browser host, under the grant, with the plugin as the rename's cause.
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Plugins

/// The tabs of each Persona as the session would give them, and the renames it was asked for.
@MainActor
private final class FakeTabsHost: PluginBrowserHost {
    struct Rename: Equatable {
        var tab: UUID
        var name: String?
        var document: URL?
        var cause: BrowserEventCause
    }

    var tabs: [PersonaID: [PluginTab]] = [:]
    private(set) var renames: [Rename] = []
    /// Called after each rename, as the session posts the rename's title change.
    var onRename: ((Rename) -> Void)?

    func tabs(in persona: PersonaID) -> [PluginTab] {
        tabs[persona] ?? []
    }

    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool {
        let rename = Rename(tab: id, name: name, document: document, cause: cause)
        renames.append(rename)
        onRename?(rename)
        return applying
    }

    func webContents(forTab id: UUID) -> (any EngineWebContents)? { nil }
}

/// Renames tabs on example.org, with nothing to run.
@MainActor
private final class RenamingPlugin: BuiltInPlugin {
    static var manifest: PluginManifest {
        PluginManifest(id: PluginID(rawValue: "org.example.renaming")!, name: "Renaming", version: "1", summary: "", permissions: [.renameTabs],
                       sites: [try! MatchPattern("https://example.org/*")], contributions: PluginContributions())
    }

    static var isOnByDefault: Bool { true }

    init() {}

    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}
}

/// Keeps the keys of the setting changes it hears in `heard`, by Persona and plugin, where they stay whatever becomes of the manager; `QuietSettingsPlugin` does not ask for them.
@MainActor
private class SettingsPlugin: BuiltInPlugin {
    class var id: PluginID { PluginID(rawValue: "org.example.settings")! }
    class var receivesSettingChanges: Bool { true }
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "Settings", version: "1", summary: "",
                       contributions: PluginContributions(settings: [PluginSetting(key: "name", title: "Name", kind: .text(default: "")),
                                                                     PluginSetting(key: "count", title: "Count", kind: .number(default: 1, range: 1...9)),
                                                                     PluginSetting(key: "token", title: "Token", kind: .secret)]),
                       receivesSettingChanges: receivesSettingChanges)
    }

    static var heard: [PersonaID: [PluginID: [String]]] = [:]

    static var isOnByDefault: Bool { true }

    private var context: (any PluginContext)?

    required init() {}

    func activate(in context: any PluginContext) async throws {
        self.context = context
    }

    func run(_ command: String, _ invocation: PluginInvocation) async throws {}

    func handle(_ event: PluginEvent) async throws {
        guard case let .settingChanged(key) = event, let context else { return }
        Self.heard[context.personaID, default: [:]][context.pluginID, default: []].append(key)
    }
}

@MainActor
private final class QuietSettingsPlugin: SettingsPlugin {
    override class var id: PluginID { PluginID(rawValue: "org.example.quiet-settings")! }
    override class var receivesSettingChanges: Bool { false }
}

@MainActor
@Suite struct PluginEventsTests {
    private let folder = TemporaryFolder()
    private let persona = UUID()
    private let bus = BrowserEventBus()
    private let host = FakeTabsHost()

    private func manager(builtIns: [any BuiltInPlugin.Type] = []) -> PluginManager {
        PluginManager(persona: persona, directory: folder.url, builtIns: builtIns, secretStore: MemorySecretStore(), events: bus, browserHost: host)
    }

    private func writePackage(_ files: [String: String]) throws -> URL {
        let root = folder.url.appendingPathComponent("Packages/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    private let manifest = #"{"id": "org.example.events", "name": "Events", "version": "1", "apiVersion": 1, "summary": "Keeps events.""#

    /// The keys of the setting changes that reached the Persona's `SettingsPlugin` or `QuietSettingsPlugin`.
    private func heard(by id: PluginID? = nil) -> [String] {
        SettingsPlugin.heard[persona]?[id ?? SettingsPlugin.id] ?? []
    }

    @Test func readsTheEventsAndTheRenamePermissionOfAManifest() async throws {
        let manager = manager()
        let package = try await manager.stage(try writePackage([
            "plugin.json": manifest + #", "permissions": ["tabs.rename"], "events": ["pageLoaded", "tabClosed"], "background": "b.js"}"#, "b.js": "",
        ]))
        #expect(package.manifest.events == [.pageLoaded, .tabClosed])
        #expect(package.manifest.permissions == [.renameTabs])
        #expect(PluginGrant(requestedBy: package.manifest).summaries == ["Suggest names for your tabs"])
        let refusals: [(String, PluginError)] = [
            (manifest + #", "events": ["pageClosed"], "background": "b.js"}"#, .invalidPackage("plugin.json: events lists “pageClosed”, which is not an event Arch sends.")),
            (manifest + #", "events": ["pageLoaded"]}"#, .invalidPackage("plugin.json: events need a background script.")),
        ]
        for (text, error) in refusals {
            await #expect(throws: error) { try await manager.stage(try writePackage(["plugin.json": text, "b.js": ""])) }
        }
    }

    /// `settingChanged` asks for the plugin's own setting changes, which come from Settings, not the bus, so they are not among `events` and make no hooks of a plugin with `ai`.
    @Test func readsSettingChangedAmongTheEventsOfAManifest() async throws {
        let manager = manager()
        let settings = #""contributes": {"settings": [{"key": "name", "title": "Name", "type": "text"}]}"#
        let both = try await manager.stage(try writePackage([
            "plugin.json": manifest + #", "events": ["settingChanged", "pageLoaded"], "background": "b.js", "# + settings + "}", "b.js": "",
        ]))
        #expect(both.manifest.events == [.pageLoaded] && both.manifest.receivesSettingChanges)
        let only = try await manager.stage(try writePackage([
            "plugin.json": manifest + #", "permissions": ["ai"], "events": ["settingChanged"], "background": "b.js", "# + settings + "}", "b.js": "",
        ]))
        #expect(only.manifest.events.isEmpty && only.manifest.receivesSettingChanges)
        #expect(!InstalledPlugin(manifest: only.manifest, grant: PluginGrant(requestedBy: only.manifest), isEnabled: true).runsHooks)
        let refusals: [(String, PluginError)] = [
            (manifest + #", "events": ["settingChanged"], "# + settings + "}", .invalidPackage("plugin.json: events need a background script.")),
            (manifest + #", "events": ["settingChanged"], "background": "b.js"}"#, .invalidPackage("plugin.json: events lists settingChanged, which needs contributes.settings.")),
        ]
        for (text, error) in refusals {
            await #expect(throws: error) { try await manager.stage(try writePackage(["plugin.json": text, "b.js": ""])) }
        }
    }

    @Test func eventsOfThePersonaReachTheKindsTheManifestListsInTheGrantsView() async throws {
        let manager = manager()
        defer { manager.close() }
        let background = """
        arch.events.on("pageLoaded", async (event) => {
          const seen = (await arch.storage.get("seen")) ?? [];
          seen.push({ event, tab: await arch.tabs.get(event.tab.id) });
          await arch.storage.set("seen", seen);
        });
        """
        let package = try await manager.stage(try writePackage([
            "plugin.json": manifest + #", "sites": ["https://example.org/*"], "events": ["pageLoaded"], "background": "b.js"}"#, "b.js": background,
        ]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let id = try #require(manager.plugins.first?.id)
        let covered = BrowserTabRef(id: UUID(), personaID: persona, spaceID: UUID(), kind: .open, engine: .webKit, url: URL(string: "https://example.org/a"))
        let other = BrowserTabRef(id: UUID(), personaID: persona, spaceID: UUID(), kind: .pinned, engine: .chromium, url: URL(string: "https://other.example/b"))
        host.tabs[persona] = [covered, other].map {
            PluginTab(id: $0.id, spaceID: $0.spaceID, title: "Title", url: $0.url, engine: $0.engine, isPinned: $0.kind == .pinned, isSelected: false, kind: $0.kind)
        }
        let storage = manager.makeContext(for: try #require(manager.plugins.first { $0.id == id })).storage
        func seen() -> [PluginValue] {
            guard case .array(let items)? = storage.value(forKey: "seen") else { return [] }
            return items
        }

        bus.post(.pageLoaded(tab: covered, isRestore: false, isFirstLoadAfterOpen: true))
        #expect(await eventually { seen().count == 1 })
        bus.post(.pageLoaded(tab: other, isRestore: false, isFirstLoadAfterOpen: false))
        #expect(await eventually { seen().count == 2 })
        // A kind the manifest does not list, and another Persona's event, reach nothing.
        bus.post(.tabOpened(tab: covered, openerTabID: nil))
        bus.post(.pageLoaded(tab: BrowserTabRef(id: UUID(), personaID: UUID(), spaceID: nil, kind: .open, engine: .webKit, url: covered.url), isRestore: false, isFirstLoadAfterOpen: false))
        try await Task.sleep(for: .milliseconds(300))
        let items = seen()
        #expect(items.count == 2)
        guard items.count == 2, case .object(let first) = items[0], case .object(let second) = items[1],
              case .object(let coveredEvent)? = first["event"], case .object(let otherEvent)? = second["event"],
              case .object(let coveredTab)? = coveredEvent["tab"], case .object(let otherTab)? = otherEvent["tab"] else { return }
        // The granted sites cover the first page, so its address shows; without `tabs`, the second's does not.
        #expect(coveredEvent["kind"] == .string("pageLoaded") && coveredEvent["isFirstLoadAfterOpen"] == .bool(true))
        #expect(coveredTab["url"] == .string("https://example.org/a") && coveredTab["kind"] == .string("open"))
        #expect(otherTab["url"] == nil && otherTab["engine"] == .string("chromium") && otherTab["kind"] == .string("pinned"))
        guard case .object(let coveredListed)? = first["tab"], case .object(let otherListed)? = second["tab"] else { return }
        #expect(coveredListed["title"] == .string("Title") && coveredListed["url"] == .string("https://example.org/a"))
        #expect(otherListed["title"] == nil && otherListed["url"] == nil && otherListed["isPinned"] == .bool(true))
    }

    /// A listener that renames the tab of each title change would otherwise run again for its own rename without end; changes from elsewhere, such as a hook that answers each rename, are capped instead.
    @Test func aPluginGetsNoEventsOfItsOwnRenamesAndAtMostTenForOneTabAMinute() async throws {
        let manager = manager()
        defer { manager.close() }
        let background = """
        let runs = 0;
        arch.events.on("titleChanged", async (event) => {
          runs += 1;
          await arch.storage.set("runs", runs);
          await arch.tabs.rename(event.tab.id, "Run " + runs);
        });
        """
        let package = try await manager.stage(try writePackage([
            "plugin.json": manifest + #", "permissions": ["tabs.rename"], "events": ["titleChanged"], "background": "b.js"}"#, "b.js": background,
        ]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let installed = try #require(manager.plugins.first)
        func tab() -> BrowserTabRef {
            BrowserTabRef(id: UUID(), personaID: persona, spaceID: UUID(), kind: .open, engine: .webKit, url: URL(string: "https://example.org/a"))
        }
        let first = tab()
        let second = tab()
        host.tabs[persona] = [first, second].map {
            PluginTab(id: $0.id, spaceID: $0.spaceID, title: "Title", url: $0.url, engine: $0.engine, isPinned: false, isSelected: false, kind: $0.kind)
        }
        host.onRename = { [bus] rename in
            bus.post(.titleChanged(tab: rename.tab == first.id ? first : second, source: .suggested), cause: rename.cause)
        }
        let storage = manager.makeContext(for: installed).storage
        func runs() -> PluginValue? { storage.value(forKey: "runs") }

        bus.post(.titleChanged(tab: first, source: .page))
        #expect(await eventually { host.renames.count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs() == .number(1) && host.renames.count == 1)
        #expect(host.renames.first?.cause == BrowserEventCause(origin: .plugin(id: installed.id.rawValue)))

        for _ in 0..<12 {
            bus.post(.titleChanged(tab: first, source: .page))
        }
        #expect(await eventually { runs() == .number(10) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs() == .number(10))
        // Another tab's changes still arrive.
        bus.post(.titleChanged(tab: second, source: .page))
        #expect(await eventually { runs() == .number(11) })
    }

    @Test func tabCallsGoThroughTheBrowserHostUnderTheGrant() async throws {
        let manager = manager(builtIns: [RenamingPlugin.self])
        let installed = try #require(manager.plugins.first)
        let covered = PluginTab(id: UUID(), spaceID: UUID(), title: "Covered", url: URL(string: "https://example.org/a"), engine: .webKit, isPinned: false, isSelected: true)
        let other = PluginTab(id: UUID(), spaceID: nil, title: "Other", url: URL(string: "https://other.example/"), engine: .chromium, isPinned: false, isSelected: false, kind: .favorite)
        host.tabs[persona] = [covered, other]
        let context = manager.makeContext(for: installed)
        #expect(try context.tabs().map(\.title) == ["Covered", nil])
        #expect(try context.tab(other.id)?.kind == .favorite)
        #expect(try context.tab(UUID()) == nil)

        #expect(try context.renameTab(other.id, to: "Name"))
        #expect(host.renames == [FakeTabsHost.Rename(tab: other.id, name: "Name", document: nil, cause: BrowserEventCause(origin: .plugin(id: "org.example.renaming")))])
        // A tab outside the Persona is refused, and without `tabs.rename` every rename is.
        let unnamed = UUID()
        #expect(throws: PluginError.notGranted(unnamed)) { _ = try context.renameTab(unnamed, to: "Name") }
        var withoutRename = installed
        withoutRename.grant.permissions = []
        #expect(throws: PluginError.permissionDenied(.renameTabs)) { _ = try manager.makeContext(for: withoutRename).renameTab(other.id, to: "Name") }
        context.end()
        #expect(throws: PluginError.stopped) { _ = try context.tabs() }
    }

    /// A setting's changes reach its plugin once, after they settle, and none that brings the value back; only a plugin that asks for them, while it is on, hears of them, and only of its own.
    @Test func aPluginHearsOfItsSettingChangesOnceTheySettle() async throws {
        let manager = manager(builtIns: [SettingsPlugin.self, QuietSettingsPlugin.self])
        defer { manager.close() }
        let listening = try #require(manager.plugins.first { $0.id == SettingsPlugin.id })
        let quiet = try #require(manager.plugins.first { $0.id == QuietSettingsPlugin.id })
        let name = listening.manifest.contributions.settings[0]
        let count = listening.manifest.contributions.settings[1]

        for text in ["a", "ab", "abc"] {
            try manager.setValue(.string(text), of: name, for: listening.id)
        }
        try manager.setValue(.string("x"), of: name, for: quiet.id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(heard().isEmpty)
        #expect(await eventually { heard() == ["name"] })
        // A change that the next one undoes before they settle, and a value written again as it is, change nothing the plugin would hear of.
        try manager.setValue(.number(5), of: count, for: listening.id)
        try manager.setValue(nil, of: count, for: listening.id)
        try manager.setValue(.string("abc"), of: name, for: listening.id)
        try await Task.sleep(for: PluginManager.settingChangeDelay * 2)
        #expect(heard() == ["name"])
        // Restoring the default is a change.
        try manager.setValue(nil, of: name, for: listening.id)
        #expect(await eventually { heard() == ["name", "name"] })
        // Switched off, the plugin hears of nothing.
        manager.setEnabled(false, for: listening.id)
        try manager.setValue(.number(3), of: count, for: listening.id)
        try await Task.sleep(for: PluginManager.settingChangeDelay * 2)
        #expect(heard() == ["name", "name"])
        #expect(heard(by: quiet.id).isEmpty)
    }

    /// The manager does not read a secret back, so each save counts, the same secret again among them.
    @Test func eachSaveOfASecretSettingReachesThePlugin() async throws {
        let manager = manager(builtIns: [SettingsPlugin.self])
        defer { manager.close() }
        let listening = try #require(manager.plugins.first)
        let token = listening.manifest.contributions.settings[2]
        try await manager.setSecret("secret", of: token, for: listening.id)
        #expect(await eventually { heard() == ["token"] })
        try await manager.setSecret("secret", of: token, for: listening.id)
        #expect(await eventually { heard() == ["token", "token"] })
    }

    /// A change reaches nothing when, before it settles, its plugin is switched off or its manager closes, and switching the plugin on again brings neither that change nor one made while it was off.
    @Test func aSettingChangeReachesNothingWhenItsPluginGoesOffBeforeItSettles() async throws {
        let manager = manager(builtIns: [SettingsPlugin.self])
        defer { manager.close() }
        let listening = try #require(manager.plugins.first)
        let name = listening.manifest.contributions.settings[0]

        try manager.setValue(.string("a"), of: name, for: listening.id)
        manager.setEnabled(false, for: listening.id)
        try manager.setValue(.string("b"), of: name, for: listening.id)
        try await Task.sleep(for: PluginManager.settingChangeDelay * 2)
        manager.setEnabled(true, for: listening.id)
        try await Task.sleep(for: PluginManager.settingChangeDelay * 2)
        #expect(heard().isEmpty)

        try manager.setValue(.string("c"), of: name, for: listening.id)
        manager.close()
        try await Task.sleep(for: PluginManager.settingChangeDelay * 2)
        #expect(heard().isEmpty)
    }

    /// A change reaches nothing when, before it settles, an update leaves its setting out or stops asking for setting changes, or the plugin is removed. The listener renames the Persona's tab after the key, so that the host sees each change that arrives, whatever becomes of the plugin's storage.
    @Test func aSettingChangeReachesNothingAfterAnUpdateOrARemovalBeforeItSettles() async throws {
        let manager = manager()
        defer { manager.close() }
        host.tabs[persona] = [PluginTab(id: UUID(), spaceID: UUID(), title: "Title", url: URL(string: "https://example.org/a"), engine: .webKit, isPinned: false, isSelected: true)]
        let background = """
        arch.events.on("settingChanged", async (event) => {
          const [tab] = await arch.tabs.list();
          await arch.tabs.rename(tab.id, event.key);
        });
        """
        func stage(events: String, settings: [String]) async throws -> PluginPackage {
            try await manager.stage(try writePackage([
                "plugin.json": manifest + #", "permissions": ["tabs.rename"], "events": \#(events), "background": "b.js", "contributes": {"settings": [\#(settings.joined(separator: ", "))]}}"#,
                "b.js": background,
            ]))
        }
        func install(_ package: PluginPackage) throws -> InstalledPlugin {
            _ = try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
            return try #require(manager.plugins.first)
        }
        func renames() -> [String?] { host.renames.map(\.name) }
        let name = #"{"key": "name", "title": "Name", "type": "text"}"#
        let other = #"{"key": "other", "title": "Other", "type": "text"}"#
        let listening = try install(try await stage(events: #"["settingChanged"]"#, settings: [name, other]))
        let nameSetting = listening.manifest.contributions.settings[0]
        let otherSetting = listening.manifest.contributions.settings[1]
        try manager.setValue(.string("a"), of: nameSetting, for: listening.id)
        #expect(await eventually { renames() == ["name"] })

        // An update without the setting; the plugin still hears of its other setting.
        let withoutName = try await stage(events: #"["settingChanged"]"#, settings: [other])
        try manager.setValue(.string("b"), of: nameSetting, for: listening.id)
        _ = try install(withoutName)
        try await Task.sleep(for: PluginManager.settingChangeDelay * 2)
        #expect(renames() == ["name"])
        try manager.setValue(.string("x"), of: otherSetting, for: listening.id)
        #expect(await eventually { renames() == ["name", "other"] })

        // An update that no longer asks for setting changes.
        let deaf = try await stage(events: "[]", settings: [name, other])
        try manager.setValue(.string("y"), of: otherSetting, for: listening.id)
        _ = try install(deaf)
        try await Task.sleep(for: PluginManager.settingChangeDelay * 2)
        #expect(renames() == ["name", "other"])

        // A removal.
        _ = try install(try await stage(events: #"["settingChanged"]"#, settings: [name, other]))
        try manager.setValue(.string("c"), of: nameSetting, for: listening.id)
        try manager.remove(listening.id)
        try await Task.sleep(for: PluginManager.settingChangeDelay * 2)
        #expect(renames() == ["name", "other"])
    }

    /// A script plugin's `arch.events.on("settingChanged", …)` gets the key and reads the new value; a secret setting's change counts once the Keychain has it.
    @Test func aScriptPluginsListenerGetsTheChangedSettingsKey() async throws {
        let manager = manager()
        defer { manager.close() }
        let background = """
        arch.events.on("settingChanged", async (event) => {
          const heard = (await arch.storage.get("heard")) ?? [];
          heard.push({ event, value: (await arch.settings.get(event.key)) ?? null });
          await arch.storage.set("heard", heard);
        });
        """
        let settings = #"[{"key": "name", "title": "Name", "type": "text"}, {"key": "token", "title": "Token", "type": "secret"}]"#
        let package = try await manager.stage(try writePackage([
            "plugin.json": manifest + #", "events": ["settingChanged"], "background": "b.js", "contributes": {"settings": "# + settings + "}}", "b.js": background,
        ]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let installed = try #require(manager.plugins.first)
        let storage = manager.makeContext(for: installed).storage
        func heard() -> [PluginValue] {
            guard case .array(let items)? = storage.value(forKey: "heard") else { return [] }
            return items
        }

        try manager.setValue(.string("Arch"), of: installed.manifest.contributions.settings[0], for: installed.id)
        #expect(await eventually { heard().count == 1 })
        try await manager.setSecret("secret", of: installed.manifest.contributions.settings[1], for: installed.id)
        #expect(await eventually { heard().count == 2 })
        #expect(heard() == [
            .object(["event": .object(["kind": .string("settingChanged"), "key": .string("name")]), "value": .string("Arch")]),
            .object(["event": .object(["kind": .string("settingChanged"), "key": .string("token")]), "value": .null]),
        ])
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
