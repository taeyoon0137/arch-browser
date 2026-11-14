// The space pages below the favorites: one page per space, each with the space's header and menu, then its pinned tabs, its open tabs, their nested folders, and the new tab row. A tab or folder row's drag starts and ends here (`SidebarDragState.swift`).
import AppKit
import SwiftUI

/// Lays out one page per space side by side and shows the current space's page. During a swipe the pages follow the fingers; a change of space slides them into place.
struct SpacePagesView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let translation: CGFloat
    @Environment(\.sidebarWidth) private var width

    var body: some View {
        let index = session.spaces.firstIndex { $0.id == windowModel.currentSpaceID } ?? 0
        HStack(spacing: 0) {
            ForEach(session.spaces) { space in
                let isCurrent = space.id == windowModel.currentSpaceID
                SpaceTabsView(session: session, space: space)
                    .frame(width: width)
                    // Clipping hides the other pages but does not stop them from taking clicks over the page beside the sidebar, or from reaching assistive apps.
                    .allowsHitTesting(isCurrent)
                    .accessibilityElement(children: isCurrent ? .contain : .ignore)
                    .accessibilityHidden(!isCurrent)
            }
        }
        .offset(x: -CGFloat(index) * width + translation)
        .frame(width: width, alignment: .leading)
        .clipped()
        .animation(SidebarView.pageSpring, value: windowModel.currentSpaceID)
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
        case divider
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
        let pinned = listItems(pinned: true, in: tree)
        return pinned + (pinned.isEmpty ? [] : [.divider]) + listItems(pinned: false, in: tree) + [.newTab]
    }

    /// The pinned or open list's rows. A collapsed folder still shows its selected tab, and its dragged tab until release, so that the drag keeps its row. A dragged folder shows its row alone until release.
    private func listItems(pinned: Bool, in tree: FolderTree) -> [Item] {
        let isDragging = !sidebarDrag.isSettling
        return tree.rows(in: space.id, pinned: pinned, hidingContentsOf: isDragging ? sidebarDrag.folderID : nil) { $0.id == windowModel.selectedTabID || ($0.id == sidebarDrag.tabID && isDragging) }.map(Item.row)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SpaceHeaderView(session: session, space: space)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                ForEach(items) { item in
                    switch item {
                    case .row(.folder(let folder, let depth)):
                        row(for: folder)
                            .padding(.leading, CGFloat(depth) * Self.folderIndent)
                    case .row(.tab(let tab, let depth)):
                        row(for: tab)
                            .padding(.leading, CGFloat(depth) * Self.folderIndent)
                    case .divider:
                        Divider().padding(.vertical, 4).padding(.horizontal, 10)
                            .background(frameReader(for: Self.pinnedListEndID))
                    case .newTab:
                        NewTabButton(action: { windowModel.showCommandPalette(.newTab, from: .sidebar) })
                            .background(frameReader(for: Self.openListEndID))
                    }
                }
            }
            // While a dragged folder hides its rows, the list keeps their height below its end, so that a list scrolled to its end does not scroll back and move other rows under the pointer.
            .padding(.bottom, sidebarDrag.folderID != nil && !sidebarDrag.isSettling && sidebarDrag.owner == dragOwner ? hiddenRowsHeight : 0)
            // The scroll view clips at its edges. Keeping the margin inside it leaves room for the selected row's shadow.
            .padding(.horizontal, SidebarView.inset)
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
        .background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
            Color.clear
                .onAppear { listFrame = frame }
                .onChange(of: frame) { listFrame = $1 }
        })
        // Hiding the sidebar or the card mid-drag removes the list without ending its gesture.
        .onDisappear { sidebarDrag.end(ownedBy: dragOwner) }
    }

    /// A dragged tab leaves an empty, dimmed slot in the list.
    private func row(for tab: Tab) -> some View {
        TabRowView(session: session, tab: tab)
            .modifier(DraggedSlot(isDragged: sidebarDrag.tabID == tab.id, isLifted: sidebarDrag.isLifted))
            .background(frameReader(for: tab.id))
            // Dragging in the name field selects text instead.
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(BrowserWindowView.coordinateSpace))
                .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
                .onChanged { dragChanged(tab, $0) }
                .onEnded { _ in dragEnded() }, including: windowModel.renamingTabID == tab.id ? .subviews : .all)
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
        guard !sidebarDrag.isSettling, sidebarDrag.item == nil || (sidebarDrag.item == item && sidebarDrag.owner == dragOwner), let frame = rowFrames[item.id] else { return false }
        if sidebarDrag.item == nil {
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
        guard continueDrag(of: .tab(tab.id), value) else { return }
        let isOverList = listFrame.contains(value.location)
        let tree = session.folderTree
        // Another space's symbol, or another folder's row at any level, under the pointer lights up and takes the tab on release. The rows do not make room for it. A space of another Persona does not take the tab.
        setDropTarget(\.targetSpaceID, to: sidebarDrag.space(at: value.location).flatMap { $0 == tab.spaceID || !session.canMoveTab(tab.id, toSpace: $0) ? nil : $0 })
        setDropTarget(\.targetFolderID, to: isOverList ? session.folders(in: space.id).first { rowFrames[$0.id]?.contains(value.location) == true }.flatMap { tree.canMoveTab(tab, into: $0.id) ? $0.id : nil } : nil)
        // Over the page area beside the list, the pane under the pointer shows where the tab opens in split view.
        setDropTarget(\.splitDrop, to: sidebarDrag.targetSpaceID == nil && value.location.x > listFrame.maxX ? sidebarDrag.splitDrop(of: tab, at: value.location, in: windowModel) : nil)
        // The row under the pointer makes room for the dragged tab, with a light haptic at each new position. A collapsed folder's selected tab does not, since the tab would join the folder and hide on release; the folder's row takes it instead. Nor does a live folder's tab, since nothing else enters a live folder and its tabs keep their source's order (live folder rule 4).
        guard isOverList else { return }
        let tabs = tree.tabs(in: space.id, pinned: true) + tree.tabs(in: space.id, pinned: false)
        if let target = tabs.first(where: { $0.id != tab.id && !tree.isInCollapsedFolder($0) && !tree.isLive($0.folderID) && rowFrames[$0.id]?.contains(value.location) == true }) {
            withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(tab.id, to: target) }
        } else if let pinned = listEnd(at: value.location), session.tabsOutsideFolders(in: space.id, pinned: pinned).last?.id != tab.id {
            // The divider or the new tab row puts the tab last in the list it ends, outside folders, so that it can leave a folder in a list with no other tab outside folders.
            withAnimation(.easeInOut(duration: 0.15)) { session.moveTabToListEnd(tab.id, pinned: pinned) }
        } else {
            return
        }
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
        guard sidebarDrag.owner == dragOwner, let item = sidebarDrag.item, let slot = rowFrames[item.id] else { return sidebarDrag.end(ownedBy: dragOwner) }
        // Over another space's symbol, the tab goes after that space's own tabs, or the folder with what it holds after its folders, and the lifted row shrinks into the symbol.
        if let spaceID = sidebarDrag.targetSpaceID {
            withAnimation(.easeInOut(duration: 0.15)) {
                if case .folder(let id) = item { session.moveFolder(id, toSpace: spaceID) } else { session.moveTab(item.id, toSpace: spaceID) }
            }
            return sidebarDrag.settle(intoSpace: spaceID, ownedBy: dragOwner)
        }
        // Over a folder's row, the tab goes after the folder's own tabs, or the folder after its folders, and the lifted row shrinks into the folder's row.
        if let folderID = sidebarDrag.targetFolderID, let folderRow = rowFrames[folderID] {
            withAnimation(.easeInOut(duration: 0.15)) {
                if case .folder(let id) = item { session.moveFolder(id, to: .into(folderID)) } else { session.moveTab(item.id, toFolder: folderID) }
            }
            return sidebarDrag.settle(shrinkingInto: folderRow, ownedBy: dragOwner)
        }
        // Over the page area, a tab opens in split view, and its row returns to its slot.
        if let drop = sidebarDrag.splitDrop, case .tab(let id) = item, let tab = session.tabs.first(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.15)) { sidebarDrag.splitDrop = nil }
            windowModel.openInSplitView(tab, at: drop.index)
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

/// The space's symbol and label above its tabs, with a button for the space menu. With several Personas, the label is "Work / Research" (Persona rule 7), the Persona's name and the slash at regular weight before the space's name. Double-clicking the space's name renames the space in place.
struct SpaceHeaderView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let space: Space
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: space.symbol)
                .font(.system(size: 10))
                .foregroundStyle(theme.symbolColor(for: space.tint))
            HStack(spacing: 0) {
                personaPart
                spaceName
            }
            Spacer(minLength: 0)
            Menu {
                SpaceMenuItems(session: session, space: space)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Space Options")
            .accessibilityLabel("Space Options")
        }
        .frame(height: 22)
        // Another space's page takes over the keyboard, so the name in this one is kept.
        .onChange(of: windowModel.currentSpaceID) { _, id in
            if id != space.id, windowModel.renamingSpaceID == space.id { windowModel.renameSpace(space.id, to: draftName) }
        }
    }

    /// The Persona's name and the slash before the space's name, which only a label with several Personas has. They stay while the space's name is being edited.
    @ViewBuilder private var personaPart: some View {
        if let personaName = session.displayedName(ofPersona: space.resolvedPersonaID) {
            Text(personaName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // A text can leave its trailing space out of its width, so the separator's spaces show as no-break spaces.
            Text(BrowserSession.labelSeparator.replacingOccurrences(of: " ", with: "\u{00A0}"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    /// The space's name, or its field while the space is being renamed.
    @ViewBuilder private var spaceName: some View {
        if windowModel.renamingSpaceID == space.id {
            // A hidden copy of the name sizes the field, which would otherwise take a share of the row from the Persona's name. So the label keeps its layout when renaming starts, and the Persona's name still gives way first.
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
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // The Persona's name gives way first when the label does not fit.
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
        Picker("Theme", selection: Binding(get: { space.tint }, set: { session.setTint($0, ofSpace: space.id) })) {
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
        Button("Delete Persona\u{2026}") { windowModel.confirmDeletePersona(space.resolvedPersonaID) }
            .disabled(!session.canDeletePersona(space.resolvedPersonaID))
        PluginMenuSections(plugins: session.plugins(in: space.resolvedPersonaID), location: .spaceMenu) { windowModel.runPluginCommand($0, inSpace: space) }
    }
}
