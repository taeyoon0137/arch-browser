// Favorite row moves use the targets reported by the rendered grid, without a window.
import AppKit
import ARCHEngine
import SwiftUI
import Testing
@testable import Browsing

@MainActor @Suite struct FavoriteRowDragTests {
    @Test(arguments: [(1, false), (1, true), (2, false), (2, true), (3, false), (3, true)], [false, true])
    func aRenderedFavoriteMovesBetweenRows(move: (source: Int, trailing: Bool), collapsed: Bool) async throws {
        let source = move.source
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFavoriteRowDrag-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { session.windowWillClose(window) }
        let suite = "ArchFavoriteRowDrag-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(4, forKey: FavoriteTileLayout.columnsKey)
        session.addFavorites((0..<4).map {
            Favorite(url: URL(string: "about:blank#favorite-\($0)")!, title: "Favorite \($0)")
        }, in: space.resolvedPersonaID)
        session.setFavoriteRows([1, 2, 1], in: space.resolvedPersonaID)
        let favorites = session.favorites(in: space.resolvedPersonaID)
        let drag = SidebarDragState(scheduleHover: { _, action in action() }), frames = FavoriteRowDragFrames(), owner = UUID()
        let host = NSHostingView(rootView: SidebarSpaceContent(session: session, translation: 0)
            .frame(width: 260, height: 600)
            .coordinateSpace(name: BrowserWindowView.coordinateSpace)
            .environmentObject(drag).environmentObject(window).environment(\.sidebarWidth, 260)
            .defaultAppStorage(defaults)
            .onPreferenceChange(SidebarItemFramesKey.self) { frames.items = $0 }
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 600)
        func layout(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            try #require(condition())
        }
        try await layout { drag.favoriteGridTargets[space.id] != nil && frames.items.count == 4 }
        let initial = try #require(drag.favoriteGridTargets[space.id])
        let tile = try #require(frames.items[favorites[source].id])
        let start = CGPoint(x: tile.midX, y: tile.midY)
        drag.begin(.favorite(favorites[source].id), frame: tile, grabbedAt: start, owner: owner)
        defer { drag.end(ownedBy: owner) }
        drag.updateFavoriteGap(in: space.id, at: start, adding: false)
        try await layout { drag.favoriteGridTargets[space.id]?.displayedGap != nil }
        if collapsed {
            // Leaving closes the gap and removes the source from the rendered rows before returning.
            drag.updateFavoriteGap(in: nil, at: CGPoint(x: initial.frame.minX - 20, y: start.y), adding: false)
            try await layout {
                if source == 3 { return drag.favoriteGridTargets[space.id]?.frame.height == 94 }
                return frames.items[favorites[source == 1 ? 2 : 1].id]?.width == initial.frame.width
            }
        }
        let point = CGPoint(x: move.trailing ? initial.frame.maxX - 1 : initial.frame.minX + 1,
                            y: initial.frame.minY + (source == 3 ? 72 : 122))
        let target = try #require(drag.favoriteGridTargets[space.id])
        #expect(target.slots.rows(for: target.count) == [1, 2, 1])
        #expect(target.favoriteIDs.firstIndex(of: favorites[source].id) == source)
        #expect(target.displayedRows == (collapsed && source == 3 ? [0, 1] : source == 3 ? [0, 1, nil] : [0, 1, 2]))
        let expected = source == 3 ? [1, 3] : [1, 1, 2]
        let expectedIndex = move.trailing ? 3 : (source == 3 ? 1 : 2)
        let placement = try #require(target.placement(at: point, adding: false, sourceIndex: source))
        #expect(placement.rowSizes == expected)
        #expect(placement.index == expectedIndex)
        drag.move(to: point)
        drag.updateFavoriteGap(in: space.id, at: point, adding: false)
        let gap = try #require(drag.favoriteGap)
        #expect(gap.rowSizes == expected)
        #expect(gap.index == placement.index && gap.frame == placement.frame)
        try await layout { drag.favoriteGridTargets[space.id]?.displayedGap?.rowSizes == gap.rowSizes }
        // A stationary release uses favoriteGapPoint; a moved pointer resolves the rendered rows again.
        drag.updateFavoriteGap(in: space.id, at: point, adding: false)
        #expect(drag.favoriteGap == gap)
        drag.updateFavoriteGap(in: space.id, at: CGPoint(x: point.x, y: point.y + 1), adding: false)
        #expect(drag.favoriteGap == gap)
        var order = favorites
        order.insert(order.remove(at: source), at: expectedIndex)
        #expect(session.favorites(in: space.resolvedPersonaID) == favorites)
        #expect(drag.dropFavoriteTile(favorites[source], in: space.id, session: session) == gap.frame)
        #expect(session.favorites(in: space.resolvedPersonaID) == order)
        #expect(session.favoriteRows(in: space.resolvedPersonaID) == expected)
        try session.saveNow().get()
        let restored = try BrowserSession(testRegistry: registry, directory: directory)
        #expect(restored.favorites(in: space.resolvedPersonaID) == order)
        #expect(restored.favoriteRows(in: space.resolvedPersonaID) == expected)
        drag.settle(into: gap.frame, ownedBy: owner)
        try await layout { drag.favoriteGridTargets[space.id]?.slots.rowSizes == expected && drag.favoriteGridTargets[space.id]?.displayedGap == nil }
        let committed = try #require(drag.favoriteGridTargets[space.id])
        let expectedFrames = committed.slots.frames(for: 4, width: committed.frame.width, origin: committed.frame.origin)
        for (favorite, expectedFrame) in zip(order, expectedFrames) {
            let rendered = try #require(frames.items[favorite.id])
            #expect(abs(rendered.minX - expectedFrame.minX) <= 0.5 && abs(rendered.minY - expectedFrame.minY) <= 0.5)
            #expect(abs(rendered.width - expectedFrame.width) <= 0.5 && rendered.height == expectedFrame.height)
        }
    }
}

@MainActor private final class FavoriteRowDragFrames {
    var items: [UUID: CGRect] = [:]
}
