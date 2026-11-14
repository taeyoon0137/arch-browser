// Plugin events and tab calls (`docs/plugins.md`, Values, events, and storage; `docs/hooks.md`, Plugins): a manifest's `events` and `tabs.rename`, the bus's events of the manager's Persona reaching an enabled script plugin's `arch.events.on` in the script view its grant allows, only for the kinds it lists, and the context's tabs and renames through the browser host, under the grant, with the plugin as the rename's cause.
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

    func tabs(in persona: PersonaID) -> [PluginTab] {
        tabs[persona] ?? []
    }

    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool {
        renames.append(Rename(tab: id, name: name, document: document, cause: cause))
        return applying
    }
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
