// Add to Favorites and Remove from Favorites (`BrowserSession.addFavorite(_:)`, `docs/bookmarks.md`, Favorites): a tab of a space's list moves into the favorites with its page, and goes back to its space when the favorite is removed in the same session; a pinned tab's favorite takes its saved page's address; a small window's and an agent's tab keep their place, and the favorite gets a copy of the page.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct FavoriteMoveTests {
    /// A session in a new temporary folder, which the caller removes.
    private func makeSession() throws -> (BrowserSession, Space, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        return (session, try #require(session.spaces.first), directory)
    }

    private func tab(_ name: String, pinned: Bool = false, in session: BrowserSession, _ space: Space) -> Tab {
        let tab = session.openTab(url: URL(string: "about:blank#\(name)")!, in: space.id, select: false)
        if pinned { session.togglePinned(tab) }
        return tab
    }

    @Test func aMovedTabGoesBackToItsSpaceWhenItsFavoriteIsRemoved() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = tab("other", in: session, space), moved = tab("moved", in: session, space)
        let contents = moved.webContents
        session.addFavorite(moved)
        let favorite = try #require(session.favorites.last)
        #expect(!session.tabs.contains { $0 === moved } && session.openFavoriteTabs.contains { $0 === moved })
        #expect(moved.spaceID == nil)

        // Removing the favorite gives the tab, with its page, back to the end of its space's open tabs.
        session.removeFavorite(favorite)
        #expect(!session.favorites.contains { $0.id == favorite.id })
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [other.id, moved.id])
        #expect(moved.spaceID == space.id && moved.webContents === contents && !moved.isPinned)
        #expect(session.openFavoriteTabs.isEmpty)
    }

    @Test func aPinnedTabsFavoriteTakesItsSavedAddressAndTheTabReturnsPinned() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pinned = tab("pinned", pinned: true, in: session, space)
        // The tab has moved off its saved page.
        let saved = SavedPage(url: try #require(URL(string: "https://saved.example/home")), title: "Home")
        pinned.savedPage = saved
        #expect(pinned.url != saved.url)
        #expect(session.canAddFavorite(pinned))
        session.addFavorite(pinned)
        let favorite = try #require(session.favorites.last)
        #expect(favorite.url == saved.url)
        #expect(!pinned.isPinned)

        session.removeFavorite(favorite)
        #expect(pinned.isPinned && pinned.savedPage == saved)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).map(\.id) == [pinned.id])
    }

    @Test func aSmallWindowsTabAndAnAgentsTabAddACopy() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let small = tab("small", in: session, space)
        small.isInSmallWindow = true
        let agentTab = try #require(session.openAgentTab(url: URL(string: "about:blank#agent")!, engine: nil, owner: UUID(), folderName: "Task", in: space.id))

        for tab in [small, agentTab] {
            #expect(session.canAddFavorite(tab))
            session.addFavorite(tab)
            #expect(session.tabs.contains { $0 === tab } && !session.openFavoriteTabs.contains { $0 === tab })
            // Once its page is a favorite, the command is off.
            #expect(!session.canAddFavorite(tab))
        }
        #expect(session.favorites.map(\.url) == [small.url, agentTab.url])
        #expect(agentTab.agentOwnerID != nil && small.isInSmallWindow)
        // Removing a copy leaves the tab where it is.
        session.removeFavorite(try #require(session.favorites.first))
        #expect(session.tabs.contains { $0 === small })
    }

    @Test(arguments: [-3, 0, 1, 2, 3, 4, 5, 20])
    func aDroppedTabTakesAnyIndexAmongItsPersonasFavorites(index: Int) throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a", "b", "c", "d", "e"] { session.addFavorite(tab(name, in: session, space)) }
        let originals = session.favorites(in: space.resolvedPersonaID)
        let other = session.addPersona(named: "Other")
        let otherSpace = try #require(session.spaces(in: other.id).first)
        for name in ["foreign-a", "foreign-b"] { session.addFavorite(tab(name, in: session, otherSpace)) }
        let foreign = session.favorites(in: other.id)
        // The stored list may interleave Personas even though each grid shows only one.
        session.moveFavorite(foreign[0].id, to: originals[2])
        #expect(session.favorites.map(\.id) == [originals[0].id, originals[1].id, foreign[0].id, originals[2].id, originals[3].id, originals[4].id, foreign[1].id])

        let moved = tab("dropped", pinned: true, in: session, space)
        let saved = SavedPage(url: try #require(URL(string: "https://saved.example/drop")), title: "Saved")
        moved.savedPage = saved
        let contents = moved.webContents
        session.addFavorite(moved, at: index)
        let favorites = session.favorites(in: space.resolvedPersonaID)
        let destination = min(max(index, 0), originals.count)
        let inserted = favorites[destination]
        var expected = originals.map(\.id)
        expected.insert(inserted.id, at: destination)
        #expect(favorites.map(\.id) == expected)
        #expect(inserted.url == saved.url)
        #expect(session.favorites(in: other.id) == foreign)
        #expect(session.favoriteTabs[inserted.id] === moved && moved.webContents === contents)
        #expect(!session.tabs.contains { $0 === moved } && moved.spaceID == nil && !moved.isPinned)

        session.removeFavorite(inserted)
        #expect(session.favorites(in: space.resolvedPersonaID) == originals)
        #expect(moved.spaceID == space.id && moved.isPinned && moved.savedPage == saved && moved.webContents === contents)
    }

    @Test(arguments: 0..<5, 0..<5)
    func reorderingUsesTheIndexAmongTheRemainingFavorites(from: Int, to: Int) throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabs = ["a", "b", "c", "d", "e"].map { tab($0, in: session, space) }
        for tab in tabs { session.addFavorite(tab) }
        let originals = session.favorites(in: space.resolvedPersonaID)
        let other = session.addPersona(named: "Other")
        let otherSpace = try #require(session.spaces(in: other.id).first)
        for name in ["foreign-a", "foreign-b"] { session.addFavorite(tab(name, in: session, otherSpace)) }
        let foreign = session.favorites(in: other.id)
        session.moveFavorite(foreign[0].id, to: originals[2])

        session.moveFavorite(originals[from].id, toIndex: to)
        var expected = originals
        expected.insert(expected.remove(at: from), at: to)
        #expect(session.favorites(in: space.resolvedPersonaID) == expected)
        #expect(session.favorites(in: other.id) == foreign)
        #expect(session.favorites.count == originals.count + foreign.count)
        for (favorite, tab) in zip(originals, tabs) {
            #expect(session.favoriteTabs[favorite.id] === tab)
        }
        let settled = session.favorites
        session.moveFavorite(UUID(), toIndex: 0)
        #expect(session.favorites == settled)
    }

    @Test(arguments: [0, 1, 2], [false, true])
    func aCopiedPageTakesTheRequestedIndexWithoutMovingItsTab(index: Int, agent: Bool) throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["before", "after"] { session.addFavorite(tab(name, in: session, space)) }
        let originals = session.favorites
        let copied: Tab
        if agent {
            copied = try #require(session.openAgentTab(url: URL(string: "about:blank#agent-copy")!, engine: nil, owner: UUID(), folderName: "Task", in: space.id))
        } else {
            copied = tab("small-copy", in: session, space)
            copied.isInSmallWindow = true
        }
        let contents = copied.webContents
        session.addFavorite(copied, at: index)
        let inserted = session.favorites[index]
        var expected = originals
        expected.insert(inserted, at: index)
        #expect(session.favorites == expected && inserted.url == copied.url)
        #expect(session.tabs.contains { $0 === copied })
        #expect(copied.spaceID == space.id && copied.webContents === contents)
        #expect(session.favoriteTabs[inserted.id] == nil)
    }
}
