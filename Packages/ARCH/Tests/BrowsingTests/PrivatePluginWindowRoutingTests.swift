// Plugin and extension selections never use a private window's stale regular-space identity.
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct PrivatePluginWindowRoutingTests {
    private func withSession(_ check: (BrowserSession) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPrivatePluginWindows-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        defer { for window in session.windows { session.windowWillClose(window) } }
        try check(session)
    }

    @Test(arguments: [false, true])
    func pluginSelectionsSkipPrivateWindowsWithStaleSpaceIDs(webExtension: Bool) throws {
        try withSession { session in
            let space = try #require(session.spaces.first)
            let regular = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id,
                                                         selectedTabID: nil, isSidebarVisible: true), kind: .main)
            let tab = session.openTab(url: URL(string: "https://example.org/regular"), in: space.id, select: false)
            _ = session.plugins(in: space.resolvedPersonaID)
            let privateWindow = session.makePrivateWindow()
            let privateTab = try #require(session.openPrivateTab(url: URL(string: "https://example.org/private"), in: privateWindow))
            privateWindow.currentSpaceID = space.id

            if webExtension {
                session.webExtensionHost.activate(tab.webContents)
            } else {
                session.pluginBrowserHost.selectTab(tab.id, cause: BrowserEventCause(origin: .plugin(id: "test")))
            }

            #expect(regular.selectedTabID == tab.id)
            #expect(privateWindow.selectedTabID == privateTab.id)
            #expect(privateWindow.privateTabs.map(\.id) == [privateTab.id])
            #expect(tab.privateSessionID == nil && privateTab.isPrivate)
        }
    }

    @Test func aPluginCannotUseAPrivateWindowAsItsOnlyDestination() throws {
        try withSession { session in
            let space = try #require(session.spaces.first)
            let tab = session.openTab(url: URL(string: "https://example.org/regular"), in: space.id, select: false)
            let privateWindow = session.makePrivateWindow()
            let privateTab = try #require(session.openPrivateTab(url: URL(string: "https://example.org/private"), in: privateWindow))
            privateWindow.currentSpaceID = space.id

            session.pluginBrowserHost.selectTab(tab.id, cause: BrowserEventCause(origin: .plugin(id: "test")))

            #expect(session.windows.count == 1)
            #expect(privateWindow.selectedTabID == privateTab.id)
            #expect(session.window(showing: tab) == nil)
        }
    }
}
