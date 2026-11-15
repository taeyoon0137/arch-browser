// Dragging a tab between a space's pinned and open lists (bookmark rule 2): the slot it takes beside the row under the pointer (`SidebarTabSlot.placement`) and at each list's end (`SidebarTabSlot.listEnd`), the rows the sidebar then shows (`project`), and what release commits, which leaves the tab as Pin Tab or Unpin Tab leaves it, saved page and unloading included. The frames stand in for a column whose pinned tabs, divider, open tabs, and New Tab row are stacked 2 points apart; the lifted row, the gesture, and the animation are app checks.
import ARCHEngine
import CoreGraphics
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct SidebarTabSlotTests {
    /// The visible list in the window: rows past its bottom, at 540, are scrolled out of sight.
    private let list = CGRect(x: 0, y: 40, width: 240, height: 500)

    /// A row of the column from `y`: 36 points tall, or `height` for the divider.
    private func frame(y: CGFloat, height: CGFloat = 36) -> CGRect {
        CGRect(x: 11, y: y, width: 218, height: height)
    }

    private func point(_ y: CGFloat) -> CGPoint {
        CGPoint(x: 120, y: y)
    }

    /// A session in a new temporary folder, which the caller removes.
    private func makeSession() throws -> (BrowserSession, Space, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        return (session, try #require(session.spaces.first), directory)
    }

    /// A tab of the space at `about:blank#name`, pinned as Pin Tab pins it, which saves its page.
    private func tab(_ name: String, pinned: Bool, in session: BrowserSession, _ space: Space) -> Tab {
        let tab = session.openTab(url: URL(string: "about:blank#\(name)")!, in: space.id, select: false)
        if pinned { session.togglePinned(tab) }
        return tab
    }

    /// What pinning and unpinning change in a tab, which a drop must leave as Pin Tab or Unpin Tab leaves it: the list, the saved page (the page the tab shows, or none), the folder, whether the tab has its page, and what closing it does.
    private struct PinState: Equatable {
        let isPinned: Bool
        let savesCurrentPage: Bool?
        let folderID: UUID?
        let isLoaded: Bool
        let close: TabCloseAction

        @MainActor init(_ tab: Tab) {
            isPinned = tab.isPinned
            savesCurrentPage = tab.savedPage.map { $0 == tab.currentPage }
            folderID = tab.folderID
            isLoaded = tab.isLoaded
            close = TabCloseAction.of(tab, reason: .user)
        }
    }

    @Test func aPinnedTabUnpinsWhereverItEntersTheOpenTabsRows() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let p1 = tab("p1", pinned: true, in: session, space), p2 = tab("p2", pinned: true, in: session, space)
        let o1 = tab("o1", pinned: false, in: session, space), o2 = tab("o2", pinned: false, in: session, space)
        let p2Row = frame(y: 138), divider = frame(y: 176, height: 10), o1Row = frame(y: 188), o2Row = frame(y: 226), newTab = frame(y: 264)
        #expect(p2.savedPage?.url == p2.url)

        // The divider ends the pinned list, so released there the last pinned tab stays where it is.
        #expect(SidebarTabSlot.listEnd(at: point(183), divider: divider, newTabRow: newTab, list: list) == true)
        // The first open tab's upper half takes it before that tab, though the pointer has not crossed the row's middle; the row stays under the pointer and its middle decides the next move.
        let upper = SidebarTabSlot.placement(beside: o1, rowFrame: o1Row, dragging: p2, slotFrame: p2Row, current: nil, at: point(192))
        #expect(upper?.slot == .beside(o1.id, folder: nil, pinned: false, after: false))
        #expect(upper?.takesRowsPlace == false)
        // Its lower half takes it after that tab, which moves up out of the way, so the slot lands under the pointer.
        let lower = SidebarTabSlot.placement(beside: o1, rowFrame: o1Row, dragging: p2, slotFrame: p2Row, current: nil, at: point(220))
        #expect(lower?.slot == .beside(o1.id, folder: nil, pinned: false, after: true))
        #expect(lower?.takesRowsPlace == true)
        // A pointer that skips the first open tab, as a fast drag does, enters the next one the same way.
        let skipped = SidebarTabSlot.placement(beside: o2, rowFrame: o2Row, dragging: p2, slotFrame: p2Row, current: nil, at: point(230))
        #expect(skipped?.slot == .beside(o2.id, folder: nil, pinned: false, after: false))

        let slot = try #require(upper).slot
        var pins = session.folderTree.rows(in: space.id, pinned: true), open = session.folderTree.rows(in: space.id, pinned: false)
        slot.project(p2, pinnedRows: &pins, openRows: &open)
        #expect(pins.map(\.id) == [p1.id] && open.map(\.id) == [p2.id, o1.id, o2.id])

        // Release unpins it as Unpin Tab unpins the other pinned tab.
        let contents = p2.webContents
        slot.commit(p2, in: space, session: session)
        session.togglePinned(p1)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).isEmpty)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [p1.id, p2.id, o1.id, o2.id])
        #expect(p2.savedPage == nil && p2.webContents === contents)
        #expect(PinState(p2) == PinState(p1))
        #expect(PinState(p2) == PinState(o1))
    }

    @Test func withinItsOwnListTheSlotStillWaitsForARowsMiddle() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = session.makeFolder(in: space.id, pinned: true)
        let inFolder = tab("folder", pinned: true, in: session, space)
        session.moveTab(inFolder.id, toFolder: folder.id)
        let p1 = tab("p1", pinned: true, in: session, space), p2 = tab("p2", pinned: true, in: session, space)
        let o1 = tab("o1", pinned: false, in: session, space)
        // The folder's row at 62, its tab's at 100, then the loose pinned tabs, the divider at 214, and the open tab.
        let inFolderRow = frame(y: 100), p1Row = frame(y: 138), p2Row = frame(y: 176), o1Row = frame(y: 226)

        // Among the pinned tabs, a row makes room only once the pointer crosses its middle, as before.
        #expect(SidebarTabSlot.placement(beside: p2, rowFrame: p2Row, dragging: p1, slotFrame: p1Row, current: nil, at: point(190)) == nil)
        let crossed = SidebarTabSlot.placement(beside: p2, rowFrame: p2Row, dragging: p1, slotFrame: p1Row, current: nil, at: point(200))
        #expect(crossed?.slot == .beside(p2.id, folder: nil, pinned: true, after: true) && crossed?.takesRowsPlace == true)
        // A tab leaving its folder for the loose pinned tabs crosses the row's middle, too, and goes before it.
        #expect(SidebarTabSlot.placement(beside: p1, rowFrame: p1Row, dragging: inFolder, slotFrame: inFolderRow, current: nil, at: point(150)) == nil)
        let outOfFolder = SidebarTabSlot.placement(beside: p1, rowFrame: p1Row, dragging: inFolder, slotFrame: inFolderRow, current: nil, at: point(160))
        #expect(outOfFolder?.slot == .beside(p1.id, folder: nil, pinned: true, after: false))

        // Once the pinned tab's slot is among the open tabs, before the first, at 188 below the risen divider, the open rows wait for their middles.
        let entered = try #require(SidebarTabSlot.placement(beside: o1, rowFrame: o1Row, dragging: p2, slotFrame: p2Row, current: nil, at: point(230)))
        #expect(entered.slot == .beside(o1.id, folder: nil, pinned: false, after: false))
        let slotRow = frame(y: 188)
        #expect(SidebarTabSlot.placement(beside: o1, rowFrame: o1Row, dragging: p2, slotFrame: slotRow, current: entered.slot, at: point(240)) == nil)
        let next = SidebarTabSlot.placement(beside: o1, rowFrame: o1Row, dragging: p2, slotFrame: slotRow, current: entered.slot, at: point(250))
        #expect(next?.slot == .beside(o1.id, folder: nil, pinned: false, after: true) && next?.takesRowsPlace == true)
    }

    @Test func anOpenTabPinsWhereverItEntersThePinnedTabsRows() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let p1 = tab("p1", pinned: true, in: session, space), p2 = tab("p2", pinned: true, in: session, space)
        let o1 = tab("o1", pinned: false, in: session, space), o2 = tab("o2", pinned: false, in: session, space)
        let p2Row = frame(y: 138), o1Row = frame(y: 188)

        // Coming from below, the last pinned tab's lower half takes the tab after it, and its upper half before it.
        let lower = SidebarTabSlot.placement(beside: p2, rowFrame: p2Row, dragging: o1, slotFrame: o1Row, current: nil, at: point(170))
        #expect(lower?.slot == .beside(p2.id, folder: nil, pinned: true, after: true) && lower?.takesRowsPlace == false)
        let upper = SidebarTabSlot.placement(beside: p2, rowFrame: p2Row, dragging: o1, slotFrame: o1Row, current: nil, at: point(145))
        #expect(upper?.slot == .beside(p2.id, folder: nil, pinned: true, after: false) && upper?.takesRowsPlace == true)

        // Release pins it as Pin Tab pins the other open tab, with the page it shows as its saved page.
        let slot = try #require(lower).slot
        var pins = session.folderTree.rows(in: space.id, pinned: true), open = session.folderTree.rows(in: space.id, pinned: false)
        slot.project(o1, pinnedRows: &pins, openRows: &open)
        #expect(pins.map(\.id) == [p1.id, p2.id, o1.id] && open.map(\.id) == [o2.id])
        slot.commit(o1, in: space, session: session)
        session.togglePinned(o2)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).map(\.id) == [p1.id, p2.id, o1.id, o2.id])
        #expect(o1.savedPage?.url == o1.url)
        #expect(PinState(o1) == PinState(o2))
        #expect(PinState(o1) == PinState(p1))

        // The divider takes it as the pinned list's last tab, too.
        let o3 = tab("o3", pinned: false, in: session, space)
        SidebarTabSlot.end(pinned: true).commit(o3, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).last === o3)
        #expect(PinState(o3) == PinState(p1))
    }

    @Test func theNewTabRowAndTheSpaceBelowItEndTheOpenList() throws {
        let divider = frame(y: 176, height: 10), newTab = frame(y: 188)
        #expect(SidebarTabSlot.listEnd(at: point(200), divider: divider, newTabRow: newTab, list: list) == false)
        // Below the New Tab row no row is, down to the visible list's bottom.
        #expect(SidebarTabSlot.listEnd(at: point(400), divider: divider, newTabRow: newTab, list: list) == false)
        #expect(SidebarTabSlot.listEnd(at: point(539), divider: divider, newTabRow: newTab, list: list) == false)
        #expect(SidebarTabSlot.listEnd(at: point(560), divider: divider, newTabRow: newTab, list: list) == nil)
        // Beside the rows, in the gap between the divider and the row, and over a pinned tab's row, no list ends.
        #expect(SidebarTabSlot.listEnd(at: CGPoint(x: 5, y: 400), divider: divider, newTabRow: newTab, list: list) == nil)
        #expect(SidebarTabSlot.listEnd(at: point(187), divider: divider, newTabRow: newTab, list: list) == nil)
        #expect(SidebarTabSlot.listEnd(at: point(150), divider: divider, newTabRow: newTab, list: list) == nil)
        // Scrolled so that the New Tab row is out of sight below the list, the space above the list's bottom is a row's, not the end's.
        #expect(SidebarTabSlot.listEnd(at: point(530), divider: frame(y: 476, height: 10), newTabRow: frame(y: 560), list: list) == nil)
        // Scrolled up, the divider above the list's top no longer counts, while the visible part of the New Tab row and the space below it do.
        #expect(SidebarTabSlot.listEnd(at: point(30), divider: frame(y: 26, height: 10), newTabRow: frame(y: 38), list: list) == nil)
        #expect(SidebarTabSlot.listEnd(at: point(45), divider: frame(y: 26, height: 10), newTabRow: frame(y: 38), list: list) == false)
        #expect(SidebarTabSlot.listEnd(at: point(300), divider: frame(y: 26, height: 10), newTabRow: frame(y: 38), list: list) == false)
    }

    @Test func aPinnedTabDroppedIntoAnEmptyOpenListUnpins() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let p1 = tab("p1", pinned: true, in: session, space), p2 = tab("p2", pinned: true, in: session, space)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).isEmpty)
        // Under the divider there is only the New Tab row and the space below it.
        #expect(SidebarTabSlot.listEnd(at: point(320), divider: frame(y: 176, height: 10), newTabRow: frame(y: 188), list: list) == false)
        let slot = SidebarTabSlot.end(pinned: false)
        var pins = session.folderTree.rows(in: space.id, pinned: true), open = session.folderTree.rows(in: space.id, pinned: false)
        slot.project(p1, pinnedRows: &pins, openRows: &open)
        #expect(pins.map(\.id) == [p2.id] && open.map(\.id) == [p1.id])
        slot.commit(p1, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [p1.id])
        session.togglePinned(p2)
        #expect(PinState(p1) == PinState(p2))
        #expect(!p1.isPinned && p1.savedPage == nil)
    }

    @Test func aSelectedTabLeavesItsCollapsedPinnedFolderForTheOpenList() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = session.makeFolder(in: space.id, pinned: true)
        let selected = tab("selected", pinned: true, in: session, space), other = tab("other", pinned: true, in: session, space)
        let last = tab("last", pinned: true, in: session, space)
        for tab in [selected, other, last] { session.moveTab(tab.id, toFolder: folder.id) }
        let o1 = tab("o1", pinned: false, in: session, space)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { session.windowWillClose(window) }
        window.selectTab(selected.id)
        session.toggleCollapsed(ofFolder: folder.id)
        #expect(window.selectedTabID == selected.id)

        // The collapsed folder shows only the selected tab, which the drag lifts; the first open tab's upper half takes it out of the folder.
        var pins = session.folderTree.rows(in: space.id, pinned: true) { $0.id == window.selectedTabID }
        var open = session.folderTree.rows(in: space.id, pinned: false)
        #expect(pins.map(\.id) == [folder.id, selected.id])
        let placement = SidebarTabSlot.placement(beside: o1, rowFrame: frame(y: 188), dragging: selected, slotFrame: frame(y: 138), current: nil, at: point(195))
        let slot = try #require(placement).slot
        #expect(slot == .beside(o1.id, folder: nil, pinned: false, after: false))
        slot.project(selected, pinnedRows: &pins, openRows: &open)
        #expect(pins.map(\.id) == [folder.id] && open.map(\.id) == [selected.id, o1.id])

        let contents = selected.webContents
        slot.commit(selected, in: space, session: session)
        session.togglePinned(other)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [other.id, selected.id, o1.id])
        #expect(session.folderTree.tabs(inFolder: folder.id).map(\.id) == [last.id])
        #expect(window.selectedTabID == selected.id && selected.webContents === contents && selected.isLoaded)
        #expect(PinState(selected) == PinState(other))
        #expect(selected.folderID == nil && selected.savedPage == nil)

        // The New Tab row takes a tab out of the folder to the open list's end.
        SidebarTabSlot.end(pinned: false).commit(last, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).last === last)
        #expect(PinState(last) == PinState(other))
    }

    @Test func anUnloadedPinnedTabUnpinsAndPinsAsTheMenuItemsLeaveIt() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dragged = tab("dragged", pinned: true, in: session, space), unpinned = tab("unpinned", pinned: true, in: session, space)
        let o1 = tab("o1", pinned: false, in: session, space)
        // Closing a pinned tab unloads it to a stand-in at its saved page (bookmark rule 4).
        #expect(session.closeTab(dragged) && session.closeTab(unpinned))
        #expect(!dragged.isLoaded && !unpinned.isLoaded)
        #expect(TabCloseAction.of(dragged, reason: .user) == .unload)
        let standIn = dragged.webContents

        let placement = SidebarTabSlot.placement(beside: o1, rowFrame: frame(y: 188), dragging: dragged, slotFrame: frame(y: 138), current: nil, at: point(220))
        try #require(placement).slot.commit(dragged, in: space, session: session)
        session.togglePinned(unpinned)
        // Unpinned, it keeps its stand-in without a saved page, and closing it now closes it into the closed list, as for any open tab.
        #expect(PinState(dragged) == PinState(unpinned))
        #expect(!dragged.isPinned && dragged.savedPage == nil && dragged.webContents === standIn && !dragged.isLoaded)
        #expect(TabCloseAction.of(dragged, reason: .user) == .close(remember: true))
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [unpinned.id, o1.id, dragged.id])

        // Dragged back over the divider, it pins again with its stand-in's page as its saved page, as Pin Tab pins the other.
        SidebarTabSlot.end(pinned: true).commit(dragged, in: space, session: session)
        session.togglePinned(unpinned)
        #expect(PinState(dragged) == PinState(unpinned))
        #expect(dragged.isPinned && dragged.savedPage?.url == dragged.url && !dragged.isLoaded)
    }
}
