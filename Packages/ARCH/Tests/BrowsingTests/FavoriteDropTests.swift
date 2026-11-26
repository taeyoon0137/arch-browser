// A tab reaches the shared favorites through the sidebar's external-drop wrapper, in window coordinates.
import AppKit
import ARCHEngine
import SwiftUI
import Testing
@testable import Browsing

@MainActor @Suite struct FavoriteDropTests {
    @Test func aFirstFavoriteSettlesAtTheTileThatReplacesTheEmptyHeaderTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFirstFavoriteDrop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { session.windowWillClose(window) }
        let tab = session.openTab(url: URL(string: "about:blank#first-favorite")!, in: space.id, select: false)
        let drag = SidebarDragState(scheduleHover: { _, action in action() }), owner = UUID()
        let host = NSHostingView(rootView: SidebarSpaceContent(session: session, translation: 0)
            .frame(width: 260, height: 600)
            .padding(.top, 80)
            .coordinateSpace(name: BrowserWindowView.coordinateSpace)
            .environmentObject(drag).environmentObject(window).environment(\.sidebarWidth, 260)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 680)
        func layout(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            #expect(condition())
        }
        try await layout { drag.favoriteTabTargets[space.id]?.frames[tab.id] != nil }
        let row = try #require(drag.favoriteTabTargets[space.id]?.frames[tab.id])
        drag.begin(.tab(tab.id), frame: row, grabbedAt: CGPoint(x: row.midX, y: row.midY), owner: owner)
        defer { drag.end(ownedBy: owner) }
        try await layout { drag.favoriteBarFrames[space.id] != nil }
        #expect(drag.favoriteGridTargets[space.id] == nil)
        let header = try #require(drag.favoriteBarFrames[space.id])
        let point = CGPoint(x: header.midX, y: header.midY)
        drag.move(to: point)
        let destination = try #require(drag.favoriteDestination(for: tab, in: space, at: point, session: session))
        drag.targetFavoriteSpaceID = destination
        drag.updateFavoriteGap(in: space.id, at: point, adding: true)
        #expect(drag.favoriteGap == nil && drag.tileFraction == 1)
        let landing = try #require(drag.dropFavorite(tab, in: space, session: session))
        let favorite = try #require(session.favorites.first)
        #expect(drag.liftedTab === tab && drag.settlingFavoriteID == favorite.id)
        drag.settle(into: landing, ownedBy: owner)
        #expect(drag.frame == landing && drag.tileFraction == 1 && !drag.isEntering)
        try await layout { drag.favoriteGridTargets[space.id]?.count == 1 }
        let grid = try #require(drag.favoriteGridTargets[space.id])
        let tile = try #require(grid.slots.frames(for: 1, width: grid.frame.width, origin: grid.frame.origin).first)
        #expect(landing == tile)
        #expect(grid.frame.origin == CGPoint(x: SidebarView.inset, y: 80))
    }

    @Test(arguments: [false, true])
    func aTabOverTheRenderedGridResolvesToAFavoriteInsertion(missingBarFrame: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFavoriteDrop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { session.windowWillClose(window) }
        _ = session.addFavorites((0..<5).map { Favorite(url: URL(string: "https://example.org/favorite/\($0)")!, title: "Favorite \($0)") }, in: space.resolvedPersonaID)
        let tab = session.openTab(url: URL(string: "https://example.org/tab")!, in: space.id, select: false)
        let drag = SidebarDragState(scheduleHover: { _, action in action() })
        let host = NSHostingView(rootView: SidebarSpaceContent(session: session, translation: 0)
            .modifier(SidebarDropTarget())
            .frame(width: 260, height: 600)
            .padding(.top, 80)
            .coordinateSpace(name: BrowserWindowView.coordinateSpace)
            .environmentObject(drag)
            .environmentObject(window)
            .environment(\.sidebarWidth, 260)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 680)
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if drag.favoriteGridTargets[space.id]?.viewport.height == 600 { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        let target = try #require(drag.favoriteGridTargets[space.id])
        #expect(target.frame.minY == 80)
        let point = CGPoint(x: target.frame.midX, y: target.frame.minY + 22)
        let owner = UUID()
        drag.begin(.tab(tab.id), frame: CGRect(x: 6, y: 300, width: 248, height: 36), grabbedAt: CGPoint(x: 120, y: 318), owner: owner)
        defer { drag.end(ownedBy: owner) }
        let destination = try #require(drag.favoriteDestination(for: tab, in: space, at: point, session: session))
        drag.targetFavoriteSpaceID = destination
        drag.updateFavoriteGap(in: destination, at: point, adding: true)
        let gap = try #require(drag.favoriteGap)
        #expect(gap.spaceID == space.id)
        #expect(drag.tileFraction == 1 && drag.frame.size == gap.frame.size)
        #expect(drag.favoriteBarFrames[space.id] != nil)
        if missingBarFrame { drag.favoriteBarFrames = [:] }
        #expect(drag.dropFavorite(tab, in: space, session: session) == gap.frame)
        let favorite = session.favorites(in: space.resolvedPersonaID)[gap.index]
        #expect(favorite.url == tab.url)
        #expect(session.favoriteTabs[favorite.id] === tab)
        #expect(!session.tabs.contains { $0 === tab })
        #expect(drag.liftedTab === tab && drag.settlingFavoriteID == favorite.id)
        drag.settle(into: gap.frame, ownedBy: owner)
        #expect(drag.isSettling && !drag.isEntering && !drag.isFadingOut)
        #expect(drag.frame == gap.frame && drag.tileFraction == 1)
        #expect(drag.liftedTab === tab && drag.settlingFavoriteID == favorite.id)
        drag.end(ownedBy: owner)
        #expect(drag.liftedTab == nil && drag.settlingFavoriteID == nil)
    }
}
