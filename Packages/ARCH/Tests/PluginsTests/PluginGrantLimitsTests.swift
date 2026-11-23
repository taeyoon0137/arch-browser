// What row 50's completion asks of plugins beyond their calls (`docs/plugins.md`, Permissions and Personas): each Persona's manager keeps its own installed plugins, `downloads` reads its Persona's download metadata only, `notifications` posts at most once every 10 seconds per plugin, and a revoke in Settings ▸ Plugins removes one part of an installed plugin's grant in its Persona, in the file too.
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Plugins

/// Each Persona's downloads, and the notifications the plugins posted.
@MainActor
private final class GrantLimitsHost: PluginBrowserHost {
    struct Post: Equatable {
        var pluginName: String
        var title: String
        var body: String
    }

    var downloads: [PersonaID: [PluginDownload]] = [:]
    private(set) var posts: [Post] = []

    func tabs(in persona: PersonaID) -> [PluginTab] { [] }
    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool { false }
    func webContents(forTab id: UUID) -> (any EngineWebContents)? { nil }
    func selectedTab(in persona: PersonaID) -> UUID? { nil }
    func openTab(_ url: URL, _ options: PluginOpenTabOptions, in persona: PersonaID, cause: BrowserEventCause) throws -> UUID { throw PluginError.closed }
    func closeTab(_ id: UUID, cause: BrowserEventCause) {}
    func selectTab(_ id: UUID, cause: BrowserEventCause) {}
    func moveTab(_ id: UUID, to place: PluginTabPlace, cause: BrowserEventCause) throws -> Bool { false }
    func downloads(in persona: PersonaID) -> [PluginDownload] { downloads[persona] ?? [] }
    func postNotification(pluginName: String, title: String, body: String) { posts.append(Post(pluginName: pluginName, title: title, body: body)) }
}

/// Asks for `downloads` and `notifications`; `QuietPlugin` asks for nothing.
@MainActor
private class NoticePlugin: BuiltInPlugin {
    class var id: PluginID { PluginID(rawValue: "org.example.notice")! }
    class var name: String { "Notice" }
    class var permissions: Set<PluginPermission> { [.downloads, .notifications] }
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: name, version: "1", summary: "", permissions: permissions, contributions: PluginContributions())
    }

    static var isOnByDefault: Bool { true }

    required init() {}

    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}
}

@MainActor
private final class OtherNoticePlugin: NoticePlugin {
    override class var id: PluginID { PluginID(rawValue: "org.example.other-notice")! }
    override class var name: String { "Other Notice" }
}

@MainActor
private final class QuietPlugin: NoticePlugin {
    override class var id: PluginID { PluginID(rawValue: "org.example.quiet")! }
    override class var permissions: Set<PluginPermission> { [] }
}

@MainActor
@Suite(.serialized) struct PluginGrantLimitsTests {
    private let folder = TemporaryFolder()
    private let host = GrantLimitsHost()

    private func manager(persona: PersonaID = UUID(), _ builtIns: [any BuiltInPlugin.Type] = []) -> PluginManager {
        PluginManager(persona: persona, directory: folder.url, builtIns: builtIns, secretStore: MemorySecretStore(), browserHost: host)
    }

    private func context(_ plugin: NoticePlugin.Type, in manager: PluginManager) throws -> ScopedPluginContext {
        manager.makeContext(for: try #require(manager.plugins.first { $0.id == plugin.id }))
    }

    /// Stages and installs, enabled, a script plugin that asks for `downloads`, `notifications`, and two sites.
    private func install(in manager: PluginManager) async throws -> InstalledPlugin {
        let root = folder.url.appendingPathComponent("Packages/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = #"{"id": "org.example.granted", "name": "Granted", "version": "1", "apiVersion": 1, "summary": "Reads.", "permissions": ["downloads", "notifications"], "sites": ["https://example.org/*", "https://example.net/*"], "background": "b.js"}"#
        try Data(manifest.utf8).write(to: root.appendingPathComponent("plugin.json"))
        try Data().write(to: root.appendingPathComponent("b.js"))
        let package = try await manager.stage(root)
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        return try #require(manager.plugins.first { $0.id == package.manifest.id })
    }

    @Test func eachPersonaKeepsItsOwnInstalledPlugins() async throws {
        let (first, second) = (UUID(), UUID())
        let installed = try await install(in: manager(persona: first))
        #expect(manager(persona: first).plugins.map(\.id) == [installed.id])
        #expect(manager(persona: second).plugins.isEmpty)
        // The other Persona installs the same package on its own, with a grant of its own.
        let other = manager(persona: second)
        _ = try await install(in: other)
        other.revoke(.downloads, from: installed.id)
        #expect(manager(persona: first).plugins.first?.grant.permissions == [.downloads, .notifications])
        #expect(manager(persona: second).plugins.first?.grant.permissions == [.notifications])
    }

    @Test func downloadsReadOnlyTheMetadataOfThePluginsPersona() throws {
        let persona = UUID()
        let own = PluginDownload(id: UUID(), name: "report.pdf", state: "completed", completedBytes: 2048, totalBytes: 2048)
        host.downloads = [persona: [own], UUID(): [PluginDownload(id: UUID(), name: "other.zip", state: "inProgress", completedBytes: 1, totalBytes: 10)]]
        let manager = manager(persona: persona, [NoticePlugin.self, QuietPlugin.self])
        #expect(try context(NoticePlugin.self, in: manager).downloads() == [own])
        #expect(throws: PluginError.permissionDenied(.downloads)) { try context(QuietPlugin.self, in: manager).downloads() }
        // What a script plugin's `arch.downloads.list()` gets names no path, folder, or contents.
        guard case let .object(value) = own.scriptValue else { Issue.record("not an object"); return }
        #expect(Set(value.keys) == ["id", "name", "state", "completedBytes", "totalBytes"])
        #expect(value["name"] == .string("report.pdf") && value["completedBytes"] == .number(2048))
    }

    @Test func notificationsPostAtMostOnceEveryTenSecondsForEachPlugin() throws {
        let manager = manager([NoticePlugin.self, OtherNoticePlugin.self, QuietPlugin.self])
        let notice = try context(NoticePlugin.self, in: manager)
        try notice.notify(title: "First", body: "Posted.")
        try notice.notify(title: "Second", body: "Ignored.")
        try context(NoticePlugin.self, in: manager).notify(title: "Third", body: "Ignored by a context of its own too.")
        // Another plugin's limit is its own.
        try context(OtherNoticePlugin.self, in: manager).notify(title: String(repeating: "t", count: 150), body: String(repeating: "b", count: 600))
        #expect(throws: PluginError.permissionDenied(.notifications)) { try context(QuietPlugin.self, in: manager).notify(title: "No", body: "Refused.") }
        #expect(host.posts == [GrantLimitsHost.Post(pluginName: "Notice", title: "First", body: "Posted."),
                               GrantLimitsHost.Post(pluginName: "Other Notice", title: String(repeating: "t", count: 100), body: String(repeating: "b", count: 500))])
    }

    @Test func aSwitchedOffPluginPostsNothing() throws {
        let manager = manager([NoticePlugin.self])
        let notice = try context(NoticePlugin.self, in: manager)
        manager.setEnabled(false, for: NoticePlugin.id)
        try? notice.notify(title: "Off", body: "Not posted.")
        #expect(host.posts.isEmpty)
    }

    @Test func aRevokeRemovesOnePartOfTheGrantInItsPersona() async throws {
        let persona = UUID()
        let manager = manager(persona: persona)
        let installed = try await install(in: manager)
        #expect(installed.revocablePermissions == [.downloads, .notifications])
        manager.revoke(.downloads, from: installed.id)
        manager.revoke(try MatchPattern("https://example.net/*"), from: installed.id)
        let revoked = try #require(manager.plugins.first)
        let kept = try MatchPattern("https://example.org/*")
        #expect(revoked.grant.permissions == [.notifications] && revoked.grant.sites == [kept])
        // Later calls that need the revoked part refuse; the rest go on.
        #expect(throws: PluginError.permissionDenied(.downloads)) { try manager.makeContext(for: revoked).downloads() }
        try manager.makeContext(for: revoked).notify(title: "Still", body: "Allowed.")
        #expect(host.posts.map(\.title) == ["Still"])
        // `plugins.json` keeps the narrower grant for the next launch.
        #expect(self.manager(persona: persona).plugins.first?.grant == revoked.grant)
    }

    @Test func aBuiltInPluginKeepsItsCompiledGrant() throws {
        let manager = manager([NoticePlugin.self])
        manager.revoke(.downloads, from: NoticePlugin.id)
        #expect(manager.plugins.first?.grant.permissions == [.downloads, .notifications])
    }
}
