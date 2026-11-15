// Sidebar drags (`SidebarDragState.swift`): the reorder hover that moves a row once per crossing, the slot a release commits, the favorites bar as a drop destination, the favorites grid's row capacities, and a first pin into an empty pinned list. The gestures themselves need the app.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct SidebarDragTests {
    @Test func aTabReordersOnceWhileThePointerStaysOverTheDisplacedRow() {
        let row = CGRect(x: 6, y: 100, width: 224, height: 36)
        let point = CGPoint(x: row.midX, y: row.midY)
        let above = row.offsetBy(dx: 0, dy: -38), below = row.offsetBy(dx: 0, dy: 38)
        #expect(!SidebarReorderHover.crossedMidpoint(from: above, into: row, at: CGPoint(x: point.x, y: row.minY)))
        #expect(SidebarReorderHover.crossedMidpoint(from: above, into: row, at: point))
        #expect(!SidebarReorderHover.crossedMidpoint(from: below, into: row, at: CGPoint(x: point.x, y: row.maxY)))
        #expect(SidebarReorderHover.crossedMidpoint(from: below, into: row, at: point))
        var drag = SidebarReorderHover()
        let initial = drag.canMove(at: point)
        #expect(initial)
        drag.moved(into: row)
        for y in [row.midY, row.midY + 1, row.maxY, row.maxY + 1] {
            let canRepeat = drag.canMove(at: CGPoint(x: point.x, y: y))
            #expect(!canRepeat)
        }
        let left = drag.canMove(at: CGPoint(x: point.x, y: row.maxY + 12))
        let returned = drag.canMove(at: point)
        #expect(left && returned)
    }

    @Test func aCoalescedReleaseOutsideTheViewportClearsTheDividerHover() {
        let list = CGRect(x: 0, y: 40, width: 230, height: 320)
        let divider = CGRect(x: 6, y: 110, width: 218, height: 26)
        let favorite = CGRect(x: 6, y: 40, width: 218, height: 22)
        let midpoint = CGPoint(x: divider.midX, y: divider.midY)
        var hover = SidebarReorderHover()
        hover.moved(into: divider)
        let repeatsInPlace = hover.canMove(at: midpoint)
        let acceptsOutside = hover.acceptsRow(at: CGPoint(x: midpoint.x, y: 37), in: list, excluding: favorite)
        let acceptsReturn = hover.acceptsRow(at: midpoint, in: list, excluding: favorite)
        let canMoveOnReturn = hover.canMove(at: midpoint)
        #expect(!repeatsInPlace && !acceptsOutside && acceptsReturn && canMoveOnReturn)
        hover.moved(into: divider)
        let acceptsFavorite = hover.acceptsRow(at: CGPoint(x: favorite.midX, y: favorite.midY), in: list, excluding: favorite)
        let canMoveAfterFavorite = hover.canMove(at: midpoint)
        #expect(!acceptsFavorite && canMoveAfterFavorite)
    }

    @Test func eachFavoriteRowUsesItsOwnCapacityAndLaterRowsUseTheDefault() {
        let sizes = FavoriteTileLayout.rowSizes(from: FavoriteTileLayout.encode(rowSizes: [3, 2]))
        #expect(sizes == [3, 2])
        #expect(FavoriteTileLayout.counts(for: 0, rowSizes: sizes, defaultColumns: 4) == [])
        #expect(FavoriteTileLayout.counts(for: 5, rowSizes: sizes, defaultColumns: 4) == [3, 2])
        #expect(FavoriteTileLayout.counts(for: 11, rowSizes: sizes, defaultColumns: 4) == [3, 2, 4, 2])
        #expect(FavoriteTileLayout.counts(for: 4, rowSizes: [1, 4], defaultColumns: 4) == [1, 3])
        #expect(FavoriteTileLayout.rowSizes(from: Data("[0,9]".utf8)) == [1, 4])
        #expect(FavoriteTileLayout.rowSizes(from: Data("invalid".utf8)).isEmpty)
    }

    @Test func anEmptyFavoritesBarAcceptsOnlyTheDraggedTabsOwnSpace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let other = session.addPersona(named: "Other")
        let otherSpace = try #require(session.spaces(in: other.id).first)
        let tab = session.openTab(url: URL(string: "about:blank#drop")!, in: space.id, select: false)
        let drag = SidebarDragState()
        let frame = CGRect(x: 5, y: 10, width: 230, height: 44)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        drag.favoriteBarFrames = [space.id: frame, otherSpace.id: frame]
        let owner = UUID()
        drag.begin(.tab(tab.id), frame: frame, grabbedAt: point, owner: owner)
        #expect(drag.favoriteDestination(for: tab, in: space, at: point, session: session) == space.id)
        #expect(drag.favoriteDestination(for: tab, in: otherSpace, at: point, session: session) == nil)
        #expect(drag.favoriteDestination(for: tab, in: space, at: .zero, session: session) == nil)
        // A page that is a favorite already is no destination.
        session.addFavorite(tab)
        #expect(drag.favoriteDestination(for: tab, in: space, at: point, session: session) == nil)
        drag.end(ownedBy: owner)
        #expect(drag.targetFavoriteSpaceID == nil)
    }

    @Test(arguments: [false, true]) func theOtherListsEndShowsAFolderTabThereOnly(pinned: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let folder = session.makeFolder(in: space.id, pinned: pinned)
        let tabs = ["before", "page", "after"].map {
            session.openTab(url: URL(string: "about:blank#\($0)")!, in: space.id, select: false)
        }
        for tab in tabs { session.moveTab(tab.id, toFolder: folder.id) }
        let tab = tabs[1]
        let slot = SidebarTabSlot.end(pinned: !pinned)
        var pins = session.folderTree.rows(in: space.id, pinned: true)
        var open = session.folderTree.rows(in: space.id, pinned: false)
        slot.project(tab, pinnedRows: &pins, openRows: &open)
        #expect((pinned ? open : pins).last?.id == tab.id)
        #expect(!(pinned ? pins : open).contains { $0.id == tab.id })
    }

    @Test func releasingTheRowCommitsItsDisplayedSideOnlyWhileItsTargetStillExists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let tab = session.openTab(url: URL(string: "about:blank#source")!, in: space.id, select: false)
        let target = session.openTab(url: URL(string: "about:blank#target")!, in: space.id, select: false)
        let neighbor = session.openTab(url: URL(string: "about:blank#neighbor")!, in: space.id, select: false)
        let slot = SidebarTabSlot.beside(target.id, folder: nil, pinned: false, after: true)
        // An independent move before release must not reverse the displayed side.
        session.moveTabToListEnd(tab.id, pinned: false)
        slot.commit(tab, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [target.id, tab.id, neighbor.id])

        SidebarTabSlot.end(pinned: true).commit(tab, in: space, session: session)
        let saved = try #require(tab.savedPage)
        #expect(tab.isPinned && saved.url == tab.url)
        session.togglePinned(target)
        slot.commit(tab, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).contains { $0 === tab })
        _ = session.closeTab(target)
        slot.commit(tab, in: space, session: session)
        #expect(tab.isPinned && tab.savedPage == saved)
    }

    @Test func movingToAnEmptyPinnedListPinsTheTabWithItsPage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let other = session.addPersona(named: "Other")
        let otherSpace = try #require(session.spaces(in: other.id).first)
        let tab = session.openTab(url: URL(string: "about:blank#pin"), in: space.id, select: false, engine: .webKit)
        let foreign = session.openTab(url: URL(string: "about:blank#other"), in: otherSpace.id, select: false, engine: .webKit)
        let contents = tab.webContents
        #expect(session.folderTree.rows(in: space.id, pinned: true).isEmpty)
        session.moveTabToListEnd(tab.id, pinned: true)
        #expect(tab.isPinned && tab.savedPage?.url == tab.url && tab.webContents === contents)
        // Another Persona's tab is no target.
        session.moveTab(tab.id, to: foreign)
        #expect(tab.spaceID == space.id && tab.personaID == space.resolvedPersonaID && !foreign.isPinned)
        session.moveTabToListEnd(tab.id, pinned: false)
        #expect(!tab.isPinned && tab.savedPage == nil)
    }
}
