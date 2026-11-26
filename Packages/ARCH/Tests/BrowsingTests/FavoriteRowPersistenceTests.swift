// Favorite commands persist the visible row counts without moving tiles from unrelated rows.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct FavoriteRowPersistenceTests {
    private func withSession(rows: [Int] = [3, 1], movingTabs: Bool = false,
                             _ check: (BrowserSession, Space, URL) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let savedColumns = defaults.object(forKey: FavoriteTileLayout.columnsKey)
        defer {
            defaults.set(savedColumns, forKey: FavoriteTileLayout.columnsKey)
        }
        defaults.set(4, forKey: FavoriteTileLayout.columnsKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFavoriteRows-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let favorites = (0..<rows.reduce(0, +)).map {
            Favorite(url: URL(string: "about:blank#favorite-\($0)")!, title: "Favorite \($0)", personaID: space.resolvedPersonaID)
        }
        if movingTabs {
            for favorite in favorites {
                session.addFavorite(session.openTab(url: favorite.url, in: space.id, select: false))
            }
        } else {
            session.addFavorites(favorites, in: space.resolvedPersonaID)
        }
        session.setFavoriteRows(rows, in: space.resolvedPersonaID)
        try check(session, space, directory)
    }

    @Test func menuAdditionsFillOnlyTheLastRowThenStartAnother() throws {
        try withSession { session, space, _ in
            let originals = session.favorites(in: space.resolvedPersonaID)
            for (index, expected) in [[3, 2], [3, 3], [3, 4], [3, 4, 1]].enumerated() {
                let tab = session.openTab(url: URL(string: "about:blank#menu-\(index)")!, in: space.id, select: false)
                session.addFavorite(tab)
                let stored = session.favoriteRows(in: space.resolvedPersonaID)
                #expect(stored == expected)
                #expect(Array(session.favorites(in: space.resolvedPersonaID).prefix(originals.count)) == originals)
            }
        }
    }

    @Test(arguments: [0, 3], [false, true])
    func removingAFavoriteShrinksOnlyItsRow(index: Int, movingTabs: Bool) throws {
        try withSession(movingTabs: movingTabs) { session, space, _ in
            let originals = session.favorites(in: space.resolvedPersonaID)
            let removed = originals[index]
            let tab = session.favoriteTabs[removed.id]
            session.removeFavorite(removed)
            let stored = session.favoriteRows(in: space.resolvedPersonaID)
            #expect(stored == (index == 0 ? [2, 1] : [3]))
            #expect(session.favorites(in: space.resolvedPersonaID) == originals.filter { $0.id != removed.id })
            if let tab { #expect(session.tabs.contains { $0 === tab } && tab.spaceID == space.id) }
        }
    }

    @Test(arguments: [0, 3], [false, true])
    func draggingAFavoriteToTabsShrinksOnlyItsRow(index: Int, pinned: Bool) throws {
        try withSession(movingTabs: true) { session, space, _ in
            let originals = session.favorites(in: space.resolvedPersonaID)
            let favorite = originals[index]
            let originalTab = try #require(session.favoriteTabs[favorite.id])
            let moved = try #require(session.moveFavoriteToTab(favorite, in: space, pinned: pinned))
            #expect(moved === originalTab && moved.spaceID == space.id && moved.isPinned == pinned)
            let stored = session.favoriteRows(in: space.resolvedPersonaID)
            #expect(stored == (index == 0 ? [2, 1] : [3]))
            #expect(session.favorites(in: space.resolvedPersonaID) == originals.filter { $0.id != favorite.id })
        }
    }

    @Test func configuredRowsDiscardExcessEntriesBeforeAnAddition() throws {
        try withSession { session, space, _ in
            session.setFavoriteRows([3, 4, 2], in: space.resolvedPersonaID)
            let tab = session.openTab(url: URL(string: "about:blank#normalize")!, in: space.id, select: false)
            session.addFavorite(tab)
            let stored = session.favoriteRows(in: space.resolvedPersonaID)
            #expect(stored == [3, 2])
            #expect(session.favorites(in: space.resolvedPersonaID).count == 5)
        }
    }

    @Test func batchAdditionsAppendOnlyNewFavoritesToTheLastRow() throws {
        try withSession { session, space, _ in
            let originals = session.favorites(in: space.resolvedPersonaID)
            let additions = (0..<2).map { Favorite(url: URL(string: "about:blank#batch-\($0)")!, title: "Added \($0)") }
            #expect(session.addFavorites([originals[0]] + additions, in: space.resolvedPersonaID) == 2)
            let stored = session.favoriteRows(in: space.resolvedPersonaID)
            #expect(stored == [3, 3])
            #expect(Array(session.favorites(in: space.resolvedPersonaID).prefix(originals.count)) == originals)
        }
    }

    @Test func aDropExpandsTheLastRowPastTheDefaultColumnCount() throws {
        try withSession(rows: [3]) { session, space, _ in
            UserDefaults.standard.set(3, forKey: FavoriteTileLayout.columnsKey)
            session.setFavoriteRows([4], in: space.resolvedPersonaID)
            let slots = FavoriteGridSlots(rowSizes: [4], defaultColumns: 3)
            let target = FavoriteGridSlots.Target(slots: slots, frame: CGRect(x: 0, y: 0, width: 240, height: slots.height(for: 3)),
                                                  viewport: CGRect(x: 0, y: 0, width: 240, height: 200), count: 3)
            let placement = try #require(target.placement(at: CGPoint(x: 239, y: 22), adding: true))
            #expect(placement.rowSizes == [4])
            let tab = session.openTab(url: URL(string: "about:blank#drop")!, in: space.id, select: false)
            session.addFavorite(tab, at: placement.index, rowSizes: placement.rowSizes)
            let stored = session.favoriteRows(in: space.resolvedPersonaID)
            #expect(stored == [4])
            #expect(session.favorites(in: space.resolvedPersonaID).count == 4)
        }
    }

    @Test(arguments: [
        // Original rows, source index, target row, left/right slot, expected rows, expected order, displayed row origins.
        ([1, 2, 1], 1, 2, false, [1, 1, 2], [0, 2, 1, 3], [0, 1, 2]),
        ([1, 2, 1], 1, 2, true, [1, 1, 2], [0, 2, 3, 1], [0, 1, 2]),
        ([1, 2, 1], 2, 2, false, [1, 1, 2], [0, 1, 2, 3], [0, 1, 2]),
        ([1, 2, 1], 3, 1, true, [1, 3], [0, 1, 2, 3], [0, 1]),
        ([1, 2, 1], 0, 2, true, [2, 2], [1, 2, 3, 0], [1, 2]),
        ([1, 2, 1], 1, 1, true, [1, 2, 1], [0, 2, 1, 3], [0, 1, 2]),
        ([1, 2, 1], 0, 0, false, [1, 2, 1], [0, 1, 2, 3], [nil, 1, 2]),
        ([4], 0, 0, true, [4], [1, 2, 3, 0], [0]),
        ([1, 4, 1], 0, 1, false, [4, 1, 1], [1, 2, 3, 4, 0, 5], [1, nil, 2]),
        ([1, 4, 1], 5, 1, true, [1, 4, 1], [0, 1, 2, 3, 4, 5], [0, 1, nil]),
        ([1, 2, 1, 2], 1, 2, true, [1, 1, 2, 2], [0, 2, 3, 1, 4, 5], [0, 1, 2, 3])
    ])
    func aReorderCommitsThePreviewAndRestoresItsRows(rows: [Int], source: Int, targetRow: Int, trailing: Bool,
                                                   expectedRows: [Int], expectedOrder: [Int], displayedRows: [Int?]) throws {
        try withSession(rows: rows) { session, space, directory in
            let originals = session.favorites(in: space.resolvedPersonaID)
            let ids = originals.map(\.id)
            let slots = FavoriteGridSlots(rowSizes: rows, defaultColumns: 4)
            let frame = CGRect(x: 0, y: 0, width: 240, height: slots.height(for: ids.count))
            let viewport = CGRect(x: 0, y: 0, width: 240, height: 600)
            let drag = SidebarDragState(scheduleHover: { _, action in action() }), owner = UUID()
            drag.favoriteGridTargets[space.id] = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport,
                                                                          count: ids.count, favoriteIDs: ids)
            let sourceFrame = slots.frames(for: ids.count, width: frame.width, origin: frame.origin)[source]
            drag.begin(.favorite(ids[source]), frame: sourceFrame, grabbedAt: sourceFrame.origin, owner: owner)
            defer { drag.end(ownedBy: owner) }
            let point = CGPoint(x: trailing ? 239 : 1, y: CGFloat(targetRow) * 50 + 22)
            drag.updateFavoriteGap(in: space.id, at: point, adding: false)
            let gap = try #require(drag.favoriteGap)
            let previewRows = gap.rowSizes ?? rows
            let preview = FavoriteGridSlots.items(ids, dragged: ids[source], gap: gap.index)
            #expect(previewRows == expectedRows)
            #expect(preview.map(\.entry) == expectedOrder.map { .favorite(ids[$0]) })
            #expect(session.favorites(in: space.resolvedPersonaID) == originals)
            #expect(session.favoriteRows(in: space.resolvedPersonaID) == rows)

            // Resolve release against the rendered gap after the source row shrinks or disappears.
            let projected = FavoriteGridSlots(rowSizes: previewRows, defaultColumns: 4)
            let projectedFrame = CGRect(origin: frame.origin, size: CGSize(width: frame.width, height: projected.height(for: ids.count)))
            drag.favoriteGridTargets[space.id] = FavoriteGridSlots.Target(
                slots: slots, frame: projectedFrame, viewport: viewport, count: ids.count, favoriteIDs: ids,
                displayedRows: displayedRows,
                displayedGap: FavoriteGridSlots.Placement(index: gap.index, frame: gap.frame, newRow: gap.newRow, rowSizes: previewRows))
            drag.updateFavoriteGap(in: space.id, at: point, adding: false)
            #expect(drag.favoriteGap == gap)
            drag.updateFavoriteGap(in: space.id, at: CGPoint(x: gap.frame.midX, y: gap.frame.midY), adding: false)
            let released = try #require(drag.favoriteGap)
            #expect(released == gap)
            session.moveFavorite(ids[source], toIndex: released.index, rowSizes: released.rowSizes)
            #expect(session.favorites(in: space.resolvedPersonaID).map(\.id) == expectedOrder.map { ids[$0] })
            #expect(session.favoriteRows(in: space.resolvedPersonaID) == previewRows)
            try session.saveNow().get()
            let registry = EngineRegistry()
            registry.register(SessionTestEngine())
            let restored = try BrowserSession(testRegistry: registry, directory: directory)
            #expect(restored.favorites(in: space.resolvedPersonaID) == session.favorites(in: space.resolvedPersonaID))
            let restoredSlots = FavoriteGridSlots(rowSizes: restored.favoriteRows(in: space.resolvedPersonaID), defaultColumns: 4)
            #expect(restoredSlots.rows(for: ids.count) == expectedRows)
            #expect(restoredSlots.frames(for: ids.count, width: frame.width, origin: frame.origin)[gap.index] == gap.frame)
        }
    }

    @Test(arguments: [[3, 1], [1, 3, 1], [3, 1, 1]])
    func restoringASessionKeepsTheSavedRows(rows: [Int]) throws {
        try withSession(rows: rows) { session, space, directory in
            let originals = session.favorites(in: space.resolvedPersonaID)
            try session.saveNow().get()
            let registry = EngineRegistry()
            registry.register(SessionTestEngine())
            let restored = try BrowserSession(testRegistry: registry, directory: directory)
            #expect(restored.favorites(in: space.resolvedPersonaID) == originals)
            let stored = restored.favoriteRows(in: space.resolvedPersonaID)
            #expect(stored == rows)
            let slots = FavoriteGridSlots(rowSizes: stored, defaultColumns: 4)
            #expect(slots.rows(for: restored.favorites(in: space.resolvedPersonaID).count) == rows)
        }
    }
}
