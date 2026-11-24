// Favorite drags preview ordinary tab slots without opening or moving their pages before release.
import AppKit
import ARCHEngine
import SwiftUI
import Testing
@testable import Browsing

@MainActor @Suite struct FavoriteTabDropTests {
    @Test(arguments: [false, true], [false, true])
    func aFavoriteLeavesTheGridAndDropsBesideATab(pinned: Bool, after: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFavoriteTabDrop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { session.windowWillClose(window) }
        let neighbor = session.openTab(url: URL(string: "about:blank#neighbor")!, in: space.id, pinned: pinned, select: false)
        let favorite = Favorite(url: URL(string: "about:blank#favorite")!, title: "Favorite", personaID: space.resolvedPersonaID)
        session.addFavorites([favorite], in: space.resolvedPersonaID)
        let drag = SidebarDragState(), owner = UUID()
        let host = NSHostingView(rootView: SidebarSpaceContent(session: session, translation: 0)
            .frame(width: 260, height: 600)
            .coordinateSpace(name: BrowserWindowView.coordinateSpace)
            .environmentObject(drag).environmentObject(window).environment(\.sidebarWidth, 260)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 600)
        func layout(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            #expect(condition())
        }
        try await layout { drag.favoriteTabTargets[space.id]?.frames[neighbor.id] != nil && drag.favoriteGridTargets[space.id] != nil }
        let grid = try #require(drag.favoriteGridTargets[space.id])
        let tile = grid.frame
        drag.begin(.favorite(favorite.id), frame: tile, grabbedAt: CGPoint(x: tile.midX, y: tile.midY), owner: owner)
        defer { drag.end(ownedBy: owner) }
        drag.updateFavoriteGap(in: space.id, at: CGPoint(x: tile.midX, y: tile.midY), adding: false)
        #expect(drag.favoriteGap != nil)
        drag.updateFavoriteGap(in: nil, at: .zero, adding: false)
        try await layout { drag.favoriteGridTargets[space.id]?.frame.height == 0 }
        let row = try #require(drag.favoriteTabTargets[space.id]?.frames[neighbor.id])
        let point = CGPoint(x: row.midX, y: after ? row.maxY - 4 : row.minY + 4)
        drag.updateFavoriteTabDrop(in: space.id, at: point, session: session)
        let drop = try #require(drag.favoriteTabDrop)
        #expect(drop.slot == .beside(neighbor.id, folder: nil, pinned: pinned, after: after))
        #expect(drag.tileFraction == 0 && drag.frame.size == drop.frame.size)
        #expect(drag.favoriteGap == nil && session.favorites == [favorite] && session.favoriteTabs.isEmpty)
        try await layout { drag.favoriteTabTargets[space.id]?.frames[favorite.id]?.height == 36 }
        // Cancelling restores even the grid's only row, without opening the favorite.
        drag.end(ownedBy: owner)
        try await layout { drag.favoriteGridTargets[space.id]?.frame.height == 44 && drag.favoriteTabTargets[space.id]?.frames[favorite.id] == nil }
        #expect(session.favorites == [favorite] && session.favoriteTabs.isEmpty)
        drag.begin(.favorite(favorite.id), frame: tile, grabbedAt: CGPoint(x: tile.midX, y: tile.midY), owner: owner)
        try await layout { drag.favoriteGridTargets[space.id]?.frame.height == 0 }
        let returnedRow = try #require(drag.favoriteTabTargets[space.id]?.frames[neighbor.id])
        drag.updateFavoriteTabDrop(in: space.id, at: CGPoint(x: returnedRow.midX, y: after ? returnedRow.maxY - 4 : returnedRow.minY + 4), session: session)
        let landing = try #require(drag.dropFavoriteIntoTabs(favorite, session: session))
        let moved = try #require(session.tabs.first(where: { $0 !== neighbor }))
        #expect(session.favorites.isEmpty && moved.isPinned == pinned)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: pinned).map(\.id) == (after ? [neighbor.id, moved.id] : [moved.id, neighbor.id]))
        #expect(drag.liftedFavorite == favorite && drag.liftedTab === moved && drag.settlingTabID == moved.id)
        drag.settle(into: landing, ownedBy: owner)
        #expect(drag.isSettling && !drag.isEntering && !drag.isFadingOut)
        #expect(drag.frame == landing && drag.tileFraction == 0)
        #expect(drag.settlingTabID == moved.id)
        try await layout { drag.favoriteTabTargets[space.id]?.frames[moved.id] == landing }
        #expect(drag.favoriteTabTargets[space.id]?.frames[moved.id] == landing)
        drag.end(ownedBy: owner)
        #expect(drag.liftedFavorite == nil && drag.liftedTab == nil && drag.settlingTabID == nil)
    }

    @Test func leavingTheListsOrCancellingKeepsTheFavoriteAndBothEmptySectionsAcceptIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFavoriteCancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let favorite = Favorite(url: URL(string: "about:blank#cancel")!, title: "Favorite", personaID: space.resolvedPersonaID)
        session.addFavorites([favorite], in: space.resolvedPersonaID)
        let drag = SidebarDragState(), owner = UUID(), newTab = UUID()
        drag.favoriteTabTargets[space.id] = .init(pinnedArea: CGRect(x: 6, y: 100, width: 248, height: 0), pinnedFrames: [:],
            openArea: CGRect(x: 6, y: 148, width: 248, height: 452), openFrames: [newTab: CGRect(x: 6, y: 148, width: 248, height: 36)],
            divider: CGRect(x: 6, y: 100, width: 248, height: 46), newTabID: newTab)
        let tile = CGRect(x: 6, y: 0, width: 248, height: 44)
        drag.begin(.favorite(favorite.id), frame: tile, grabbedAt: CGPoint(x: tile.midX, y: tile.midY), owner: owner)
        for pinned in [true, false] {
            drag.updateFavoriteTabDrop(in: space.id, at: CGPoint(x: 120, y: pinned ? 120 : 300), session: session)
            #expect(drag.favoriteTabDrop?.slot == .end(pinned: pinned))
            drag.updateFavoriteTabDrop(in: space.id, at: CGPoint(x: 500, y: 300), session: session)
            #expect(drag.favoriteTabDrop == nil)
            #expect(drag.dropFavoriteIntoTabs(favorite, session: session) == nil)
            #expect(session.favorites == [favorite] && session.tabs.isEmpty && session.favoriteTabs.isEmpty)
        }
        // A release outside both lists returns the row-shaped preview to its original tile.
        #expect(drag.tileFraction == 0 && drag.frame.height == 36)
        drag.settle(into: tile, ownedBy: owner)
        #expect(drag.frame == tile && drag.tileFraction == 1 && drag.settlingTabID == nil)
        #expect(session.favorites == [favorite] && session.tabs.isEmpty && session.favoriteTabs.isEmpty)
        drag.end(ownedBy: owner)
        #expect(drag.favoriteTabDrop == nil && drag.favoriteGap == nil && session.favorites == [favorite])
    }

    @Test func aFavoriteCanCrossBackOverTheSameRowsMidpointAndCannotDropAfterTheListHides() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFavoriteCrossing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let neighbor = session.openTab(url: URL(string: "about:blank#neighbor")!, in: space.id, select: false)
        let favorite = Favorite(url: URL(string: "about:blank#favorite")!, title: "Favorite", personaID: space.resolvedPersonaID)
        session.addFavorites([favorite], in: space.resolvedPersonaID)
        let drag = SidebarDragState(), owner = UUID(), newTab = UUID()
        let row = CGRect(x: 6, y: 150, width: 248, height: 36)
        func target(showingSlot: Bool) -> SidebarDragState.FavoriteTabTarget {
            var frames = [neighbor.id: row, newTab: row.offsetBy(dx: 0, dy: showingSlot ? 76 : 38)]
            if showingSlot { frames[favorite.id] = row.offsetBy(dx: 0, dy: 38) }
            return .init(pinnedArea: CGRect(x: 6, y: 100, width: 248, height: 0), pinnedFrames: [:],
                         openArea: CGRect(x: 6, y: 148, width: 248, height: 452), openFrames: frames,
                         divider: CGRect(x: 6, y: 100, width: 248, height: 46), newTabID: newTab)
        }
        drag.favoriteTabTargets[space.id] = target(showingSlot: false)
        drag.begin(.favorite(favorite.id), frame: row, grabbedAt: .zero, owner: owner)
        defer { drag.end(ownedBy: owner) }
        drag.updateFavoriteTabDrop(in: space.id, at: CGPoint(x: row.midX, y: row.maxY - 4), session: session)
        #expect(drag.favoriteTabDrop?.slot == .beside(neighbor.id, folder: nil, pinned: false, after: true))
        drag.favoriteTabTargets[space.id] = target(showingSlot: true)
        drag.updateFavoriteTabDrop(in: space.id, at: CGPoint(x: row.midX, y: row.minY + 4), session: session)
        #expect(drag.favoriteTabDrop?.slot == .beside(neighbor.id, folder: nil, pinned: false, after: false))
        drag.favoriteTabTargets[space.id] = nil
        #expect(drag.dropFavoriteIntoTabs(favorite, session: session) == nil)
        #expect(session.favorites == [favorite] && session.favoriteTabs.isEmpty)
    }
}
