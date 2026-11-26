// Window-local selection memory uses favorite identities independently of their live tabs.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct SelectionMemoryTests {
    private func withSession(_ check: (BrowserSession, BrowserWindowModel, Space, Space) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSelectionMemory-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let other = session.makeSpace(in: space.resolvedPersonaID)
        try check(session, makeWindow(session, in: space), space, other)
    }

    /// These model tests create no AppKit window.
    private func makeWindow(_ session: BrowserSession, in space: Space) -> BrowserWindowModel {
        BrowserWindowModel(session: session, record: .init(id: UUID(), frame: nil, currentSpaceID: space.id,
                                                         selectedTabID: nil, isSidebarVisible: true), kind: .main)
    }

    private func addFavorite(_ session: BrowserSession, in space: Space, path: String = "favorite") -> Favorite {
        let favorite = Favorite(url: URL(string: "https://example.org/\(path)")!, title: path, personaID: space.resolvedPersonaID)
        session.addFavorites([favorite], in: space.resolvedPersonaID)
        return favorite
    }

    @Test func eachPersonaRestoresItsSelectedFavoriteInsteadOfAnOrdinaryTab() throws {
        try withSession { session, window, space, _ in
            let work = session.addPersona(named: "Work")
            let workSpace = try #require(session.spaces(in: work.id).first)
            let homeFavorite = addFavorite(session, in: space)
            let workFavorite = addFavorite(session, in: workSpace)
            for place in [space, workSpace] { session.openTab(in: place.id, select: false) }

            window.openFavorite(homeFavorite)
            let homeTabID = window.selectedTabID
            window.switchToSpace(workSpace.id)
            window.openFavorite(workFavorite)
            let workTabID = window.selectedTabID
            window.switchToSpace(space.id)
            #expect(window.selectedFavoriteID == homeFavorite.id && window.selectedTabID == homeTabID)
            window.switchToSpace(workSpace.id)
            #expect(window.selectedFavoriteID == workFavorite.id && window.selectedTabID == workTabID)
        }
    }

    @Test func spacesOfOnePersonaKeepDifferentSelections() throws {
        try withSession { session, window, space, other in
            let favorite = addFavorite(session, in: space)
            session.openTab(in: other.id, select: false)
            let tab = session.openTab(in: other.id, select: false)
            window.openFavorite(favorite)
            window.switchToSpace(other.id)
            window.selectTab(tab.id)
            window.switchToSpace(space.id)
            #expect(window.selectedFavoriteID == favorite.id)
            window.switchToSpace(other.id)
            #expect(window.selectedTabID == tab.id && window.selectedFavoriteID == nil)
        }
    }

    @Test func eachWindowKeepsItsOwnSelectionInTheSameSpace() throws {
        try withSession { session, first, space, other in
            let second = makeWindow(session, in: space)
            let favorite = addFavorite(session, in: space)
            let tab = session.openTab(in: space.id, select: false)
            first.openFavorite(favorite)
            second.selectTab(tab.id)
            first.switchToSpace(other.id)
            second.switchToSpace(other.id)
            first.switchToSpace(space.id)
            second.switchToSpace(space.id)
            #expect(first.selectedFavoriteID == favorite.id)
            #expect(second.selectedTabID == tab.id && second.selectedFavoriteID == nil)
        }
    }

    @Test func selectingAnItemInAnotherSpaceRemembersTheOutgoingItem() throws {
        try withSession { session, window, space, other in
            let favorite = addFavorite(session, in: space)
            let work = session.addPersona(named: "Work")
            let workSpace = try #require(session.spaces(in: work.id).first)
            let workFavorite = addFavorite(session, in: workSpace)
            let tab = session.openTab(in: other.id, select: false)
            window.openFavorite(favorite)
            window.selectTab(tab.id)
            window.openFavorite(workFavorite)
            window.switchToSpace(other.id)
            #expect(window.selectedTabID == tab.id)
            window.switchToSpace(space.id)
            #expect(window.selectedFavoriteID == favorite.id)
            window.switchToSpace(workSpace.id)
            #expect(window.selectedFavoriteID == workFavorite.id)
        }
    }

    @Test func returningToAnEmptySelectionDoesNotSelectANewTab() throws {
        try withSession { session, window, space, other in
            window.selectTab(nil)
            window.switchToSpace(other.id)
            session.openTab(in: space.id, select: false)
            window.switchToSpace(space.id)
            #expect(window.selectedTabID == nil && window.selectedFavoriteID == nil)
        }
    }

    @Test func aRememberedFavoriteReopensAfterItsOldTabEnds() throws {
        try withSession { session, window, space, other in
            let favorite = addFavorite(session, in: space)
            window.openFavorite(favorite)
            let old = try #require(window.selectedTab)
            window.switchToSpace(other.id)
            #expect(session.removeTab(old, closedRecord: nil, reason: .user))
            window.switchToSpace(space.id)
            #expect(window.selectedFavoriteID == favorite.id && window.selectedTabID != old.id)
        }
    }

    @Test func removingTheRememberedFavoriteFallsBackToASpaceTab() throws {
        try withSession { session, window, space, other in
            let favorite = addFavorite(session, in: space)
            let fallback = session.openTab(in: space.id, select: false)
            window.openFavorite(favorite)
            let old = try #require(window.selectedTab)
            window.switchToSpace(other.id)
            #expect(session.removeTab(old, closedRecord: nil, reason: .user))
            session.removeFavorite(favorite)
            window.switchToSpace(space.id)
            #expect(window.selectedTabID == fallback.id && window.selectedFavoriteID == nil)
        }
    }

    @Test func closingOrMovingTheRememberedTabFallsBackWithinTheOriginalSpace() throws {
        try withSession { session, window, space, other in
            let fallback = session.openTab(in: space.id, select: false)
            let closed = session.openTab(in: space.id, select: false)
            window.selectTab(closed.id)
            window.switchToSpace(other.id)
            #expect(session.closeTab(closed))
            window.switchToSpace(space.id)
            #expect(window.selectedTabID == fallback.id)

            let moved = session.openTab(in: space.id, select: false)
            window.selectTab(moved.id)
            window.switchToSpace(other.id)
            session.moveTab(moved.id, toSpace: other.id)
            window.switchToSpace(space.id)
            #expect(window.currentSpaceID == space.id && window.selectedTabID == fallback.id)
        }
    }

    @Test func convertingTheSelectedTabToAFavoriteRemembersTheFavorite() throws {
        try withSession { session, window, space, other in
            let tab = session.openTab(url: URL(string: "https://example.org/")!, in: space.id, select: false)
            window.selectTab(tab.id)
            session.addFavorite(tab)
            let favoriteID = try #require(window.selectedFavoriteID)
            window.switchToSpace(other.id)
            window.switchToSpace(space.id)
            #expect(window.selectedFavoriteID == favoriteID && window.selectedTabID == tab.id)
            window.switchToSpace(space.id)
            #expect(window.selectedFavoriteID == favoriteID && window.selectedTabID == tab.id)
        }
    }
}
