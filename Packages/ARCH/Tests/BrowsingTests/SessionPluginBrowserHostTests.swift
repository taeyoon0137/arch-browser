// The session's side of plugins' tab calls (`SessionPluginBrowserHost`, `docs/plugins.md`, Permissions): a tab that a plugin opens downloads no file that its address points at, and its pages' downloads ask until the user acts in it.
import ARCHEngine
import Events
import Foundation
import Plugins
import Testing
@testable import Browsing

@MainActor @Suite struct SessionPluginBrowserHostTests {
    private let cause = BrowserEventCause(origin: .plugin(id: "org.example.managing"))

    private func withSession(_ check: (BrowserSession, SessionPluginBrowserHost) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPluginHost-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        registry.register(SessionTestEngine(kind: .chromium))
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        try check(session, session.pluginBrowserHost)
    }

    /// A plugin's tab whose address turns out to be a file downloads nothing, as a restored tab does not fetch its file again, while the user's own tab downloads it; the plugin's tab's pages ask before their first download.
    @Test func aTabThatAPluginOpensDownloadsNothingWithoutTheUser() throws {
        try withSession { session, host in
            let space = try #require(session.spaces.first)
            let file = try #require(URL(string: "https://example.org/a.bin"))
            let id = try #require(host.openTab(file, PluginOpenTabOptions(select: false), in: space.resolvedPersonaID, cause: cause))
            let opened = try #require(session.tabs.first { $0.id == id })
            #expect(opened.pageDownloads.isOpenedByPlugin)
            #expect(!opened.webContents(opened.webContents, shouldDownload: file, hasPage: false))
            let own = session.openTab(url: file, in: space.id, select: false, engine: .webKit)
            #expect(!own.pageDownloads.isOpenedByPlugin)
            #expect(own.webContents(own.webContents, shouldDownload: file, hasPage: false))
        }
    }
}
