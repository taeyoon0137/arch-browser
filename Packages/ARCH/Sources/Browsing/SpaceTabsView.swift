// The space pages below the favorites: one page per space, each with the space's header and menu, then its pinned tabs, its open tabs, their folders, and the new tab row. A tab row's drag starts and ends here (`SidebarDragState.swift`).
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

/// Shows a space's pinned tabs first, followed by the remaining tabs and the new tab row. Each of the two lists starts with its folders, each followed by its tabs unless collapsed.
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

    /// How far a folder's tabs sit in from its row.
    private static let folderIndent: CGFloat = 12
    /// The keys in `rowFrames` of the rows that end the pinned and open lists: the divider and the new tab row.
    private static let pinnedListEndID = UUID()
    private static let openListEndID = UUID()

    /// Pinned and open tabs share one list, so a tab keeps its row and drag when moving between them or into and out of a folder.
    private enum Item: Identifiable {
        case folder(TabFolder)
        case tab(Tab, isInFolder: Bool)
        case divider
        case newTab

        var id: String {
            switch self {
            case .folder(let folder): return folder.id.uuidString
            case .tab(let tab, _): return tab.id.uuidString
            case .divider: return "divider"
            case .newTab: return "new-tab"
            }
        }
    }

    private var items: [Item] {
        let pinned = listItems(pinned: true)
        return pinned + (pinned.isEmpty ? [] : [.divider]) + listItems(pinned: false) + [.newTab]
    }

    /// The pinned or open list: each folder followed by its tabs, then the tabs outside folders. A collapsed folder still shows its selected tab, and its dragged tab until release, so that the drag keeps its row.
    private func listItems(pinned: Bool) -> [Item] {
        let folders = session.folders(in: space.id, pinned: pinned).flatMap { folder in
            let shown = session.tabs(in: folder).filter { !folder.isCollapsed || $0.id == windowModel.selectedTabID || ($0.id == sidebarDrag.tabID && !sidebarDrag.isSettling) }
            return [Item.folder(folder)] + shown.map { Item.tab($0, isInFolder: true) }
        }
        return folders + session.tabsOutsideFolders(in: space.id, pinned: pinned).map { Item.tab($0, isInFolder: false) }
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
                    case .folder(let folder):
                        TabFolderRowView(session: session, folder: folder)
                            .background(frameReader(for: folder.id))
                    case .tab(let tab, let isInFolder):
                        row(for: tab)
                            .padding(.leading, isInFolder ? Self.folderIndent : 0)
                    case .divider:
                        Divider().padding(.vertical, 4).padding(.horizontal, 10)
                            .background(frameReader(for: Self.pinnedListEndID))
                    case .newTab:
                        NewTabButton(action: { windowModel.showCommandPalette(.newTab, from: .sidebar) })
                            .background(frameReader(for: Self.openListEndID))
                    }
                }
            }
            // The scroll view clips at its edges. Keeping the margin inside it leaves room for the selected row's shadow.
            .padding(.horizontal, SidebarView.inset)
            .environment(\.isDraggingTab, sidebarDrag.tabID != nil)
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
        let isDragged = sidebarDrag.tabID == tab.id
        return TabRowView(session: session, tab: tab)
            .opacity(isDragged ? 0 : 1)
            .background {
                if isDragged {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(sidebarDrag.isLifted ? 0.06 : 0))
                }
            }
            .background(frameReader(for: tab.id))
            // Dragging in the name field selects text instead.
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(BrowserWindowView.coordinateSpace))
                .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
                .onChanged { dragChanged(tab, $0) }
                .onEnded { _ in dragEnded() }, including: windowModel.renamingTabID == tab.id ? .subviews : .all)
    }

    /// Reports a tab's or folder's row frame in the window.
    private func frameReader(for id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: TabRowFramesKey.self, value: [id: proxy.frame(in: .named(BrowserWindowView.coordinateSpace))])
        }
    }

    /// The lifted row follows the pointer anywhere in the window. Only a pointer over the visible list moves the tab.
    private func dragChanged(_ tab: Tab, _ value: DragGesture.Value) {
        guard !sidebarDrag.isSettling, sidebarDrag.item == nil || (sidebarDrag.tabID == tab.id && sidebarDrag.owner == dragOwner), let frame = rowFrames[tab.id] else { return }
        if sidebarDrag.item == nil {
            sidebarDrag.begin(.tab(tab.id), frame: frame, grabbedAt: value.startLocation, owner: dragOwner)
            // The row appears without a shadow, which then fades in.
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: SidebarDragState.liftDuration)) { sidebarDrag.isLifted = true } }
        }
        sidebarDrag.move(to: value.location)
        let isOverList = listFrame.contains(value.location)
        // Another space's symbol, or another folder's row, under the pointer lights up and takes the tab on release. The rows do not make room for it. A space of another Persona does not take the tab.
        setDropTarget(\.targetSpaceID, to: sidebarDrag.space(at: value.location).flatMap { $0 == tab.spaceID || !session.canMoveTab(tab.id, toSpace: $0) ? nil : $0 })
        setDropTarget(\.targetFolderID, to: isOverList ? session.folders(in: space.id).first { $0.id != tab.folderID && rowFrames[$0.id]?.contains(value.location) == true }?.id : nil)
        // Over the page area beside the list, the pane under the pointer shows where the tab opens in split view.
        setDropTarget(\.splitDrop, to: sidebarDrag.targetSpaceID == nil && value.location.x > listFrame.maxX ? sidebarDrag.splitDrop(of: tab, at: value.location, in: windowModel) : nil)
        // The row under the pointer makes room for the dragged tab, with a light haptic at each new position. A collapsed folder's selected tab does not, since the tab would join the folder and hide on release; the folder's row takes it instead.
        guard isOverList else { return }
        let tabs = session.tabs(in: space.id, pinned: true) + session.tabs(in: space.id, pinned: false)
        if let target = tabs.first(where: { $0.id != tab.id && !session.isInCollapsedFolder($0) && rowFrames[$0.id]?.contains(value.location) == true }) {
            withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(tab.id, to: target) }
        } else if let pinned = listEnd(at: value.location), session.tabsOutsideFolders(in: space.id, pinned: pinned).last?.id != tab.id {
            // The divider or the new tab row puts the tab last in the list it ends, outside folders, so that it can leave a folder in a list with no other tab outside folders.
            withAnimation(.easeInOut(duration: 0.15)) { session.moveTabToListEnd(tab.id, pinned: pinned) }
        } else {
            return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// The list whose closing row is under the pointer: `true` for the divider after the pinned list, `false` for the new tab row after the open list.
    private func listEnd(at point: CGPoint) -> Bool? {
        if rowFrames[Self.pinnedListEndID]?.contains(point) == true { return true }
        if rowFrames[Self.openListEndID]?.contains(point) == true { return false }
        return nil
    }

    /// Lights up a drop target newly under the dragged tab, with a light haptic, or turns off the one it left.
    private func setDropTarget<Target: Equatable>(_ keyPath: ReferenceWritableKeyPath<SidebarDragState, Target?>, to target: Target?) {
        guard sidebarDrag[keyPath: keyPath] != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { sidebarDrag[keyPath: keyPath] = target }
        if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// On release, the lifted row returns to its slot, wherever the pointer is, and its shadow fades out before the tab reappears in the list.
    private func dragEnded() {
        guard sidebarDrag.owner == dragOwner, let id = sidebarDrag.tabID, let slot = rowFrames[id] else { return sidebarDrag.end(ownedBy: dragOwner) }
        // Over another space's symbol, the tab goes after that space's own tabs and the lifted row shrinks into the symbol.
        if let spaceID = sidebarDrag.targetSpaceID {
            withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(id, toSpace: spaceID) }
            return sidebarDrag.settle(intoSpace: spaceID, ownedBy: dragOwner)
        }
        // Over a folder's row, the tab goes after the folder's own tabs and the lifted row shrinks into the folder's row.
        if let folderID = sidebarDrag.targetFolderID, let folderRow = rowFrames[folderID] {
            withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(id, toFolder: folderID) }
            return sidebarDrag.settle(shrinkingInto: folderRow, ownedBy: dragOwner)
        }
        // Over the page area, the tab opens in split view, and its row returns to its slot.
        if let drop = sidebarDrag.splitDrop, let tab = session.tabs.first(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.15)) { sidebarDrag.splitDrop = nil }
            windowModel.openInSplitView(tab, at: drop.index)
        }
        sidebarDrag.settle(into: slot, ownedBy: dragOwner)
    }
}

private struct TabRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The space's symbol and name above its tabs, with a button for the space menu, and with several Personas the space's Persona above them. Double-clicking the name renames the space in place.
struct SpaceHeaderView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let space: Space
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let personaName = session.displayedName(ofPersona: space.resolvedPersonaID) {
                Text(personaName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            nameRow
        }
        // Another space's page takes over the keyboard, so the name in this one is kept.
        .onChange(of: windowModel.currentSpaceID) { _, id in
            if id != space.id, windowModel.renamingSpaceID == space.id { windowModel.renameSpace(space.id, to: draftName) }
        }
    }

    private var nameRow: some View {
        HStack(spacing: 6) {
            Image(systemName: space.symbol)
                .font(.system(size: 10))
                .foregroundStyle(theme.symbolColor(for: space.tint))
            if windowModel.renamingSpaceID == space.id {
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
            } else {
                Text(space.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { windowModel.renamingSpaceID = space.id }
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
