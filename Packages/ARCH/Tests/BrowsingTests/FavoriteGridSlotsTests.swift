// Grid geometry and drag projection without SwiftUI rendering or a window.
import Foundation
import Testing
@testable import Browsing

@Suite struct FavoriteGridSlotsTests {
    private let origin = CGPoint(x: 12, y: 80)
    private let width: CGFloat = 228
    private let viewport = CGRect(x: 0, y: 80, width: 252, height: 600)

    @Test func mixedRowsShareTheirWidthAndKeepTheSidebarMetrics() {
        let slots = FavoriteGridSlots(rowSizes: [3, 1, 2], defaultColumns: 4)
        let frames = slots.frames(for: 8, width: width, origin: origin)
        #expect(slots.rows(for: 8) == [3, 1, 2, 2])
        #expect(frames[0] == CGRect(x: 12, y: 80, width: 72, height: 44))
        #expect(frames[2] == CGRect(x: 168, y: 80, width: 72, height: 44))
        #expect(frames[3] == CGRect(x: 12, y: 130, width: 228, height: 44))
        #expect(frames[4] == CGRect(x: 12, y: 180, width: 111, height: 44))
        #expect(frames[7] == CGRect(x: 129, y: 230, width: 111, height: 44))
        #expect(slots.height(for: 8) == 194)
        #expect(slots.height(for: 0) == 0 && slots.frames(for: 0, width: width, origin: origin).isEmpty)
    }

    @Test(arguments: [[], [1], [3, 1, 2], [4, 2, 1], [1, 4, 1, 1, 1]], 0...12)
    func incomingTabsGrowOnlyTheHoveredRowOrAddARowAfterIt(rowSizes: [Int], count: Int) throws {
        let slots = FavoriteGridSlots(rowSizes: rowSizes, defaultColumns: 4)
        let rows = slots.rows(for: count)
        let ids = (0..<count).map { _ in UUID() }
        let target = FavoriteGridSlots.Target(slots: slots, frame: CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: count))), viewport: viewport, count: count)
        var points: [CGPoint] = []
        for row in 0..<max(1, slots.rows(for: count).count) {
            for column in 0..<4 {
                points.append(CGPoint(x: origin.x + width * (CGFloat(column) + 0.5) / 4,
                                      y: origin.y + CGFloat(row) * 50 + 22))
            }
        }
        points.append(CGPoint(x: origin.x + width / 2, y: origin.y + slots.height(for: count) + 5))
        var reached: Set<Int> = []
        for point in points {
            let placement = try #require(target.placement(at: point, adding: true))
            reached.insert(placement.index)
            let projected = FavoriteGridSlots(rowSizes: placement.rowSizes ?? rowSizes, defaultColumns: 4)
            #expect(placement.frame == projected.frames(for: count + 1, width: width, origin: origin)[placement.index])
            let items = FavoriteGridSlots.items(ids, dragged: nil, gap: placement.index)
            #expect(items[placement.index].entry == .gap)
            #expect(items.filter { $0.entry != .gap }.map(\.entry) == ids.map(FavoriteGridSlots.Entry.favorite))
            #expect(items.count == count + 1 && !items.contains { $0.isCollapsed })
            // Repeating a move does not use the displaced tiles as new targets.
            #expect(target.placement(at: point, adding: true) == placement)
        }
        var expected: Set<Int> = [count]
        var start = 0
        for (row, tiles) in rows.enumerated() {
            if tiles < 4 {
                expected.formUnion(start...(start + tiles))
            } else {
                expected.insert(start + tiles)
            }
            let point = CGPoint(x: origin.x + width / 2, y: origin.y + CGFloat(row) * 50 + 22)
            let placement = try #require(target.placement(at: point, adding: true))
            let projected = FavoriteGridSlots(rowSizes: placement.rowSizes ?? rowSizes, defaultColumns: 4)
            var expectedRows = rows
            if tiles < 4 {
                expectedRows[row] += 1
            } else {
                expectedRows.insert(1, at: row + 1)
            }
            #expect(projected.rows(for: count + 1) == expectedRows)
            start += tiles
        }
        #expect(reached == expected)
    }

    @Test(arguments: [false, true])
    func aDisplayedGapStaysValidWhenFavoritesDisappear(adding: Bool) throws {
        // A concurrent removal shortens the grid while the drag still holds its previous index.
        let count = adding ? 3 : 4
        let slots = FavoriteGridSlots(rowSizes: [4], defaultColumns: 4)
        let projected = FavoriteGridSlots(rowSizes: [3, 1], defaultColumns: 4)
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: projected.height(for: 4)))
        let target = FavoriteGridSlots.Target(
            slots: slots, frame: frame, viewport: viewport, count: count,
            displayedRows: [0, nil],
            displayedGap: .init(index: 5, frame: .zero, rowSizes: [3, 1]))
        let gapFrame = projected.frames(for: 4, width: width, origin: origin)[3]
        let placement = try #require(target.placement(at: CGPoint(x: gapFrame.midX, y: gapFrame.midY),
                                                      adding: adding, sourceIndex: adding ? nil : 0))
        #expect(placement.index == 3 && placement.frame == gapFrame)
        #expect(placement.rowSizes == [3, 1])
    }

    @Test func favoritesReorderAcrossRowsWithoutDuplicatingTheirDragView() {
        let ids = (0..<7).map { _ in UUID() }
        for source in ids.indices {
            for destination in ids.indices {
                let items = FavoriteGridSlots.items(ids, dragged: ids[source], gap: destination)
                var expected = ids
                expected.insert(expected.remove(at: source), at: destination)
                #expect(items.map(\.entry) == expected.map(FavoriteGridSlots.Entry.favorite))
                #expect(Set(items.map(\.id)).count == ids.count)
                #expect(!items.contains { $0.isCollapsed })
            }
        }
    }

    @Test(arguments: [1, 4, 5, 9])
    func leavingClosesTheGapButKeepsTheDraggedIdentityAndReturnTarget(count: Int) throws {
        let slots = FavoriteGridSlots(rowSizes: [], defaultColumns: 4)
        let ids = (0..<count).map { _ in UUID() }, dragged = ids[0]
        let items = FavoriteGridSlots.items(ids, dragged: dragged, gap: nil)
        #expect(items.filter { !$0.isCollapsed }.map(\.entry) == ids.dropFirst().map(FavoriteGridSlots.Entry.favorite))
        #expect(items.last?.entry == .favorite(dragged) && items.last?.isCollapsed == true)
        #expect(Set(items.map(\.id)).count == ids.count)
        // The rendered grid has already shrunk, possibly to zero height.
        let collapsedFrame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: count - 1)))
        let target = FavoriteGridSlots.Target(slots: slots, frame: collapsedFrame, viewport: viewport, count: count)
        let lastFrame = try #require(slots.frames(for: count, width: width, origin: origin).last)
        let returned = try #require(target.placement(at: CGPoint(x: lastFrame.midX, y: lastFrame.midY), adding: false))
        #expect(returned.index == count - 1)
        #expect(!FavoriteGridSlots.items(ids, dragged: dragged, gap: returned.index).contains { $0.isCollapsed })
        #expect(FavoriteGridSlots.items(ids, dragged: nil, gap: nil).map(\.entry) == ids.map(FavoriteGridSlots.Entry.favorite))
    }

    @Test(arguments: [[], [3, 1, 2], [4, 2, 1]], [false, true])
    func boundaryDropsOpenSeparateRowsAndKeepTheirVisibleGaps(rowSizes: [Int], adding: Bool) throws {
        let slots = FavoriteGridSlots(rowSizes: rowSizes, defaultColumns: 4)
        // Includes full and partly filled last rows for additions and reorders.
        for count in 2...9 {
            let total = count + (adding ? 1 : 0)
            let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: count)))
            let target = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport, count: count)
            for edge in [FavoriteGridSlots.NewRow.first, .last] {
                for x in [frame.minX + 1, frame.midX, frame.maxX - 1] {
                    let point = CGPoint(x: x, y: edge == .first ? frame.minY - 5 : frame.maxY + 5)
                    let placement = try #require(target.placement(at: point, adding: adding))
                    let sizes = try #require(placement.rowSizes)
                    let projected = FavoriteGridSlots(rowSizes: sizes, defaultColumns: 4)
                    let others = slots.rows(for: total - 1)
                    #expect(projected.rows(for: total) == (edge == .first ? [1] + others : others + [1]))
                    #expect(placement.newRow == edge)
                    #expect(placement.index == (edge == .first ? 0 : total - 1))
                    #expect(placement.frame.width == width)
                    #expect(placement.frame.minY == (edge == .first ? origin.y : origin.y + slots.height(for: total - 1) + FavoriteTileLayout.spacing))
                    let center = CGPoint(x: placement.frame.midX, y: placement.frame.midY)
                    #expect(target.placement(at: center, adding: adding, holding: edge) == placement)
                    // The saved row-size encoding reproduces the preview's row break and gap frame exactly.
                    let saved = FavoriteGridSlots(rowSizes: FavoriteTileLayout.rowSizes(from: FavoriteTileLayout.encode(rowSizes: sizes)), defaultColumns: 4)
                    #expect(saved.frames(for: total, width: width, origin: origin)[placement.index] == placement.frame)
                    let ids = (0..<count).map { _ in UUID() }
                    let dragged = adding ? nil : ids[0]
                    let items = FavoriteGridSlots.items(ids, dragged: dragged, gap: placement.index)
                    #expect(items.count == total && Set(items.map(\.id)).count == total)
                    #expect(items[placement.index].entry == (dragged.map(FavoriteGridSlots.Entry.favorite) ?? .gap))
                }
            }
        }
    }

    @Test func boundaryRowsDiscardUnusedCountsAndStoreOnlyOccupiedTiles() throws {
        let slots = FavoriteGridSlots(rowSizes: [3, 2, 4, 2], defaultColumns: 4)
        #expect(slots.insertingRow(.first, remaining: 4).rowSizes == [1, 3, 1])
        #expect(slots.insertingRow(.last, remaining: 4).rowSizes == [3, 1, 1])
        // A single favorite has no other row to separate from during a reorder.
        let target = FavoriteGridSlots.Target(slots: slots, frame: CGRect(origin: origin, size: CGSize(width: width, height: 44)), viewport: viewport, count: 1)
        #expect(target.placement(at: CGPoint(x: 120, y: 75), adding: false)?.newRow == nil)
        #expect(target.placement(at: CGPoint(x: 120, y: 129), adding: false)?.newRow == nil)
        #expect(try #require(target.placement(at: CGPoint(x: 120, y: 129), adding: true)).rowSizes == [1, 1])
    }

    @Test(arguments: [FavoriteGridSlots.NewRow.first, .last])
    func addingABoundaryRowPreservesThreeAndOneTileRows(edge: FavoriteGridSlots.NewRow) throws {
        let slots = FavoriteGridSlots(rowSizes: [3, 1], defaultColumns: 4)
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: 4)))
        let target = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport, count: 4)
        let point = CGPoint(x: frame.midX, y: edge == .first ? frame.minY - 5 : frame.maxY + 5)
        let placement = try #require(target.placement(at: point, adding: true))
        let expected = edge == .first ? [1, 3, 1] : [3, 1, 1]
        let saved = FavoriteTileLayout.rowSizes(from: FavoriteTileLayout.encode(rowSizes: try #require(placement.rowSizes)))
        #expect(saved == expected)
        #expect(FavoriteTileLayout.counts(for: 5, rowSizes: saved, defaultColumns: 4) == expected)
        #expect(placement.index == (edge == .first ? 0 : 4))
        #expect(placement.frame.width == width)
    }

    @Test(arguments: [[2], [4], [2, 1], [4, 1]])
    func aRowTakesAnIncomingTileUntilFourWithoutChangingOtherRows(rows: [Int]) throws {
        let count = rows.reduce(0, +)
        let slots = FavoriteGridSlots(rowSizes: rows, defaultColumns: 4)
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: count)))
        let target = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport, count: count)
        let placement = try #require(target.placement(at: CGPoint(x: frame.maxX - 1, y: frame.minY + 22), adding: true))
        var expected = rows
        if rows[0] < 4 { expected[0] += 1 } else { expected.insert(1, at: 1) }
        #expect(placement.rowSizes == expected)
        #expect(placement.index == rows[0])
        let saved = FavoriteTileLayout.rowSizes(from: FavoriteTileLayout.encode(rowSizes: try #require(placement.rowSizes)))
        #expect(FavoriteTileLayout.counts(for: count + 1, rowSizes: saved, defaultColumns: 4) == expected)
    }

    @Test func aReorderedFavoriteShrinksOnlyItsSourceRow() throws {
        let slots = FavoriteGridSlots(rowSizes: [3, 1], defaultColumns: 4)
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: 4)))
        let target = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport, count: 4)
        let ids = (0..<4).map { _ in UUID() }

        let above = try #require(target.placement(at: CGPoint(x: frame.midX, y: frame.minY - 5), adding: false, sourceIndex: 3))
        #expect(above.rowSizes == [1, 3])
        #expect(above.index == 0)
        #expect(FavoriteGridSlots.items(ids, dragged: ids[3], gap: above.index).map(\.entry) == [ids[3], ids[0], ids[1], ids[2]].map(FavoriteGridSlots.Entry.favorite))

        let below = try #require(target.placement(at: CGPoint(x: frame.midX, y: frame.maxY + 5), adding: false, sourceIndex: 1))
        #expect(below.rowSizes == [2, 1, 1])
        #expect(below.index == 3)
        #expect(FavoriteGridSlots.items(ids, dragged: ids[1], gap: below.index).map(\.entry) == [ids[0], ids[2], ids[3], ids[1]].map(FavoriteGridSlots.Entry.favorite))

        let intoLast = try #require(target.placement(at: CGPoint(x: frame.maxX - 1, y: frame.maxY - 22), adding: false, sourceIndex: 1))
        #expect(intoLast.rowSizes == [2, 2])
        #expect(intoLast.index == 3)

        let intoFirst = try #require(target.placement(at: CGPoint(x: frame.maxX - 1, y: frame.minY + 22), adding: false, sourceIndex: 3))
        #expect(intoFirst.rowSizes == [4])
        #expect(intoFirst.index == 3)
    }

    @Test func staleSavedCountsNormalizeWithoutCreatingEmptyRows() {
        let stale = [0, -2, 9, 1, 4]
        let decoded = FavoriteTileLayout.rowSizes(from: Data("[0,-2,9,1,4]".utf8))
        #expect(decoded == [4, 1, 4])
        #expect(FavoriteTileLayout.rowSizes(from: FavoriteTileLayout.encode(rowSizes: stale)) == decoded)
        let normalized = FavoriteTileLayout.counts(for: 6, rowSizes: stale, defaultColumns: 4)
        #expect(normalized == [4, 1, 1])
        #expect(FavoriteTileLayout.rowSizes(from: FavoriteTileLayout.encode(rowSizes: normalized)) == normalized)
        #expect(FavoriteTileLayout.counts(for: 0, rowSizes: stale, defaultColumns: 4).isEmpty)
        #expect(FavoriteTileLayout.counts(for: 8, rowSizes: [2, 0, 1], defaultColumns: 3) == [2, 1, 3, 2])
        #expect(FavoriteTileLayout.rowSizes(from: Data("invalid".utf8)).isEmpty)
    }

    @Test(arguments: [[], [1, 4, 1, 1, 1]])
    func seventhFavoriteCanFillTheLastExistingRow(rowSizes: [Int]) throws {
        let slots = FavoriteGridSlots(rowSizes: rowSizes, defaultColumns: 4)
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: 6)))
        let target = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport, count: 6)
        let placement = try #require(target.placement(at: CGPoint(x: frame.maxX - 1, y: frame.maxY - 22), adding: true))
        let committed = FavoriteGridSlots(rowSizes: placement.rowSizes ?? rowSizes, defaultColumns: 4)
        #expect(placement.index == 6 && placement.newRow == nil)
        #expect(committed.rows(for: 7) == (rowSizes.isEmpty ? [4, 3] : [1, 4, 2]))
        #expect(committed.rowSizes.count <= committed.rows(for: 7).count)
        #expect(placement.frame == committed.frames(for: 7, width: width, origin: origin)[6])
    }

    @Test(arguments: [FavoriteGridSlots.NewRow.first, .last])
    func aNewRowCanAcceptAnotherTab(edge: FavoriteGridSlots.NewRow) throws {
        let slots = FavoriteGridSlots(rowSizes: [1, 4, 1, 1, 1], defaultColumns: 4).insertingRow(edge, remaining: 6)
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: 7)))
        let target = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport, count: 7)
        let point = CGPoint(x: frame.maxX - 1, y: edge == .first ? frame.minY + 22 : frame.maxY - 22)
        let placement = try #require(target.placement(at: point, adding: true))
        let committed = FavoriteGridSlots(rowSizes: placement.rowSizes ?? slots.rowSizes, defaultColumns: 4)
        #expect(placement.index == (edge == .first ? 1 : 7) && placement.newRow == nil)
        #expect(committed.rows(for: 8) == (edge == .first ? [2, 1, 4, 1] : [1, 4, 1, 2]))
        #expect(committed.rowSizes.count <= committed.rows(for: 8).count)
    }

    @Test(arguments: [false, true]) func anUnopenedBoundaryDoesNotCoverTheSpaceHeader(adding: Bool) throws {
        let slots = FavoriteGridSlots(rowSizes: [], defaultColumns: 4)
        let target = FavoriteGridSlots.Target(slots: slots, frame: CGRect(origin: origin, size: CGSize(width: width, height: 44)), viewport: viewport, count: 3)
        let below = CGPoint(x: 120, y: 150)
        #expect(target.placement(at: below, adding: adding) == nil)
        let gap = try #require(target.placement(at: CGPoint(x: 120, y: 129), adding: adding))
        #expect(gap.newRow == .last)
        #expect(target.placement(at: below, adding: adding, holding: gap.newRow) == gap)
    }

    @MainActor @Test func changingOnlyTheRowBoundaryUpdatesTheGapAndLeavingClearsIt() throws {
        let slots = FavoriteGridSlots(rowSizes: [3, 1], defaultColumns: 4)
        let drag = SidebarDragState(scheduleHover: { _, action in action() }), space = UUID(), owner = UUID()
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: 4)))
        drag.favoriteGridTargets[space] = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport, count: 4)
        drag.begin(.favorite(UUID()), frame: frame, grabbedAt: origin, owner: owner)
        drag.updateFavoriteGap(in: space, at: CGPoint(x: 20, y: 100), adding: false)
        #expect(drag.favoriteGap?.index == 0 && drag.favoriteGap?.rowSizes == nil)
        drag.updateFavoriteGap(in: space, at: CGPoint(x: 20, y: 75), adding: false)
        let first = try #require(drag.favoriteGap)
        #expect(first.index == 0 && first.rowSizes == [1, 3])
        drag.updateFavoriteGap(in: space, at: CGPoint(x: 120, y: 100), adding: false)
        #expect(drag.favoriteGap == first)
        drag.updateFavoriteGap(in: space, at: CGPoint(x: -50, y: 100), adding: false)
        #expect(drag.favoriteGap == nil)
        drag.updateFavoriteGap(in: space, at: CGPoint(x: 120, y: 179), adding: false)
        #expect(drag.favoriteGap?.newRow == .last)
        drag.end(ownedBy: owner)
        #expect(drag.favoriteGap == nil)
        #expect(drag.favoriteGridTargets[space]?.slots.rowSizes == [3, 1])
    }

    @MainActor @Test func aCollapsedSingletonKeepsTheVisibleDestinationRow() throws {
        let slots = FavoriteGridSlots(rowSizes: [1, 2, 1], defaultColumns: 4)
        let ids = (0..<4).map { _ in UUID() }
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: 94))
        let drag = SidebarDragState(scheduleHover: { _, action in action() }), space = UUID(), owner = UUID()
        drag.favoriteGridTargets[space] = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport, count: 4,
                                                                 favoriteIDs: ids, displayedRows: [1, 2])
        let source = slots.frames(for: 4, width: width, origin: origin)[0]
        drag.begin(.favorite(ids[0]), frame: source, grabbedAt: CGPoint(x: source.midX, y: source.midY), owner: owner)
        defer { drag.end(ownedBy: owner) }
        drag.updateFavoriteGap(in: space, at: CGPoint(x: frame.maxX - 1, y: 152), adding: false)
        let gap = try #require(drag.favoriteGap)
        #expect(gap.rowSizes == [2, 2])
        #expect(gap.index == 3)
        #expect(gap.frame.minY == 130)
        #expect(FavoriteGridSlots.items(ids, dragged: ids[0], gap: gap.index).map(\.entry) == [ids[1], ids[2], ids[3], ids[0]].map(FavoriteGridSlots.Entry.favorite))
    }

    @Test func anInsertedGapRowKeepsItsTargetAndTheRowsBelowItReachable() throws {
        let slots = FavoriteGridSlots(rowSizes: [4, 2], defaultColumns: 4)
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: 6)))
        let target = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport, count: 6)
        let gap = try #require(target.placement(at: CGPoint(x: frame.maxX - 1, y: frame.minY + 22), adding: true))
        #expect(gap.rowSizes == [4, 1, 2])
        let projected = FavoriteGridSlots(rowSizes: try #require(gap.rowSizes), defaultColumns: 4)
        let expanded = FavoriteGridSlots.Target(slots: slots,
                                               frame: CGRect(origin: origin, size: CGSize(width: width, height: projected.height(for: 7))),
                                               viewport: viewport, count: 6, displayedRows: [0, nil, 1], displayedGap: gap)
        let held = try #require(expanded.placement(at: CGPoint(x: gap.frame.midX, y: gap.frame.midY), adding: true))
        #expect(held == gap)
        let last = try #require(expanded.placement(at: CGPoint(x: frame.maxX - 1, y: origin.y + 122), adding: true))
        #expect(last.rowSizes == [4, 3])
        #expect(last.index == 6)
        let committed = FavoriteGridSlots(rowSizes: try #require(last.rowSizes), defaultColumns: 4)
        #expect(last.frame == committed.frames(for: 7, width: width, origin: origin)[6])
        #expect(Array(committed.frames(for: 7, width: width, origin: origin).prefix(4)) == Array(slots.frames(for: 6, width: width, origin: origin).prefix(4)))
    }

    @MainActor @Test(arguments: [false, true])
    func aHeldFavoriteGapRetargetsAfterLeavingOrScrolling(scroll: Bool) throws {
        let slots = FavoriteGridSlots(rowSizes: [1, 2, 1], defaultColumns: 4)
        let ids = (0..<4).map { _ in UUID() }
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: 4)))
        let drag = SidebarDragState(scheduleHover: { _, action in action() }), space = UUID(), owner = UUID()
        drag.favoriteGridTargets[space] = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport,
                                                                  count: 4, favoriteIDs: ids)
        drag.begin(.favorite(ids[0]), frame: frame, grabbedAt: origin, owner: owner)
        defer { drag.end(ownedBy: owner) }
        let point = CGPoint(x: frame.maxX - 1, y: origin.y + 122)
        drag.updateFavoriteGap(in: space, at: point, adding: false)
        let gap = try #require(drag.favoriteGap)
        #expect(gap.rowSizes == [2, 2])
        var collapsedFrame = CGRect(origin: origin, size: CGSize(width: width, height: 94))
        if scroll {
            collapsedFrame.origin.y -= 20
        } else {
            drag.updateFavoriteGap(in: nil, at: point, adding: false)
            #expect(drag.favoriteGap == nil)
        }
        drag.favoriteGridTargets[space] = FavoriteGridSlots.Target(slots: slots, frame: collapsedFrame, viewport: viewport,
                                                                  count: 4, favoriteIDs: ids, displayedRows: [1, 2])
        drag.updateFavoriteGap(in: space, at: point, adding: false)
        #expect(drag.favoriteGap?.rowSizes == [2, 1, 1])
        #expect(drag.favoriteGap?.newRow == .last)
        // A moved pointer can choose another occupied row immediately.
        drag.updateFavoriteGap(in: space, at: CGPoint(x: point.x, y: origin.y + 22), adding: false)
        #expect(drag.favoriteGap?.rowSizes == [3, 1])
        #expect(drag.favoriteGap?.newRow == nil)
    }

    @MainActor @Test func aMovedFavoriteGapKeepsItsDwellAcrossRepeatedGeometryUpdates() throws {
        let slots = FavoriteGridSlots(rowSizes: [1, 2, 1], defaultColumns: 4)
        let ids = (0..<4).map { _ in UUID() }
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: 4)))
        var callbacks: [() -> Void] = []
        let drag = SidebarDragState(scheduleHover: { _, action in callbacks.append(action) })
        let space = UUID(), owner = UUID()
        drag.favoriteGridTargets[space] = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport,
                                                                  count: 4, favoriteIDs: ids)
        let source = slots.frames(for: 4, width: width, origin: origin)[0]
        drag.begin(.favorite(ids[0]), frame: source, grabbedAt: CGPoint(x: source.midX, y: source.midY), owner: owner)
        defer { drag.end(ownedBy: owner) }
        drag.updateFavoriteGap(in: space, at: CGPoint(x: frame.maxX - 1, y: origin.y + 122), adding: false)
        let confirmFirst = try #require(callbacks.first)
        confirmFirst()
        let confirmed = try #require(drag.favoriteGap)
        #expect(confirmed.rowSizes == [2, 2])
        callbacks.removeAll()

        let collapsedFrame = CGRect(origin: origin, size: CGSize(width: width, height: 94))
        drag.favoriteGridTargets[space] = FavoriteGridSlots.Target(slots: slots, frame: collapsedFrame, viewport: viewport,
                                                                  count: 4, favoriteIDs: ids, displayedRows: [1, 2])
        let next = CGPoint(x: frame.maxX - 1, y: origin.y + 22)
        drag.updateFavoriteGap(in: space, at: next, adding: false)
        #expect(drag.favoriteGap == confirmed)
        drag.updateFavoriteGap(in: space, at: next, adding: false)
        #expect(callbacks.count == 1 && drag.favoriteGap == confirmed)
        let confirmNext = try #require(callbacks.first)
        confirmNext()
        #expect(drag.favoriteGap?.rowSizes == [3, 1])
        #expect(drag.favoriteGap?.index == 2)
    }

    @Test func spacingAndOuterEdgesHaveDeterministicInsertionIndexes() {
        let slots = FavoriteGridSlots(rowSizes: [2, 2], defaultColumns: 4)
        func index(_ x: CGFloat, _ y: CGFloat) -> Int {
            slots.slot(at: CGPoint(x: x, y: y), count: 4, width: width, origin: origin)
        }
        #expect(index(125.9, 100) == 0 && index(126, 100) == 1)
        #expect(index(20, 126.9) == 0 && index(20, 127) == 2)
        #expect(index(239, 79) == 0 && index(13, 174) == 3)
        #expect(index(-100, 150) == 2 && index(1000, 150) == 3)
    }

    @Test func targetsRejectPointsOutsideTheVisibleSidebar() {
        let slots = FavoriteGridSlots(rowSizes: [], defaultColumns: 4)
        let target = FavoriteGridSlots.Target(slots: slots, frame: CGRect(x: 12, y: 80, width: 228, height: 144),
                                              viewport: CGRect(x: 0, y: 80, width: 252, height: 80), count: 9)
        #expect(target.placement(at: CGPoint(x: 11, y: 100), adding: true) == nil)
        #expect(target.placement(at: CGPoint(x: 241, y: 100), adding: true) == nil)
        #expect(target.placement(at: CGPoint(x: 120, y: 69), adding: true) == nil)
        #expect(target.placement(at: CGPoint(x: 120, y: 180), adding: true) == nil)
    }

    @MainActor @Test func theFinalPointerResolvesTheGapBeforeAnyViewUpdate() throws {
        let slots = FavoriteGridSlots(rowSizes: [2, 1], defaultColumns: 4)
        let drag = SidebarDragState(scheduleHover: { _, action in action() }), space = UUID(), owner = UUID()
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: slots.height(for: 3)))
        drag.favoriteGridTargets[space] = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: viewport, count: 3)
        drag.begin(.tab(UUID()), frame: frame, grabbedAt: origin, owner: owner)
        drag.updateFavoriteGap(in: space, at: CGPoint(x: 230, y: 100), adding: true)
        #expect(drag.favoriteGap?.index == 2)
        drag.updateFavoriteGap(in: space, at: CGPoint(x: 120, y: 190), adding: true)
        let released = try #require(drag.favoriteGap)
        #expect(released.index == 3 && released.frame.minY == 180)
        drag.updateFavoriteGap(in: nil, at: .zero, adding: true)
        #expect(drag.favoriteGap == nil)
        drag.updateFavoriteGap(in: space, at: CGPoint(x: 230, y: 75), adding: true)
        #expect(drag.favoriteGap?.index == 0)
        drag.end(ownedBy: owner)
        #expect(drag.favoriteGap == nil)
    }
}
