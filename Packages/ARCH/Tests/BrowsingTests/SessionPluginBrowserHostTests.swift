// The session's side of plugins' tab calls (`SessionPluginBrowserHost`, `docs/plugins.md`, Permissions): a tab that a plugin opens downloads no file that its address points at, and its pages' downloads ask until the user acts in it; a plugin's close posts the `plugin` reason with its cause and keeps ⌘Z to the user's own closes.
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

    /// A plugin's close of an open tab joins the closed list and posts `tabClosed` with the reason `plugin` and its cause, and ⌘Z then reopens none of the user's earlier closes, so it never reopens the plugin's tab in place of the user's; Reopen Last Closed Tab still does. A pinned tab that it unloads leaves the closed list and ⌘Z as they were.
    @Test func aPluginsCloseKeepsUndoCloseToTheUsersCloses() throws {
        try withSession { session, host in
            let space = try #require(session.spaces.first)
            let mine = session.openTab(url: URL(string: "https://example.org/mine"), in: space.id, select: false, engine: .webKit)
            let theirs = session.openTab(url: URL(string: "https://example.org/theirs"), in: space.id, select: false, engine: .webKit)
            let pinned = session.openTab(url: URL(string: "https://example.org/pinned"), in: space.id, pinned: true, select: false, engine: .webKit)
            var closes: [String] = []
            let subscription = session.events.subscribe(BrowserEventFilter()) { event in
                if case .tabClosed(let tab, let reason) = event.payload { closes.append("\(tab.id == theirs.id ? "theirs" : "other") \(reason.rawValue) \(event.cause == cause)") }
            }
            defer { subscription.cancel() }
            session.requestCloseTab(mine)
            #expect(session.undoableCloseCount == 1)
            host.closeTab(pinned.id, cause: cause)
            #expect(session.undoableCloseCount == 1 && session.tabs.contains { $0 === pinned })
            host.closeTab(theirs.id, cause: cause)
            #expect(session.undoableCloseCount == 0 && !session.tabs.contains { $0.id == theirs.id })
            #expect(closes == ["other user false", "theirs plugin true"])
            session.reopenLastClosedTab()
            #expect(session.tabs.contains { $0.id == theirs.id } && !session.tabs.contains { $0.id == mine.id })
        }
    }
}
