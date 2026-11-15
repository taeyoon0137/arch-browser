// The session's side of plugins' tab calls (`SessionPluginBrowserHost`, `docs/plugins.md`, Permissions and Personas): a tab that a plugin opens goes to the preferred or the named space of its Persona in its engine, and its opening, selection, and first load carry the plugin's cause; a selection goes to the window of the tab's Persona that shows it, else the front main window on its space, else the front main window of its Persona, and never to a window of another Persona; a tab that a plugin opens downloads no file that its address points at, and its pages' downloads ask until the user acts in it; a plugin's close posts the `plugin` reason with its cause and keeps ⌘Z to the user's own closes; an open names a space of another Persona as not granted and a deleted Persona as closed; and a selection of the tab that a window has selected already leaves the window's internal page and palette.
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

    /// A tab that a plugin opens goes where a new tab of its Persona goes, the last main window's space while that is the Persona's, else the Persona's first space, or to the space the options name, in their engine, and is selected in a window of its Persona only. Its opening, its selection with the space switch it brings, and its first load carry the plugin's cause, and its next load none; so do a close and the selection that it moves to another tab.
    @Test func aPluginsTabOpensInItsPersonasSpaceWithItsCause() throws {
        try withSession { session, host in
            let home = try #require(session.spaces.first)
            let side = session.makeSpace(in: home.resolvedPersonaID)
            let work = session.addPersona(named: "Work")
            let research = try #require(session.spaces(in: work.id).first)
            let workWindow = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: research.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            let homeWindow = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            defer { [homeWindow, workWindow].forEach(session.windowWillClose) }
            var events: [String] = []
            let subscription = session.events.subscribe(BrowserEventFilter()) { event in events.append("\(event.kind.rawValue) \(event.cause == cause)") }
            defer { subscription.cancel() }
            let address = try #require(URL(string: "https://example.org/opened"))

            let openedID = try host.openTab(address, PluginOpenTabOptions(engine: .chromium), in: home.resolvedPersonaID, cause: cause)
            let opened = try #require(session.tabs.first { $0.id == openedID })
            #expect(opened.spaceID == home.id && opened.engineKind == .chromium && homeWindow.selectedTabID == opened.id)
            opened.webContentsDidFinishLoadingDocument(opened.webContents)
            #expect(events.filter { !$0.hasPrefix("titleChanged") } == ["tabOpened true", "tabSelected true", "pageLoaded true"])
            events = []
            opened.webContentsDidFinishLoadingDocument(opened.webContents)
            #expect(events == ["pageLoaded false"])

            let behind = try host.openTab(address, PluginOpenTabOptions(spaceID: side.id, select: false), in: home.resolvedPersonaID, cause: cause)
            #expect(session.tabs.first { $0.id == behind }?.spaceID == side.id && homeWindow.selectedTabID == opened.id)
            // The front main window is the home Persona's, so the work Persona's tab opens in its first space, in the window on it.
            let workTab = try host.openTab(address, PluginOpenTabOptions(), in: work.id, cause: cause)
            #expect(session.tabs.first { $0.id == workTab }?.spaceID == research.id && workWindow.selectedTabID == workTab)
            #expect(homeWindow.selectedTabID == opened.id && homeWindow.currentSpaceID == home.id)
            events = []
            host.selectTab(behind, cause: cause)
            #expect(homeWindow.selectedTabID == behind && homeWindow.currentSpaceID == side.id)
            #expect(events == ["tabSelected true", "spaceSwitched true"])
            // The window that showed a tab that the plugin closes selects another with the plugin's cause too.
            let neighbor = session.openTab(url: address, in: side.id, select: false, engine: .webKit)
            events = []
            host.closeTab(behind, cause: cause)
            #expect(homeWindow.selectedTabID == neighbor.id)
            #expect(events == ["tabClosed true", "tabSelected true"])
        }
    }

    /// A selection goes to the window of the tab's Persona that shows it, else to the front main window on its space, else to the front main window of its Persona, which then shows the tab's space; a favorite's tab of another Persona goes to that Persona's window, so the front window keeps its Persona / Space, and without a window of the Persona nothing changes.
    @Test func aPluginsSelectionStaysInAWindowOfTheTabsPersona() throws {
        try withSession { session, host in
            let home = try #require(session.spaces.first)
            let side = session.makeSpace(in: home.resolvedPersonaID)
            let work = session.addPersona(named: "Work")
            let research = try #require(session.spaces(in: work.id).first)
            let travel = session.addPersona(named: "Travel")
            let trip = try #require(session.spaces(in: travel.id).first)
            let workWindow = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: research.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            let behindWindow = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            let frontWindow = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            defer { [frontWindow, behindWindow, workWindow].forEach(session.windowWillClose) }
            @MainActor func tab(in space: Space) -> Tab { session.openTab(url: URL(string: "https://example.org/\(UUID())"), in: space.id, select: false, engine: .webKit) }
            let shownBehind = tab(in: home), inHome = tab(in: home), inSide = tab(in: side), inTrip = tab(in: trip)
            behindWindow.selectTab(shownBehind.id)
            let frontSelection = frontWindow.selectedTabID

            // The window that shows the tab keeps it, and the front window on its space does not take it.
            host.selectTab(shownBehind.id, cause: cause)
            #expect(frontWindow.selectedTabID == frontSelection && behindWindow.selectedTabID == shownBehind.id)
            host.selectTab(inHome.id, cause: cause)
            #expect(frontWindow.selectedTabID == inHome.id && behindWindow.selectedTabID == shownBehind.id)
            // No window shows the side space, so the front main window of the Persona moves there.
            host.selectTab(inSide.id, cause: cause)
            #expect(frontWindow.selectedTabID == inSide.id && frontWindow.currentSpaceID == side.id && behindWindow.currentSpaceID == home.id)

            // A favorite's tab of the work Persona goes to the work window, though the front window is in front.
            let favorite = Favorite(url: URL(string: "https://example.org/favorite")!, title: "Favorite", personaID: work.id)
            session.addFavorites([favorite], in: work.id)
            let favoriteTab = session.openTab(for: favorite)
            host.selectTab(favoriteTab.id, cause: cause)
            #expect(workWindow.selectedTabID == favoriteTab.id && workWindow.personaID == work.id)
            #expect(frontWindow.selectedTabID == inSide.id && frontWindow.personaID == home.resolvedPersonaID)
            // No window of the travel Persona is open, so nothing changes.
            host.selectTab(inTrip.id, cause: cause)
            #expect([frontWindow, behindWindow, workWindow].map(\.selectedTabID) == [inSide.id, shownBehind.id, favoriteTab.id])
            #expect(frontWindow.currentSpaceID == side.id && workWindow.currentSpaceID == research.id)
        }
    }

    /// A plugin's tab whose address turns out to be a file downloads nothing, as a restored tab does not fetch its file again, while the user's own tab downloads it; the plugin's tab's pages ask before their first download.
    @Test func aTabThatAPluginOpensDownloadsNothingWithoutTheUser() throws {
        try withSession { session, host in
            let space = try #require(session.spaces.first)
            let file = try #require(URL(string: "https://example.org/a.bin"))
            let id = try host.openTab(file, PluginOpenTabOptions(select: false), in: space.resolvedPersonaID, cause: cause)
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

    /// An open in a space of another Persona is not granted, and one for a Persona that is gone is closed, whether or not it names a space, and neither opens a tab.
    @Test func anOpenTellsAForeignSpaceFromAPersonaThatIsGone() throws {
        try withSession { session, host in
            let home = try #require(session.spaces.first)
            let work = session.addPersona(named: "Work")
            let research = try #require(session.spaces(in: work.id).first)
            let address = try #require(URL(string: "https://example.org/"))
            let count = session.allTabs.count
            #expect(throws: PluginError.notGranted(research.id)) {
                _ = try host.openTab(address, PluginOpenTabOptions(spaceID: research.id, select: false), in: home.resolvedPersonaID, cause: cause)
            }
            session.deletePersona(work.id)
            #expect(throws: PluginError.closed) { _ = try host.openTab(address, PluginOpenTabOptions(select: false), in: work.id, cause: cause) }
            #expect(throws: PluginError.closed) {
                _ = try host.openTab(address, PluginOpenTabOptions(spaceID: research.id, select: false), in: work.id, cause: cause)
            }
            #expect(session.allTabs.count == count)
        }
    }

    /// A plugin's selection of the tab that the window has selected already leaves the internal page and the palette that the user has open there, while one of another tab selects it as any selection does.
    @Test func selectingTheSelectedTabLeavesTheWindowAsItIs() throws {
        try withSession { session, host in
            let space = try #require(session.spaces.first)
            let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            defer { session.windowWillClose(window) }
            let shown = session.openTab(url: URL(string: "https://example.org/shown"), in: space.id, select: false, engine: .webKit)
            let other = session.openTab(url: URL(string: "https://example.org/other"), in: space.id, select: false, engine: .webKit)
            window.selectTab(shown.id)
            window.showCommandPalette(.newTab)
            window.submitCommandPalette("flags://")
            window.showCommandPalette(.newTab)
            #expect(window.internalPage != nil && window.commandPaletteMode == .newTab)
            host.selectTab(shown.id, cause: cause)
            #expect(window.selectedTabID == shown.id && window.internalPage != nil && window.commandPaletteMode == .newTab)
            host.selectTab(other.id, cause: cause)
            #expect(window.selectedTabID == other.id && window.internalPage == nil && window.commandPaletteMode == nil)
        }
    }
}
