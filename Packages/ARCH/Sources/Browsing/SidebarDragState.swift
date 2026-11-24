// A sidebar drag tracks the lifted item, its position, and the drop target. A layer draws a lifted tab or folder row over the sidebar and page.
// `SpaceTabsView.swift` starts tab and folder drags and scrolls a row held near an edge through `DragAutoScroll.swift`.
// `SidebarDragAndDrop.swift` starts favorite and space-symbol drags. `SplitView.swift` finds a dragged tab's place in the page area.
import SwiftUI

/// What a drag in the sidebar lifts.
enum SidebarDragItem: Equatable {
    case tab(UUID)
    case folder(UUID)
    case favorite(UUID)
    case space(UUID)

    var id: UUID {
        switch self {
        case .tab(let id), .folder(let id), .favorite(let id), .space(let id): return id
        }
    }

    /// Whether the item is a row of a space's list, which `TabDragLayer` draws.
    var isRow: Bool {
        switch self {
        case .tab, .folder: return true
        case .favorite, .space: return false
        }
    }
}

/// Keep the pointer's last destination while its row moves aside. Newly reported frames at that position belong to the same move.
struct SidebarReorderHover {
    private var destination: CGRect?

    /// A row preview belongs to the list under the pointer. Reset its hysteresis when
    /// leaving so a direct return to the same divider can preview another drop.
    mutating func acceptsRow(at point: CGPoint, in list: CGRect, excluding favorites: CGRect?) -> Bool {
        guard list.contains(point), favorites?.contains(point) != true else {
            destination = nil
            return false
        }
        return true
    }

    /// A row only makes room after the pointer crosses its center in the direction of travel.
    static func crossedMidpoint(from slot: CGRect, into row: CGRect, at point: CGPoint) -> Bool {
        slot.midY < row.midY ? point.y >= row.midY : point.y <= row.midY
    }

    mutating func canMove(at point: CGPoint) -> Bool {
        if let destination, destination.insetBy(dx: -2, dy: -2).contains(point) { return false }
        destination = nil
        return true
    }

    mutating func moved(into frame: CGRect) {
        destination = frame
    }

    /// The list scrolled `distance` points toward its bottom, or toward its top for a negative distance, under a still pointer. The destination moves with the rows, up in the window as the list scrolls down, so that the row the scroll brings under the pointer can take the slot.
    mutating func scrolled(by distance: CGFloat) {
        destination = destination?.offsetBy(dx: 0, dy: -distance)
    }
}

/// The dimmed slot follows the pointer without moving a real tab. A drop on the favorites discards
/// this slot. An ordinary drop resolves it against the current tabs and folders.
@MainActor enum SidebarTabSlot: Equatable {
    case beside(UUID, folder: UUID?, pinned: Bool, after: Bool)
    case end(pinned: Bool)

    var pinned: Bool {
        switch self {
        case .beside(_, _, let pinned, _), .end(let pinned): return pinned
        }
    }

    var folderID: UUID? {
        if case .beside(_, let folder, _, _) = self { return folder }
        return nil
    }

    /// A preview does not change the tab's stored folder. Its newly empty source row restores that original slot.
    func sourceFolderReturnFrame(for tab: Tab, at point: CGPoint, emptyFolderFrames: [UUID: CGRect]) -> CGRect? {
        guard let source = tab.folderID, folderID != source || pinned != tab.isPinned,
              let frame = emptyFolderFrames[source], frame.contains(point) else { return nil }
        return frame
    }

    /// The list whose end a dragged tab's pointer is at in the visible `list`, outside which rows are scrolled out of sight: `true` over the divider, which ends the pinned list, and `false` over the New Tab row, which ends the open list, or below it, where no row is, so an open list without tabs takes the tab anywhere under the divider.
    static func listEnd(at point: CGPoint, divider: CGRect?, newTabRow: CGRect?, list: CGRect) -> Bool? {
        guard list.contains(point) else { return nil }
        if divider?.contains(point) == true { return true }
        guard let newTabRow else { return nil }
        let belowRows = CGRect(x: newTabRow.minX, y: newTabRow.minY, width: newTabRow.width, height: max(newTabRow.height, list.maxY - newTabRow.minY))
        return belowRows.contains(point) ? false : nil
    }

    /// The slot a dragged tab takes beside `target`, the tab row under the pointer, or nil while the tab keeps its slot. `current` is the slot shown so far, nil while the tab shows in its own place, and `slotFrame` the frame of that slot. Within the slot's list, pinned or open, the row makes room once the pointer crosses its middle in the direction of travel, and coming from above the tab goes after it only in the row's own folder. The divider always lies between the slot and a row of the other list, so that row takes the tab as soon as the pointer is over it: before the row in its upper half, after it in its lower half, with the middle itself in the far half, as `SidebarReorderHover.crossedMidpoint` counts it, so that the next move at the same point keeps the slot. A pinned tab thus unpins wherever it enters the open tabs' rows, and an open tab pins wherever it enters the pinned tabs' rows. `takesRowsPlace` tells whether the slot lands where the row was, under the pointer, so that the row's frame holds the hysteresis (`SidebarReorderHover.moved(into:)`); a slot placed on the near side of a row of the other list does not, and the row's middle then decides the next move.
    static func placement(beside target: Tab, rowFrame: CGRect, dragging tab: Tab, slotFrame: CGRect, current: SidebarTabSlot?, at point: CGPoint) -> (slot: SidebarTabSlot, takesRowsPlace: Bool)? {
        let fromAbove = slotFrame.midY < rowFrame.midY
        guard (current?.pinned ?? tab.isPinned) == target.isPinned else {
            let after = fromAbove ? point.y >= rowFrame.midY : point.y > rowFrame.midY
            return (.beside(target.id, folder: target.folderID, pinned: target.isPinned, after: after), after == fromAbove)
        }
        guard SidebarReorderHover.crossedMidpoint(from: slotFrame, into: rowFrame, at: point) else { return nil }
        let folderID = current.map(\.folderID) ?? tab.folderID
        return (.beside(target.id, folder: target.folderID, pinned: target.isPinned, after: folderID == target.folderID && fromAbove), true)
    }

    /// The slot of a tab shown among the pinned tabs while the pointer is under the divider and above the New Tab row where no row takes the tab: over an agent folder's row or tabs, which take only their agent's tabs, over a collapsed folder's selected tab, or between two rows. The tab goes before the first of `openTabs`, the open tabs outside folders, whose row is not above the pointer, or to the open list's end without one, so that it unpins wherever it is released among the open tabs. Nil for a slot among the open tabs or a pointer elsewhere. The slot lands away from the pointer, so no row's frame holds the hysteresis.
    static func unpinning(_ tab: Tab, current: SidebarTabSlot?, at point: CGPoint, divider: CGRect?, newTabRow: CGRect?, openTabs: [Tab], rowFrames: [UUID: CGRect]) -> SidebarTabSlot? {
        guard current?.pinned ?? tab.isPinned, let divider, let newTabRow,
              point.y >= divider.maxY, point.y < newTabRow.minY, point.x >= newTabRow.minX, point.x < newTabRow.maxX else { return nil }
        guard let next = openTabs.first(where: { $0.id != tab.id && rowFrames[$0.id].map { $0.maxY > point.y } == true }) else { return .end(pinned: false) }
        return .beside(next.id, folder: nil, pinned: false, after: false)
    }

    /// The slot a dragged tab moves to with the pointer at `point` in the window, and the frame of the row whose place it takes, which then holds the hysteresis (`SidebarReorderHover.moved(into:)`), or nil while the tab keeps `current`: the end of the list whose closing row is under the pointer (`listEnd`), unless the tab already ends that list; beside the tab row under it (`placement`), but not a collapsed folder's tab or an agent's tab outside the dragged tab's folder; or under the divider where no row takes it (`unpinning`). `rowFrames` holds the frames of the space's tab rows, `divider` and `newTabRow` those of the rows that end the pinned and open lists, and `list` the visible part of the list.
    static func next(for tab: Tab, at point: CGPoint, current: SidebarTabSlot?, in spaceID: UUID, tree: FolderTree, rowFrames: [UUID: CGRect],
                     divider: CGRect?, newTabRow: CGRect?, list: CGRect) -> (slot: SidebarTabSlot, holding: CGRect?)? {
        if let pinned = listEnd(at: point, divider: divider, newTabRow: newTabRow, list: list), let endFrame = pinned ? divider : newTabRow {
            if current == nil && tree.tabsOutsideFolders(in: spaceID, pinned: pinned).last?.id == tab.id { return nil }
            return (.end(pinned: pinned), endFrame)
        }
        let tabs = tree.tabs(in: spaceID, pinned: true) + tree.tabs(in: spaceID, pinned: false)
        if let target = tabs.first(where: { $0.id != tab.id && !tree.isInCollapsedFolder($0) && rowFrames[$0.id]?.contains(point) == true }),
           let rowFrame = rowFrames[target.id], let slot = rowFrames[tab.id],
           let placement = placement(beside: target, rowFrame: rowFrame, dragging: tab, slotFrame: slot, current: current, at: point),
           target.agentOwnerID == nil || target.folderID == tab.folderID {
            return (placement.slot, placement.takesRowsPlace ? rowFrame : nil)
        }
        return unpinning(tab, current: current, at: point, divider: divider, newTabRow: newTabRow,
                         openTabs: tree.tabsOutsideFolders(in: spaceID, pinned: false), rowFrames: rowFrames).map { ($0, nil) }
    }

    /// The frames of the rows that the pointer can reach at `point`: those of the area under it, the pinned area's or the open area's with its New Tab row, since rows scrolled out of an area's sight lie under the divider or the other area; none over the divider, which ends the pinned list itself; and the frame of `slotOf`, the dragged row's slot, wherever it is, which `placement` measures the pointer from.
    static func reachableFrames(at point: CGPoint, pinnedArea: CGRect, pinnedFrames: [UUID: CGRect], openArea: CGRect, openFrames: [UUID: CGRect], slotOf draggedID: UUID?) -> [UUID: CGRect] {
        var frames = pinnedArea.contains(point) ? pinnedFrames : openArea.contains(point) ? openFrames : [:]
        if let draggedID, let slot = pinnedFrames[draggedID] ?? openFrames[draggedID] { frames[draggedID] = slot }
        return frames
    }

    /// Move only the dragged row in this render's lists. Its identity stays with the gesture.
    func project(_ tab: Tab, pinnedRows: inout [FolderTree.Row], openRows: inout [FolderTree.Row]) {
        var destination = (pinned ? pinnedRows : openRows).filter { $0.id != tab.id }
        switch self {
        case .beside(let id, let folder, _, let after):
            guard let index = destination.firstIndex(where: { $0.id == id }),
                  case .tab(let target, let depth) = destination[index], target.folderID == folder else { return }
            destination.insert(.tab(tab, depth: depth), at: after ? index + 1 : index)
        case .end:
            destination.append(.tab(tab, depth: 0))
        }
        if pinned {
            pinnedRows = destination
            openRows.removeAll { $0.id == tab.id }
        } else {
            openRows = destination
            pinnedRows.removeAll { $0.id == tab.id }
        }
    }

    func commit(_ tab: Tab, in space: Space, session: BrowserSession) {
        guard tab.spaceID == space.id, tab.personaID == space.resolvedPersonaID,
              session.tabs.contains(where: { $0 === tab }) else { return }
        switch self {
        case .end(let pinned):
            session.moveTabToListEnd(tab.id, pinned: pinned)
        case .beside(let id, let folder, let pinned, let after):
            guard let target = session.tabs.first(where: { $0.id == id && $0.spaceID == space.id }),
                  target.isPinned == pinned, target.folderID == folder, target.isListedInSidebar,
                  !session.folderTree.isInCollapsedFolder(target) else { return }
            session.moveTab(tab.id, to: target, after: after)
        }
    }
}

/// A drag in the window's sidebar: the tab row, folder row, favorite, or space symbol it lifts, its drop target, and the frames of the space symbols and the page area's panes that a dragged row's targets are found in. The window draws the lifted item above the sidebar and the page, so it can follow the pointer out of the list.
final class SidebarDragState: ObservableObject {
    /// How long a lifted item's shadow and its slot's dimming take to appear and disappear.
    static let liftDuration = 0.4

    /// The dragged item.
    @Published private(set) var item: SidebarDragItem?
    /// The lifted row's frame in the window.
    @Published var frame: CGRect = .zero
    /// Set after release, while the row returns to its slot.
    @Published var isSettling = false
    /// Shows the lifted row's shadow and backing and the slot's dimming.
    @Published var isLifted = false
    /// The other space whose symbol is under a dragged tab or folder. Releasing the row there moves it to that space.
    @Published var targetSpaceID: UUID?
    /// The folder whose row is under a dragged tab or folder. Releasing the row there moves it into the folder.
    @Published var targetFolderID: UUID?
    /// Set while a row released over a space's symbol or the favorites shrinks into it.
    @Published var isEntering = false
    /// A folder drop waits for its committed row's frame in this area, never its old source frame.
    private var folderDropPinned: Bool?
    /// Set while a row released with its slot scrolled out of sight fades out at the list's edge.
    @Published var isFadingOut = false
    /// Each space page's favorites grid, or its header while there are none, which accepts a tab from the same page.
    var favoriteBarFrames: [UUID: CGRect] = [:]
    @Published var targetFavoriteSpaceID: UUID?

    @MainActor
    func favoriteDestination(for tab: Tab, in space: Space, at point: CGPoint, session: BrowserSession) -> UUID? {
        guard tabID == tab.id, tab.spaceID == space.id, tab.personaID == space.resolvedPersonaID,
              tab.agentOwnerID == nil, session.canAddFavorite(tab),
              favoriteBarFrames[space.id]?.contains(point) == true else { return nil }
        return space.id
    }

    /// Where a tab released over the page area opens in split view.
    @Published var splitDrop: SplitDrop?
    /// Each space symbol's frame in the window and the strip's visible part, reported by the bottom bar on screen.
    var spaceSymbolFrames: [UUID: CGRect] = [:]
    var spaceStripFrame = CGRect.zero
    /// The page area's panes, left to right, reported by the page area.
    var paneFrames: [PaneFrame] = []
    /// The list or item that started the drag.
    private(set) var owner: UUID?
    /// The pointer's position in the row when the drag started.
    private var grabOffset: CGSize = .zero

    /// The dragged tab.
    var tabID: UUID? {
        if case .tab(let id) = item { return id }
        return nil
    }

    /// The dragged folder.
    var folderID: UUID? {
        if case .folder(let id) = item { return id }
        return nil
    }

    func begin(_ item: SidebarDragItem, frame: CGRect, grabbedAt point: CGPoint, owner: UUID) {
        self.item = item
        self.owner = owner
        self.frame = frame
        grabOffset = CGSize(width: point.x - frame.minX, height: point.y - frame.minY)
    }

    func move(to point: CGPoint) {
        frame.origin = CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height)
    }

    /// Ends the drag if `owner` started it, so a list cannot end another list's drag.
    func end(ownedBy owner: UUID) {
        guard self.owner == owner else { return }
        item = nil
        self.owner = nil
        isSettling = false
        isLifted = false
        targetSpaceID = nil
        targetFolderID = nil
        targetFavoriteSpaceID = nil
        isEntering = false
        folderDropPinned = nil
        isFadingOut = false
        splitDrop = nil
    }

    /// The space whose symbol is at `point` in the window. Only symbols in the strip's visible part count.
    func space(at point: CGPoint) -> UUID? {
        // Some slack above and below makes the small symbols easier to hit.
        guard spaceStripFrame.insetBy(dx: 0, dy: -6).contains(point) else { return nil }
        return spaceSymbolFrames.first { $0.value.insetBy(dx: -1, dy: -6).contains(point) }?.key
    }

    /// The space whose symbol is at `point` and that takes the dragged tab on release: another space, of any Persona, as `BrowserSession.canCarryTab(_:toSpace:)` allows. In another Persona's space the tab's page loads again in that Persona's profile (`BrowserSession.moveTab(_:toSpace:windowsFollow:)`).
    @MainActor
    func spaceDestination(forTab tab: Tab, at point: CGPoint, session: BrowserSession) -> UUID? {
        space(at: point).flatMap { session.canCarryTab(tab.id, toSpace: $0) ? $0 : nil }
    }

    /// The space whose symbol is at `point` and that takes the dragged folder with what it holds, as `BrowserSession.canMoveFolder(_:toSpace:)` allows.
    @MainActor
    func spaceDestination(forFolder id: UUID, at point: CGPoint, session: BrowserSession) -> UUID? {
        space(at: point).flatMap { session.canMoveFolder(id, toSpace: $0) ? $0 : nil }
    }

    /// A visible folder header or empty child row takes a tab through the same folder move.
    @MainActor
    func folderDestination(for tab: Tab, at point: CGPoint, in tree: FolderTree,
                           rowFrames: [UUID: CGRect], emptyFolderFrames: [UUID: CGRect]) -> UUID? {
        tree.folders.first {
            (rowFrames[$0.id]?.contains(point) == true || emptyFolderFrames[$0.id]?.contains(point) == true)
                && tree.canMoveTab(tab, into: $0.id)
        }?.id
    }

    /// Commit a folder drop, keeping the lifted row visible until the destination reports its slot.
    @MainActor
    func drop(intoFolder folderID: UUID, session: BrowserSession, ownedBy owner: UUID) -> Bool {
        guard self.owner == owner, !isSettling, let item, let folder = session.folderTree.folder(folderID) else { return false }
        switch item {
        case .tab(let id):
            guard let tab = session.tabs.first(where: { $0.id == id }), session.folderTree.canMoveTab(tab, into: folderID) else { return false }
        case .folder(let id):
            guard session.folderTree.canMoveFolder(id, to: .into(folderID)) else { return false }
        case .favorite, .space:
            return false
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            folderDropPinned = folder.isPinned
            isSettling = true
            targetFolderID = nil
            // The new row needs a visible slot even when the destination was collapsed.
            if folder.isCollapsed { session.toggleCollapsed(ofFolder: folderID) }
            if case .folder(let id) = item { session.moveFolder(id, to: .into(folderID)) }
            else { session.moveTab(item.id, toFolder: folderID) }
        }
        return true
    }

    /// Only a fresh report from the destination area can finish a folder drop's layout wait.
    func settleFolderDrop(in frames: [UUID: CGRect], pinned: Bool, within list: CGRect, ownedBy owner: UUID) {
        guard self.owner == owner, folderDropPinned == pinned, let item, let slot = frames[item.id], slot.height > 0 else { return }
        folderDropPinned = nil
        settle(into: slot, within: list, ownedBy: owner)
    }

    /// On release, the lifted item returns to its slot, and its shadow fades out before the item reappears there. With `list`, the visible part of the slot's list, a slot whose middle lies above or below it takes the item only to that edge of the list, where the item fades out.
    func settle(into slot: CGRect, within list: CGRect? = nil, ownedBy owner: UUID) {
        let isHidden = list.map { slot.midY < $0.minY || slot.midY > $0.maxY } ?? false
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            isSettling = true
            frame = slot
            if isHidden, let list { frame.origin.y = max(list.minY, min(slot.minY, list.maxY - slot.height)) }
        }
        withAnimation(.easeInOut(duration: Self.liftDuration)) {
            isLifted = false
            if isHidden { isFadingOut = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftDuration) { self.end(ownedBy: owner) }
    }

    /// A row released over a space's symbol shrinks into it while the symbol's highlight fades.
    func settle(intoSpace spaceID: UUID, ownedBy owner: UUID) {
        settle(shrinkingInto: spaceSymbolFrames[spaceID] ?? frame, ownedBy: owner)
    }

    /// A row released over a space symbol or the favorites shrinks into the target's frame while its highlight fades.
    func settle(shrinkingInto target: CGRect, ownedBy owner: UUID) {
        withAnimation(.easeIn(duration: 0.25)) {
            isSettling = true
            isEntering = true
            targetSpaceID = nil
            targetFolderID = nil
            frame.origin = CGPoint(x: target.midX - frame.width / 2, y: target.midY - frame.height / 2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.end(ownedBy: owner) }
    }
}

/// Draws the lifted tab or folder row at the pointer.
struct TabDragLayer: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var sidebarDrag: SidebarDragState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch sidebarDrag.item {
        case .tab(let id):
            if let tab = session.tabs.first(where: { $0.id == id }) {
                lifted(TabRowView(session: session, tab: tab))
            }
        case .folder(let id):
            if let folder = session.folders.first(where: { $0.id == id }) {
                lifted(TabFolderRowView(session: session, folder: folder))
            }
        case .favorite, .space, nil:
            EmptyView()
        }
    }

    private func lifted(_ row: some View) -> some View {
        // Over the page the row needs a backing of its own.
        row
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SidebarFill.selected.color(in: colorScheme)).opacity(sidebarDrag.isLifted ? 1 : 0))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial).opacity(sidebarDrag.isLifted ? 1 : 0))
            .shadow(color: .black.opacity(sidebarDrag.isLifted ? 0.18 : 0), radius: 5, y: 2)
            // A row released over a space's symbol or the favorites shrinks into it.
            .scaleEffect(sidebarDrag.isEntering ? 0.2 : 1)
            // A row whose slot is out of sight fades out at the list's edge.
            .opacity(sidebarDrag.isEntering || sidebarDrag.isFadingOut ? 0 : 1)
            .environment(\.isDraggingTab, true)
            .frame(width: sidebarDrag.frame.width, height: sidebarDrag.frame.height)
            .offset(x: sidebarDrag.frame.minX, y: sidebarDrag.frame.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
