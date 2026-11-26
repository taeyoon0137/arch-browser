// Private pages never enter user-tab sharing, plugins, extensions, hooks, or AI page readers.
// An agent-created private page is listed only for its opener, without a space or Persona record.
import Agent
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct PrivateAgentTests {
    private func withSession(_ check: (BrowserSession) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPrivateAgentTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        defer { for window in session.windows { session.windowWillClose(window) } }
        try await check(session)
    }

    @Test func userPrivatePagesAreInvisibleToEveryBrowserHost() async throws {
        try await withSession { session in
            let host = BrowserAgentHost(session: session)
            let window = session.makePrivateWindow()
            let tab = try #require(session.openPrivateTab(url: URL(string: "https://example.org/private"), in: window))
            #expect(host.tabs(withIDs: [tab.id]).isEmpty)
            #expect(host.userTabs(in: Persona.defaultID).isEmpty)
            #expect(host.userTabs(in: tab.personaID).isEmpty)
            #expect(host.agentTabs(of: UUID()).isEmpty)
            #expect(!host.personas.contains { $0.id == tab.personaID })
            #expect(host.spaces(in: tab.personaID).isEmpty)

            var refusedRead = false
            host.readableContent(of: tab.id, limit: 100) { if case .failure = $0 { refusedRead = true } }
            #expect(refusedRead)
            var refusedScript = false
            host.runPageScript("document.title", world: "test", in: tab.id) { if case .failure = $0 { refusedScript = true } }
            #expect(refusedScript)
            var refusedCapture = false
            host.capture(tab.id, fullPage: false) { refusedCapture = $0 == nil }
            #expect(refusedCapture && host.trustedInput(of: tab.id) == nil)

            let hooks = BrowserHookHost(session: session)
            #expect(hooks.tab(tab.id) == nil && hooks.closingTab(tab.id) == nil)
            #expect(hooks.tabs(inPersona: tab.personaID).isEmpty)
            let plugins = session.pluginBrowserHost
            #expect(plugins.tabs(in: tab.personaID).isEmpty)
            #expect(plugins.webContents(forTab: tab.id) == nil)
            #expect(plugins.selectedTab(in: tab.personaID) == nil)
            #expect(!plugins.renameTab(tab.id, to: "Leaked", showing: tab.url, cause: BrowserEventCause(origin: .plugin(id: "test")), applying: true))
            #expect(!plugins.setPinned(true, tab: tab.id, cause: BrowserEventCause(origin: .plugin(id: "test"))))
            plugins.closeTab(tab.id, cause: BrowserEventCause(origin: .plugin(id: "test")))
            #expect(session.allTabs.contains { $0.id == tab.id })
            #expect(tab.receivePageScriptMessage == nil && tab.addPluginMenuItems == nil && tab.askAboutSelection == nil)

            let reader = TabPageSource()
            reader.session = session
            await #expect(throws: EngineReadableContentError.self) { try await reader.content(ofTab: tab.id, limit: 100) }
            #expect(!BrowserHooks.suggest("Leaked", for: try #require(tab.url), to: tab, applying: true))
        }
    }

    @Test func eachAgentListsOnlyItsOwnPrivatePages() async throws {
        try await withSession { session in
            let host = BrowserAgentHost(session: session)
            let owner = UUID(), otherOwner = UUID()
            let first = session.makePrivateWindow(ownerID: owner)
            let second = session.makePrivateWindow(ownerID: otherOwner)
            let firstTab = try #require(session.openPrivateTab(url: URL(string: "https://example.org/first"), in: first, ownerID: owner))
            let secondTab = try #require(session.openPrivateTab(url: URL(string: "https://example.org/second"), in: second, ownerID: otherOwner))
            let mine = try #require(host.agentTabs(of: owner).first)
            #expect(mine.id == firstTab.id && mine.isPrivate && mine.spaceID == nil && mine.agentOwnerID == owner)
            #expect(host.agentTabs(of: owner).count == 1)
            #expect(host.agentTabs(of: otherOwner).map(\.id) == [secondTab.id])
            #expect(host.userTabs(in: firstTab.personaID).isEmpty)
            #expect(session.pluginBrowserHost.webContents(forTab: firstTab.id) == nil)
            #expect(session.pluginBrowserHost.webContents(forTab: secondTab.id) == nil)
            #expect(firstTab.receivePageScriptMessage == nil && secondTab.receivePageScriptMessage == nil)
        }
    }

    @Test(arguments: [false, true])
    func webExtensionsCannotReachOrActivatePrivatePages(agentOwned: Bool) async throws {
        try await withSession { session in
            let regular = session.openTab(url: URL(string: "https://example.org/regular"), select: false)
            _ = session.plugins(in: regular.personaID)
            let extensions = session.webExtensionHost
            #expect(extensions.webContents(ofTab: regular.id) === regular.webContents)
            let owner: UUID? = agentOwned ? UUID() : nil
            let window = session.makePrivateWindow(ownerID: owner)
            let first = try #require(session.openPrivateTab(url: URL(string: "https://example.org/private-first"), in: window, ownerID: owner))
            let selected = try #require(session.openPrivateTab(url: URL(string: "https://example.org/private-selected"), in: window, ownerID: owner))
            #expect(extensions.webContents(ofTab: first.id) == nil)
            #expect(extensions.webContents(ofTab: selected.id) == nil)
            extensions.activate(first.webContents)
            #expect(window.selectedTabID == selected.id)
            extensions.close(first.webContents)
            #expect(window.privateTabs.contains { $0.id == first.id })
            #expect(window.selectedTabID == selected.id)
        }
    }
}
