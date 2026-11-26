// Favorite additions keep wrapping beyond the configured rows; removals shrink only their source row.
import AppKit
import ARCHEngine
import SwiftUI
import Testing
@testable import Browsing

@MainActor @Suite struct FavoriteCapacityTests {
    @Test(arguments: [6, 7, 10, 16], [[], [3, 3], [1, 2, 3], [1, 4, 1, 1, 1]])
    func draggedTabsCanAddToEveryRowAndBothBoundaries(count: Int, rowSizes: [Int]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFavoriteCapacity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let originals = (0..<count).map { Favorite(url: URL(string: "https://example.org/favorite/\($0)")!, title: "Favorite \($0)", personaID: space.resolvedPersonaID) }
        session.addFavorites(originals, in: space.resolvedPersonaID)
        let tab = session.openTab(url: URL(string: "https://example.org/incoming")!, in: space.id, select: false)
        let contents = tab.webContents
        let slots = FavoriteGridSlots(rowSizes: rowSizes, defaultColumns: 3)
        let frame = CGRect(x: 6, y: 80, width: 248, height: slots.height(for: count))
        let target = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: CGRect(x: 0, y: 80, width: 260, height: 600), count: count)
        let frames = slots.frames(for: count + 1, width: frame.width, origin: frame.origin)
        let points = frames.map { CGPoint(x: $0.midX, y: $0.midY) }
            + [CGPoint(x: frame.midX, y: frame.minY - 5), CGPoint(x: frame.midX, y: frame.maxY + 5)]
        for point in points {
            let drag = SidebarDragState(), owner = UUID()
            drag.favoriteGridTargets[space.id] = target
            drag.begin(.tab(tab.id), frame: CGRect(x: 6, y: 500, width: 248, height: 36), grabbedAt: CGPoint(x: 100, y: 518), owner: owner)
            let destination = try #require(drag.favoriteDestination(for: tab, in: space, at: point, session: session))
            drag.targetFavoriteSpaceID = destination
            drag.updateFavoriteGap(in: destination, at: point, adding: true)
            let gap = try #require(drag.favoriteGap)
            let index = gap.index
            #expect(drag.dropFavorite(tab, in: space, session: session) == gap.frame)
            let favorites = session.favorites(in: space.resolvedPersonaID)
            #expect(favorites.count == count + 1)
            let inserted = favorites[index]
            #expect(inserted.url == tab.url && session.favoriteTabs[inserted.id] === tab)
            #expect(tab.webContents === contents)
            var expected = originals
            expected.insert(inserted, at: index)
            #expect(favorites == expected)
            let committed = FavoriteGridSlots(rowSizes: gap.rowSizes ?? rowSizes, defaultColumns: 3)
            #expect(committed.frames(for: count + 1, width: frame.width, origin: frame.origin)[index] == gap.frame)
            if let sizes = gap.rowSizes {
                #expect(session.favoriteRows(in: space.resolvedPersonaID) == sizes)
                #expect(sizes.count <= committed.rows(for: count + 1).count)
                if let edge = gap.newRow {
                    #expect(committed.rows(for: count + 1) == (edge == .first ? [1] + slots.rows(for: count) : slots.rows(for: count) + [1]))
                }
            }
            session.removeFavorite(inserted)
            #expect(session.favorites(in: space.resolvedPersonaID) == originals)
            #expect(session.canAddFavorite(tab))
            drag.end(ownedBy: owner)
        }
    }

    @Test(arguments: [false, true])
    func aTallGridScrollsToLaterFavoritesAndKeepsTabsReachable(pinnedTabs: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFavoriteCapacity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { session.windowWillClose(window) }
        let suite = "ArchFavoriteCapacity-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: FavoriteTileLayout.columnsKey)
        let favorites = (0..<7).map { Favorite(url: URL(string: "https://example.org/favorite/\($0)")!, title: "Favorite \($0)") }
        session.addFavorites(favorites, in: space.resolvedPersonaID)
        session.setFavoriteRows(Array(repeating: 1, count: favorites.count), in: space.resolvedPersonaID)
        let tab = session.openTab(url: URL(string: "https://example.org/tab")!, in: space.id, select: false)
        let other = session.addPersona(named: "Other")
        let otherSpace = try #require(session.spaces(in: other.id).first)
        session.addFavorites((0..<7).map { Favorite(url: URL(string: "https://example.org/other/\($0)")!, title: "Other \($0)") }, in: other.id)
        session.setFavoriteRows(Array(repeating: 1, count: 7), in: other.id)
        let otherTab = session.openTab(url: URL(string: "https://example.org/other-tab")!, in: otherSpace.id, select: false)
        if pinnedTabs {
            for targetSpace in [space, otherSpace] {
                for index in 0..<6 {
                    let pinned = session.openTab(url: URL(string: "https://example.org/pinned/\(index)")!, in: targetSpace.id, select: false)
                    session.togglePinned(pinned)
                }
            }
        }
        let drag = SidebarDragState(), frames = CapacityFrames()
        let host = NSHostingView(rootView: SidebarSpaceContent(session: session, translation: 0)
            .frame(width: 260, height: 300)
            .coordinateSpace(name: BrowserWindowView.coordinateSpace)
            .environmentObject(drag)
            .environmentObject(window)
            .environment(\.sidebarWidth, 260)
            .defaultAppStorage(defaults)
            .onPreferenceChange(SidebarItemFramesKey.self) { frames.items = $0 }
            .onPreferenceChange(TabRowFramesKey.self) { frames.rows = $0 }
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 300)
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if drag.favoriteGridTargets[space.id]?.count == 7 && frames.items.count == 14 && frames.rows[tab.id] != nil && frames.rows[otherTab.id] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        let target = try #require(drag.favoriteGridTargets[space.id])
        let row = try #require(frames.rows[tab.id])
        #expect(row.maxY <= 300)
        #expect(frames.rows[otherTab.id]?.minY == row.minY)
        #expect(Set(drag.favoriteGridTargets.keys) == [space.id])
        #expect(target.frame.height > target.viewport.height)
        let first = try #require(frames.items[favorites[0].id])
        let point = CGPoint(x: first.midX, y: host.isFlipped ? first.midY : host.bounds.height - first.midY)
        let scrollView = try #require(scrollViews(in: host).first { scrollView in
            scrollView.bounds.contains(scrollView.convert(point, from: host))
        })
        let clip = scrollView.contentView
        let firstBoundary = try #require(target.placement(at: CGPoint(x: first.midX, y: target.frame.minY - 5), adding: true))
        #expect(firstBoundary.index == 0 && firstBoundary.newRow == .first)
        // SwiftUI's offscreen scroll host has no document size; use the measured grid and its end spacing.
        clip.scroll(to: CGPoint(x: 0, y: target.frame.height + 2 * FavoriteTileLayout.gridHeaderSpacing - clip.bounds.height))
        scrollView.reflectScrolledClipView(clip)
        let scrollDeadline = ContinuousClock.now + .seconds(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let last = frames.items[favorites[6].id], let visible = drag.favoriteGridTargets[space.id]?.viewport,
               visible.contains(CGPoint(x: last.midX, y: last.midY)) { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < scrollDeadline
        let last = try #require(frames.items[favorites[6].id])
        let scrolled = try #require(drag.favoriteGridTargets[space.id])
        let destination = CGPoint(x: last.midX, y: last.midY)
        #expect(scrolled.viewport.contains(destination))
        // The last one-tile row grows to two slots; its center selects the trailing slot.
        #expect(scrolled.placement(at: destination, adding: true)?.index == 7)
        #expect(scrolled.frame.minY < target.frame.minY)
        #expect(frames.rows[tab.id] == row)
        let lastBoundaryPoint = CGPoint(x: last.midX, y: scrolled.frame.maxY + 5)
        #expect(scrolled.viewport.contains(lastBoundaryPoint))
        let lastBoundary = try #require(scrolled.placement(at: lastBoundaryPoint, adding: true))
        #expect(lastBoundary.index == 7 && lastBoundary.newRow == .last)
        let owner = UUID()
        drag.begin(.tab(tab.id), frame: row, grabbedAt: CGPoint(x: row.midX, y: row.midY), owner: owner)
        defer { drag.end(ownedBy: owner) }
        drag.targetFavoriteSpaceID = space.id
        drag.updateFavoriteGap(in: space.id, at: lastBoundaryPoint, adding: true)
        let gapDeadline = ContinuousClock.now + .seconds(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if drag.favoriteGridTargets[space.id]?.frame.height == target.frame.height + FavoriteTileLayout.height + FavoriteTileLayout.spacing { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < gapDeadline
        let expanded = try #require(drag.favoriteGridTargets[space.id])
        clip.scroll(to: CGPoint(x: 0, y: expanded.frame.height + 2 * FavoriteTileLayout.gridHeaderSpacing - clip.bounds.height))
        scrollView.reflectScrolledClipView(clip)
        let expandedDeadline = ContinuousClock.now + .seconds(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let current = drag.favoriteGridTargets[space.id], current.frame.minY < scrolled.frame.minY { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < expandedDeadline
        let current = try #require(drag.favoriteGridTargets[space.id])
        let gapCenter = CGPoint(x: current.frame.midX, y: current.frame.maxY - FavoriteTileLayout.height / 2)
        #expect(current.viewport.contains(gapCenter))
        drag.updateFavoriteGap(in: space.id, at: gapCenter, adding: true)
        #expect(drag.favoriteGap?.index == 7 && drag.favoriteGap?.newRow == .last)
        #expect(drag.dropFavorite(tab, in: space, session: session) == drag.favoriteGap?.frame)
        #expect(session.favorites(in: space.resolvedPersonaID).count == 8)
        #expect(session.favorites(in: space.resolvedPersonaID).last?.url == tab.url)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    @Test func commandChangesKeepEveryTileVisibleAndReflowUntilTheGridIsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFavoriteCapacity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { session.windowWillClose(window) }
        let suite = "ArchFavoriteCapacity-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(3, forKey: FavoriteTileLayout.columnsKey)
        let drag = SidebarDragState(), frames = CapacityFrames()
        let host = NSHostingView(rootView: SidebarSpaceContent(session: session, translation: 0)
            .frame(width: 260, height: 600)
            .coordinateSpace(name: BrowserWindowView.coordinateSpace)
            .environmentObject(drag)
            .environmentObject(window)
            .environment(\.sidebarWidth, 260)
            .defaultAppStorage(defaults)
            .onPreferenceChange(SidebarItemFramesKey.self) { frames.items = $0 }
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 600)
        func mutateFavorites(_ change: () -> Void) {
            let standard = UserDefaults.standard
            let savedColumns = standard.object(forKey: FavoriteTileLayout.columnsKey)
            defer {
                standard.set(savedColumns, forKey: FavoriteTileLayout.columnsKey)
            }
            standard.set(3, forKey: FavoriteTileLayout.columnsKey)
            change()
        }
        func checkLayout(count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                let targetMatches = count == 0 ? drag.favoriteGridTargets[space.id] == nil : drag.favoriteGridTargets[space.id]?.count == count
                if targetMatches && frames.items.count == count { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            #expect(frames.items.count == count)
            guard count > 0 else {
                #expect(drag.favoriteGridTargets[space.id] == nil && drag.favoriteBarFrames[space.id] == nil)
                return
            }
            let target = try #require(drag.favoriteGridTargets[space.id])
            #expect(target.count == count)
            let expected = target.slots.frames(for: count, width: target.frame.width, origin: target.frame.origin)
            #expect(target.frame.height == target.slots.height(for: count))
            for (favorite, frame) in zip(session.favorites, expected) {
                let rendered = try #require(frames.items[favorite.id])
                // Centered scale transitions can round a fractional tile origin to the nearest pixel.
                #expect(abs(rendered.minX - frame.minX) <= 0.5 && abs(rendered.minY - frame.minY) <= 0.5)
                #expect(abs(rendered.width - frame.width) < 0.001 && rendered.height == frame.height)
                #expect(target.viewport.contains(CGPoint(x: frame.midX, y: frame.midY)))
            }
        }
        for count in 1...13 {
            let tab = session.openTab(url: URL(string: "https://example.org/favorite/\(count)")!, in: space.id, select: false)
            #expect(session.canAddFavorite(tab))
            mutateFavorites { session.addFavorite(tab) }
            #expect(session.favorites.count == count)
            try await checkLayout(count: count)
        }
        for count in stride(from: 12, through: 0, by: -1) {
            // Removing from the middle keeps each remaining tile in its own row.
            let favorite = session.favorites[session.favorites.count / 2]
            mutateFavorites { session.removeFavorite(favorite) }
            #expect(session.favorites.count == count && !session.favorites.contains { $0.id == favorite.id })
            try await checkLayout(count: count)
        }
    }
}

@MainActor private final class CapacityFrames {
    var items: [UUID: CGRect] = [:]
    var rows: [UUID: CGRect] = [:]
}
