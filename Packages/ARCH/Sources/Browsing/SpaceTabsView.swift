// Each sidebar page holds its Persona’s favorites, the space header, and the pinned tabs in place, and below them the open tabs, nested folders, and the new tab row, which scroll. A tab or folder row's drag starts and ends here (`SidebarDragState.swift`), and scrolls the pinned or open area while it is held near the area's top or bottom (`DragAutoScroll.swift`).
import AppKit
import SwiftUI

private struct FavoriteBarFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A plugin's page in place of the tab list, with the sidebar's return button. Escape closes it only while focus is in the panel's page, so Escape anywhere else in the window still reaches the page, the address field, the palette, or the find bar. The panel's page ends when the panel leaves the window, so the panel closes then too.
private struct SidebarPluginPanelContent: View {
    let panel: BrowserWindowModel.SidebarPluginPanel
    let windowModel: BrowserWindowModel
    @State private var escapeMonitor: Any?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                SidebarIconButton(symbol: "chevron.left", label: localized("Back to Tabs")) { windowModel.closeSidebarPanel() }
                Text(panel.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(panel.title)
                Spacer(minLength: 0)
            }
            .frame(height: 36)
            SidebarPluginPanelController(controller: panel.controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { [windowModel, controller = panel.controller] in
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak windowModel, weak controller] event in
                guard event.keyCode == 53, let windowModel, let controller,
                      Self.panelHasFocus(controller.view, in: event.window) else { return event }
                windowModel.closeSidebarPanel()
                return nil
            }
        }
        .onDisappear { [windowModel, controller = panel.controller] in
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            if windowModel.sidebarPanel?.controller === controller { windowModel.closeSidebarPanel() }
        }
    }

    /// Whether the window's focus is in the panel's view.
    static func panelHasFocus(_ panelView: NSView, in window: NSWindow?) -> Bool {
        guard let window, panelView.window === window, let focused = window.firstResponder as? NSView else { return false }
        return focused.isDescendant(of: panelView)
    }
}

private struct SidebarPluginPanelController: NSViewControllerRepresentable {
    let controller: NSViewController

    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}

/// Lays out one page per space side by side and shows the current space's page. During a swipe the pages follow the fingers; a change of space slides them into place.
struct SpacePagesView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let translation: CGFloat
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    @Environment(\.sidebarWidth) private var width

    var body: some View {
        let index = session.spaces.firstIndex { $0.id == windowModel.currentSpaceID } ?? 0
        HStack(alignment: .top, spacing: 0) {
            ForEach(session.spaces) { space in
                let isCurrent = space.id == windowModel.currentSpaceID
                SpaceTabsView(session: session, space: space)
                .frame(width: width, alignment: .topLeading)
                // Clipping alone does not keep offscreen pages from receiving clicks or accessibility actions.
                .allowsHitTesting(isCurrent)
                .accessibilityElement(children: isCurrent ? .contain : .ignore)
                .accessibilityHidden(!isCurrent)
            }
        }
        .onPreferenceChange(FavoriteBarFramesKey.self) { sidebarDrag.favoriteBarFrames = $0 }
        .offset(x: -CGFloat(index) * width + translation)
        .frame(width: width, alignment: .leading)
        .clipped()
        .animation(SidebarView.pageSpring, value: windowModel.currentSpaceID)
    }
}

/// Measures the existing grid, or the space header while it offers the first favorite.
private struct FavoriteDropArea: ViewModifier {
    let spaceID: UUID
    let viewport: CGRect
    @EnvironmentObject private var sidebarDrag: SidebarDragState

    func body(content: Content) -> some View {
        content
            .overlay {
                if sidebarDrag.targetFavoriteSpaceID == spaceID {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .background(GeometryReader { proxy in
                let visible = viewport.intersection(proxy.frame(in: .named(BrowserWindowView.coordinateSpace)))
                Color.clear.preference(key: FavoriteBarFramesKey.self, value: visible.isEmpty ? [:] : [spaceID: visible])
            })
    }
}

/// Shows a space's favorites, its header, and its pinned tabs fixed under the address pill, and below the divider the remaining tabs and the new tab row, which scroll on their own. A long pinned list scrolls in its own area, at most `pinnedAreaMaxShare` of the page's height. Each of the two lists starts with its folders, each followed, unless collapsed, by its own folders and then its tabs, indented by level (`FolderTree.rows(in:pinned:showingInCollapsedFolders:)`).
struct SpaceTabsView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let space: Space
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    /// Set during a row's drag gesture. Resets automatically if the gesture is cancelled, such as when its row disappears.
    @GestureState private var isDragGestureActive = false
    /// Each tab and folder row's frame in the window, in the pinned area and in the open area with the New Tab row, used to find the row under the pointer and the dropped tab's destination.
    @State private var pinnedFrames: [UUID: CGRect] = [:]
    @State private var openFrames: [UUID: CGRect] = [:]
    /// The divider's frame in the window, which ends the pinned list.
    @State private var dividerFrame = CGRect.zero
    /// The page's frame in the window, and the visible parts of the pinned and open areas in it. Rows scrolled out of sight lie outside their area.
    @State private var pageFrame = CGRect.zero
    @State private var pinnedAreaFrame = CGRect.zero
    @State private var openAreaFrame = CGRect.zero
    /// Each area's content in its scroll view's visible area, which tells how much is hidden above and below.
    @State private var pinnedContentFrame = CGRect.zero
    @State private var openContentFrame = CGRect.zero
    @State private var tabReorder = SidebarReorderHover()
    @State private var tabSlot: SidebarTabSlot?
    @State private var startedWithoutPins = false
    /// Whether the dragged row started in the pinned area, where its own view stays for the gesture's life.
    @State private var dragStartedPinned = false
    /// The dragged row's height as the drag started, which its slot keeps.
    @State private var draggedRowHeight: CGFloat = 0
    private static let pinnedScrollSpace = "SpaceTabsPinnedScroll"
    private static let openScrollSpace = "SpaceTabsOpenScroll"
    /// Identifies this list as the owner of a drag it started, since each space and the floating card has its own list.
    @State private var dragOwner = UUID()
    /// The height of the rows a folder dragged from this list hides, measured as the drag starts.
    @State private var hiddenRowsHeight: CGFloat = 0
    /// The pointer of the last move of a row's drag that this list started, in the window.
    @State private var dragPoint: CGPoint?
    /// Set once that drag may scroll the pinned or the open area from a band (`DragAutoScroll.arms(from:at:in:)`).
    @State private var pinnedAutoScrollArmed = false
    @State private var openAutoScrollArmed = false
    /// Set when an area scrolls under the pointer during a drag, until the rows report their new frames.
    @State private var scrolledUnderPointer = false

    /// How far a folder's folders and tabs sit in from its row.
    private static let folderIndent: CGFloat = 12
    /// The space below each tab, folder, and New Tab row, and below the divider.
    static let rowSpacing: CGFloat = 2
    /// The room between the space's header and its first row: the rows' own spacing.
    static let headerBottomSpacing: CGFloat = rowSpacing
    /// The divider's height between the pinned and open tabs.
    static let dividerHeight: CGFloat = 10
    /// The pinned list's end while it has no rows, a row's height, so that a drag can pin a tab there; it keeps that height through the drag of a space's first pin.
    static let emptyPinnedEndHeight: CGFloat = 36
    /// The largest share of the page's height that the pinned area takes; a longer pinned list scrolls within it.
    static let pinnedAreaMaxShare: CGFloat = 0.5
    /// The keys in the frames of the row that ends the open list, the New Tab row, and of the dragged row's slot's stand-in for the divider.
    private static let openListEndID = UUID()

    /// A row of the pinned or open area: a tab's or folder's, or the slot of the dragged row, where it lands on release.
    private enum Item: Identifiable {
        case row(FolderTree.Row)
        case slot

        var id: String {
            switch self {
            case .row(let row): return row.id.uuidString
            case .slot: return "slot"
            }
        }
    }

    /// The tab or folder row that this list drags, until release.
    private var draggedRowID: UUID? {
        guard sidebarDrag.owner == dragOwner, !sidebarDrag.isSettling, sidebarDrag.item?.isRow == true else { return nil }
        return sidebarDrag.item?.id
    }

    /// The pinned and open areas' items, and whether the pinned list shows no rows. A dragged tab shows its slot where it would land (`SidebarTabSlot.project`), and a dragged folder where it is; the dragged row's own view stays, collapsed, in the area where its drag started, since a row moved into another area's list would be a new view and end the drag.
    private var areaItems: (pinned: [Item], open: [Item], pinnedIsEmpty: Bool) {
        let tree = session.folderTree
        var pinned = listRows(pinned: true, in: tree)
        var open = listRows(pinned: false, in: tree)
        if sidebarDrag.owner == dragOwner, !sidebarDrag.isSettling, let tabSlot, let id = sidebarDrag.tabID,
           let tab = session.tabs.first(where: { $0.id == id && $0.spaceID == space.id && $0.isListedInSidebar }) {
            tabSlot.project(tab, pinnedRows: &pinned, openRows: &open)
        }
        guard let draggedID = draggedRowID, let dragged = (pinned + open).first(where: { $0.id == draggedID }) else {
            return (pinned.map(Item.row), open.map(Item.row), pinned.isEmpty)
        }
        var pinnedItems = pinned.map { $0.id == draggedID ? Item.slot : .row($0) }
        var openItems = open.map { $0.id == draggedID ? Item.slot : .row($0) }
        if dragStartedPinned { pinnedItems.append(.row(dragged)) } else { openItems.append(.row(dragged)) }
        return (pinnedItems, openItems, pinned.isEmpty)
    }

    /// The pinned or open list's rows. A collapsed folder still shows its selected tab, and its dragged tab until release, so that the drag keeps its row. A dragged folder shows its row alone until release.
    private func listRows(pinned: Bool, in tree: FolderTree) -> [FolderTree.Row] {
        let isDragging = !sidebarDrag.isSettling
        return tree.rows(in: space.id, pinned: pinned, hidingContentsOf: isDragging ? sidebarDrag.folderID : nil) { $0.id == windowModel.selectedTabID || ($0.id == sidebarDrag.tabID && isDragging) }
    }

    private var hasFavorites: Bool { !session.favorites(in: space.resolvedPersonaID).isEmpty }

    private var offersFirstFavorite: Bool {
        guard windowModel.currentSpaceID == space.id, !hasFavorites,
              let id = sidebarDrag.tabID, let tab = session.tabs.first(where: { $0.id == id }) else { return false }
        return tab.spaceID == space.id && tab.agentOwnerID == nil && session.canAddFavorite(tab)
    }

    /// Every row's frame in the window, in either area.
    private var rowFrames: [UUID: CGRect] {
        pinnedFrames.merging(openFrames) { $1 }
    }

    /// The frames of the rows the pointer can reach at `point` (`SidebarTabSlot.reachableFrames`).
    private func reachableFrames(at point: CGPoint) -> [UUID: CGRect] {
        SidebarTabSlot.reachableFrames(at: point, pinnedArea: pinnedAreaFrame, pinnedFrames: pinnedFrames, openArea: openAreaFrame, openFrames: openFrames, slotOf: sidebarDrag.item?.id)
    }

    /// The pinned area, the divider, and the open area: where a dragged row's pointer moves it among the rows.
    private var tabsFrame: CGRect {
        pinnedAreaFrame.union(dividerFrame).union(openAreaFrame)
    }

    /// The pinned area's height: its content's, up to its share of the page.
    private var pinnedAreaHeight: CGFloat {
        min(pinnedContentFrame.height, max(0, pageFrame.height * Self.pinnedAreaMaxShare))
    }

    /// The favorites, the plugins' items, the connected agents, and the header, which stay in place above the tabs.
    private var fixedRows: some View {
        VStack(alignment: .leading, spacing: SidebarView.rowSpacing) {
            if hasFavorites {
                FavoritesGridView(session: session, personaID: space.resolvedPersonaID)
                    .modifier(FavoriteDropArea(spaceID: space.id, viewport: pageFrame))
                    .padding(.bottom, FavoriteTileLayout.gridHeaderSpacing)
            }
            if windowModel.sidebarPanel?.spaceID != space.id {
                if let plugins = windowModel.currentSpaceID == space.id ? windowModel.plugins : session.loadedPlugins(in: space.resolvedPersonaID) {
                    PluginSidebarItemsView(plugins: plugins, spaceID: space.id)
                }
                if let agents = session.agents { ConnectedAgentRows(agents: agents) }
                header
            }
        }
        .padding(.horizontal, SidebarView.inset)
    }

    /// The space's header, at its own height. While a tab of a space without favorites is dragged, it shows where to drop the tab to make the first favorite.
    private var header: some View {
        SpaceHeaderView(session: session, space: space)
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .opacity(offersFirstFavorite ? 0 : 1)
            .overlay {
                if offersFirstFavorite {
                    Label(localized("Add to Favorites"), systemImage: "star")
                        .font(.callout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .modifier(FavoriteDropArea(spaceID: space.id, viewport: pageFrame))
                        .allowsHitTesting(false)
                }
            }
            .padding(.bottom, Self.headerBottomSpacing)
    }

    /// The rows of the pinned or open area.
    @ViewBuilder private func rows(_ items: [Item]) -> some View {
        ForEach(items) { item in
            Group {
                switch item {
                case .row(.folder(let folder, let depth)):
                    row(for: folder, collapsed: folder.id == draggedRowID)
                        .padding(.leading, CGFloat(depth) * Self.folderIndent)
                case .row(.tab(let tab, let depth)):
                    row(for: tab, collapsed: tab.id == draggedRowID)
                        .padding(.leading, CGFloat(depth) * Self.folderIndent)
                case .slot:
                    DraggedSlot(height: draggedRowHeight, isLifted: sidebarDrag.isLifted)
                        .background(frameReader(for: sidebarDrag.item?.id ?? UUID()))
                        .padding(.bottom, Self.rowSpacing)
                }
            }
            .transition(Self.rowTransition)
        }
    }

    /// A list area's content: its rows, and the New Tab row after the open ones. While a dragged folder hides its rows, the area it started in keeps their height below its end, so that an area scrolled to its end does not scroll back and move other rows under the pointer.
    private func areaContent(_ items: [Item], pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rows(items)
            if !pinned {
                NewTabButton(action: { windowModel.showCommandPalette(.newTab, from: .sidebar) })
                    .background(frameReader(for: Self.openListEndID))
                    .padding(.bottom, Self.rowSpacing)
            }
        }
        // A row that closes or opens fades while the rows after it slide into place. Only a change of which rows the list holds animates here, so a drag's moves keep their own timing.
        .animation(sidebarDrag.item?.isRow == true ? nil : .easeInOut(duration: 0.2), value: Set(items.map(\.id)))
        .padding(.bottom, keptHeight(pinned: pinned))
        // The scroll view clips at its edges. Keeping the margin inside it leaves room for the selected row's shadow.
        .padding(.horizontal, SidebarView.inset)
        .background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(pinned ? Self.pinnedScrollSpace : Self.openScrollSpace))
            Color.clear
                .onAppear { setContentFrame(frame, pinned: pinned) }
                .onChange(of: frame) { setContentFrame($1, pinned: pinned) }
        })
        // A lifted row held near an area's top or bottom scrolls it, down to the end of its rows, and the drop targets follow the rows that this scroll or a mouse's wheel moves under the pointer.
        .background(DragAutoScroller(point: rowDragPoint, scrolls: pinned ? pinnedAutoScrollArmed : openAutoScrollArmed, visible: pinned ? pinnedAreaFrame : openAreaFrame,
                                     limit: scrollLimit(pinned: pinned), onScroll: listScrolled(by:))
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true))
    }

    private func setContentFrame(_ frame: CGRect, pinned: Bool) {
        if pinned { pinnedContentFrame = frame } else { openContentFrame = frame }
    }

    /// The offset that shows an area's end, without the height a dragged folder's hidden rows keep.
    private func scrollLimit(pinned: Bool) -> CGFloat {
        let content = pinned ? pinnedContentFrame : openContentFrame, area = pinned ? pinnedAreaFrame : openAreaFrame
        return max(0, content.height - keptHeight(pinned: pinned) - area.height)
    }

    /// A list area in its own scroll view, whose rows fade out at each end only while rows are hidden past it.
    private func area(_ items: [Item], pinned: Bool) -> some View {
        let content = pinned ? pinnedContentFrame : openContentFrame, visible = pinned ? pinnedAreaFrame : openAreaFrame
        return ScrollView {
            areaContent(items, pinned: pinned)
                .onPreferenceChange(TabRowFramesKey.self) { frames in
                    if pinned { pinnedFrames = frames } else { openFrames = frames }
                    guard scrolledUnderPointer else { return }
                    scrolledUnderPointer = false
                    // After the update that reported the frames, since a new slot moves the rows again.
                    DispatchQueue.main.async { updateDropTargetsAfterScroll() }
                }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .coordinateSpace(name: pinned ? Self.pinnedScrollSpace : Self.openScrollSpace)
        .mask(ScrollEdgeFade(hiddenAbove: -content.minY, hiddenBelow: content.maxY - visible.height))
        .background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
            Color.clear
                .onAppear { if pinned { pinnedAreaFrame = frame } else { openAreaFrame = frame } }
                .onChange(of: frame) { if pinned { pinnedAreaFrame = $1 } else { openAreaFrame = $1 } }
        })
    }

    /// The divider that ends the pinned list, in place between the two areas. While the pinned list is empty it is a row high, and shows Pin Tab while a tab of this list is dragged.
    private func divider(pinnedIsEmpty: Bool) -> some View {
        let draggedHere = sidebarDrag.owner == dragOwner && sidebarDrag.tabID != nil
        return ZStack {
            if pinnedIsEmpty && draggedHere {
                Label(localized("Pin Tab"), systemImage: "pin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Divider().padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: pinnedIsEmpty || (draggedHere && startedWithoutPins) ? Self.emptyPinnedEndHeight : Self.dividerHeight)
        .padding(.horizontal, SidebarView.inset)
        .background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
            Color.clear
                .onAppear { dividerFrame = frame }
                .onChange(of: frame) { dividerFrame = $1 }
        })
        .padding(.bottom, Self.rowSpacing)
        .accessibilityHidden(true)
    }

    /// While a dragged folder hides its rows, the area its drag started in keeps their height.
    private func keptHeight(pinned: Bool) -> CGFloat {
        sidebarDrag.folderID != nil && !sidebarDrag.isSettling && sidebarDrag.owner == dragOwner && dragStartedPinned == pinned ? hiddenRowsHeight : 0
    }

    /// The pointer of a lifted tab or folder row that this list's current page drags, under which the areas' scrolls move the rows, and which scrolls an area near its top or bottom once armed. A favorite's or space symbol's drag does neither.
    private var rowDragPoint: CGPoint? {
        guard windowModel.currentSpaceID == space.id, sidebarDrag.owner == dragOwner, sidebarDrag.item?.isRow == true,
              sidebarDrag.isLifted, !sidebarDrag.isSettling else { return nil }
        return dragPoint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fixedRows
            if let panel = windowModel.sidebarPanel, panel.spaceID == space.id {
                // The panel takes at least 320 points, and the page scrolls when the sidebar is shorter.
                GeometryReader { proxy in
                    ScrollView {
                        SidebarPluginPanelContent(panel: panel, windowModel: windowModel)
                            .frame(height: max(320, proxy.size.height))
                            .padding(.horizontal, SidebarView.inset)
                    }
                    .scrollIndicators(.never)
                }
                .padding(.top, hasFavorites ? SidebarView.rowSpacing : 0)
            } else {
                let items = areaItems
                area(items.pinned, pinned: true)
                    .frame(height: pinnedAreaHeight)
                divider(pinnedIsEmpty: items.pinnedIsEmpty)
                area(items.open, pinned: false)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.isDraggingTab, sidebarDrag.item?.isRow == true)
        // A cancelled gesture never reports its end. Drop the drag once the gesture is gone and nothing is settling.
        .onChange(of: isDragGestureActive) { _, isActive in
            guard !isActive else { return }
            DispatchQueue.main.async {
                if !isDragGestureActive, !sidebarDrag.isSettling { sidebarDrag.end(ownedBy: dragOwner) }
            }
        }
        .background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
            Color.clear
                .onAppear { pageFrame = frame }
                .onChange(of: frame) { pageFrame = $1 }
        })
        // Hiding the sidebar or the card mid-drag removes the list without ending its gesture.
        .onDisappear { sidebarDrag.end(ownedBy: dragOwner) }
    }

    /// A closing row fades and shrinks a little in place; a new row fades in.
    private static let rowTransition = AnyTransition.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96)))

    /// A tab's row. While dragged, it stays collapsed and hidden in the area where its drag started, and its slot shows where it lands.
    private func row(for tab: Tab, collapsed: Bool) -> some View {
        TabRowView(session: session, tab: tab)
            .background { if !collapsed { frameReader(for: tab.id) } }
            .modifier(CollapsedWhileDragged(isCollapsed: collapsed, isHidden: sidebarDrag.item?.id == tab.id, isLifted: sidebarDrag.isLifted))
            // Dragging in the name field selects text instead.
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(BrowserWindowView.coordinateSpace))
                .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
                .onChanged { dragChanged(tab, $0) }
                .onEnded { value in
                    guard sidebarDrag.owner == dragOwner, dragChanged(tab, value) else {
                        return sidebarDrag.end(ownedBy: dragOwner)
                    }
                    dragEnded()
                }, including: windowModel.renamingTabID == tab.id ? .subviews : .all)
    }

    /// A folder's row. While dragged, it stays collapsed and hidden in the area where its drag started, the rows inside it hide until release, and its slot shows where it is. An agent folder's waiting step shows under its row, outside the row's frame and drag.
    private func row(for folder: TabFolder, collapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TabFolderRowView(session: session, folder: folder)
                .background { if !collapsed { frameReader(for: folder.id) } }
                // Dragging in the name field selects text instead.
                .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(BrowserWindowView.coordinateSpace))
                    .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
                    .onChanged { dragChanged(folder.id, $0) }
                    .onEnded { _ in dragEnded() }, including: windowModel.renamingFolderID == folder.id ? .subviews : .all)
            if folder.agentSessionID != nil {
                SessionFolderStepLine(session: session, folder: folder)
            }
        }
        .modifier(CollapsedWhileDragged(isCollapsed: collapsed, isHidden: sidebarDrag.item?.id == folder.id, isLifted: sidebarDrag.isLifted))
    }

    /// Reports a row's frame in the window to its area, whose own content collects its rows' frames apart from the other area's.
    private func frameReader(for id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: TabRowFramesKey.self, value: [id: proxy.frame(in: .named(BrowserWindowView.coordinateSpace))])
        }
    }

    /// Starts the drag of a row, lifting it at its frame, or continues the drag of it that this list started, and moves the lifted row to the pointer. False while another drag or a release is under way.
    private func continueDrag(of item: SidebarDragItem, _ value: DragGesture.Value) -> Bool {
        guard windowModel.currentSpaceID == space.id, !sidebarDrag.isSettling, sidebarDrag.item == nil || (sidebarDrag.item == item && sidebarDrag.owner == dragOwner), let frame = rowFrames[item.id] ?? (sidebarDrag.item == item ? sidebarDrag.frame : nil) else { return false }
        if sidebarDrag.item == nil {
            tabReorder = SidebarReorderHover()
            tabSlot = nil
            startedWithoutPins = session.folderTree.rows(in: space.id, pinned: true).isEmpty
            dragStartedPinned = pinnedFrames[item.id] != nil
            draggedRowHeight = frame.height
            if case .folder(let id) = item { hiddenRowsHeight = contentsHeight(ofFolder: id, below: frame) }
            scrolledUnderPointer = false
            pinnedAutoScrollArmed = false
            openAutoScrollArmed = false
            sidebarDrag.begin(item, frame: frame, grabbedAt: value.startLocation, owner: dragOwner)
            // The row appears without a shadow, which then fades in.
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: SidebarDragState.liftDuration)) { sidebarDrag.isLifted = true } }
        }
        sidebarDrag.move(to: value.location)
        dragPoint = value.location
        if !pinnedAutoScrollArmed, DragAutoScroll.arms(from: value.startLocation, at: value.location, in: pinnedAreaFrame) { pinnedAutoScrollArmed = true }
        if !openAutoScrollArmed, DragAutoScroll.arms(from: value.startLocation, at: value.location, in: openAreaFrame) { openAutoScrollArmed = true }
        return true
    }

    /// An area scrolled `distance` points under the pointer, from a band or by a mouse's wheel (`DragAutoScroller`), toward its bottom for a positive distance. The row whose place the tab's slot took moves with the content, and once the rows report their new frames, the drop targets are found again at the pointer.
    private func listScrolled(by distance: CGFloat) {
        tabReorder.scrolled(by: distance)
        scrolledUnderPointer = true
    }

    /// Finds the drop targets of the row this list drags at the pointer's last position, as a move of the pointer there would, after a scroll moved the rows under it. A release then lands where the slot shows.
    private func updateDropTargetsAfterScroll() {
        guard windowModel.currentSpaceID == space.id, sidebarDrag.owner == dragOwner, !sidebarDrag.isSettling, let point = dragPoint else { return }
        switch sidebarDrag.item {
        case .tab(let id):
            if let tab = session.tabs.first(where: { $0.id == id && $0.spaceID == space.id }) { updateDropTargets(for: tab, at: point) }
        case .folder(let id):
            updateDropTargets(forFolder: id, at: point)
        case .favorite, .space, nil:
            break
        }
    }

    /// The height of the rows that follow a folder's row, from its bottom to the bottom of the last of them: the folder's rows, which its drag hides.
    private func contentsHeight(ofFolder id: UUID, below folderFrame: CGRect) -> CGFloat {
        let tree = session.folderTree
        guard let folder = tree.folder(id) else { return 0 }
        let rows = tree.rows(in: space.id, pinned: folder.isPinned) { $0.id == windowModel.selectedTabID }
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return 0 }
        let frames = rowFrames
        let bottom = rows[(index + 1)...].prefix { $0.depth > rows[index].depth }.compactMap { frames[$0.id]?.maxY }.max()
        return max(0, (bottom ?? folderFrame.maxY) - folderFrame.maxY)
    }

    /// The lifted row follows the pointer anywhere in the window. Only a pointer over the visible list moves the tab.
    @discardableResult
    private func dragChanged(_ tab: Tab, _ value: DragGesture.Value) -> Bool {
        guard tab.spaceID == space.id, continueDrag(of: .tab(tab.id), value) else { return false }
        updateDropTargets(for: tab, at: value.location)
        return true
    }

    private func updateDropTargets(for tab: Tab, at point: CGPoint) {
        setDropTarget(\.targetFavoriteSpaceID, to: sidebarDrag.favoriteDestination(for: tab, in: space, at: point, session: session))
        let list = tabsFrame
        let frames = reachableFrames(at: point)
        let tree = session.folderTree
        // Another space's symbol, of any Persona, or another folder's row at any level, under the pointer lights up and takes the tab on release. The rows do not make room for it.
        setDropTarget(\.targetSpaceID, to: sidebarDrag.spaceDestination(forTab: tab, at: point, session: session))
        setDropTarget(\.targetFolderID, to: list.contains(point) ? session.folders(in: space.id).first { frames[$0.id]?.contains(point) == true }.flatMap { tree.canMoveTab(tab, into: $0.id) ? $0.id : nil } : nil)
        // Over the page area beside the list, the pane under the pointer shows where the tab opens in split view.
        setDropTarget(\.splitDrop, to: sidebarDrag.targetSpaceID == nil && point.x > pageFrame.maxX ? sidebarDrag.splitDrop(of: tab, at: point, in: windowModel) : nil)
        // The row under the pointer makes room for the dragged tab, with a light haptic at each new position. A collapsed folder's selected tab does not, since the tab would join the folder and hide on release; the folder's row takes it instead. A row of the tab's own list makes room once the pointer crosses its middle, and a row of the other list, past the divider, as soon as the pointer reaches it, so the tab pins or unpins wherever it enters the other list's rows (`SidebarTabSlot.placement`). The divider ends the pinned list; the New Tab row and the empty space below it end the open list. Between them, where no row takes a pinned tab, it goes before the next open tab outside folders (`SidebarTabSlot.unpinning`).
        guard tabReorder.acceptsRow(at: point, in: list, excluding: sidebarDrag.favoriteBarFrames[space.id]) else {
            if tabSlot != nil { tabSlot = nil }
            return
        }
        guard sidebarDrag.targetSpaceID == nil, sidebarDrag.targetFolderID == nil, tabReorder.canMove(at: point),
              let move = SidebarTabSlot.next(for: tab, at: point, current: tabSlot, in: space.id, tree: tree, rowFrames: frames,
                                             divider: dividerFrame, newTabRow: frames[Self.openListEndID], list: list),
              move.slot != tabSlot else { return }
        withAnimation(.easeOut(duration: 0.15)) { tabSlot = move.slot }
        if let frame = move.holding { tabReorder.moved(into: frame) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// The lifted folder row follows the pointer anywhere in the window.
    private func dragChanged(_ folderID: UUID, _ value: DragGesture.Value) {
        guard continueDrag(of: .folder(folderID), value) else { return }
        updateDropTargets(forFolder: folderID, at: value.location)
    }

    /// `FolderTree.dropTarget(for:at:)` decides each place in the list: the rows make room for the folder between them, with a light haptic at each new position, or a folder's row lights up to take it on release. Another space's symbol, of any Persona that takes the folder, lights up to take it with what it holds. Where the tree refuses a place, nothing moves, and the row returns to its slot on release.
    private func updateDropTargets(forFolder folderID: UUID, at point: CGPoint) {
        setDropTarget(\.targetSpaceID, to: sidebarDrag.spaceDestination(forFolder: folderID, at: point, session: session))
        let tree = session.folderTree
        let target = tabsFrame.contains(point) ? dropPosition(at: point, in: tree).flatMap { tree.dropTarget(for: folderID, at: $0) } : nil
        if case .into(let parentID)? = target {
            setDropTarget(\.targetFolderID, to: parentID)
        } else {
            setDropTarget(\.targetFolderID, to: nil)
        }
        guard let target, case .between = target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { session.moveFolder(folderID, to: target) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Where a dragged folder's pointer is among the rows: the upper third of a folder's row is above the folder, the rest of it on the folder.
    private func dropPosition(at point: CGPoint, in tree: FolderTree) -> FolderTree.DropPosition? {
        if let pinned = listEnd(at: point) { return .listEnd(spaceID: space.id, pinned: pinned) }
        guard let row = reachableFrames(at: point).first(where: { $0.key != Self.openListEndID && $0.value.contains(point) }) else { return nil }
        guard tree.folder(row.key) != nil else { return .onTab(row.key) }
        return point.y < row.value.minY + row.value.height / 3 ? .aboveFolder(row.key) : .onFolder(row.key)
    }

    /// The list whose closing row is under the pointer: `true` for the divider after the pinned list, `false` for the visible New Tab row after the open list.
    private func listEnd(at point: CGPoint) -> Bool? {
        if dividerFrame.contains(point) { return true }
        if openAreaFrame.contains(point), openFrames[Self.openListEndID]?.contains(point) == true { return false }
        return nil
    }

    /// Lights up a drop target newly under the dragged row, with a light haptic, or turns off the one it left.
    private func setDropTarget<Target: Equatable>(_ keyPath: ReferenceWritableKeyPath<SidebarDragState, Target?>, to target: Target?) {
        guard sidebarDrag[keyPath: keyPath] != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { sidebarDrag[keyPath: keyPath] = target }
        if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// On release, the lifted row returns to its slot, wherever the pointer is, and its shadow fades out before the row reappears in the list, unless a drop target under it takes it. A slot that its area scrolled out of sight takes the row only to the area's edge, where it fades out.
    private func dragEnded() {
        guard sidebarDrag.owner == dragOwner, windowModel.currentSpaceID == space.id, let item = sidebarDrag.item else { return sidebarDrag.end(ownedBy: dragOwner) }
        // Between the reports of the two areas as the slot moves from one to the other, the lifted row's frame stands in for it.
        let slot = rowFrames[item.id] ?? sidebarDrag.frame
        let slotArea = pinnedFrames[item.id] != nil ? pinnedAreaFrame : openAreaFrame
        if case .tab(let id) = item, !session.tabs.contains(where: { $0.id == id && $0.spaceID == space.id && $0.isListedInSidebar }) {
            return sidebarDrag.end(ownedBy: dragOwner)
        }
        if sidebarDrag.targetFavoriteSpaceID == space.id, windowModel.currentSpaceID == space.id, case .tab(let id) = item,
           let tab = session.tabs.first(where: { $0.id == id && $0.spaceID == space.id && $0.agentOwnerID == nil }),
           let bar = sidebarDrag.favoriteBarFrames[space.id], session.canAddFavorite(tab) {
            session.addFavorite(tab)
            return sidebarDrag.settle(shrinkingInto: bar, ownedBy: dragOwner)
        }
        // Over another space's symbol, the tab goes after that space's own tabs, or the folder with what it holds after its folders, and the lifted row shrinks into the symbol.
        if let spaceID = sidebarDrag.targetSpaceID {
            withAnimation(.easeInOut(duration: 0.15)) {
                if case .folder(let id) = item { session.moveFolder(id, toSpace: spaceID) } else { session.moveTab(item.id, toSpace: spaceID) }
            }
            return sidebarDrag.settle(intoSpace: spaceID, ownedBy: dragOwner)
        }
        // Over a folder's row, the tab goes after the folder's own tabs, or the folder after its folders, and the lifted row shrinks into the folder's row.
        if let folderID = sidebarDrag.targetFolderID {
            guard let folderRow = rowFrames[folderID] else { return sidebarDrag.end(ownedBy: dragOwner) }
            withAnimation(.easeInOut(duration: 0.15)) {
                if case .folder(let id) = item { session.moveFolder(id, to: .into(folderID)) } else { session.moveTab(item.id, toFolder: folderID) }
            }
            return sidebarDrag.settle(shrinkingInto: folderRow, ownedBy: dragOwner)
        }
        // Over the page area, a tab opens in split view, and its row returns to its slot.
        if let drop = sidebarDrag.splitDrop, case .tab(let id) = item, let tab = session.tabs.first(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.15)) { sidebarDrag.splitDrop = nil }
            windowModel.openInSplitView(tab, at: drop.index)
        } else if case .tab(let id) = item, let tab = session.tabs.first(where: { $0.id == id }) {
            tabSlot?.commit(tab, in: space, session: session)
        }
        sidebarDrag.settle(into: slot, within: slotArea, ownedBy: dragOwner)
    }
}

/// The empty slot a dragged row leaves in the list, at the row's height, which dims while the lifted row shows its shadow.
private struct DraggedSlot: View {
    let height: CGFloat
    let isLifted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(isLifted ? 0.06 : 0))
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// A dragged row's own view, which carries its drag gesture: without height while its slot shows where it lands, then, while the lifted row returns to it, hidden in its place, which dims while the lifted row shows its shadow. Otherwise a row with the rows' spacing below it.
private struct CollapsedWhileDragged: ViewModifier {
    let isCollapsed: Bool
    let isHidden: Bool
    let isLifted: Bool

    func body(content: Content) -> some View {
        content
            .frame(height: isCollapsed ? 0 : nil, alignment: .top)
            .clipped()
            .opacity(isHidden ? 0 : 1)
            .background {
                if isHidden && !isCollapsed {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(isLifted ? 0.06 : 0))
                }
            }
            .accessibilityHidden(isCollapsed)
            .padding(.bottom, isCollapsed ? 0 : SpaceTabsView.rowSpacing)
    }
}

private struct TabRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The space's symbol and name above its tabs, with a button for the space menu. The symbol sits in the tab rows' 18-point icon column, so the name starts where their titles do. With several Personas, the name follows the space's Persona on one line, as "Work / Research" (Persona rule 7), at one size: the Persona's name in regular secondary text, the slash in tertiary, and the space's name in semibold primary, with the Persona's name truncating first in a narrow sidebar, down to its first 36 points so that it stays recognizable. With one Persona, the space's name stays semibold secondary. Double-clicking the name renames the space in place; the Persona's name is not part of the field.
struct SpaceHeaderView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let space: Space
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool
    @State private var isMenuHovering = false
    @Environment(\.spaceTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        nameRow
            // Another space's page takes over the keyboard, so the name in this one is kept.
            .onChange(of: windowModel.currentSpaceID) { _, id in
                if id != space.id, windowModel.renamingSpaceID == space.id { windowModel.renameSpace(space.id, to: draftName) }
            }
    }

    private var nameRow: some View {
        HStack(spacing: 8) {
            Image(systemName: space.symbol)
                .font(.system(size: 12))
                .foregroundStyle(theme.symbolColor(for: space.tint))
                .frame(width: 18)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let personaName = session.displayedName(ofPersona: space.resolvedPersonaID) {
                    Text(personaName)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Truncating keeps at least the name's first 36 points, or all of a shorter name.
                        .frame(minWidth: min(36, ceil((personaName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)), alignment: .leading)
                    // VoiceOver reads the Persona's name and the space's without the slash.
                    Text("/")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                spaceName
            }
            Spacer(minLength: 0)
            Menu {
                SpaceMenuItems(session: session, space: space)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 22)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isMenuHovering ? SidebarFill.buttonHover.color(in: colorScheme) : .clear))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .onHover { isMenuHovering = $0 }
            .help(localized("Space Options"))
            .accessibilityLabel(localized("Space Options"))
        }
        .frame(height: 22)
    }

    /// The space's name, or the field that renames it.
    @ViewBuilder private var spaceName: some View {
        if windowModel.renamingSpaceID == space.id {
            // A hidden copy of the name sizes the field, which would otherwise take a share of the row from the Persona's name. So the header keeps its layout when renaming starts, and the Persona's name still truncates first.
            Text(draftName.isEmpty ? localized("Space Name") : draftName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .hidden()
                .overlay(alignment: .leading) {
                    TextField(localized("Space Name"), text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($isNameFocused)
                        .onSubmit { windowModel.renameSpace(space.id, to: draftName) }
                        .onExitCommand { windowModel.renamingSpaceID = nil }
                        .onChange(of: isNameFocused) { _, focused in
                            if !focused, windowModel.renamingSpaceID == space.id { windowModel.renameSpace(space.id, to: draftName) }
                        }
                        .onAppear {
                            draftName = space.name
                            DispatchQueue.main.async { isNameFocused = true }
                        }
                        // Opening the library or hiding the sidebar removes the field without moving focus, so the name is kept here.
                        .onDisappear {
                            if windowModel.renamingSpaceID == space.id { windowModel.renameSpace(space.id, to: draftName) }
                        }
                }
                .layoutPriority(1)
        } else {
            Text(space.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(session.displayedName(ofPersona: space.resolvedPersonaID) == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                // The space's name keeps its width, so the Persona's name truncates before it.
                .layoutPriority(1)
                .onTapGesture(count: 2) { windowModel.renamingSpaceID = space.id }
        }
    }
}

/// The space menu, shared by the button beside a space's name and the context menu of its symbol at the bottom of the sidebar. Its Persona items act on the space's Persona.
struct SpaceMenuItems: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let space: Space

    /// The spaces of the space's Persona, among which it moves.
    private var personaSpaces: [Space] { session.spaces(in: space.resolvedPersonaID) }
    private var homeURL: URL? { session.spaces.first { $0.id == space.id }?.homeURL }

    var body: some View {
        Button(localized("Rename Space")) {
            windowModel.switchToSpace(space.id)
            windowModel.renamingSpaceID = space.id
        }
        // Automatic follows the system accent color; the others are the space's own color.
        Picker(localized("Tint"), selection: Binding(get: { space.tint }, set: { session.setTint($0, ofSpace: space.id) })) {
            ForEach([SpaceTint.automatic] + SpaceTint.colors, id: \.self) { tint in
                Text(tint.title).tag(tint)
            }
        }
        Picker(localized("Icon"), selection: Binding(get: { space.symbol }, set: { session.setSymbol($0, ofSpace: space.id) })) {
            ForEach(Space.symbolChoices, id: \.symbol) { choice in
                Label(choice.name, systemImage: choice.symbol).tag(choice.symbol)
            }
        }
        Divider()
        Button(localized("Set Current Page as Home")) { windowModel.setCurrentPageAsHome(ofSpace: space.id) }
            .disabled(!windowModel.canSetCurrentPageAsHome)
        Button(localized("Clear Home")) { session.clearHome(ofSpace: space.id) }
            .disabled(homeURL == nil)
        Divider()
        Button(localized("Move Left")) { session.moveSpace(space.id, by: -1) }
            .disabled(personaSpaces.first?.id == space.id)
        Button(localized("Move Right")) { session.moveSpace(space.id, by: 1) }
            .disabled(personaSpaces.last?.id == space.id)
        Divider()
        Button(localized("New Folder")) { withAnimation(.easeInOut(duration: 0.15)) { windowModel.addFolder(toSpace: space.id) } }
        Button(localized("New Space"), action: windowModel.addSpace)
        Button(localized("Delete Space")) { session.deleteSpace(space.id) }
            .disabled(!session.canDeleteSpace(space.id))
        Button(localized("Merge Space Into\u{2026}")) { windowModel.confirmMergeSpace(space) }
            .disabled(session.spaceMergeTargets(for: space.id).isEmpty)
        Divider()
        Button(localized("New Persona\u{2026}"), action: windowModel.promptForNewPersona)
        Button(localized("Rename Persona\u{2026}")) { windowModel.promptToRenamePersona(space.resolvedPersonaID) }
        Button(localized("Delete Persona\u{2026}")) { windowModel.confirmDeletePersona(ofSpace: space) }
            .disabled(!session.canDeletePersona(space.resolvedPersonaID))
        Button(localized("Merge Persona Into\u{2026}")) { windowModel.confirmMergePersona(ofSpace: space) }
            .disabled(session.personaMergeTargets(for: space.resolvedPersonaID).isEmpty)
        PluginMenuSections(plugins: session.plugins(in: space.resolvedPersonaID), location: .spaceMenu) { windowModel.runPluginCommand($0, inSpace: space) }
    }
}

/// The mask of a scrolling list: each end fades out over `length` points, in proportion to how much content is hidden past it, so the list's ends stay crisp at rest and rows slide under softly once scrolled.
struct ScrollEdgeFade: View {
    static let length: CGFloat = 20

    let hiddenAbove: CGFloat
    let hiddenBelow: CGFloat

    /// How strongly an end fades: 0 with nothing hidden past it, 1 once at least `length` points are.
    static func strength(hidden: CGFloat) -> Double {
        Double(min(1, max(0, hidden / length)))
    }

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(1 - Self.strength(hidden: hiddenAbove)), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.length)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(1 - Self.strength(hidden: hiddenBelow))], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.length)
        }
    }
}
