// Add to Favorites and Remove from Favorites (`BrowserSession.addFavorite(_:)`, `docs/bookmarks.md`, Favorites): a tab of a space's list moves into the favorites with its page, and goes back to its space when the favorite is removed in the same session; a pinned tab's favorite takes its saved page's address; a small window's, a live folder item's, and an agent's tab keep their place, and the favorite gets a copy of the page.
import ARCHEngine
import Foundation
import LiveFolders
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

    @Test func aSmallWindowsTabALiveItemsTabAndAnAgentsTabAddACopy() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let small = tab("small", in: session, space)
        small.isInSmallWindow = true
        let folder = session.makeFolder(in: space.id, pinned: true)
        session.updateFolder(folder.id) { $0.live = LiveFolderConfiguration(source: .feed(address: URL(string: "https://fixture.invalid/feed.xml")!, isPrivate: true)) }
        let item = LiveItem(id: "a", url: URL(string: "https://fixture.invalid/a")!, title: "Item a")
        let itemTab = session.openTab(url: item.url, in: space.id, pinned: true, select: false)
        LiveFolderTabs.prepare(itemTab, as: item, inFolder: folder.id)
        let agentTab = try #require(session.openAgentTab(url: URL(string: "about:blank#agent")!, engine: nil, owner: UUID(), folderName: "Task", in: space.id))

        for tab in [small, itemTab, agentTab] {
            #expect(session.canAddFavorite(tab))
            session.addFavorite(tab)
            #expect(session.tabs.contains { $0 === tab } && !session.openFavoriteTabs.contains { $0 === tab })
            // Once its page is a favorite, the command is off.
            #expect(!session.canAddFavorite(tab))
        }
        #expect(session.favorites.map(\.url) == [small.url, item.url, agentTab.url])
        #expect(itemTab.folderID == folder.id && agentTab.agentOwnerID != nil && small.isInSmallWindow)
        // Removing a copy leaves the tab where it is.
        session.removeFavorite(try #require(session.favorites.first))
        #expect(session.tabs.contains { $0 === small })
    }
}
