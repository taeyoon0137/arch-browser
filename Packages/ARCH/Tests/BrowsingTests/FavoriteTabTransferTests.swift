// A favorite dropped into a space's tab list keeps its page and takes that list's pinned state.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct FavoriteTabTransferTests {
    private func withSession(_ snapshot: SessionSnapshot? = nil, _ check: (BrowserSession, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFavoriteTransfer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if let snapshot { try SessionStore(directory: directory, seal: .fixture).saveNow(snapshot).get() }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        try check(BrowserSession(testRegistry: registry, directory: directory), directory)
    }

    @Test(arguments: [false, true], [false, true])
    func aLiveFavoriteKeepsItsTabAndPageInEitherList(pinned: Bool, anotherSpace: Bool) throws {
        try withSession { session, directory in
            let source = try #require(session.spaces.first)
            let destination = anotherSpace ? session.makeSpace(in: source.resolvedPersonaID) : source
            let tab = session.openTab(url: URL(string: "https://example.org/current")!, in: source.id, select: false)
            session.togglePinned(tab)
            let saved = SavedPage(url: URL(string: "https://example.org/saved")!, title: "Saved page")
            tab.savedPage = saved
            let page = tab.webContents
            session.addFavorite(tab)
            let favorite = try #require(session.favorites.first)
            let moved = try #require(session.moveFavoriteToTab(favorite, in: destination, pinned: pinned))

            #expect(moved === tab && moved.webContents === page)
            #expect(moved.url == URL(string: "https://example.org/current"))
            #expect(moved.spaceID == destination.id && moved.personaID == destination.resolvedPersonaID)
            #expect(moved.isPinned == pinned && moved.folderID == nil)
            #expect(moved.savedPage == (pinned ? SavedPage(url: favorite.url, title: favorite.title) : nil))
            #expect(session.tabsOutsideFolders(in: destination.id, pinned: pinned).map(\.id) == [tab.id])
            #expect(session.favorites.isEmpty && session.favoriteTabs.isEmpty)
            #expect(!session.hasTab(favorite))
            #expect(session.moveFavoriteToTab(favorite, in: destination, pinned: pinned) == nil)
            try session.saveNow().get()
            let stored = try #require(SessionStore(directory: directory, seal: .fixture).load())
            #expect(stored.favorites.isEmpty && stored.favoriteTabs?.isEmpty != false)
            #expect(stored.tabs.first?.id == tab.id && stored.tabs.first?.spaceID == destination.id)
        }
    }

    @Test(arguments: [false, true])
    func anUnopenedFavoriteBecomesATabOnlyOnTransfer(pinned: Bool) throws {
        try withSession { session, _ in
            let space = try #require(session.spaces.first)
            let favorite = Favorite(url: URL(string: "https://example.org/unopened")!, title: "Unopened", personaID: space.resolvedPersonaID)
            session.addFavorites([favorite], in: space.resolvedPersonaID)
            #expect(session.favoriteTabs.isEmpty && session.tabs.isEmpty)
            let tab = try #require(session.moveFavoriteToTab(favorite, in: space, pinned: pinned))
            #expect(tab.url == favorite.url && tab.isPinned == pinned)
            #expect(tab.savedPage == (pinned ? SavedPage(url: favorite.url, title: favorite.title) : nil))
            #expect(session.tabs.map(\.id) == [tab.id] && session.favorites.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func aSavedFavoriteRestoresItsTabAtItsCurrentAddress(pinned: Bool) throws {
        var snapshot = SessionSnapshot.empty.normalized()
        let space = try #require(snapshot.spaces.first)
        let favorite = Favorite(url: URL(string: "https://example.org/saved")!, title: "Saved", personaID: space.resolvedPersonaID)
        let id = UUID(), currentURL = URL(string: "https://example.org/current")!
        snapshot.favorites = [favorite]
        snapshot.favoriteTabs = [.init(id: id, favoriteID: favorite.id, url: currentURL, engine: .webKit)]
        try withSession(snapshot) { session, _ in
            #expect(session.hasTab(favorite) && session.favoriteTabs.isEmpty)
            let tab = try #require(session.moveFavoriteToTab(favorite, in: space, pinned: pinned))
            #expect(tab.id == id && tab.url == currentURL && tab.preferredEngine == .webKit)
            #expect(tab.savedPage == (pinned ? SavedPage(url: favorite.url, title: favorite.title) : nil))
            #expect(session.favorites.isEmpty && !session.hasTab(favorite))
        }
    }

    @Test func aMissingFavoriteOrInvalidDestinationChangesNothing() throws {
        try withSession { session, _ in
            let space = try #require(session.spaces.first)
            let favorite = Favorite(url: URL(string: "https://example.org/kept")!, title: "Kept", personaID: space.resolvedPersonaID)
            session.addFavorites([favorite], in: space.resolvedPersonaID)
            let other = session.addPersona(named: "Other")
            let foreignSpace = try #require(session.spaces(in: other.id).first)
            let missingSpace = Space(name: "Missing", personaID: space.resolvedPersonaID)
            for destination in [foreignSpace, missingSpace] {
                #expect(session.moveFavoriteToTab(favorite, in: destination, pinned: false) == nil)
            }
            let missing = Favorite(url: favorite.url, title: favorite.title, personaID: favorite.personaID)
            #expect(session.moveFavoriteToTab(missing, in: space, pinned: true) == nil)
            #expect(session.favorites == [favorite] && session.favoriteTabs.isEmpty && session.tabs.isEmpty)
        }
    }
}
