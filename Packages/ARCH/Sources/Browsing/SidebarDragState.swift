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

/// The dimmed slot follows the pointer without moving a real tab. A shortcut drop discards
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
    /// The current space's top shortcuts can accept a tab from this same page of the sidebar.
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
