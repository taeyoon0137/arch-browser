// What a drag in a window's sidebar lifts, where it is, and the drop target under it, with the layer that draws a lifted tab or folder row above the sidebar and the page. Tab and folder rows start their drags in `SpaceTabsView.swift`, favorites and space symbols in `SidebarDragAndDrop.swift`, and the page area finds a dragged tab's place in split view (`SplitView.swift`).
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
    /// Set while a row released over a space's symbol or a folder's row shrinks into it.
    @Published var isEntering = false
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
        splitDrop = nil
    }

    /// The space whose symbol is at `point` in the window. Only symbols in the strip's visible part count.
    func space(at point: CGPoint) -> UUID? {
        // Some slack above and below makes the small symbols easier to hit.
        guard spaceStripFrame.insetBy(dx: 0, dy: -6).contains(point) else { return nil }
        return spaceSymbolFrames.first { $0.value.insetBy(dx: -1, dy: -6).contains(point) }?.key
    }

    /// On release, the lifted item returns to its slot, and its shadow fades out before the item reappears there.
    func settle(into slot: CGRect, ownedBy owner: UUID) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            isSettling = true
            frame = slot
        }
        withAnimation(.easeInOut(duration: Self.liftDuration)) { isLifted = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftDuration) { self.end(ownedBy: owner) }
    }

    /// A row released over a space's symbol shrinks into it while the symbol's highlight fades.
    func settle(intoSpace spaceID: UUID, ownedBy owner: UUID) {
        settle(shrinkingInto: spaceSymbolFrames[spaceID] ?? frame, ownedBy: owner)
    }

    /// A row released over a drop target, such as a folder's row, shrinks into the target's frame while its highlight fades.
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
            // A row released over a space's symbol or a folder's row shrinks into it.
            .scaleEffect(sidebarDrag.isEntering ? 0.2 : 1)
            .opacity(sidebarDrag.isEntering ? 0 : 1)
            .environment(\.isDraggingTab, true)
            .frame(width: sidebarDrag.frame.width, height: sidebarDrag.frame.height)
            .offset(x: sidebarDrag.frame.minX, y: sidebarDrag.frame.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
