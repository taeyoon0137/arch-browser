// Dragging a tab between a space's pinned and open lists (bookmark rule 2): the slot it takes beside the row under the pointer (`SidebarTabSlot.placement`), at each list's end (`SidebarTabSlot.listEnd`), and under the divider where no row takes it (`SidebarTabSlot.unpinning`), also after the list scrolls under a pointer held near its end (`DragAutoScroll`), as the chain that picks the slot sees the rows' new frames (`SidebarTabSlot.next`), the rows the sidebar then shows (`project`), and what release commits, which leaves the tab as Pin Tab or Unpin Tab leaves it, saved page, unloading, live folder items, and agent tabs included. The frames stand in for a column whose pinned tabs, divider, open tabs, and New Tab row are stacked 2 points apart; the lifted row, the gesture, and the animation are app checks.
import ARCHEngine
import CoreGraphics
import Foundation
import LiveFolders
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

    /// The frames of rows stacked from `top`, 2 points apart, in a list scrolled `scrolled` points further down, which moves each up as far.
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
        // The row's middle is in its far half from either side, as a row of the slot's own list counts it, so the slot lands under the pointer and the next move at the same point keeps it.
        let middle = SidebarTabSlot.placement(beside: p2, rowFrame: p2Row, dragging: o1, slotFrame: o1Row, current: nil, at: point(p2Row.midY))
        #expect(middle?.slot == .beside(p2.id, folder: nil, pinned: true, after: false) && middle?.takesRowsPlace == true)
        let fromAbove = SidebarTabSlot.placement(beside: o1, rowFrame: o1Row, dragging: p2, slotFrame: p2Row, current: nil, at: point(o1Row.midY))
        #expect(fromAbove?.slot == .beside(o1.id, folder: nil, pinned: false, after: true) && fromAbove?.takesRowsPlace == true)

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

    @Test func underTheDividerAPinnedTabUnpinsWhereNoRowTakesIt() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let p1 = tab("p1", pinned: true, in: session, space), p2 = tab("p2", pinned: true, in: session, space)
        let agentTab = try #require(session.openAgentTab(url: URL(string: "about:blank#agent")!, engine: nil, owner: UUID(), folderName: "Task", in: space.id))
        let o1 = tab("o1", pinned: false, in: session, space), o2 = tab("o2", pinned: false, in: session, space)
        // An agent's folder, expanded, starts the open list; neither its row nor its tab takes the user's tab.
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
        // Between two open tabs the lower one takes it, and between the last one and the New Tab row the open list's end does.
        #expect(unpinning(p2, current: endOfPins, at: point(301)) == .beside(o2.id, folder: nil, pinned: false, after: false))
        #expect(unpinning(p2, current: endOfPins, at: point(339)) == .end(pinned: false))
        // Without open tabs outside folders, the agent folder's row takes it to the open list's end.
        #expect(unpinning(p2, current: endOfPins, at: point(200), openTabs: []) == .end(pinned: false))
        // A slot among the open tabs, an open tab, the divider and the pinned rows, the New Tab row, and the space beside the rows are left to the other rules.
        #expect(unpinning(p2, current: beforeO1, at: point(200)) == nil)
        #expect(unpinning(o1, current: nil, at: point(200)) == nil)
        #expect(unpinning(p2, current: endOfPins, at: point(180)) == nil)
        #expect(unpinning(p2, current: endOfPins, at: point(150)) == nil)
        #expect(unpinning(p2, current: endOfPins, at: point(345)) == nil)
        #expect(unpinning(p2, current: endOfPins, at: CGPoint(x: 5, y: 200)) == nil)

        var pins = session.folderTree.rows(in: space.id, pinned: true), open = session.folderTree.rows(in: space.id, pinned: false)
        beforeO1.project(p2, pinnedRows: &pins, openRows: &open)
        #expect(pins.map(\.id) == [p1.id] && open.map(\.id) == [agentFolder.id, agentTab.id, p2.id, o1.id, o2.id])
        // Release unpins it as Unpin Tab unpins the other pinned tab, and the agent keeps its folder and tab.
        beforeO1.commit(p2, in: space, session: session)
        session.togglePinned(p1)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).isEmpty)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [p1.id, p2.id, o1.id, o2.id])
        #expect(PinState(p2) == PinState(p1))
        #expect(p2.savedPage == nil && p2.agentOwnerID == nil)
        #expect(session.folders(in: space.id).map(\.id) == [agentFolder.id] && agentTab.folderID == agentFolder.id && agentTab.agentOwnerID != nil)
    }

    @Test func aLiveFolderItemsTabDraggedAmongTheOpenTabsLeavesItsFolderAsUnpinTabDoes() throws {
        let (session, space, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A private feed's live folder that has fetched two items. Its address is not in the Keychain store, so no refresh reaches the network.
        let folder = session.makeFolder(in: space.id, pinned: true)
        session.updateFolder(folder.id) { $0.live = LiveFolderConfiguration(source: .feed(address: URL(string: "https://fixture.invalid/feed.xml")!, isPrivate: true)) }
        let items = ["a", "b"].map { LiveItem(id: $0, url: URL(string: "https://fixture.invalid/\($0)")!, title: "Item \($0)") }
        session.liveFolderService.store.update(folder.id) { $0.recordSuccess(items: items, at: Date()) }
        let itemTabs = items.map { item in
            let tab = session.openTab(url: item.url, in: space.id, pinned: true, select: false)
            LiveFolderTabs.prepare(tab, as: item, inFolder: folder.id)
            return tab
        }
        let dragged = itemTabs[0], unpinned = itemTabs[1]
        let o1 = tab("o1", pinned: false, in: session, space)
        #expect(session.folderTree.isLive(dragged.folderID) && dragged.savedPage?.url == items[0].url)

        // The first open tab's upper half takes the item's tab before it.
        let placement = SidebarTabSlot.placement(beside: o1, rowFrame: frame(y: 188), dragging: dragged, slotFrame: frame(y: 100), current: nil, at: point(195))
        let slot = try #require(placement).slot
        #expect(slot == .beside(o1.id, folder: nil, pinned: false, after: false))
        slot.commit(dragged, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [dragged.id, o1.id])
        session.togglePinned(unpinned)
        // Each is an ordinary open tab without a saved page, and the folder has a new tab for each item (live folder rule 4).
        #expect(PinState(dragged) == PinState(unpinned))
        #expect(!dragged.isPinned && dragged.folderID == nil && dragged.liveItemID == nil && dragged.savedPage == nil)
        #expect(unpinned.liveItemID == nil && unpinned.savedPage == nil)
        let inFolder = session.folderTree.tabs(inFolder: folder.id)
        #expect(inFolder.compactMap(\.liveItemID).sorted() == ["a", "b"])
        #expect(!inFolder.contains { $0 === dragged || $0 === unpinned })
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

        // Coming from below, the last pinned tab's lower half takes the agent's tab after it; the divider takes another to the pinned list's end.
        let placement = SidebarTabSlot.placement(beside: p1, rowFrame: frame(y: 100), dragging: dragged, slotFrame: frame(y: 188), current: nil, at: point(130))
        let slot = try #require(placement).slot
        #expect(slot == .beside(p1.id, folder: nil, pinned: true, after: true))
        slot.commit(dragged, in: space, session: session)
        SidebarTabSlot.end(pinned: true).commit(overDivider, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).map(\.id) == [p1.id, dragged.id, overDivider.id])
        session.togglePinned(pinned)
        // Each is the user's pinned tab with the page it shows as its saved page, and each agent folder went with its last tab.
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
        // Under the empty pinned list's divider, the slot took o9's place, which shows the dragged tab after o9 at 492, and the pointer rests over it in the bottom band.
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
        // Before the scroll, only the slot is under the pointer, and its frame holds the hysteresis.
        #expect(next(shown, scrolled: 0) == nil)
        var unmoved = hover
        let staysUnmoved = !unmoved.canMove(at: held)
        // The list scrolls 40 points down: the slot rises to 452, and o10, at 490, comes under the pointer past its middle from above. If the slot's place did not move with the rows, it would still hold the pointer and keep the slot.
        hover.scrolled(by: 40)
        let movesAfterScroll = hover.canMove(at: held)
        #expect(staysUnmoved && movesAfterScroll)
        let move = try #require(next(shown, scrolled: 40))
        #expect(move.slot == .beside(o10.id, folder: nil, pinned: false, after: true) && move.holding == frame(y: 490))
        hover.moved(into: frame(y: 490))
        let repeatsInPlace = hover.canMove(at: held)
        #expect(!repeatsInPlace)
        // The rows then show the tab after o10, under the pointer, so that the next frames keep the slot.
        current = move.slot
        var pins = tree.rows(in: space.id, pinned: true), rows = tree.rows(in: space.id, pinned: false)
        move.slot.project(dragged, pinnedRows: &pins, openRows: &rows)
        let expected = open[1...9].map(\.id) + [dragged.id] + open[10...].map(\.id)
        #expect(rows.map(\.id) == expected)
        let reshown = Array(open[1...9]) + [dragged] + Array(open[10...])
        #expect(next(reshown, scrolled: 40) == nil)
        // Another 90 points down, the New Tab row comes under the pointer at 514 and takes the tab to the open list's end.
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
        // In a list scrolled 300 points down, the last open tab's slot took o5's place at the list's top, at 40 before o5, and the pointer rests in the top band. The pinned tabs, the divider, and o1 to o4 are above it, out of sight.
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
        // The list scrolls 200 points up, the pinned rows come back into view, and p2, at 38, comes under the pointer.
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
}
