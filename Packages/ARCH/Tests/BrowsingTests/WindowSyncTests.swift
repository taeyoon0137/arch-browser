// Every main window shows the one session's spaces, tabs, folders, and favorites (`docs/windows-personas.md`): a change made through one window reaches the lists that every other window's sidebar reads, on the same space and on another space of the Persona, and the session announces each change, which every window's sidebar views observe. Each window keeps its own selection and current space. The windows' AppKit windows are never ordered in.
import ARCHEngine
import Combine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct WindowSyncTests {
    /// Two main windows of one session on its first space, and a second space of the same Persona.
    private func withTwoWindows(_ check: (BrowserSession, BrowserWindowModel, BrowserWindowModel, Space, Space) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchWindowSync-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let other = session.makeSpace(in: space.resolvedPersonaID)
        let first = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let second = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { [first, second].forEach(session.windowWillClose) }
        try check(session, first, second, space, other)
    }

    /// The rows a window's sidebar shows for `space`, as `SpaceTabsView` reads them.
    private func rows(_ session: BrowserSession, _ window: BrowserWindowModel, in space: Space, pinned: Bool) -> [UUID] {
        session.folderTree.rows(in: space.id, pinned: pinned) { $0.id == window.selectedTabID }.map(\.id)
    }

    /// Counts the session's announcements, which the sidebar views of every window observe.
    private final class Announcements {
        var count = 0
        var observer: AnyCancellable?
    }

    private func announcements(of session: BrowserSession) -> Announcements {
        let counter = Announcements()
        counter.observer = session.objectWillChange.sink { [counter] in counter.count += 1 }
        return counter
    }

    @Test func tabsOpenCloseMoveAndPinInBothWindows() throws {
        try withTwoWindows { session, first, second, space, other in
            let changes = announcements(of: session)
            let a = session.openTab(url: URL(string: "https://example.org/a")!, in: space.id, select: false)
            first.selectTab(a.id)
            let b = session.openTab(url: URL(string: "https://example.org/b")!, in: space.id, select: false)
            second.selectTab(b.id)
            #expect(changes.count > 0)
            for window in [first, second] {
                #expect(rows(session, window, in: space, pinned: false) == [a.id, b.id])
            }
            // Each window keeps its own selection.
            #expect(first.selectedTabID == a.id && second.selectedTabID == b.id)

            changes.count = 0
            session.moveTab(b.id, to: a, after: false)
            #expect(changes.count > 0)
            for window in [first, second] { #expect(rows(session, window, in: space, pinned: false) == [b.id, a.id]) }

            changes.count = 0
            session.togglePinned(a)
            #expect(changes.count > 0)
            for window in [first, second] {
                #expect(rows(session, window, in: space, pinned: true) == [a.id])
                #expect(rows(session, window, in: space, pinned: false) == [b.id])
            }
            session.togglePinned(a)
            for window in [first, second] { #expect(rows(session, window, in: space, pinned: true).isEmpty) }

            // A window on another space of the Persona sees the move into its space.
            second.switchToSpace(other.id)
            #expect(second.currentSpaceID == other.id && first.currentSpaceID == space.id)
            changes.count = 0
            session.moveTab(a.id, toSpace: other.id)
            #expect(changes.count > 0)
            for window in [first, second] {
                #expect(rows(session, window, in: other, pinned: false) == [a.id])
                #expect(rows(session, window, in: space, pinned: false) == [b.id])
            }

            changes.count = 0
            #expect(session.closeTab(b))
            #expect(changes.count > 0)
            for window in [first, second] { #expect(rows(session, window, in: space, pinned: false).isEmpty) }
        }
    }

    @Test func aRenameShowsInBothWindows() throws {
        try withTwoWindows { session, first, second, space, _ in
            let tab = session.openTab(url: URL(string: "https://example.org/")!, in: space.id, select: false)
            var tabChanges = 0
            let observer = tab.objectWillChange.sink { tabChanges += 1 }
            defer { observer.cancel() }
            first.renameTab(tab.id, to: "Reading")
            // Each row observes its tab, in every window.
            #expect(tabChanges > 0 && tab.shownTitle == "Reading")
            #expect(second.session.tabs.first { $0.id == tab.id }?.shownTitle == "Reading")
        }
    }

    @Test func favoritesAddRemoveAndReorderInBothWindows() throws {
        try withTwoWindows { session, first, second, space, other in
            second.switchToSpace(other.id)
            let changes = announcements(of: session)
            let a = session.openTab(url: URL(string: "https://example.org/a")!, in: space.id, select: false)
            let b = session.openTab(url: URL(string: "https://example.org/b")!, in: space.id, select: false)
            session.addFavorite(a)
            session.addFavorite(b)
            #expect(changes.count > 0)
            // Both windows' Persona is the same, so both grids list the same favorites, on either space.
            #expect(first.personaID == second.personaID)
            let favorites = session.favorites(in: first.personaID)
            #expect(favorites.map(\.url.absoluteString) == ["https://example.org/a", "https://example.org/b"])
            #expect(session.favorites(in: second.personaID).map(\.id) == favorites.map(\.id))

            changes.count = 0
            session.moveFavorite(favorites[1].id, to: favorites[0])
            #expect(changes.count > 0)
            #expect(session.favorites(in: second.personaID).map(\.id) == [favorites[1].id, favorites[0].id])

            changes.count = 0
            session.removeFavorite(favorites[0])
            #expect(changes.count > 0)
            #expect(session.favorites(in: first.personaID).map(\.id) == [favorites[1].id])
            #expect(session.favorites(in: second.personaID).map(\.id) == [favorites[1].id])
        }
    }

    @Test func foldersCreateAndRenameInBothWindows() throws {
        try withTwoWindows { session, first, second, space, _ in
            let changes = announcements(of: session)
            first.addFolder(toSpace: space.id)
            let id = try #require(first.renamingFolderID)
            #expect(changes.count > 0)
            // Only the window that made the folder edits its name.
            #expect(second.renamingFolderID == nil)
            #expect(rows(session, second, in: space, pinned: true) == [id])
            changes.count = 0
            first.renameFolder(id, to: "Reading")
            #expect(changes.count > 0)
            #expect(session.folders.first { $0.id == id }?.name == "Reading")
        }
    }

    @Test func aSpaceSwitchStaysInItsWindow() throws {
        try withTwoWindows { session, first, second, space, other in
            let tab = session.openTab(url: URL(string: "https://example.org/")!, in: space.id, select: false)
            first.selectTab(tab.id)
            second.switchToSpace(other.id)
            #expect(first.currentSpaceID == space.id && first.selectedTabID == tab.id)
            #expect(second.currentSpaceID == other.id && second.selectedTabID == nil)
            // A space added through one window shows in the other's bottom bar.
            first.addSpace()
            #expect(session.spaces.count == 3 && second.currentSpaceID == other.id)
        }
    }

    /// A small window's tab stays out of every main window's list.
    @Test func aSmallWindowsTabStaysOutOfEveryList() throws {
        try withTwoWindows { session, first, second, space, _ in
            let small = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: false), kind: .small)
            defer { session.windowWillClose(small) }
            let tab = session.openTab(url: URL(string: "https://example.org/")!, in: space.id, select: false)
            tab.isInSmallWindow = true
            for window in [first, second] { #expect(!rows(session, window, in: space, pinned: false).contains(tab.id)) }
        }
    }
}
