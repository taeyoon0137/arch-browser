// Each sidebar page holds its Persona’s favorites, the space header, pinned and open tabs, nested folders, and the new tab row. A tab or folder row's drag starts and ends here (`SidebarDragState.swift`).
import AppKit
import SwiftUI

private struct FavoriteBarFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
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

/// Shows a space's pinned tabs first, followed by the remaining tabs and the new tab row. Each of the two lists starts with its folders, each followed, unless collapsed, by its own folders and then its tabs, indented by level (`FolderTree.rows(in:pinned:showingInCollapsedFolders:)`).
struct SpaceTabsView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let space: Space
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    /// Set during a row's drag gesture. Resets automatically if the gesture is cancelled, such as when its row disappears.
    @GestureState private var isDragGestureActive = false
    /// Each tab and folder row's frame in the window, and those of the rows that end the pinned and open lists, used to find the row under the pointer and the dropped tab's destination.
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// The visible part of the list in the window. Rows scrolled out of sight lie outside it.
    @State private var listFrame = CGRect.zero
    @State private var tabReorder = SidebarReorderHover()
    @State private var tabSlot: SidebarTabSlot?
    @State private var startedWithoutPins = false
    /// The list's content in the scroll view's visible area, which tells how much is hidden above and below.
    @State private var contentFrame = CGRect.zero
    private static let scrollSpace = "SpaceTabsScroll"
    /// Identifies this list as the owner of a drag it started, since each space and the floating card has its own list.
    @State private var dragOwner = UUID()
    /// The height of the rows a folder dragged from this list hides, measured as the drag starts.
    @State private var hiddenRowsHeight: CGFloat = 0

    /// How far a folder's folders and tabs sit in from its row.
    private static let folderIndent: CGFloat = 12
    /// The keys in `rowFrames` of the rows that end the pinned and open lists: the divider and the new tab row.
    private static let pinnedListEndID = UUID()
    private static let openListEndID = UUID()

    /// Pinned and open tabs share one list, so a tab keeps its row and drag when moving between them or into and out of a folder.
    private enum Item: Identifiable {
        case row(FolderTree.Row)
        case divider(empty: Bool)
        case newTab

        var id: String {
            switch self {
            case .row(let row): return row.id.uuidString
            case .divider: return "divider"
            case .newTab: return "new-tab"
            }
        }
    }

    private var items: [Item] {
        let tree = session.folderTree
        var pinned = listRows(pinned: true, in: tree)
        var open = listRows(pinned: false, in: tree)
        if sidebarDrag.owner == dragOwner, !sidebarDrag.isSettling, let tabSlot, let id = sidebarDrag.tabID,
           let tab = session.tabs.first(where: { $0.id == id && $0.spaceID == space.id && $0.isListedInSidebar }) {
            tabSlot.project(tab, pinnedRows: &pinned, openRows: &open)
        }
        return pinned.map(Item.row) + [.divider(empty: pinned.isEmpty)] + open.map(Item.row) + [.newTab]
    }

    /// The pinned or open list's rows. A collapsed folder still shows its selected tab, and its dragged tab until release, so that the drag keeps its row. A dragged folder shows its row alone until release.
    private func listRows(pinned: Bool, in tree: FolderTree) -> [FolderTree.Row] {
        let isDragging = !sidebarDrag.isSettling
        return tree.rows(in: space.id, pinned: pinned, hidingContentsOf: isDragging ? sidebarDrag.folderID : nil) { $0.id == windowModel.selectedTabID || ($0.id == sidebarDrag.tabID && isDragging) }
    }

    private var offersFirstFavorite: Bool {
        guard windowModel.currentSpaceID == space.id, session.favorites(in: space.resolvedPersonaID).isEmpty,
              let id = sidebarDrag.tabID, let tab = session.tabs.first(where: { $0.id == id }) else { return false }
        return tab.spaceID == space.id && tab.agentOwnerID == nil && session.canAddFavorite(tab)
    }

    private var tabRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            SpaceHeaderView(session: session, space: space)
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.bottom, 4)
                .opacity(offersFirstFavorite ? 0 : 1)
                .overlay {
                    if offersFirstFavorite {
                        Label("Add to Favorites", systemImage: "star")
                            .font(.callout)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 9).strokeBorder(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .modifier(FavoriteDropArea(spaceID: space.id, viewport: listFrame))
                            .allowsHitTesting(false)
                    }
                }
            ForEach(items) { item in
                Group {
                    switch item {
                    case .row(.folder(let folder, let depth)):
                        row(for: folder)
                            .padding(.leading, CGFloat(depth) * Self.folderIndent)
                    case .row(.tab(let tab, let depth)):
                        row(for: tab)
                            .padding(.leading, CGFloat(depth) * Self.folderIndent)
                    case .divider(let empty):
                        let draggedHere = sidebarDrag.owner == dragOwner && sidebarDrag.tabID != nil
                        ZStack {
                            if empty && draggedHere {
                                Label("Pin Tab", systemImage: "pin")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Divider().padding(.horizontal, 10)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: empty || (draggedHere && startedWithoutPins) ? 26 : 10)
                        .background(frameReader(for: Self.pinnedListEndID))
                        .accessibilityHidden(true)
                    case .newTab:
                        NewTabButton(action: { windowModel.showCommandPalette(.newTab, from: .sidebar) })
                            .background(frameReader(for: Self.openListEndID))
                    }
                }
                .transition(Self.rowTransition)
            }
        }
        // A row that closes or opens fades while the rows after it slide into place. Only a change of which rows the list holds animates here, so a drag's moves keep their own timing.
        .animation(sidebarDrag.item?.isRow == true ? nil : .easeInOut(duration: 0.2), value: Set(items.map(\.id)))
        // While a dragged folder hides its rows, the list keeps their height below its end, so that a list scrolled to its end does not scroll back and move other rows under the pointer.
        .padding(.bottom, sidebarDrag.folderID != nil && !sidebarDrag.isSettling && sidebarDrag.owner == dragOwner ? hiddenRowsHeight : 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SidebarView.rowSpacing) {
                if !session.favorites(in: space.resolvedPersonaID).isEmpty {
                    FavoritesGridView(session: session, personaID: space.resolvedPersonaID)
                        .modifier(FavoriteDropArea(spaceID: space.id, viewport: listFrame))
                }
                if let plugins = windowModel.currentSpaceID == space.id ? windowModel.plugins : session.loadedPlugins(in: space.resolvedPersonaID) {
                    PluginSidebarItemsView(plugins: plugins)
                }
                if let agents = session.agents { ConnectedAgentRows(agents: agents) }
                tabRows
            }
            // The scroll view clips at its edges. Keeping the margin inside it leaves room for the selected row's shadow.
            .padding(.horizontal, SidebarView.inset)
            .background(GeometryReader { proxy in
                let frame = proxy.frame(in: .named(Self.scrollSpace))
                Color.clear
                    .onAppear { contentFrame = frame }
                    .onChange(of: frame) { contentFrame = $1 }
            })
            .environment(\.isDraggingTab, sidebarDrag.item?.isRow == true)
            .onPreferenceChange(TabRowFramesKey.self) { rowFrames = $0 }
            // A cancelled gesture never reports its end. Drop the drag once the gesture is gone and nothing is settling.
            .onChange(of: isDragGestureActive) { _, isActive in
                guard !isActive else { return }
                DispatchQueue.main.async {
                    if !isDragGestureActive, !sidebarDrag.isSettling { sidebarDrag.end(ownedBy: dragOwner) }
                }
            }
        }
        .scrollIndicators(.never)
        .coordinateSpace(name: Self.scrollSpace)
        // Rows fade out under the address field and above the bottom bar instead of being cut off, at each end only while rows are hidden past it.
        .mask(ScrollEdgeFade(hiddenAbove: -contentFrame.minY, hiddenBelow: contentFrame.maxY - listFrame.height))
        .background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
            Color.clear
                .onAppear { listFrame = frame }
                .onChange(of: frame) { listFrame = $1 }
        })
        // Hiding the sidebar or the card mid-drag removes the list without ending its gesture.
        .onDisappear { sidebarDrag.end(ownedBy: dragOwner) }
    }

    /// A closing row fades and shrinks a little in place; a new row fades in.
    private static let rowTransition = AnyTransition.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96)))

    /// A dragged tab leaves an empty, dimmed slot in the list.
    private func row(for tab: Tab) -> some View {
        TabRowView(session: session, tab: tab)
            .modifier(DraggedSlot(isDragged: sidebarDrag.tabID == tab.id, isLifted: sidebarDrag.isLifted))
            .background(frameReader(for: tab.id))
            // Dragging in the name field selects text instead.
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(BrowserWindowView.coordinateSpace))
                .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
                .onChanged { dragChanged(tab, $0) }
                .onEnded { value in
                    if sidebarDrag.owner == dragOwner { dragChanged(tab, value) }
                    dragEnded()
                }, including: windowModel.renamingTabID == tab.id ? .subviews : .all)
    }

    /// A dragged folder leaves an empty, dimmed slot in the list, and the rows inside it hide until release.
    private func row(for folder: TabFolder) -> some View {
        TabFolderRowView(session: session, folder: folder)
            .modifier(DraggedSlot(isDragged: sidebarDrag.folderID == folder.id, isLifted: sidebarDrag.isLifted))
            .background(frameReader(for: folder.id))
            // Dragging in the name field selects text instead.
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(BrowserWindowView.coordinateSpace))
                .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
                .onChanged { dragChanged(folder.id, $0) }
                .onEnded { _ in dragEnded() }, including: windowModel.renamingFolderID == folder.id ? .subviews : .all)
    }

    /// Reports a tab's or folder's row frame in the window.
    private func frameReader(for id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: TabRowFramesKey.self, value: [id: proxy.frame(in: .named(BrowserWindowView.coordinateSpace))])
        }
    }

    /// Starts the drag of a row, lifting it at its frame, or continues the drag of it that this list started, and moves the lifted row to the pointer. False while another drag or a release is under way.
    private func continueDrag(of item: SidebarDragItem, _ value: DragGesture.Value) -> Bool {
        guard windowModel.currentSpaceID == space.id, !sidebarDrag.isSettling, sidebarDrag.item == nil || (sidebarDrag.item == item && sidebarDrag.owner == dragOwner), let frame = rowFrames[item.id] else { return false }
        if sidebarDrag.item == nil {
            tabReorder = SidebarReorderHover()
            tabSlot = nil
            startedWithoutPins = session.folderTree.rows(in: space.id, pinned: true).isEmpty
            if case .folder(let id) = item { hiddenRowsHeight = contentsHeight(ofFolder: id, below: frame) }
            sidebarDrag.begin(item, frame: frame, grabbedAt: value.startLocation, owner: dragOwner)
            // The row appears without a shadow, which then fades in.
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: SidebarDragState.liftDuration)) { sidebarDrag.isLifted = true } }
        }
        sidebarDrag.move(to: value.location)
        return true
    }

    /// The height of the rows that follow a folder's row, from its bottom to the bottom of the last of them: the folder's rows, which its drag hides.
    private func contentsHeight(ofFolder id: UUID, below folderFrame: CGRect) -> CGFloat {
        let tree = session.folderTree
        guard let folder = tree.folder(id) else { return 0 }
        let rows = tree.rows(in: space.id, pinned: folder.isPinned) { $0.id == windowModel.selectedTabID }
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return 0 }
        let bottom = rows[(index + 1)...].prefix { $0.depth > rows[index].depth }.compactMap { rowFrames[$0.id]?.maxY }.max()
        return max(0, (bottom ?? folderFrame.maxY) - folderFrame.maxY)
    }

    /// The lifted row follows the pointer anywhere in the window. Only a pointer over the visible list moves the tab.
    private func dragChanged(_ tab: Tab, _ value: DragGesture.Value) {
        guard tab.spaceID == space.id, continueDrag(of: .tab(tab.id), value) else { return }
        setDropTarget(\.targetFavoriteSpaceID, to: sidebarDrag.favoriteDestination(for: tab, in: space, at: value.location, session: session))
        let isOverList = listFrame.contains(value.location)
        let tree = session.folderTree
        // Another space's symbol, or another folder's row at any level, under the pointer lights up and takes the tab on release. The rows do not make room for it. A space of another Persona does not take the tab.
        setDropTarget(\.targetSpaceID, to: sidebarDrag.space(at: value.location).flatMap { $0 == tab.spaceID || !session.canMoveTab(tab.id, toSpace: $0) ? nil : $0 })
        setDropTarget(\.targetFolderID, to: isOverList ? session.folders(in: space.id).first { rowFrames[$0.id]?.contains(value.location) == true }.flatMap { tree.canMoveTab(tab, into: $0.id) ? $0.id : nil } : nil)
        // Over the page area beside the list, the pane under the pointer shows where the tab opens in split view.
        setDropTarget(\.splitDrop, to: sidebarDrag.targetSpaceID == nil && value.location.x > listFrame.maxX ? sidebarDrag.splitDrop(of: tab, at: value.location, in: windowModel) : nil)
        // The row under the pointer makes room for the dragged tab, with a light haptic at each new position. A collapsed folder's selected tab does not, since the tab would join the folder and hide on release; the folder's row takes it instead. Nor does a live folder's tab, since nothing else enters a live folder and its tabs keep their source's order (live folder rule 4).
        if sidebarDrag.favoriteBarFrames[space.id]?.contains(value.location) == true {
            if tabSlot != nil {
                tabSlot = nil
                tabReorder = SidebarReorderHover()
            }
            return
        }
        guard isOverList, sidebarDrag.targetSpaceID == nil, sidebarDrag.targetFolderID == nil,
              tabReorder.canMove(at: value.location) else { return }
        let tabs = tree.tabs(in: space.id, pinned: true) + tree.tabs(in: space.id, pinned: false)
        let frame: CGRect
        let next: SidebarTabSlot
        if let pinned = listEnd(at: value.location), let endFrame = rowFrames[pinned ? Self.pinnedListEndID : Self.openListEndID] {
            if tabSlot == nil && tree.tabsOutsideFolders(in: space.id, pinned: pinned).last?.id == tab.id { return }
            next = .end(pinned: pinned)
            frame = endFrame
        } else if let target = tabs.first(where: { $0.id != tab.id && !tree.isInCollapsedFolder($0) && !tree.isLive($0.folderID) && rowFrames[$0.id]?.contains(value.location) == true }),
                  let rowFrame = rowFrames[target.id], let slot = rowFrames[tab.id],
                  SidebarReorderHover.crossedMidpoint(from: slot, into: rowFrame, at: value.location) {
            guard target.agentOwnerID == nil || target.folderID == tab.folderID else { return }
            let sameList = tabSlot.map { $0.pinned == target.isPinned && $0.folderID == target.folderID }
                ?? (tab.isPinned == target.isPinned && tab.folderID == target.folderID)
            next = .beside(target.id, folder: target.folderID, pinned: target.isPinned, after: sameList && slot.midY < rowFrame.midY)
            frame = rowFrame
        } else {
            return
        }
        guard next != tabSlot else { return }
        withAnimation(.easeOut(duration: 0.15)) { tabSlot = next }
        tabReorder.moved(into: frame)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// The lifted folder row follows the pointer anywhere in the window. `FolderTree.dropTarget(for:at:)` decides each place in the list: the rows make room for the folder between them, with a light haptic at each new position, or a folder's row lights up to take it on release. Another space's symbol of its Persona lights up to take it with what it holds. Where the tree refuses a place, nothing moves, and the row returns to its slot on release.
    private func dragChanged(_ folderID: UUID, _ value: DragGesture.Value) {
        guard continueDrag(of: .folder(folderID), value) else { return }
        setDropTarget(\.targetSpaceID, to: sidebarDrag.space(at: value.location).flatMap { session.canMoveFolder(folderID, toSpace: $0) ? $0 : nil })
        let tree = session.folderTree
        let target = listFrame.contains(value.location) ? dropPosition(at: value.location, in: tree).flatMap { tree.dropTarget(for: folderID, at: $0) } : nil
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
        guard let row = rowFrames.first(where: { $0.value.contains(point) }) else { return nil }
        guard tree.folder(row.key) != nil else { return .onTab(row.key) }
        return point.y < row.value.minY + row.value.height / 3 ? .aboveFolder(row.key) : .onFolder(row.key)
    }

    /// The list whose closing row is under the pointer: `true` for the divider after the pinned list, `false` for the new tab row after the open list.
    private func listEnd(at point: CGPoint) -> Bool? {
        if rowFrames[Self.pinnedListEndID]?.contains(point) == true { return true }
        if rowFrames[Self.openListEndID]?.contains(point) == true { return false }
        return nil
    }

    /// Lights up a drop target newly under the dragged row, with a light haptic, or turns off the one it left.
    private func setDropTarget<Target: Equatable>(_ keyPath: ReferenceWritableKeyPath<SidebarDragState, Target?>, to target: Target?) {
        guard sidebarDrag[keyPath: keyPath] != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { sidebarDrag[keyPath: keyPath] = target }
        if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// On release, the lifted row returns to its slot, wherever the pointer is, and its shadow fades out before the row reappears in the list, unless a drop target under it takes it.
    private func dragEnded() {
        guard sidebarDrag.owner == dragOwner, windowModel.currentSpaceID == space.id, let item = sidebarDrag.item,
              let slot = rowFrames[item.id] else { return sidebarDrag.end(ownedBy: dragOwner) }
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
        sidebarDrag.settle(into: slot, ownedBy: dragOwner)
    }
}

/// The empty slot a dragged row leaves in the list: the row hides, and the slot dims while the lifted row shows its shadow.
private struct DraggedSlot: ViewModifier {
    let isDragged: Bool
    let isLifted: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isDragged ? 0 : 1)
            .background {
                if isDragged {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(isLifted ? 0.06 : 0))
                }
            }
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
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isMenuHovering ? 0.08 : 0)))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .onHover { isMenuHovering = $0 }
            .help("Space Options")
            .accessibilityLabel("Space Options")
        }
        .frame(height: 22)
    }

    /// The space's name, or the field that renames it.
    @ViewBuilder private var spaceName: some View {
        if windowModel.renamingSpaceID == space.id {
            // A hidden copy of the name sizes the field, which would otherwise take a share of the row from the Persona's name. So the header keeps its layout when renaming starts, and the Persona's name still truncates first.
            Text(draftName.isEmpty ? "Space Name" : draftName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .hidden()
                .overlay(alignment: .leading) {
                    TextField("Space Name", text: $draftName)
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
        Button("Rename Space") {
            windowModel.switchToSpace(space.id)
            windowModel.renamingSpaceID = space.id
        }
        // Automatic follows the system accent color; the others are the space's own color.
        Picker("Tint", selection: Binding(get: { space.tint }, set: { session.setTint($0, ofSpace: space.id) })) {
            ForEach([SpaceTint.automatic] + SpaceTint.colors, id: \.self) { tint in
                Text(tint.title).tag(tint)
            }
        }
        Picker("Icon", selection: Binding(get: { space.symbol }, set: { session.setSymbol($0, ofSpace: space.id) })) {
            ForEach(Space.symbolChoices, id: \.symbol) { choice in
                Label(choice.name, systemImage: choice.symbol).tag(choice.symbol)
            }
        }
        Divider()
        Button("Set Current Page as Home") { windowModel.setCurrentPageAsHome(ofSpace: space.id) }
            .disabled(!windowModel.canSetCurrentPageAsHome)
        Button("Clear Home") { session.clearHome(ofSpace: space.id) }
            .disabled(homeURL == nil)
        Divider()
        Button("Move Left") { session.moveSpace(space.id, by: -1) }
            .disabled(personaSpaces.first?.id == space.id)
        Button("Move Right") { session.moveSpace(space.id, by: 1) }
            .disabled(personaSpaces.last?.id == space.id)
        Divider()
        Button("New Folder") { withAnimation(.easeInOut(duration: 0.15)) { windowModel.addFolder(toSpace: space.id) } }
        Button("New Live Folder\u{2026}") { windowModel.showNewLiveFolderSheet(inSpace: space.id) }
        Button("New Space", action: windowModel.addSpace)
        Button("Delete Space") { session.deleteSpace(space.id) }
            .disabled(!session.canDeleteSpace(space.id))
        Divider()
        Button("New Persona\u{2026}", action: windowModel.promptForNewPersona)
        Button("Rename Persona\u{2026}") { windowModel.promptToRenamePersona(space.resolvedPersonaID) }
        Button("Delete Persona\u{2026}") { windowModel.confirmDeletePersona(ofSpace: space) }
            .disabled(!session.canDeletePersona(space.resolvedPersonaID))
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
