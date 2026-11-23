// A plugin's history search (`docs/plugins.md`, Permissions and Plugins and the context): `history` in a manifest and its sentence, the context's search of its Persona's pages through the browser host under the grant, with the limit kept from 0 to 100, none of the pages on sites excluded from AI for a plugin with `ai` while the others still fill the limit, `stopped` once the instance stops, and a script plugin's `arch.history.search` with its pages' JSON and the calls it refuses.
import ARCHEngine
import AI
import Events
import Foundation
import Testing
@testable import Plugins

/// Each Persona's history pages, most visited first, and the searches it was asked for.
@MainActor
private final class HistoryHost: PluginBrowserHost {
    struct Search: Equatable {
        var text: String
        var limit: Int
        var persona: PersonaID
    }

    var pages: [PersonaID: [PluginHistoryEntry]] = [:]
    private(set) var searches: [Search] = []

    func tabs(in persona: PersonaID) -> [PluginTab] { [] }
    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool { false }
    func webContents(forTab id: UUID) -> (any EngineWebContents)? { nil }
    func selectedTab(in persona: PersonaID) -> UUID? { nil }
    func openTab(_ url: URL, _ options: PluginOpenTabOptions, in persona: PersonaID, cause: BrowserEventCause) throws -> UUID { throw PluginError.closed }
    func closeTab(_ id: UUID, cause: BrowserEventCause) {}
    func selectTab(_ id: UUID, cause: BrowserEventCause) {}
    func moveTab(_ id: UUID, to place: PluginTabPlace, cause: BrowserEventCause) throws -> Bool { false }

    /// The Persona's pages whose address or title holds the text, or all of them for empty text, up to `limit` of those the check accepts, as the history store gives them.
    func history(matching text: String, limit: Int, in persona: PersonaID, where isIncluded: @escaping @Sendable (URL) -> Bool) async -> [PluginHistoryEntry] {
        searches.append(Search(text: text, limit: limit, persona: persona))
        let matching = (pages[persona] ?? []).filter { text.isEmpty || $0.url.absoluteString.contains(text) || $0.title.contains(text) }
        return Array(matching.filter { isIncluded($0.url) }.prefix(limit))
    }
}

/// Asks for `history`; `AIHistoryPlugin` also asks for `ai`, and `NoHistoryPlugin` for nothing.
@MainActor
private class HistoryPlugin: BuiltInPlugin {
    class var id: PluginID { PluginID(rawValue: "org.example.history")! }
    class var permissions: Set<PluginPermission> { [.history] }
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "History", version: "1", summary: "", permissions: permissions, contributions: PluginContributions())
    }

    static var isOnByDefault: Bool { true }

    required init() {}

    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}
}

@MainActor
private final class AIHistoryPlugin: HistoryPlugin {
    override class var id: PluginID { PluginID(rawValue: "org.example.history-ai")! }
    override class var permissions: Set<PluginPermission> { [.history, .ai] }
}

@MainActor
private final class NoHistoryPlugin: HistoryPlugin {
    override class var id: PluginID { PluginID(rawValue: "org.example.no-history")! }
    override class var permissions: Set<PluginPermission> { [] }
}

@MainActor
@Suite struct PluginHistoryTests {
    private let folder = TemporaryFolder()
    private let persona = UUID()
    private let host = HistoryHost()

    private func manager(ai: AIService? = nil) -> PluginManager {
        PluginManager(persona: persona, directory: folder.url, builtIns: [HistoryPlugin.self, AIHistoryPlugin.self, NoHistoryPlugin.self], secretStore: MemorySecretStore(),
                      browserHost: host, ai: ai)
    }

    private func context(_ type: HistoryPlugin.Type, in manager: PluginManager) throws -> ScopedPluginContext {
        manager.makeContext(for: try #require(manager.plugins.first { $0.id == type.id }))
    }

    private static func page(_ address: String, title: String = "Page", visits: Int = 1) -> PluginHistoryEntry {
        PluginHistoryEntry(url: URL(string: address)!, title: title, lastVisit: Date(timeIntervalSince1970: 1_800_000_000), visitCount: visits)
    }

    private func writePackage(_ files: [String: String]) throws -> URL {
        let root = folder.url.appendingPathComponent("Packages/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    @Test func readsTheHistoryPermissionAndStatesIt() async throws {
        let manager = manager()
        defer { manager.close() }
        let package = try await manager.stage(try writePackage([
            "plugin.json": #"{"id": "org.example.searching", "name": "Searching", "version": "1", "apiVersion": 1, "summary": "Searches.", "permissions": ["history", "clipboard"]}"#,
        ]))
        #expect(package.manifest.permissions == [.history, .clipboard])
        #expect(PluginGrant(requestedBy: package.manifest).summaries == ["Write text to the clipboard", "Search your browsing history in this Persona"])
    }

    /// The search goes to the host for the manager's Persona with the limit kept from 0 to 100, needs `history`, and stops with the instance.
    @Test func aPluginSearchesItsPersonasHistoryUnderItsGrant() async throws {
        let manager = manager()
        defer { manager.close() }
        let docs = Self.page("https://docs.example/a", title: "Docs", visits: 3)
        host.pages[persona] = [docs, Self.page("https://mail.example/")]
        host.pages[UUID()] = [Self.page("https://docs.example/other")]
        let searching = try context(HistoryPlugin.self, in: manager)

        #expect(try await searching.history(matching: "docs", limit: 10) == [docs])
        #expect(try await searching.history(matching: "", limit: 1_000).count == 2)
        #expect(try await searching.history(matching: "", limit: -1).isEmpty)
        #expect(host.searches == [HistoryHost.Search(text: "docs", limit: 10, persona: persona), HistoryHost.Search(text: "", limit: PluginManager.historyLimit, persona: persona),
                                  HistoryHost.Search(text: "", limit: 0, persona: persona)])

        let refused = try context(NoHistoryPlugin.self, in: manager)
        await #expect(throws: PluginError.permissionDenied(.history)) { try await refused.history(matching: "", limit: 10) }
        searching.end()
        await #expect(throws: PluginError.stopped) { try await searching.history(matching: "", limit: 10) }
        #expect(host.searches.count == 3)
    }

    /// A plugin with `ai` gets no page on a site excluded from AI, and the pages after it fill its place; a plugin without `ai` gets them all.
    @Test func aPluginWithAIGetsNoPageOnASiteExcludedFromAI() async throws {
        let service = AIService(directory: folder.url.appendingPathComponent("AI", isDirectory: true))
        service.settings.excludedSites = [AISitePattern("private.example")]
        let manager = manager(ai: service)
        defer { manager.close() }
        let pages = [Self.page("https://private.example/inbox"), Self.page("https://a.example/"), Self.page("https://mail.private.example/"), Self.page("https://b.example/")]
        host.pages[persona] = pages

        #expect(try await context(AIHistoryPlugin.self, in: manager).history(matching: "", limit: 2).map(\.url) == [pages[1].url, pages[3].url])
        #expect(try await context(HistoryPlugin.self, in: manager).history(matching: "", limit: 2).map(\.url) == [pages[0].url, pages[1].url])
    }

    /// `arch.history.search(text, limit)` resolves with `{url, title, lastVisit, visitCount}` for each page, takes no limit or null as the most, and refuses a call it cannot read.
    @Test func aScriptPluginSearchesHistoryThroughArchHistory() async throws {
        let manager = manager()
        defer { manager.close() }
        host.pages[persona] = [Self.page("https://docs.example/a", title: "Docs A", visits: 4), Self.page("https://docs.example/b", title: "", visits: 2),
                               Self.page("https://mail.example/", title: "Mail")]
        let background = """
        arch.commands.onRun("search", async () => {
          const fail = async (call) => { try { await call(); return "resolved"; } catch (error) { return error.message; } };
          await arch.storage.set("results", {
            two: await arch.history.search("docs", 2),
            all: (await arch.history.search("")).length,
            nullLimit: (await arch.history.search("mail", null)).length,
            noText: await fail(() => arch.history.search()),
            notText: await fail(() => arch.history.search(1)),
            zero: await fail(() => arch.history.search("docs", 0)),
            fraction: await fail(() => arch.history.search("docs", 1.5)),
            textLimit: await fail(() => arch.history.search("docs", "2")),
          });
        });
        """
        let package = try await manager.stage(try writePackage([
            "plugin.json": #"{"id": "org.example.history-script", "name": "History Script", "version": "1", "apiVersion": 1, "summary": "Searches.", "permissions": ["history"], "background": "b.js", "contributes": {"commands": [{"id": "search", "title": "Search"}]}}"#,
            "b.js": background,
        ]))
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let installed = try #require(manager.plugins.first { $0.id.rawValue == "org.example.history-script" })
        let storage = manager.makeContext(for: installed).storage

        await manager.run(PluginCommandRef(plugin: installed.id, command: "search"), PluginInvocation(tab: nil))
        let lastVisit = PluginValue.string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(storage.value(forKey: "results") == .object([
            "two": .array([
                .object(["url": .string("https://docs.example/a"), "title": .string("Docs A"), "lastVisit": lastVisit, "visitCount": .number(4)]),
                .object(["url": .string("https://docs.example/b"), "title": .string(""), "lastVisit": lastVisit, "visitCount": .number(2)]),
            ]),
            "all": .number(3), "nullLimit": .number(1),
            "noText": .string("invalidCall"), "notText": .string("invalidCall"), "zero": .string("invalidCall"), "fraction": .string("invalidCall"), "textLimit": .string("invalidCall"),
        ]))
        #expect(host.searches.map(\.limit) == [2, PluginManager.historyLimit, PluginManager.historyLimit])
    }
}
