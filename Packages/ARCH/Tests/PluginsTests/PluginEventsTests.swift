// Plugin events and tab calls (`docs/plugins.md`, Values, events, and storage; `docs/hooks.md`, Plugins): a manifest's `events` and `tabs.rename`, the bus's events of the manager's Persona reaching an enabled script plugin's `arch.events.on` in the script view its grant allows, only for the kinds it lists, never for the plugin's own renames and at most 10 for one tab a minute, the user's setting changes reaching a plugin that asks for them once they settle, each save of a secret among them, and none once the plugin is switched off, updated without the setting or the event, or removed, or its manager closes, and the context's tabs, renames, opens, closes, selections, and moves through the browser host, under the grant, with the plugin as their cause.
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Plugins

/// The tabs of each Persona as the session would give them, and the renames, opens, closes, selections, and moves it was asked for.
@MainActor
private final class FakeTabsHost: PluginBrowserHost {
    struct Rename: Equatable {
        var tab: UUID
        var name: String?
        var document: URL?
        var cause: BrowserEventCause
    }

    /// An open, close, selection, or move, with the tab it opened or acted on.
    struct Change: Equatable {
        enum Kind: Equatable {
            case opened(URL, PluginOpenTabOptions)
            case closed
            case selected
            case moved(PluginTabPlace)
        }

        var kind: Kind
        var tab: UUID
        var cause: BrowserEventCause
    }

    var tabs: [PersonaID: [PluginTab]] = [:]
    /// The spaces of each Persona, in which tabs open.
    var spaces: [PersonaID: [UUID]] = [:]
    /// The selected tab of the window that last became main, for each Persona.
    var selected: [PersonaID: UUID] = [:]
    private(set) var renames: [Rename] = []
    private(set) var changes: [Change] = []
    /// Called after each rename, as the session posts the rename's title change.
    var onRename: ((Rename) -> Void)?
    /// Called after each open, close, selection, and move, as the session posts its event.
    var onChange: ((Change) -> Void)?

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

    func selectedTab(in persona: PersonaID) -> UUID? {
        selected[persona]
    }

    /// The tab joins the Persona's tabs in the space the options name, or the Persona's first. A Persona without spaces is gone.
    func openTab(_ url: URL, _ options: PluginOpenTabOptions, in persona: PersonaID, cause: BrowserEventCause) throws -> UUID {
        guard let spaces = spaces[persona], let first = spaces.first else { throw PluginError.closed }
        let space = options.spaceID ?? first
        guard spaces.contains(space) else { throw PluginError.notGranted(space) }
        let tab = PluginTab(id: UUID(), spaceID: space, title: "", url: url, engine: options.engine ?? .webKit, isPinned: false, isSelected: options.select)
        tabs[persona, default: []].append(tab)
        record(Change(kind: .opened(url, options), tab: tab.id, cause: cause))
        return tab.id
    }

    func closeTab(_ id: UUID, cause: BrowserEventCause) {
        for persona in tabs.keys { tabs[persona]?.removeAll { $0.id == id } }
        record(Change(kind: .closed, tab: id, cause: cause))
    }

    func selectTab(_ id: UUID, cause: BrowserEventCause) {
        record(Change(kind: .selected, tab: id, cause: cause))
    }

    /// The tab goes next to the other tab, taking its space, or last in its Persona's order, in the space named, which must be one of the Persona's.
    func moveTab(_ id: UUID, to place: PluginTabPlace, cause: BrowserEventCause) throws -> Bool {
        guard let persona = tabs.first(where: { $0.value.contains { $0.id == id } })?.key, var list = tabs[persona],
              let index = list.firstIndex(where: { $0.id == id }) else { return false }
        var tab = list.remove(at: index)
        switch place {
        case let .before(other), let .after(other):
            guard let at = list.firstIndex(where: { $0.id == other }) else { return false }
            tab.spaceID = list[at].spaceID
            list.insert(tab, at: place == .after(other) ? at + 1 : at)
        case let .end(ofSpace: space):
            if let space {
                guard spaces[persona]?.contains(space) == true else { throw PluginError.notGranted(space) }
                tab.spaceID = space
            }
            list.append(tab)
        }
        tabs[persona] = list
        record(Change(kind: .moved(place), tab: id, cause: cause))
        return true
    }

    private func record(_ change: Change) {
        changes.append(change)
        onChange?(change)
    }
}

/// Opens, closes, selects, and moves tabs, and so renames them, with nothing to run; the sites cover example.org.
@MainActor
private final class ManagingPlugin: BuiltInPlugin {
    static var manifest: PluginManifest {
        PluginManifest(id: PluginID(rawValue: "org.example.managing")!, name: "Managing", version: "1", summary: "", permissions: [.manageTabs],
                       sites: [try! MatchPattern("https://example.org/*")], contributions: PluginContributions())
    }

    static var isOnByDefault: Bool { true }

    init() {}

    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}
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
        #expect(PluginGrant(requestedBy: package.manifest).summaries == [catalogText("Suggest names for your tabs")])
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

    /// `tabs.manage` opens, closes, and selects the Persona's tabs through the host with the plugin as the cause, and includes `tabs.rename`; the selected tab needs no permission and shows only what the grant covers.
    @Test func tabManagementGoesThroughTheBrowserHostUnderTheGrant() async throws {
        let manager = manager(builtIns: [ManagingPlugin.self])
        let installed = try #require(manager.plugins.first)
        let space = UUID()
        let covered = PluginTab(id: UUID(), spaceID: space, title: "Covered", url: URL(string: "https://example.org/a"), engine: .webKit, isPinned: false, isSelected: true)
        let other = PluginTab(id: UUID(), spaceID: space, title: "Other", url: URL(string: "https://other.example/"), engine: .chromium, isPinned: true, isSelected: false, kind: .pinned)
        host.tabs[persona] = [covered, other]
        host.spaces[persona] = [space]
        let context = manager.makeContext(for: installed)
        let cause = BrowserEventCause(origin: .plugin(id: "org.example.managing"))

        // The selected tab, as the grant shows it, and none outside the Persona's tabs, as for an agent tab or another Persona's.
        #expect(try context.selectedTab() == nil)
        host.selected[persona] = covered.id
        #expect(try context.selectedTab()?.title == "Covered")
        host.selected[persona] = other.id
        let selected = try #require(try context.selectedTab())
        #expect(selected.id == other.id && selected.title == nil && selected.url == nil && selected.isPinned)
        host.selected[persona] = UUID()
        #expect(try context.selectedTab() == nil)

        let address = URL(string: "https://example.org/new")!
        let opened = try context.openTab(address, PluginOpenTabOptions(select: false, engine: .chromium))
        #expect(try context.tab(opened)?.engine == .chromium)
        try context.selectTab(other.id)
        try context.closeTab(covered.id)
        #expect(host.changes == [
            FakeTabsHost.Change(kind: .opened(address, PluginOpenTabOptions(select: false, engine: .chromium)), tab: opened, cause: cause),
            FakeTabsHost.Change(kind: .selected, tab: other.id, cause: cause),
            FakeTabsHost.Change(kind: .closed, tab: covered.id, cause: cause),
        ])
        #expect(try context.renameTab(other.id, to: "Name"))

        // Only web pages open, in the Persona's spaces, and only the Persona's tabs close or take the selection.
        for text in ["file:///etc/hosts", "about:blank", "javascript:alert(1)", "https:///path"] {
            #expect(throws: PluginError.invalidAddress(text)) { _ = try context.openTab(URL(string: text)!, PluginOpenTabOptions()) }
        }
        let foreign = UUID()
        #expect(throws: PluginError.notGranted(foreign)) { _ = try context.openTab(address, PluginOpenTabOptions(spaceID: foreign)) }
        #expect(throws: PluginError.notGranted(covered.id)) { try context.closeTab(covered.id) }
        #expect(throws: PluginError.notGranted(foreign)) { try context.selectTab(foreign) }
        host.spaces[persona] = nil
        #expect(throws: PluginError.closed) { _ = try context.openTab(address, PluginOpenTabOptions()) }
        #expect(throws: PluginError.closed) { _ = try context.openTab(address, PluginOpenTabOptions(spaceID: space)) }
        #expect(host.changes.count == 3)

        // Without `tabs.manage`, nothing changes, while the selected tab still shows.
        var withoutManage = installed
        withoutManage.grant.permissions = []
        let limited = manager.makeContext(for: withoutManage)
        #expect(throws: PluginError.permissionDenied(.manageTabs)) { _ = try limited.openTab(address, PluginOpenTabOptions()) }
        #expect(throws: PluginError.permissionDenied(.manageTabs)) { try limited.closeTab(other.id) }
        #expect(throws: PluginError.permissionDenied(.manageTabs)) { try limited.selectTab(other.id) }
        #expect(throws: PluginError.permissionDenied(.renameTabs)) { _ = try limited.renameTab(other.id, to: "Name") }
        host.selected[persona] = other.id
        #expect(try limited.selectedTab()?.id == other.id)
        #expect(PluginGrant(requestedBy: installed.manifest).summaries.first == catalogText("Open any website in your tabs, signed in as you, and close, select, move, and suggest names for your tabs"))

        context.end()
        #expect(throws: PluginError.stopped) { _ = try context.selectedTab() }
        #expect(throws: PluginError.stopped) { _ = try context.openTab(address, PluginOpenTabOptions()) }
        #expect(throws: PluginError.stopped) { try context.closeTab(other.id) }
        #expect(throws: PluginError.stopped) { try context.selectTab(other.id) }
        #expect(host.changes.count == 3)
    }

    /// `tabs.manage` moves the Persona's tabs through the host with the plugin as the cause, next to another of its tabs or to one of its spaces, and neither a tab nor a neighbor outside the Persona's tabs, as another Persona's, which the host would move; the host's refusal of a space reaches the plugin, and `SessionPluginBrowserHostTests` checks the spaces and the agent tabs that the session refuses.
    @Test func tabMovesGoThroughTheBrowserHostUnderTheGrant() async throws {
        let manager = manager(builtIns: [ManagingPlugin.self])
        let installed = try #require(manager.plugins.first)
        let space = UUID(), side = UUID()
        let first = PluginTab(id: UUID(), spaceID: space, title: "First", url: URL(string: "https://example.org/a"), engine: .webKit, isPinned: false, isSelected: true)
        let second = PluginTab(id: UUID(), spaceID: space, title: "Second", url: URL(string: "https://example.org/b"), engine: .webKit, isPinned: false, isSelected: false)
        host.tabs[persona] = [first, second]
        host.spaces[persona] = [space, side]
        let context = manager.makeContext(for: installed)
        let cause = BrowserEventCause(origin: .plugin(id: "org.example.managing"))

        #expect(try context.moveTab(first.id, to: .after(second.id)))
        #expect(try context.tabs().map(\.id) == [second.id, first.id])
        #expect(try context.moveTab(second.id, to: .end(ofSpace: side)))
        #expect(try context.tab(second.id)?.spaceID == side)
        #expect(host.changes == [
            FakeTabsHost.Change(kind: .moved(.after(second.id)), tab: first.id, cause: cause),
            FakeTabsHost.Change(kind: .moved(.end(ofSpace: side)), tab: second.id, cause: cause),
        ])

        // Only the Persona's tabs move or take a tab next to them, though the host would move another Persona's, and a space that the host refuses stays refused.
        let elsewhere = PluginTab(id: UUID(), spaceID: UUID(), title: "Elsewhere", url: URL(string: "https://example.org/c"), engine: .webKit, isPinned: false, isSelected: false)
        host.tabs[UUID()] = [elsewhere]
        let foreign = UUID()
        #expect(throws: PluginError.notGranted(elsewhere.id)) { _ = try context.moveTab(elsewhere.id, to: .end(ofSpace: nil)) }
        #expect(throws: PluginError.notGranted(elsewhere.id)) { _ = try context.moveTab(first.id, to: .before(elsewhere.id)) }
        #expect(throws: PluginError.notGranted(foreign)) { _ = try context.moveTab(foreign, to: .end(ofSpace: nil)) }
        #expect(throws: PluginError.notGranted(foreign)) { _ = try context.moveTab(first.id, to: .end(ofSpace: foreign)) }
        #expect(host.changes.count == 2)

        var withoutManage = installed
        withoutManage.grant.permissions = [.tabs, .renameTabs]
        #expect(throws: PluginError.permissionDenied(.manageTabs)) { _ = try manager.makeContext(for: withoutManage).moveTab(first.id, to: .end(ofSpace: nil)) }
        context.end()
        #expect(throws: PluginError.stopped) { _ = try context.moveTab(first.id, to: .end(ofSpace: nil)) }
        #expect(host.changes.count == 2)
    }

    /// A plugin opens at most 10 tabs within a minute, so that plugins that open a tab for each other's `tabOpened` stop, each tab being an event subject of its own; an open that the host refuses does not count, and another plugin's opens count for it alone.
    @Test func aPluginOpensAtMostTenTabsWithinAMinute() async throws {
        let manager = manager(builtIns: [ManagingPlugin.self])
        let installed = try #require(manager.plugins.first)
        let space = UUID()
        host.spaces[persona] = [space]
        let context = manager.makeContext(for: installed)
        let address = URL(string: "https://example.org/new")!
        #expect(throws: PluginError.notGranted(persona)) { _ = try context.openTab(address, PluginOpenTabOptions(spaceID: persona)) }
        for _ in 0..<PluginManager.tabOpenLimit { _ = try context.openTab(address, PluginOpenTabOptions(select: false)) }
        #expect(throws: PluginError.tooManyTabs) { _ = try context.openTab(address, PluginOpenTabOptions(select: false)) }
        #expect(host.changes.count == PluginManager.tabOpenLimit)
        // A context that the plugin's next instance gets counts the same opens.
        #expect(throws: PluginError.tooManyTabs) { _ = try manager.makeContext(for: installed).openTab(address, PluginOpenTabOptions()) }
        var other = installed
        other.manifest.id = PluginID(rawValue: "org.example.other")!
        _ = try manager.makeContext(for: other).openTab(address, PluginOpenTabOptions())
        #expect(host.changes.count == PluginManager.tabOpenLimit + 1)
    }

    /// A script plugin reaches the tab members through `arch.tabs`, `move` with a place of exactly one key or none, each key read as its place, and the events of its own opens and closes never reach its listeners, while another tab's do.
    @Test func aScriptPluginManagesTabsThroughArchTabsWithoutHearingItsOwnChanges() async throws {
        let manager = manager()
        defer { manager.close() }
        let space = UUID(), side = UUID()
        let shown = PluginTab(id: UUID(), spaceID: space, title: "Shown", url: URL(string: "https://example.org/a"), engine: .webKit, isPinned: false, isSelected: true)
        host.tabs[persona] = [shown]
        host.spaces[persona] = [space, side]
        host.selected[persona] = shown.id
        host.onChange = { [bus, persona] change in
            let ref = BrowserTabRef(id: change.tab, personaID: persona, spaceID: space, kind: .open, engine: .webKit, url: nil)
            switch change.kind {
            case .opened: bus.post(.tabOpened(tab: ref, openerTabID: nil), cause: change.cause)
            case .closed: bus.post(.tabClosed(tab: ref, reason: .plugin), cause: change.cause)
            case .selected: bus.post(.tabSelected(tab: ref, windowID: UUID()), cause: change.cause)
            case .moved: break
            }
        }
        let background = """
        arch.events.on("tabOpened", async (event) => {
          await arch.storage.set("heard", [...((await arch.storage.get("heard")) ?? []), event.tab.id]);
        });
        arch.commands.onRun("go", async () => {
          const fail = async (call) => { try { await call(); return "resolved"; } catch (error) { return error.message; } };
          const selected = await arch.tabs.selected();
          const opened = await arch.tabs.open("https://example.org/new", { select: false, engine: "chromium", spaceId: null });
          await arch.tabs.select(opened);
          const order = async () => (await arch.tabs.list()).map((tab) => tab.id);
          const movedBefore = await arch.tabs.move(opened, { before: selected.id });
          const orderBefore = await order();
          const movedAfter = await arch.tabs.move(opened, { after: selected.id, before: null });
          const orderAfter = await order();
          const movedToSpace = await arch.tabs.move(opened, { spaceId: "\(side.uuidString)" });
          const space = (await arch.tabs.get(opened)).spaceId;
          const movedLast = await arch.tabs.move(opened);
          await arch.tabs.close(opened);
          await arch.storage.set("results", {
            selected: selected.id, title: selected.title ?? null, opened, movedBefore, orderBefore, movedAfter, orderAfter, movedToSpace, space, movedLast,
            missingNeighbor: await fail(() => arch.tabs.move(selected.id, { before: undefined })),
            nullSpace: await fail(() => arch.tabs.move(selected.id, { spaceId: null })),
            twoPlaces: await fail(() => arch.tabs.move(selected.id, { before: opened, after: opened })),
            unknownPlace: await fail(() => arch.tabs.move(selected.id, { index: 0 })),
            notAPlace: await fail(() => arch.tabs.move(selected.id, "first")),
            foreignNeighbor: await fail(() => arch.tabs.move(selected.id, { after: "00000000-0000-0000-0000-000000000000" })),
            fileAddress: await fail(() => arch.tabs.open("file:///etc/hosts")),
            relativeAddress: await fail(() => arch.tabs.open("example.org")),
            unknownOption: await fail(() => arch.tabs.open("https://example.org/", { window: 1 })),
            unknownEngine: await fail(() => arch.tabs.open("https://example.org/", { engine: "other" })),
            foreignSpace: await fail(() => arch.tabs.open("https://example.org/", { spaceId: "00000000-0000-0000-0000-000000000000" })),
            unknownTab: await fail(() => arch.tabs.close("00000000-0000-0000-0000-000000000000")),
            notATab: await fail(() => arch.tabs.select("tab")),
          });
        });
        """
        let package = try await manager.stage(try writePackage([
            "plugin.json": manifest + #", "permissions": ["tabs.manage"], "events": ["tabOpened"], "background": "b.js", "contributes": {"commands": [{"id": "go", "title": "Go"}]}}"#,
            "b.js": background,
        ]))
        #expect(package.manifest.permissions == [.manageTabs])
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let installed = try #require(manager.plugins.first)
        let storage = manager.makeContext(for: installed).storage

        await manager.run(PluginCommandRef(plugin: installed.id, command: "go"), PluginInvocation(tab: nil))
        guard case .object(let results)? = storage.value(forKey: "results"), case .string(let opened)? = results["opened"] else {
            Issue.record("The command stored no results.")
            return
        }
        #expect(host.changes.map(\.kind) == [.opened(URL(string: "https://example.org/new")!, PluginOpenTabOptions(select: false, engine: .chromium)), .selected,
                                              .moved(.before(shown.id)), .moved(.after(shown.id)), .moved(.end(ofSpace: side)), .moved(.end(ofSpace: nil)), .closed])
        #expect(host.changes.allSatisfy { $0.tab.uuidString == opened && $0.cause == BrowserEventCause(origin: .plugin(id: installed.id.rawValue)) })
        #expect(results == [
            "selected": .string(shown.id.uuidString), "title": .null, "opened": .string(opened),
            "movedBefore": .bool(true), "orderBefore": .array([.string(opened), .string(shown.id.uuidString)]),
            "movedAfter": .bool(true), "orderAfter": .array([.string(shown.id.uuidString), .string(opened)]),
            "movedToSpace": .bool(true), "space": .string(side.uuidString), "movedLast": .bool(true),
            "missingNeighbor": .string("invalidCall"), "nullSpace": .string("invalidCall"), "twoPlaces": .string("invalidCall"),
            "unknownPlace": .string("invalidCall"), "notAPlace": .string("invalidCall"), "foreignNeighbor": .string("notGranted"),
            "fileAddress": .string("invalidAddress"), "relativeAddress": .string("invalidCall"), "unknownOption": .string("invalidCall"),
            "unknownEngine": .string("invalidCall"), "foreignSpace": .string("notGranted"), "unknownTab": .string("notGranted"), "notATab": .string("invalidCall"),
        ])
        // The plugin's own open did not reach its listener; a tab that opens otherwise does.
        try await Task.sleep(for: .milliseconds(300))
        #expect(storage.value(forKey: "heard") == nil)
        let elsewhere = UUID()
        bus.post(.tabOpened(tab: BrowserTabRef(id: elsewhere, personaID: persona, spaceID: space, kind: .open, engine: .webKit, url: nil), openerTabID: nil))
        #expect(await eventually { storage.value(forKey: "heard") == .array([.string(elsewhere.uuidString)]) })
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
