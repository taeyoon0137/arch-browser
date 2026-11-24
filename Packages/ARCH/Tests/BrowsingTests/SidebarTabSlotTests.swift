// Dragging a tab between a space's pinned and open lists (bookmark rule 2): tests cover slots beside the row under the pointer (`SidebarTabSlot.placement`), at each list's end (`SidebarTabSlot.listEnd`), and under the divider where no row takes the tab (`SidebarTabSlot.unpinning`). They also cover scrolling under a pointer held near the list's end (`DragAutoScroll`). The slot selection chain sees the rows' new frames (`SidebarTabSlot.next`). Tests check the rows the sidebar then shows (`project`). Release leaves the tab as Pin Tab or Unpin Tab does, including its saved page, unloading, live folder items, and agent tabs. The frames stand in for a column with pinned tabs, a divider, open tabs, and a New Tab row stacked 2 points apart. App checks cover the lifted row, the gesture, and the animation.
import ARCHEngine
import CoreGraphics
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct SidebarTabSlotTests {
    /// The visible list in the window. Scrolling moves rows past its bottom at 540 out of sight.
    private let list = CGRect(x: 0, y: 40, width: 240, height: 500)

    /// A row of the column from `y`: 36 points tall, or `height` for the divider.
    private func frame(y: CGFloat, height: CGFloat = 36) -> CGRect {
        CGRect(x: 11, y: y, width: 218, height: height)
    }

    private func point(_ y: CGFloat) -> CGPoint {
        CGPoint(x: 120, y: y)
    }

    /// The frames of rows stacked from `top`, 2 points apart. Scrolling the list `scrolled` points farther down moves each row up as far.
    private func stacked(_ ids: [UUID], from top: CGFloat, scrolled: CGFloat = 0) -> [UUID: CGRect] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, frame(y: top + CGFloat($0) * 38 - scrolled)) })
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

    /// A tab of the space at `about:blank#name`. Pinning it works as Pin Tab does and saves its page.
    private func tab(_ name: String, pinned: Bool, in session: BrowserSession, _ space: Space) -> Tab {
        let tab = session.openTab(url: URL(string: "about:blank#\(name)")!, in: space.id, select: false)
        if pinned { session.togglePinned(tab) }
        return tab
    }

    /// Pinning and unpinning change the tab's list, saved page (the page the tab shows, or none), folder, whether it has its page, and what closing it does. A drop must leave these as Pin Tab or Unpin Tab does.
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

        // The divider ends the pinned list. Releasing the last pinned tab there leaves it in place.
        #expect(SidebarTabSlot.listEnd(at: point(183), divider: divider, newTabRow: newTab, list: list) == true)
        // The first open tab's upper half places it before that tab, even before the pointer crosses the row's middle. The row stays under the pointer. Its middle decides the next move.
        let upper = SidebarTabSlot.placement(beside: o1, rowFrame: o1Row, dragging: p2, slotFrame: p2Row, current: nil, at: point(192))
        #expect(upper?.slot == .beside(o1.id, folder: nil, pinned: false, after: false))
        #expect(upper?.takesRowsPlace == false)
        // Its lower half places it after that tab. That tab moves up out of the way, so the slot lands under the pointer.
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

        // The pinned tab's slot enters the open tabs before the first, at 188 below the raised divider. The open rows then wait for their middles.
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

        // Coming from below, the last pinned tab's lower half places the tab after it. Its upper half places the tab before it.
        let lower = SidebarTabSlot.placement(beside: p2, rowFrame: p2Row, dragging: o1, slotFrame: o1Row, current: nil, at: point(170))
        #expect(lower?.slot == .beside(p2.id, folder: nil, pinned: true, after: true) && lower?.takesRowsPlace == false)
        let upper = SidebarTabSlot.placement(beside: p2, rowFrame: p2Row, dragging: o1, slotFrame: o1Row, current: nil, at: point(145))
        #expect(upper?.slot == .beside(p2.id, folder: nil, pinned: true, after: false) && upper?.takesRowsPlace == true)
        // The row's middle counts as its far half from either side, as it does in the slot's own list. The slot therefore lands under the pointer. The next move at the same point keeps it.
        let middle = SidebarTabSlot.placement(beside: p2, rowFrame: p2Row, dragging: o1, slotFrame: o1Row, current: nil, at: point(p2Row.midY))
        #expect(middle?.slot == .beside(p2.id, folder: nil, pinned: true, after: false) && middle?.takesRowsPlace == true)
        let fromAbove = SidebarTabSlot.placement(beside: o1, rowFrame: o1Row, dragging: p2, slotFrame: p2Row, current: nil, at: point(o1Row.midY))
        #expect(fromAbove?.slot == .beside(o1.id, folder: nil, pinned: false, after: true) && fromAbove?.takesRowsPlace == true)

        // Release pins it as Pin Tab pins the other open tab. Its saved page is the page it shows.
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
        // No rows lie between the New Tab row and the visible list's bottom.
        #expect(SidebarTabSlot.listEnd(at: point(400), divider: divider, newTabRow: newTab, list: list) == false)
        #expect(SidebarTabSlot.listEnd(at: point(539), divider: divider, newTabRow: newTab, list: list) == false)
        #expect(SidebarTabSlot.listEnd(at: point(560), divider: divider, newTabRow: newTab, list: list) == nil)
        // Beside the rows, in the gap between the divider and the row, and over a pinned tab's row, no list ends.
        #expect(SidebarTabSlot.listEnd(at: CGPoint(x: 5, y: 400), divider: divider, newTabRow: newTab, list: list) == nil)
        #expect(SidebarTabSlot.listEnd(at: point(187), divider: divider, newTabRow: newTab, list: list) == nil)
        #expect(SidebarTabSlot.listEnd(at: point(150), divider: divider, newTabRow: newTab, list: list) == nil)
        // Scrolling puts the New Tab row out of sight below the list. The space above the list's bottom then belongs to a row, not the end.
        #expect(SidebarTabSlot.listEnd(at: point(530), divider: frame(y: 476, height: 10), newTabRow: frame(y: 560), list: list) == nil)
        // Scrolling up puts the divider above the list's top, where it no longer counts. The visible part of the New Tab row and the space below it still count.
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

        // The collapsed folder shows only the selected tab, which the drag lifts. The first open tab's upper half takes it out of the folder.
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
        // Unpinning keeps its stand-in without a saved page. Closing it now adds it to the closed list, as for any open tab.
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

    @Test func underTheDividerAPinnedTabUnpinsWhereNoRowTakesIt() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let p1 = tab("p1", pinned: true, in: session, space), p2 = tab("p2", pinned: true, in: session, space)
        let agentTab = try #require(session.openAgentTab(url: URL(string: "about:blank#agent")!, engine: nil, owner: UUID(), folderName: "Task", in: space.id))
        let o1 = tab("o1", pinned: false, in: session, space), o2 = tab("o2", pinned: false, in: session, space)
        // An expanded agent folder starts the open list. Neither its row nor its tab takes the user's tab.
        let agentFolder = try #require(session.folders(in: space.id, pinned: false).first)
        #expect(agentFolder.isAgentFolder && !agentFolder.isCollapsed && agentTab.agentOwnerID != nil)
        #expect(session.folderTree.rows(in: space.id, pinned: false).map(\.id) == [agentFolder.id, agentTab.id, o1.id, o2.id])
        #expect(!session.folderTree.canMoveTab(p2, into: agentFolder.id))
        let divider = frame(y: 176, height: 10), newTab = frame(y: 340)
        let frames = [p1.id: frame(y: 100), p2.id: frame(y: 138), agentFolder.id: frame(y: 188), agentTab.id: frame(y: 226), o1.id: frame(y: 264), o2.id: frame(y: 302)]
        let looseOpenTabs = session.folderTree.tabsOutsideFolders(in: space.id, pinned: false)
        func unpinning(_ tab: Tab, current: SidebarTabSlot?, at point: CGPoint, openTabs: [Tab]? = nil) -> SidebarTabSlot? {
            SidebarTabSlot.unpinning(tab, current: current, at: point, divider: divider, newTabRow: newTab, openTabs: openTabs ?? looseOpenTabs, rowFrames: frames)
        }

        // Past the divider, which showed the tab at the pinned list's end, the gap under it, the agent folder's row, and its tab take the tab before the first open tab.
        let endOfPins = SidebarTabSlot.end(pinned: true)
        let beforeO1 = SidebarTabSlot.beside(o1.id, folder: nil, pinned: false, after: false)
        #expect(unpinning(p2, current: endOfPins, at: point(187)) == beforeO1)
        #expect(unpinning(p2, current: endOfPins, at: point(200)) == beforeO1)
        #expect(unpinning(p2, current: endOfPins, at: point(240)) == beforeO1)
        // A tab still in its own pinned slot, as after a fast drag that skips the divider, too.
        #expect(unpinning(p2, current: nil, at: point(240)) == beforeO1)
        // Between two open tabs, the lower one takes it. Between the last one and the New Tab row, the open list's end does.
        #expect(unpinning(p2, current: endOfPins, at: point(301)) == .beside(o2.id, folder: nil, pinned: false, after: false))
        #expect(unpinning(p2, current: endOfPins, at: point(339)) == .end(pinned: false))
        // Without open tabs outside folders, the agent folder's row takes it to the open list's end.
        #expect(unpinning(p2, current: endOfPins, at: point(200), openTabs: []) == .end(pinned: false))
        // Other rules handle a slot among the open tabs, an open tab, the divider and pinned rows, the New Tab row, and the space beside the rows.
        #expect(unpinning(p2, current: beforeO1, at: point(200)) == nil)
        #expect(unpinning(o1, current: nil, at: point(200)) == nil)
        #expect(unpinning(p2, current: endOfPins, at: point(180)) == nil)
        #expect(unpinning(p2, current: endOfPins, at: point(150)) == nil)
        #expect(unpinning(p2, current: endOfPins, at: point(345)) == nil)
        #expect(unpinning(p2, current: endOfPins, at: CGPoint(x: 5, y: 200)) == nil)

        var pins = session.folderTree.rows(in: space.id, pinned: true), open = session.folderTree.rows(in: space.id, pinned: false)
        beforeO1.project(p2, pinnedRows: &pins, openRows: &open)
        #expect(pins.map(\.id) == [p1.id] && open.map(\.id) == [agentFolder.id, agentTab.id, p2.id, o1.id, o2.id])
        // Release unpins it as Unpin Tab unpins the other pinned tab. The agent keeps its folder and tab.
        beforeO1.commit(p2, in: space, session: session)
        session.togglePinned(p1)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).isEmpty)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [p1.id, p2.id, o1.id, o2.id])
        #expect(PinState(p2) == PinState(p1))
        #expect(p2.savedPage == nil && p2.agentOwnerID == nil)
        #expect(session.folders(in: space.id).map(\.id) == [agentFolder.id] && agentTab.folderID == agentFolder.id && agentTab.agentOwnerID != nil)
    }

    @Test func anAgentsTabDraggedAmongThePinnedTabsBecomesTheUsersAsPinTabMakesIt() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let p1 = tab("p1", pinned: true, in: session, space)
        func agentTab(_ name: String) throws -> Tab {
            try #require(session.openAgentTab(url: URL(string: "about:blank#\(name)")!, engine: nil, owner: UUID(), folderName: name, in: space.id))
        }
        // Each in an agent folder of its own.
        let dragged = try agentTab("dragged"), overDivider = try agentTab("divider"), pinned = try agentTab("pinned")
        #expect(session.folders(in: space.id, pinned: false).filter(\.isAgentFolder).count == 3)
        #expect([dragged, overDivider, pinned].allSatisfy { $0.agentOwnerID != nil })

        // Coming from below, the last pinned tab's lower half places the agent's tab after it. The divider takes another to the pinned list's end.
        let placement = SidebarTabSlot.placement(beside: p1, rowFrame: frame(y: 100), dragging: dragged, slotFrame: frame(y: 188), current: nil, at: point(130))
        let slot = try #require(placement).slot
        #expect(slot == .beside(p1.id, folder: nil, pinned: true, after: true))
        slot.commit(dragged, in: space, session: session)
        SidebarTabSlot.end(pinned: true).commit(overDivider, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).map(\.id) == [p1.id, dragged.id, overDivider.id])
        session.togglePinned(pinned)
        // Each tab now belongs to the user. Each is pinned with the page it shows as its saved page. Each agent folder went with its last tab.
        #expect(PinState(dragged) == PinState(pinned) && PinState(overDivider) == PinState(pinned))
        #expect(PinState(dragged) == PinState(p1))
        #expect([dragged, overDivider, pinned].allSatisfy { $0.agentOwnerID == nil })
        #expect(session.folders(in: space.id).isEmpty)
    }

    @Test func aListScrollingDownUnderTheHeldPointerMovesTheSlotToTheRowsItBrings() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let open = (1...12).map { tab("o\($0)", pinned: false, in: session, space) }
        let dragged = open[0], o9 = open[8], o10 = open[9]
        let tree = session.folderTree
        // Under the empty pinned list's divider, the slot took o9's place. This shows the dragged tab after o9 at 492. The pointer rests over it in the bottom band.
        let held = point(520)
        #expect(DragAutoScroll.step(at: held, in: list) > 0)
        var current = SidebarTabSlot.beside(o9.id, folder: nil, pinned: false, after: true)
        let shown = Array(open[1...8]) + [dragged] + Array(open[9...])
        // The slot that `rows`, shown from 188 and moved up `scrolled` points by the scroll, give the tab at the pointer.
        func next(_ rows: [Tab], scrolled: CGFloat) -> (slot: SidebarTabSlot, holding: CGRect?)? {
            SidebarTabSlot.next(for: dragged, at: held, current: current, in: space.id, tree: tree, rowFrames: stacked(rows.map(\.id), from: 188, scrolled: scrolled),
                                divider: frame(y: 160 - scrolled, height: 26), newTabRow: frame(y: 188 + CGFloat(rows.count) * 38 - scrolled), list: list)
        }
        var hover = SidebarReorderHover()
        hover.moved(into: frame(y: 492))
        // Before the scroll, only the slot is under the pointer. Its frame holds the hysteresis.
        #expect(next(shown, scrolled: 0) == nil)
        var unmoved = hover
        let staysUnmoved = !unmoved.canMove(at: held)
        // The list scrolls 40 points down. The slot rises to 452. At 490, o10 comes under the pointer past its middle from above. If the slot's place did not move with the rows, it would still hold the pointer and keep the slot.
        hover.scrolled(by: 40)
        let movesAfterScroll = hover.canMove(at: held)
        #expect(staysUnmoved && movesAfterScroll)
        let move = try #require(next(shown, scrolled: 40))
        #expect(move.slot == .beside(o10.id, folder: nil, pinned: false, after: true) && move.holding == frame(y: 490))
        hover.moved(into: frame(y: 490))
        let repeatsInPlace = hover.canMove(at: held)
        #expect(!repeatsInPlace)
        // The rows then show the tab after o10, under the pointer. The next frames therefore keep the slot.
        current = move.slot
        var pins = tree.rows(in: space.id, pinned: true), rows = tree.rows(in: space.id, pinned: false)
        move.slot.project(dragged, pinnedRows: &pins, openRows: &rows)
        let expected = open[1...9].map(\.id) + [dragged.id] + open[10...].map(\.id)
        #expect(rows.map(\.id) == expected)
        let reshown = Array(open[1...9]) + [dragged] + Array(open[10...])
        #expect(next(reshown, scrolled: 40) == nil)
        // Another 90 points down, the New Tab row comes under the pointer at 514. It takes the tab to the open list's end.
        hover.scrolled(by: 90)
        let movesAtEnd = hover.canMove(at: held)
        #expect(movesAtEnd)
        let end = try #require(next(reshown, scrolled: 130))
        #expect(end.slot == .end(pinned: false) && end.holding == frame(y: 514))

        // Released after the first scroll, the tab lands after o10, where the slot showed.
        move.slot.commit(dragged, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == expected)
    }

    @Test func aListScrollingUpUnderTheHeldPointerBringsThePinnedRowsThatPinTheTab() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let p1 = tab("p1", pinned: true, in: session, space), p2 = tab("p2", pinned: true, in: session, space)
        let open = (1...12).map { tab("o\($0)", pinned: false, in: session, space) }
        let dragged = open[11], o5 = open[4]
        let tree = session.folderTree
        // In a list scrolled 300 points down, the last open tab's slot took o5's place at the list's top, at 40 before o5. The pointer rests in the top band. The pinned tabs, the divider, and o1 to o4 are above it, out of sight.
        let held = point(48)
        #expect(DragAutoScroll.step(at: held, in: list) < 0)
        let current = SidebarTabSlot.beside(o5.id, folder: nil, pinned: false, after: false)
        let shown = Array(open[0...3]) + [dragged] + Array(open[4...10])
        // The slot that the rows give the tab at the pointer once the list scrolls `scrolled` more points down.
        func next(scrolled: CGFloat) -> (slot: SidebarTabSlot, holding: CGRect?)? {
            let frames = stacked([p1.id, p2.id], from: -200, scrolled: scrolled).merging(stacked(shown.map(\.id), from: -112, scrolled: scrolled)) { $1 }
            return SidebarTabSlot.next(for: dragged, at: held, current: current, in: space.id, tree: tree, rowFrames: frames,
                                       divider: frame(y: -124 - scrolled, height: 10), newTabRow: frame(y: 344 - scrolled), list: list)
        }
        var hover = SidebarReorderHover()
        hover.moved(into: frame(y: 40))
        #expect(next(scrolled: 0) == nil)
        // The list scrolls 200 points up. The pinned rows come back into view. At 38, p2 comes under the pointer.
        hover.scrolled(by: -200)
        let movesAfterScroll = hover.canMove(at: held)
        #expect(movesAfterScroll)
        // A row of the other list takes the tab as soon as the pointer reaches it: before p2 in its upper half.
        let move = try #require(next(scrolled: -200))
        #expect(move.slot == .beside(p2.id, folder: nil, pinned: true, after: false) && move.holding == frame(y: 38))

        // Released there, it pins between p1 and p2 with the page it shows as its saved page, as Pin Tab pins it.
        move.slot.commit(dragged, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).map(\.id) == [p1.id, dragged.id, p2.id])
        #expect(dragged.isPinned && dragged.savedPage?.url == dragged.url)
        #expect(PinState(dragged) == PinState(p1))
    }

    @Test(arguments: [false, true]) func aTabCanReturnToItsNewlyEmptySourceFolder(pinned: Bool) throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = session.makeFolder(in: space.id, pinned: pinned)
        let other = session.makeFolder(in: space.id, pinned: pinned)
        let dragged = tab("source", pinned: pinned, in: session, space)
        session.moveTab(dragged.id, toFolder: source.id)
        let sourceFrame = frame(y: 100), otherFrame = frame(y: 200)
        let emptyFrames = [source.id: sourceFrame, other.id: otherFrame]
        let overSource = point(sourceFrame.midY)

        // Both an ordinary move out and a move across the divider leave the stored folder unchanged until release.
        for destination in [SidebarTabSlot.end(pinned: pinned), .end(pinned: !pinned)] {
            var pins = session.folderTree.rows(in: space.id, pinned: true)
            var open = session.folderTree.rows(in: space.id, pinned: false)
            destination.project(dragged, pinnedRows: &pins, openRows: &open)
            #expect(FolderTree.emptyFolderIDs(in: pinned ? pins : open).contains(source.id))
            #expect(destination.sourceFolderReturnFrame(for: dragged, at: overSource, emptyFolderFrames: emptyFrames) == sourceFrame)
            #expect(destination.sourceFolderReturnFrame(for: dragged, at: point(otherFrame.midY), emptyFolderFrames: emptyFrames) == nil)
            #expect(destination.sourceFolderReturnFrame(for: dragged, at: point(sourceFrame.maxY + 1), emptyFolderFrames: emptyFrames) == nil)
            #expect(destination.sourceFolderReturnFrame(for: dragged, at: overSource, emptyFolderFrames: [:]) == nil)
            #expect(dragged.folderID == source.id && dragged.isPinned == pinned)
        }

        // Clearing the preview restores the original child, and a slot still inside that folder needs no return.
        let restored = session.folderTree.rows(in: space.id, pinned: pinned)
        #expect(!FolderTree.emptyFolderIDs(in: restored).contains(source.id))
        #expect(restored.contains { $0.id == dragged.id })
        let inside = SidebarTabSlot.beside(dragged.id, folder: source.id, pinned: pinned, after: false)
        #expect(inside.sourceFolderReturnFrame(for: dragged, at: overSource, emptyFolderFrames: emptyFrames) == nil)
        let loose = tab("loose", pinned: pinned, in: session, space)
        #expect(SidebarTabSlot.end(pinned: !pinned).sourceFolderReturnFrame(for: loose, at: overSource, emptyFolderFrames: emptyFrames) == nil)
    }

    /// The column as the sidebar lays it out with the pinned tabs in place (`SpaceTabsView`). The pinned area starts at 40, keeps at least the empty target's height, and grows with its rows up to `maxPinned`. It scrolls `pinnedScroll` points. The divider follows it at its own fixed height. The open area starts 2 points below the divider and ends at the list's bottom at 540. The New Tab row follows the open rows. `slot` shows the dragged tab where it would land, as the rows do during the drag.
    private struct TwoAreaColumn {
        let pinnedArea: CGRect, divider: CGRect, openArea: CGRect
        let pinnedListEnd: CGRect
        let pinnedFrames: [UUID: CGRect], openFrames: [UUID: CGRect]
        let newTab: CGRect
        var list: CGRect { pinnedArea.union(divider).union(openArea) }

        @MainActor init(_ tab: Tab, slot: SidebarTabSlot?, in space: Space, session: BrowserSession, maxPinned: CGFloat, pinnedScroll: CGFloat, newTabID: UUID) {
            let tree = session.folderTree
            var pinned = tree.rows(in: space.id, pinned: true), open = tree.rows(in: space.id, pinned: false)
            slot?.project(tab, pinnedRows: &pinned, openRows: &open)
            let rowFrame = { (y: CGFloat) in CGRect(x: 11, y: y, width: 218, height: 36) }
            let rowExtent = SpaceTabsView.emptyPinnedEndHeight + SpaceTabsView.rowSpacing
            pinnedArea = CGRect(x: 0, y: 40, width: 240, height: min(max(rowExtent, CGFloat(pinned.count) * rowExtent), maxPinned))
            pinnedFrames = Dictionary(uniqueKeysWithValues: pinned.enumerated().map { ($1.id, rowFrame(40 + CGFloat($0) * rowExtent - pinnedScroll)) })
            divider = CGRect(x: 0, y: pinnedArea.maxY, width: 240, height: SpaceTabsView.dividerHeight)
            pinnedListEnd = pinned.isEmpty ? pinnedArea.union(divider) : divider
            let openTop = divider.maxY + SpaceTabsView.rowSpacing
            openArea = CGRect(x: 0, y: openTop, width: 240, height: 540 - openTop)
            var openFrames = Dictionary(uniqueKeysWithValues: open.enumerated().map { ($1.id, rowFrame(openTop + CGFloat($0) * rowExtent)) })
            newTab = rowFrame(openTop + CGFloat(open.count) * rowExtent)
            openFrames[newTabID] = newTab
            self.openFrames = openFrames
        }
    }

    @Test func theFirstAndLastPinUseTheEmptyTargetsHeightInBothDirections() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dragged = tab("dragged", pinned: false, in: session, space)
        let newTabID = UUID()
        func column(_ slot: SidebarTabSlot?) -> TwoAreaColumn {
            TwoAreaColumn(dragged, slot: slot, in: space, session: session, maxPinned: 500, pinnedScroll: 0, newTabID: newTabID)
        }
        let empty = column(nil)
        #expect(empty.pinnedArea.height == SpaceTabsView.emptyPinnedEndHeight + SpaceTabsView.rowSpacing)
        #expect(empty.divider.height == SpaceTabsView.dividerHeight)
        let overTarget = point(empty.pinnedArea.midY)
        let first = try #require(SidebarTabSlot.next(for: dragged, at: overTarget, current: nil, in: space.id,
                                                   tree: session.folderTree, rowFrames: empty.openFrames,
                                                   divider: empty.pinnedListEnd, newTabRow: empty.newTab, list: empty.list))
        #expect(first.slot == .end(pinned: true) && first.holding == empty.pinnedArea.union(empty.divider))

        // The first slot replaces the empty target, and leaving or returning never shifts either area's boundary.
        for slot in [first.slot, .end(pinned: false), first.slot] {
            let shown = column(slot)
            #expect(shown.pinnedArea == empty.pinnedArea)
            #expect(shown.divider == empty.divider && shown.openArea == empty.openArea)
        }
        first.slot.commit(dragged, in: space, session: session)
        #expect(dragged.isPinned)
        let committed = column(nil)
        #expect(committed.pinnedArea == empty.pinnedArea && committed.divider == empty.divider && committed.openArea == empty.openArea)

        // The same footprint holds when the existing last pin leaves and comes back.
        for slot in [SidebarTabSlot.end(pinned: false), .end(pinned: true), .end(pinned: false)] {
            let shown = column(slot)
            #expect(shown.pinnedArea == committed.pinnedArea)
            #expect(shown.divider == committed.divider && shown.openArea == committed.openArea)
            if !slot.pinned {
                #expect(shown.pinnedFrames.isEmpty && shown.pinnedListEnd.contains(overTarget))
            }
        }
    }

    /// Drags `tab` from its row's middle toward `y` a point at a time, as the sidebar follows the pointer. Each move picks the next slot from the rows the pointer can reach (`SidebarTabSlot.reachableFrames`). The rows then lay out again with that slot.
    private func drag(_ tab: Tab, toward y: CGFloat, in space: Space, session: BrowserSession, maxPinned: CGFloat = 500, pinnedScroll: CGFloat = 0) -> SidebarTabSlot? {
        let newTabID = UUID()
        var slot: SidebarTabSlot?
        var hover = SidebarReorderHover()
        let start = TwoAreaColumn(tab, slot: nil, in: space, session: session, maxPinned: maxPinned, pinnedScroll: pinnedScroll, newTabID: newTabID)
        var pointer = (start.pinnedFrames[tab.id] ?? start.openFrames[tab.id])?.midY ?? 0
        while pointer < y {
            pointer += 1
            let at = point(pointer)
            let column = TwoAreaColumn(tab, slot: slot, in: space, session: session, maxPinned: maxPinned, pinnedScroll: pinnedScroll, newTabID: newTabID)
            guard hover.acceptsRow(at: at, in: column.list, excluding: nil) else { continue }
            let frames = SidebarTabSlot.reachableFrames(at: at, pinnedArea: column.pinnedArea, pinnedFrames: column.pinnedFrames, openArea: column.openArea, openFrames: column.openFrames, slotOf: tab.id)
            guard hover.canMove(at: at),
                  let move = SidebarTabSlot.next(for: tab, at: at, current: slot, in: space.id, tree: session.folderTree, rowFrames: frames,
                                                 divider: column.pinnedListEnd, newTabRow: frames[newTabID], list: column.list),
                  move.slot != slot else { continue }
            slot = move.slot
            if let frame = move.holding { hover.moved(into: frame) }
        }
        return slot
    }

    @Test(arguments: [(CGFloat(200), 1), (CGFloat(250), 2), (CGFloat(300), 3), (CGFloat(420), 3)])
    func aPinnedTabDraggedBelowTheDividerUnpinsWhereItsSlotShows(toward y: CGFloat, at index: Int) throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pins = ["p1", "p2", "p3"].map { tab($0, pinned: true, in: session, space) }
        let open = ["o1", "o2", "o3"].map { tab($0, pinned: false, in: session, space) }
        let dragged = pins[1]
        // The pinned rows at 40, 78, and 116, the divider at 154, and the open rows from 170, with the New Tab row at 284: among the open tabs, past the last, over the New Tab row, and below it.
        let slot = try #require(drag(dragged, toward: y, in: space, session: session))
        #expect(!slot.pinned)
        var shownPins = session.folderTree.rows(in: space.id, pinned: true), shownOpen = session.folderTree.rows(in: space.id, pinned: false)
        slot.project(dragged, pinnedRows: &shownPins, openRows: &shownOpen)
        #expect(shownOpen.map(\.id).firstIndex(of: dragged.id) == index)

        // Released there, it unpins at that place as Unpin Tab unpins a tab.
        slot.commit(dragged, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).map(\.id) == [pins[0].id, pins[2].id])
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == shownOpen.map(\.id))
        session.togglePinned(pins[0])
        #expect(PinState(dragged) == PinState(pins[0]) && PinState(dragged) == PinState(open[0]))
    }

    @Test func theOnlyPinnedTabUnpinsThoughThePinnedListEmptiesUnderThePointer() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pinned = tab("pinned", pinned: true, in: session, space)
        let o1 = tab("o1", pinned: false, in: session, space), o2 = tab("o2", pinned: false, in: session, space)
        // The empty target keeps the open area at 94. Cross the first displaced open row's middle at 150.
        let slot = try #require(drag(pinned, toward: 160, in: space, session: session))
        slot.commit(pinned, in: space, session: session)
        #expect(!pinned.isPinned && pinned.savedPage == nil)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [o1.id, pinned.id, o2.id])
    }

    @Test func rowsScrolledOutOfThePinnedAreaDoNotTakeATabOverTheOpenArea() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pins = (1...6).map { tab("p\($0)", pinned: true, in: session, space) }
        let open = ["o1", "o2"].map { tab($0, pinned: false, in: session, space) }
        // The pinned area shows two rows of six, from 40 to 116. The rows p3 to p6 lie under the divider and open area, out of sight.
        let column = TwoAreaColumn(pins[0], slot: nil, in: space, session: session, maxPinned: 76, pinnedScroll: 0, newTabID: UUID())
        let overO1 = point(column.openFrames[open[0].id]!.minY + 4)
        #expect(column.pinnedFrames[pins[2].id]!.contains(overO1))
        let frames = SidebarTabSlot.reachableFrames(at: overO1, pinnedArea: column.pinnedArea, pinnedFrames: column.pinnedFrames, openArea: column.openArea, openFrames: column.openFrames, slotOf: pins[0].id)
        #expect(frames[pins[2].id] == nil && frames[open[0].id] != nil && frames[pins[0].id] != nil)
        // Over the divider, the pointer can reach only the slot.
        let overDivider = point(column.divider.midY)
        #expect(SidebarTabSlot.reachableFrames(at: overDivider, pinnedArea: column.pinnedArea, pinnedFrames: column.pinnedFrames, openArea: column.openArea, openFrames: column.openFrames, slotOf: nil).isEmpty)

        // So the first pinned tab dragged into the first open tab's upper half unpins before it, not beside a hidden pin.
        let slot = try #require(drag(pins[0], toward: overO1.y, in: space, session: session, maxPinned: 76))
        #expect(slot == .beside(open[0].id, folder: nil, pinned: false, after: false))
        slot.commit(pins[0], in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [pins[0].id] + open.map(\.id))
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).map(\.id) == pins[1...].map(\.id))
    }
}
