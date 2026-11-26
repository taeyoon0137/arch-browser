// Sidebar drags (`SidebarDragState.swift`): the reorder hover that moves a row once per crossing, a release whose slot is scrolled out of sight, the slot a release commits, the favorites bar as a drop destination, the favorites grid's row capacities, and a first pin into an empty pinned list. The gestures themselves need the app.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct SidebarDragTests {
    @Test func morphingBetweenRowsAndTilesKeepsThePointerAttachedToTheGrabPoint() {
        let drag = SidebarDragState(), owner = UUID(), space = UUID()
        let row = CGRect(x: 6, y: 200, width: 240, height: 36)
        let grabbed = CGPoint(x: row.minX + row.width / 4, y: row.midY)
        let grid = CGRect(x: 6, y: 40, width: 240, height: 44)
        drag.favoriteGridTargets[space] = .init(slots: .init(rowSizes: [], defaultColumns: 4), frame: grid,
                                               viewport: CGRect(x: 0, y: 0, width: 260, height: 600), count: 2)
        drag.begin(.tab(UUID()), frame: row, grabbedAt: grabbed, owner: owner)
        defer { drag.end(ownedBy: owner) }
        #expect(drag.tileFraction == 0 && drag.frame == row)
        #expect(drag.previewAnchor.x == 0.25 && drag.previewAnchor.y == 0.5)
        let point = CGPoint(x: grid.midX, y: grid.midY)
        drag.move(to: point)
        drag.targetFavoriteSpaceID = space
        drag.updateFavoriteGap(in: space, at: point, adding: true)
        #expect(drag.tileFraction == 1 && drag.frame.height == 44)
        #expect(drag.frame.width == 76)
        #expect(drag.previewPosition == point)
        #expect(drag.frame.minX + drag.frame.width / 4 == point.x)
        #expect(drag.frame.midY == point.y)

        let next = CGPoint(x: point.x + 15, y: point.y + 9)
        drag.move(to: next)
        #expect(drag.previewPosition == next)
        #expect(drag.frame.minX + drag.frame.width / 4 == next.x)
        #expect(drag.frame.midY == next.y && drag.frame.width == 76)

        drag.targetFavoriteSpaceID = nil
        drag.updateFavoriteGap(in: nil, at: next, adding: true)
        #expect(drag.tileFraction == 0 && drag.frame.size == row.size)
        #expect(drag.previewPosition == next)
        #expect(drag.frame.minX + drag.frame.width / 4 == next.x && drag.frame.midY == next.y)
        drag.end(ownedBy: owner)
        #expect(drag.item == nil && drag.favoriteGap == nil && drag.tileFraction == 0)
    }

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

    @Test func aReleasedRowWhoseSlotIsScrolledOutOfSightFadesOutAtTheListsEdge() {
        let list = CGRect(x: 0, y: 40, width: 240, height: 500), owner = UUID(), drag = SidebarDragState()
        func release(into y: CGFloat, within list: CGRect?) {
            drag.begin(.tab(UUID()), frame: CGRect(x: 11, y: 300, width: 218, height: 36), grabbedAt: CGPoint(x: 120, y: 310), owner: owner)
            drag.settle(into: CGRect(x: 11, y: y, width: 218, height: 36), within: list, ownedBy: owner)
        }
        // A slot above the visible list takes the row to its top edge, where it fades out. A slot below the list takes the row to its bottom edge.
        release(into: -60, within: list)
        #expect(drag.isSettling && drag.isFadingOut && drag.frame == CGRect(x: 11, y: 40, width: 218, height: 36))
        drag.end(ownedBy: owner)
        #expect(!drag.isFadingOut)
        release(into: 560, within: list)
        #expect(drag.isFadingOut && drag.frame.minY == 504)
        drag.end(ownedBy: owner)
        // A slot whose middle shows takes the row, even partly under the edge. The row does not fade.
        release(into: 30, within: list)
        #expect(!drag.isFadingOut && drag.frame.minY == 30)
        drag.end(ownedBy: owner)
        // Without a list, as for a favorite, the item returns to its slot wherever it is.
        release(into: -60, within: nil)
        #expect(!drag.isFadingOut && drag.frame.minY == -60)
        drag.end(ownedBy: owner)
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
        #expect(FavoriteTileLayout.rowSizes(from: Data("[0,9]".utf8)) == [4])
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
        // A page that is already a favorite cannot be a destination.
        session.addFavorite(tab)
        #expect(drag.favoriteDestination(for: tab, in: space, at: point, session: session) == nil)
        drag.end(ownedBy: owner)
        #expect(drag.targetFavoriteSpaceID == nil)
    }

    @Test func anEmptyFoldersPlaceholderTakesATabWithoutExtendingItsDropBounds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let folder = session.makeFolder(in: space.id, pinned: true)
        let agent = TabFolder(spaceID: space.id, name: "Agent", isPinned: false, agentSessionID: UUID())
        session.appendFolder(agent)
        let tab = session.openTab(url: URL(string: "about:blank#folder-drop")!, in: space.id, select: false)
        let drag = SidebarDragState()
        let header = CGRect(x: 6, y: 100, width: 224, height: 36)
        let placeholder = CGRect(x: 18, y: 140, width: 212, height: 36)
        let agentPlaceholder = placeholder.offsetBy(dx: 0, dy: 100)
        let stalePlaceholder = placeholder.offsetBy(dx: 0, dy: 200)
        let headers = [folder.id: header, agent.id: header.offsetBy(dx: 0, dy: 100)]
        let placeholders = [folder.id: placeholder, agent.id: agentPlaceholder, UUID(): stalePlaceholder]
        func destination(_ point: CGPoint) -> UUID? {
            drag.folderDestination(for: tab, at: point, in: session.folderTree, rowFrames: headers, emptyFolderFrames: placeholders)
        }
        #expect(destination(CGPoint(x: header.midX, y: header.midY)) == folder.id)
        let point = CGPoint(x: placeholder.midX, y: placeholder.midY)
        #expect(destination(point) == folder.id)
        #expect(destination(CGPoint(x: header.midX, y: 138)) == nil)
        #expect(destination(CGPoint(x: 10, y: placeholder.midY)) == nil)
        #expect(destination(CGPoint(x: placeholder.midX, y: placeholder.maxY + 1)) == nil)
        #expect(destination(CGPoint(x: agentPlaceholder.midX, y: agentPlaceholder.midY)) == nil)
        #expect(destination(CGPoint(x: stalePlaceholder.midX, y: stalePlaceholder.midY)) == nil)

        let target = try #require(destination(point))
        let owner = UUID()
        let lifted = CGRect(x: 6, y: 300, width: 224, height: 36)
        drag.begin(.tab(tab.id), frame: lifted, grabbedAt: CGPoint(x: lifted.midX, y: lifted.midY), owner: owner)
        drag.isLifted = true
        drag.targetFolderID = target
        let accepted = drag.drop(intoFolder: target, session: session, ownedBy: owner)
        #expect(accepted && drag.isSettling && drag.isLifted && !drag.isEntering)
        #expect(drag.frame == lifted && drag.targetFolderID == nil)
        #expect(tab.folderID == folder.id && tab.isPinned && tab.savedPage?.url == tab.url)
        #expect(session.folderTree.tabs(inFolder: folder.id).map(\.id) == [tab.id])
        #expect(destination(point) == nil)

        let area = CGRect(x: 0, y: 80, width: 240, height: 160)
        // The source can still report the old row before the destination lays out its child.
        drag.settleFolderDrop(in: [tab.id: lifted], pinned: false, within: area, ownedBy: owner)
        drag.settleFolderDrop(in: headers, pinned: true, within: area, ownedBy: owner)
        #expect(drag.frame == lifted && drag.isLifted && !drag.isEntering)
        drag.settleFolderDrop(in: [tab.id: placeholder], pinned: true, within: area, ownedBy: owner)
        #expect(drag.frame == placeholder && drag.isSettling && !drag.isLifted)
        #expect(!drag.isEntering && !drag.isFadingOut && drag.frame.height == lifted.height)
        drag.end(ownedBy: owner)
    }

    @Test(arguments: [false, true]) func aDropIntoACollapsedNestedFolderSettlesAfterItsExistingTabs(pinned: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let parent = session.makeFolder(in: space.id, pinned: pinned)
        let folder = session.makeFolder(in: space.id, pinned: pinned, inside: parent.id)
        let existing = session.openTab(url: URL(string: "about:blank#existing"), in: space.id, select: false)
        session.moveTab(existing.id, toFolder: folder.id)
        let tab = session.openTab(url: URL(string: "about:blank#nested-drop"), in: space.id, select: false)
        session.moveTabToListEnd(tab.id, pinned: !pinned)
        session.toggleCollapsed(ofFolder: folder.id)
        let originalIDs = Set(session.tabs.map(\.id))
        let page = tab.webContents
        let drag = SidebarDragState(), owner = UUID()
        let lifted = CGRect(x: 6, y: 350, width: 224, height: 36)
        drag.begin(.tab(tab.id), frame: lifted, grabbedAt: CGPoint(x: lifted.midX, y: lifted.midY), owner: owner)
        drag.isLifted = true

        let accepted = drag.drop(intoFolder: folder.id, session: session, ownedBy: owner)
        #expect(accepted && drag.isSettling && drag.frame == lifted && !drag.isEntering)
        #expect(session.folderTree.folder(folder.id)?.isCollapsed == false)
        #expect(session.folderTree.tabs(inFolder: folder.id).map(\.id) == [existing.id, tab.id])
        #expect(Set(session.tabs.map(\.id)) == originalIDs && tab.webContents === page)
        let rows = session.folderTree.rows(in: space.id, pinned: pinned)
        #expect(rows.map(\.id) == [parent.id, folder.id, existing.id, tab.id])
        #expect(rows.last?.depth == 2 && tab.isPinned == pinned)

        let area = CGRect(x: 0, y: 80, width: 240, height: 400)
        let slot = CGRect(x: 30, y: 214, width: 200, height: 36)
        drag.settleFolderDrop(in: [tab.id: lifted], pinned: !pinned, within: area, ownedBy: owner)
        #expect(drag.frame == lifted && drag.isLifted)
        drag.settleFolderDrop(in: [tab.id: slot], pinned: pinned, within: area, ownedBy: owner)
        #expect(drag.frame == slot && !drag.isEntering && !drag.isFadingOut)
        // Later geometry reports must not start another settlement.
        drag.settleFolderDrop(in: [tab.id: lifted], pinned: pinned, within: area, ownedBy: owner)
        #expect(drag.frame == slot)
        drag.end(ownedBy: owner)
    }

    @Test func aFolderDroppedIntoAnotherFolderUsesItsChildSlotAndKeepsItsContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let target = session.makeFolder(in: space.id, pinned: true)
        let moved = session.makeFolder(in: space.id, pinned: false)
        let tab = session.openTab(url: URL(string: "about:blank#carried"), in: space.id, select: false)
        session.moveTab(tab.id, toFolder: moved.id)
        session.toggleCollapsed(ofFolder: target.id)
        let drag = SidebarDragState(), owner = UUID()
        let lifted = CGRect(x: 6, y: 300, width: 224, height: 36)
        drag.begin(.folder(moved.id), frame: lifted, grabbedAt: CGPoint(x: lifted.midX, y: lifted.midY), owner: owner)
        drag.isLifted = true

        let accepted = drag.drop(intoFolder: target.id, session: session, ownedBy: owner)
        #expect(accepted && drag.isSettling && drag.isLifted && !drag.isEntering)
        #expect(session.folderTree.folder(moved.id)?.parentID == target.id)
        #expect(session.folderTree.folder(target.id)?.isCollapsed == false)
        #expect(session.folderTree.rows(in: space.id, pinned: true).map(\.id) == [target.id, moved.id, tab.id])
        #expect(tab.isPinned && tab.folderID == moved.id)
        let slot = CGRect(x: 18, y: 138, width: 212, height: 36)
        drag.settleFolderDrop(in: [moved.id: slot], pinned: true, within: CGRect(x: 0, y: 80, width: 240, height: 200), ownedBy: owner)
        #expect(drag.frame == slot && !drag.isEntering && !drag.isFadingOut)
        drag.end(ownedBy: owner)
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
        // Another Persona's tab cannot be a target.
        session.moveTab(tab.id, to: foreign)
        #expect(tab.spaceID == space.id && tab.personaID == space.resolvedPersonaID && !foreign.isPinned)
        session.moveTabToListEnd(tab.id, pinned: false)
        #expect(!tab.isPinned && tab.savedPage == nil)
    }
}
