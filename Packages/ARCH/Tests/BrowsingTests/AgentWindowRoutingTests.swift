// A conversation chosen in another Persona stays in its invoking window. Its tab buttons follow the tab's place.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct AgentWindowRoutingTests {
    private func withWindows(_ check: (BrowserSession, BrowserWindowModel, BrowserWindowModel, Space, Space) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchAgentWindows-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("session.unreadable.json"))
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(registry: registry, userDataDirectory: directory, builtInPlugins: [], cefVersion: nil)
        let home = try #require(session.spaces.first)
        let work = session.addPersona(named: "Work")
        let research = try #require(session.spaces(in: work.id).first)
        let main = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let small = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: research.id, selectedTabID: nil, isSidebarVisible: false), kind: .small)
        defer {
            for window in [main, small] where session.windows.contains(where: { $0 === window }) { session.windowWillClose(window) }
        }
        // Record native window raise requests without bringing a test process to the front.
        let mainWindow = WindowSpy(), smallWindow = WindowSpy()
        mainWindow.isReleasedWhenClosed = false
        smallWindow.isReleasedWhenClosed = false
        main.nsWindow = mainWindow
        small.nsWindow = smallWindow
        let ordinary = session.openTab(url: URL(string: "about:blank#home"), in: home.id, select: false, engine: .webKit)
        main.selectTab(ordinary.id)
        let popup = session.openTab(url: URL(string: "about:blank#popup"), in: research.id, select: false, engine: .webKit)
        popup.isInSmallWindow = true
        small.selectTab(popup.id)
        try withExtendedLifetime((mainWindow, smallWindow)) { try check(session, main, small, home, research) }
    }

    @Test func remoteConversationStaysHereWhileItsTabsRouteToTheRightWindowAndPersona() throws {
        try withWindows { session, main, small, home, research in
            let mainWindow = try #require(main.nsWindow as? WindowSpy), smallWindow = try #require(small.nsWindow as? WindowSpy)
            let homeTab = try #require(main.selectedTab), popup = try #require(small.selectedTab)
            let remoteConversation = UUID()
            // This is the route shared by a palette session row and the running-agents menu.
            main.showAgentSession(remoteConversation)
            #expect(main.agentPanel == .session(remoteConversation) && main.currentSpaceID == home.id && main.selectedTab === homeTab)
            main.showAgentTab(popup.id)
            #expect(smallWindow.raises == 1 && mainWindow.raises == 0)
            #expect(main.selectedTab === homeTab && main.currentSpaceID == home.id && small.selectedTab === popup)
            small.showAgentSession(remoteConversation)
            let favorite = Favorite(url: URL(string: "https://fixture.invalid/research")!, title: "Research", personaID: research.resolvedPersonaID)
            session.addFavorites([favorite], in: research.resolvedPersonaID)
            let favoriteTab = session.openTab(for: favorite)
            small.showAgentTab(favoriteTab.id)
            #expect(mainWindow.raises == 1 && main.selectedTab === favoriteTab)
            #expect(main.currentSpaceID == research.id && main.personaID == favoriteTab.personaID)
            #expect(small.selectedTab === popup && small.agentPanel == .session(remoteConversation))
            main.showAgentTab(homeTab.id)
            #expect(main.selectedTab === homeTab && main.currentSpaceID == home.id)
            main.showAgentTab(favoriteTab.id)
            #expect(main.currentSpaceID == research.id && main.selectedTab === favoriteTab)
            main.showAgentTab(UUID())
            #expect(main.selectedTab === favoriteTab && main.agentPanel == .session(remoteConversation))
        }
    }

    enum MainPanel: CaseIterable { case closed, draft, conversation }

    @Test(arguments: MainPanel.allCases) func movingAPopupCarriesItsSessionIntoAnEmptyPanel(existing: MainPanel) throws {
        try withWindows { session, main, small, _, research in
            let popup = try #require(small.selectedTab)
            switch existing {
            case .closed: break
            case .draft: main.showAgentComposer(text: "An unfinished draft")
            case .conversation: main.showAgentSession(UUID())
            }
            let original = main.agentPanel
            let id = UUID()
            small.showAgentSession(id)
            session.moveToMainWindow(small)
            #expect(main.selectedTab === popup && !popup.isInSmallWindow && main.currentSpaceID == research.id)
            #expect(main.agentPanel == (original ?? .session(id)))
            #expect((main.nsWindow as? WindowSpy)?.raises == 1)
        }
    }

    private final class WindowSpy: NSWindow {
        var raises = 0
        override func makeKeyAndOrderFront(_ sender: Any?) { raises += 1 }
    }
}
