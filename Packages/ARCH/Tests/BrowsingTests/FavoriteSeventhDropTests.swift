// A seventh favorite reaches the rendered grid with both default rows and saved rows left by boundary drops.
import AppKit
import ARCHEngine
import SwiftUI
import Testing
@testable import Browsing

@MainActor @Suite struct FavoriteSeventhDropTests {
    private enum Addition: CaseIterable { case existingRow, newRow, firstRow, menu }

    @Test(arguments: [[], [1, 4, 1, 1, 1]], [300, 600])
    func aSeventhFavoriteUsesTheRenderedDropOrMenuPath(rowSizes: [Int], height: Int) async throws {
        for addition in Addition.allCases {
            try await checkSeventhFavorite(rowSizes: rowSizes, height: CGFloat(height), addition: addition)
        }
    }

    private func checkSeventhFavorite(rowSizes: [Int], height: CGFloat, addition: Addition) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSeventhFavorite-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { session.windowWillClose(window) }
        let suite = "ArchSeventhFavorite-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(4, forKey: FavoriteTileLayout.columnsKey)
        session.addFavorites((0..<6).map {
            Favorite(url: URL(string: "https://example.org/favorite/\($0)")!, title: "Favorite \($0)")
        }, in: space.resolvedPersonaID)
        session.setFavoriteRows(rowSizes.isEmpty ? [4, 2] : rowSizes, in: space.resolvedPersonaID)
        let originals = session.favorites(in: space.resolvedPersonaID)
        let tab = session.openTab(url: URL(string: "https://example.org/seventh")!, in: space.id, select: false)
        let contents = tab.webContents
        let drag = SidebarDragState(scheduleHover: { _, action in action() }), frames = SeventhFavoriteFrames()
        let host = NSHostingView(rootView: SidebarSpaceContent(session: session, translation: 0)
            .frame(width: 260, height: height)
            .coordinateSpace(name: BrowserWindowView.coordinateSpace)
            .environmentObject(drag).environmentObject(window).environment(\.sidebarWidth, 260)
            .defaultAppStorage(defaults)
            .onPreferenceChange(SidebarItemFramesKey.self) { frames.items = $0 }
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        host.frame = CGRect(x: 0, y: 0, width: 260, height: height)
        func layout(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            #expect(condition())
        }
        try await layout { drag.favoriteGridTargets[space.id]?.count == 6 && frames.items.count == 6 }
        let target = try #require(drag.favoriteGridTargets[space.id])
        #expect(target.slots.rowSizes == (rowSizes.isEmpty ? [4, 2] : [1, 4, 1]))
        #expect(session.canAddFavorite(tab))
        let expectedIndex = addition == .firstRow ? 0 : 6
        var landing: CGRect?
        if addition == .menu {
            // Both the context menu and the menu bar call this overload after canAddFavorite.
            let savedColumns = UserDefaults.standard.object(forKey: FavoriteTileLayout.columnsKey)
            do {
                defer {
                    UserDefaults.standard.set(savedColumns, forKey: FavoriteTileLayout.columnsKey)
                }
                UserDefaults.standard.set(4, forKey: FavoriteTileLayout.columnsKey)
                session.addFavorite(tab)
            }
        } else {
            let last = try #require(frames.items[originals[5].id])
            let point = CGPoint(x: target.frame.maxX - target.frame.width / 4,
                                y: addition == .firstRow ? target.frame.minY - 5 : (addition == .newRow ? target.frame.maxY + 5 : last.midY))
            let owner = UUID()
            drag.begin(.tab(tab.id), frame: CGRect(x: 6, y: height - 44, width: 248, height: 36),
                       grabbedAt: CGPoint(x: 100, y: height - 26), owner: owner)
            defer { drag.end(ownedBy: owner) }
            // Opening the new row can enable scrolling and move the grid's origin. Resolve the
            // stationary pointer after every layout, as hover and final release do.
            for _ in 0..<3 {
                let destination = try #require(drag.favoriteDestination(for: tab, in: space, at: point, session: session))
                drag.targetFavoriteSpaceID = destination
                drag.updateFavoriteGap(in: destination, at: point, adding: true)
                let gap = try #require(drag.favoriteGap)
                #expect(gap.index == expectedIndex)
                #expect(gap.newRow == (addition == .firstRow ? .first : (addition == .newRow ? .last : nil)))
                let projected = FavoriteGridSlots(rowSizes: gap.rowSizes ?? rowSizes, defaultColumns: 4)
                let occupied = rowSizes.isEmpty ? [4, 2] : [1, 4, 1]
                let expectedRows: [Int]
                switch addition {
                case .firstRow: expectedRows = [1] + occupied
                case .newRow: expectedRows = occupied + [1]
                case .existingRow, .menu: expectedRows = rowSizes.isEmpty ? [4, 3] : [1, 4, 2]
                }
                #expect(projected.rows(for: 7) == expectedRows)
                try await layout { drag.favoriteGridTargets[space.id]?.frame.height == projected.height(for: 7) }
            }
            let destination = try #require(drag.favoriteDestination(for: tab, in: space, at: point, session: session))
            drag.targetFavoriteSpaceID = destination
            drag.updateFavoriteGap(in: destination, at: point, adding: true)
            let gap = try #require(drag.favoriteGap)
            #expect(gap.index == expectedIndex)
            landing = drag.dropFavorite(tab, in: space, session: session)
            #expect(landing == gap.frame)
            let committed = session.favoriteRows(in: space.resolvedPersonaID)
            let layout = FavoriteGridSlots(rowSizes: committed, defaultColumns: 4)
            #expect(committed.count <= layout.rows(for: 7).count)
            if addition == .newRow { #expect(committed.last == 1) }
            drag.end(ownedBy: owner)
        }
        let favorites = session.favorites(in: space.resolvedPersonaID)
        #expect(favorites.count == 7)
        #expect(Array(addition == .firstRow ? favorites.suffix(6) : favorites.prefix(6)) == originals)
        let seventh = try #require(addition == .firstRow ? favorites.first : favorites.last)
        #expect(seventh.url == tab.url && session.favoriteTabs[seventh.id] === tab)
        #expect(tab.webContents === contents && !session.tabs.contains { $0 === tab })
        #expect(!session.canAddFavorite(tab))
        try await layout { drag.favoriteGridTargets[space.id]?.count == 7 && frames.items.count == 7 }
        let committed = try #require(drag.favoriteGridTargets[space.id])
        if addition == .menu { #expect(committed.slots.rowSizes == (rowSizes.isEmpty ? [4, 3] : [1, 4, 2])) }
        let expected = committed.slots.frames(for: 7, width: committed.frame.width, origin: committed.frame.origin)
        for (favorite, frame) in zip(favorites, expected) {
            let rendered = try #require(frames.items[favorite.id])
            #expect(abs(rendered.minX - frame.minX) <= 0.5 && abs(rendered.minY - frame.minY) <= 0.5)
            #expect(abs(rendered.width - frame.width) <= 0.5 && rendered.height == frame.height)
        }
        if let landing {
            let rendered = try #require(frames.items[seventh.id])
            // SwiftUI rounds the centers of fractional-width tiles to the nearest pixel.
            #expect(abs(rendered.minX - landing.minX) <= 0.5 && abs(rendered.minY - landing.minY) <= 0.5)
            #expect(abs(rendered.width - landing.width) <= 0.5 && rendered.height == landing.height)
        }
    }
}

@MainActor private final class SeventhFavoriteFrames {
    var items: [UUID: CGRect] = [:]
}
