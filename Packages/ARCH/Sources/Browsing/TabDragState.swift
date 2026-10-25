// What a drag in a window's sidebar lifts, where it is, and the drop target under it, with the layer that draws a lifted tab row above the sidebar and the page. Tab rows start their drags in `SpaceTabsView.swift`, favorites and space symbols in `SidebarDragAndDrop.swift`, and the page area finds a dragged tab's place in split view (`SplitView.swift`).
import SwiftUI

/// What a drag in the sidebar lifts.
enum SidebarDragItem: Equatable {
    case tab(UUID)
    case favorite(UUID)
    case space(UUID)

    var id: UUID {
        switch self {
        case .tab(let id), .favorite(let id), .space(let id): return id
        }
    }
}

/// The tab row, favorite, or space symbol lifted by a drag. The window draws it above the sidebar and the page, so it can follow the pointer out of the list.
final class TabDragState: ObservableObject {
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
    /// The other space whose symbol is under a dragged tab. Releasing the tab there moves it to that space.
    @Published var targetSpaceID: UUID?
    /// The folder whose row is under a dragged tab. Releasing the tab there adds it to the folder.
    @Published var targetFolderID: UUID?
    /// Set while a tab released over a space's symbol or a folder's row shrinks into it.
    @Published var isEntering = false
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

    /// A tab released over a space's symbol shrinks into it while the symbol's highlight fades.
    func settle(intoSpace spaceID: UUID, ownedBy owner: UUID) {
        settle(shrinkingInto: spaceSymbolFrames[spaceID] ?? frame, ownedBy: owner)
    }

    /// A tab released over a drop target, such as a folder's row, shrinks into the target's frame while its highlight fades.
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

/// Draws the lifted tab row at the pointer.
struct TabDragLayer: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tabDrag: TabDragState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let id = tabDrag.tabID, let tab = session.tabs.first(where: { $0.id == id }) {
            // Over the page the row needs a backing of its own.
            TabRowView(session: session, tab: tab)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SidebarFill.selected.color(in: colorScheme)).opacity(tabDrag.isLifted ? 1 : 0))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial).opacity(tabDrag.isLifted ? 1 : 0))
                .shadow(color: .black.opacity(tabDrag.isLifted ? 0.18 : 0), radius: 5, y: 2)
                // A tab released over a space's symbol or a folder's row shrinks into it.
                .scaleEffect(tabDrag.isEntering ? 0.2 : 1)
                .opacity(tabDrag.isEntering ? 0 : 1)
                .environment(\.isDraggingTab, true)
                .frame(width: tabDrag.frame.width, height: tabDrag.frame.height)
                .offset(x: tabDrag.frame.minX, y: tabDrag.frame.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
