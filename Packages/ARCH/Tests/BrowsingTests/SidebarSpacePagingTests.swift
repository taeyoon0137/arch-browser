// Offscreen sidebar layout: favorites stay fixed within a Persona and travel with the space rows across Personas; only the current grid accepts drops.
import AppKit
import ARCHEngine
import SwiftUI
import Testing
@testable import Browsing

@MainActor @Suite struct SidebarSpacePagingTests {
    private func withSession(_ check: (BrowserSession, BrowserWindowModel, Space) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSpacePaging-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { session.windowWillClose(window) }
        try await check(session, window, space)
    }

    @Test func aSwipeMovesTabRowsButKeepsTheSharedGridInPlace() async throws {
        try await withSession { session, window, space in
            let next = session.makeSpace(in: space.resolvedPersonaID)
            _ = session.addFavorites([Favorite(url: URL(string: "https://example.org/favorite")!, title: "Favorite")], in: space.resolvedPersonaID)
            let firstTab = session.openTab(url: URL(string: "https://example.org/first")!, in: space.id, select: false)
            let nextTab = session.openTab(url: URL(string: "https://example.org/next")!, in: next.id, select: false)
            let drag = SidebarDragState(), frames = PagingFrames()
            let host = hosting(session: session, window: window, drag: drag, frames: frames)
            #expect(await layout(host) { drag.favoriteGridTargets[space.id]?.viewport.height == 600 && frames.rows[firstTab.id] != nil && frames.rows[nextTab.id] != nil })
            let grid = try #require(drag.favoriteGridTargets[space.id]?.frame)
            let firstRow = try #require(frames.rows[firstTab.id])
            let nextRow = try #require(frames.rows[nextTab.id])

            frames.translation = -80
            #expect(await layout(host) { frames.rows[firstTab.id]?.minX == firstRow.minX - 80 })
            #expect(frames.rows[nextTab.id]?.minX == nextRow.minX - 80)
            #expect(drag.favoriteGridTargets[space.id]?.frame == grid)
            #expect(Set(drag.favoriteGridTargets.keys) == [space.id])

            frames.translation = 0
            window.switchToSpace(next.id)
            #expect(await layout(host) { drag.favoriteGridTargets[next.id]?.frame == grid && frames.rows[nextTab.id]?.minX == firstRow.minX })
            #expect(Set(drag.favoriteGridTargets.keys) == [next.id])
            #expect(Set(drag.favoriteBarFrames.keys) == [next.id])
            let target = try #require(drag.favoriteGridTargets[next.id])
            #expect(target.placement(at: CGPoint(x: grid.midX, y: grid.midY), adding: true) != nil)
        }
    }

    @Test func changingPersonaKeepsOnlyTheCurrentGridsDropTarget() async throws {
        try await withSession { session, window, space in
            let other = session.addPersona(named: "Work")
            let otherSpace = try #require(session.spaces(in: other.id).first)
            let otherNext = session.makeSpace(in: other.id)
            _ = session.addFavorites([Favorite(url: URL(string: "https://example.org/personal")!, title: "Personal")], in: space.resolvedPersonaID)
            _ = session.addFavorites((0..<5).map { Favorite(url: URL(string: "https://example.org/work/\($0)")!, title: "Work \($0)") }, in: other.id)
            let drag = SidebarDragState(), frames = PagingFrames()
            let host = hosting(session: session, window: window, drag: drag, frames: frames)
            #expect(await layout(host) { drag.favoriteGridTargets[space.id]?.count == 1 })

            // A programmatic switch may pass multiple spaces before reaching its target.
            window.switchToSpace(otherNext.id)
            #expect(await layout(host) { drag.favoriteGridTargets[otherNext.id]?.count == 5 })
            #expect(Set(drag.favoriteGridTargets.keys) == [otherNext.id])
            #expect(Set(drag.favoriteBarFrames.keys) == [otherNext.id])
            let grid = try #require(drag.favoriteGridTargets[otherNext.id]?.frame)

            window.switchToSpace(otherSpace.id)
            #expect(await layout(host) { drag.favoriteGridTargets[otherSpace.id]?.count == 5 })
            #expect(drag.favoriteGridTargets[otherSpace.id]?.frame == grid)
            #expect(Set(drag.favoriteGridTargets.keys) == [otherSpace.id])
            #expect(Set(drag.favoriteBarFrames.keys) == [otherSpace.id])

            window.switchToSpace(space.id)
            #expect(await layout(host) { drag.favoriteGridTargets[space.id]?.count == 1 })
            #expect(Set(drag.favoriteGridTargets.keys) == [space.id])
        }
    }

    @Test func aSwipeAcrossPersonasMovesBothGridsWithTheirSpaceRows() async throws {
        try await withSession { session, window, space in
            let next = session.makeSpace(in: space.resolvedPersonaID)
            let other = session.addPersona(named: "Work")
            let otherSpace = try #require(session.spaces(in: other.id).first)
            let favorite = Favorite(url: URL(string: "https://example.org/personal")!, title: "Personal")
            let otherFavorites = (0..<5).map { Favorite(url: URL(string: "https://example.org/work/\($0)")!, title: "Work \($0)") }
            _ = session.addFavorites([favorite], in: space.resolvedPersonaID)
            _ = session.addFavorites(otherFavorites, in: other.id)
            let tab = session.openTab(url: URL(string: "https://example.org/tab")!, in: next.id, select: false)
            let otherTab = session.openTab(url: URL(string: "https://example.org/other")!, in: otherSpace.id, select: false)
            window.switchToSpace(next.id)
            let drag = SidebarDragState(), frames = PagingFrames()
            let host = hosting(session: session, window: window, drag: drag, frames: frames)
            #expect(await layout(host) { frames.items[favorite.id] != nil && frames.items[otherFavorites[0].id] != nil && frames.rows[tab.id] != nil && frames.rows[otherTab.id] != nil })
            let grid = try #require(frames.items[favorite.id])
            let otherGrid = try #require(frames.items[otherFavorites[0].id])
            let row = try #require(frames.rows[tab.id])
            let otherRow = try #require(frames.rows[otherTab.id])
            #expect(otherRow.minY > row.minY)

            frames.translation = -80
            #expect(await layout(host) { frames.rows[tab.id]?.minX == row.minX - 80 && frames.items[favorite.id]?.minX == grid.minX - 80 && frames.items[otherFavorites[0].id]?.minX == otherGrid.minX - 80 })
            #expect(frames.rows[otherTab.id]?.minX == otherRow.minX - 80)
            #expect(frames.rows[tab.id]?.minY == row.minY)
            #expect(frames.rows[otherTab.id]?.minY == otherRow.minY)
            #expect(frames.items[favorite.id]?.minY == grid.minY)
            #expect(frames.items[otherFavorites[0].id]?.minY == otherGrid.minY)
            #expect(Set(drag.favoriteGridTargets.keys) == [next.id])

            frames.translation = 0
            #expect(await layout(host) { frames.items[favorite.id] == grid && frames.items[otherFavorites[0].id] == otherGrid && frames.rows[tab.id] == row })
            // The other direction leads to a space in the same Persona, so only its rows move.
            frames.translation = 80
            #expect(await layout(host) { frames.rows[tab.id]?.minX == row.minX + 80 })
            #expect(frames.items[favorite.id] == grid)

            frames.translation = 0
            window.switchToSpace(otherSpace.id)
            #expect(await layout(host) { drag.favoriteGridTargets[otherSpace.id]?.count == 5 && frames.rows[otherTab.id]?.minX == row.minX })
            let settledGrid = try #require(frames.items[otherFavorites[0].id])
            let previousGrid = try #require(frames.items[favorite.id])
            let settledRow = try #require(frames.rows[otherTab.id])
            let previousRow = try #require(frames.rows[tab.id])
            #expect(settledRow.minY == otherRow.minY)
            #expect(Set(drag.favoriteGridTargets.keys) == [otherSpace.id])
            #expect(Set(drag.favoriteBarFrames.keys) == [otherSpace.id])

            frames.translation = 80
            #expect(await layout(host) { frames.items[otherFavorites[0].id]?.minX == settledGrid.minX + 80 && frames.items[favorite.id]?.minX == previousGrid.minX + 80 && frames.rows[otherTab.id]?.minX == settledRow.minX + 80 })
            #expect(frames.rows[tab.id]?.minX == previousRow.minX + 80)
            frames.translation = 0
            window.switchToSpace(next.id)
            #expect(await layout(host) { frames.items[favorite.id] == grid && frames.rows[tab.id] == row })
            #expect(Set(drag.favoriteGridTargets.keys) == [next.id])
        }
    }

    @Test func aSwipeToAPersonaWithoutFavoritesKeepsItsRowsAtTheirOwnHeight() async throws {
        try await withSession { session, window, space in
            let other = session.addPersona(named: "Work")
            let otherSpace = try #require(session.spaces(in: other.id).first)
            let favorite = Favorite(url: URL(string: "https://example.org/personal")!, title: "Personal")
            _ = session.addFavorites([favorite], in: space.resolvedPersonaID)
            let tab = session.openTab(url: URL(string: "https://example.org/tab")!, in: space.id, select: false)
            let otherTab = session.openTab(url: URL(string: "https://example.org/other")!, in: otherSpace.id, select: false)
            let drag = SidebarDragState(), frames = PagingFrames()
            let host = hosting(session: session, window: window, drag: drag, frames: frames)
            #expect(await layout(host) { frames.items[favorite.id] != nil && frames.rows[tab.id] != nil && frames.rows[otherTab.id] != nil })
            let grid = try #require(frames.items[favorite.id])
            let row = try #require(frames.rows[tab.id])
            let otherRow = try #require(frames.rows[otherTab.id])
            #expect(otherRow.minY < row.minY)

            frames.translation = -80
            #expect(await layout(host) { frames.items[favorite.id]?.minX == grid.minX - 80 && frames.rows[otherTab.id]?.minX == otherRow.minX - 80 })
            #expect(frames.rows[otherTab.id]?.minY == otherRow.minY)
            frames.translation = 0
            window.switchToSpace(otherSpace.id)
            #expect(await layout(host) { frames.rows[otherTab.id]?.minX == row.minX && drag.favoriteGridTargets.isEmpty })
            #expect(frames.rows[otherTab.id]?.minY == otherRow.minY)
        }
    }

    @Test func aPersonaWithoutFavoritesKeepsTheHeadersFirstFavoriteTarget() async throws {
        try await withSession { session, window, space in
            let tab = session.openTab(url: URL(string: "https://example.org/tab")!, in: space.id, select: false)
            let drag = SidebarDragState(), frames = PagingFrames()
            let host = hosting(session: session, window: window, drag: drag, frames: frames)
            #expect(await layout(host) { frames.rows[tab.id] != nil })
            let row = try #require(frames.rows[tab.id])
            let owner = UUID()
            drag.begin(.tab(tab.id), frame: row, grabbedAt: CGPoint(x: row.midX, y: row.midY), owner: owner)
            #expect(await layout(host) { drag.favoriteBarFrames[space.id]?.isEmpty == false })
            #expect(drag.favoriteGridTargets.isEmpty)
            #expect(Set(drag.favoriteBarFrames.keys) == [space.id])
            drag.end(ownedBy: owner)
        }
    }

    private func hosting(session: BrowserSession, window: BrowserWindowModel, drag: SidebarDragState, frames: PagingFrames) -> NSHostingView<PagingFixture> {
        let host = NSHostingView(rootView: PagingFixture(session: session, window: window, drag: drag, frames: frames))
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 600)
        return host
    }

    private func layout(_ host: NSView, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return condition()
    }
}

@MainActor private final class PagingFrames: ObservableObject {
    @Published var translation: CGFloat = 0
    var rows: [UUID: CGRect] = [:]
    var items: [UUID: CGRect] = [:]
}

private struct PagingFixture: View {
    let session: BrowserSession
    let window: BrowserWindowModel
    let drag: SidebarDragState
    @ObservedObject var frames: PagingFrames

    var body: some View {
        SidebarSpaceContent(session: session, translation: frames.translation)
            .frame(width: 260, height: 600)
            .coordinateSpace(name: BrowserWindowView.coordinateSpace)
            .environmentObject(drag)
            .environmentObject(window)
            .environment(\.sidebarWidth, 260)
            .onPreferenceChange(TabRowFramesKey.self) { frames.rows = $0 }
            .onPreferenceChange(SidebarItemFramesKey.self) { frames.items = $0 }
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }
}
