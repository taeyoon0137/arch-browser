// A folder's row in a space's tab list, above the folder's indented folders and tabs, and the Move to Folder submenu that folder and tab rows share. `SpaceTabsView` places and indents the row and reports its frame, so a dragged tab can find it.
import SwiftUI

/// Clicking the row collapses or expands the folder, Rename Folder in its context menu edits the name in place, and the menu's folder items nest it (bookmark rule 6). The row lights up while a dragged tab is over it, as a space's symbol does.
struct TabFolderRowView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let folder: TabFolder
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isDraggingTab) private var isDraggingTab
    @State private var isHovering = false

    private var isRenaming: Bool { windowModel.renamingFolderID == folder.id }
    private var isDropTarget: Bool { sidebarDrag.targetFolderID == folder.id }

    /// Rows ignore the pointer while a tab is dragged over them; the folder under it lights up instead.
    private var fill: Color {
        if isDropTarget { return Color.accentColor.opacity(0.15) }
        return isHovering && !isDraggingTab ? SidebarFill.hover.color(in: colorScheme) : .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDropTarget ? Color.accentColor : .secondary)
                .frame(width: 18, height: 18)
            if isRenaming {
                SidebarNameField(placeholder: "Folder Name", name: folder.name,
                                 onRename: { windowModel.renameFolder(folder.id, to: $0) }, onEnd: { windowModel.endRenamingFolder(folder.id) })
            } else {
                Text(folder.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // In the close button's place on a tab row.
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(folder.isCollapsed ? 0 : 90))
                .frame(width: 22, height: 22)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
        .contentShape(Rectangle())
        .help(folder.name)
        .onTapGesture(perform: toggleCollapsed)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename Folder") { windowModel.renamingFolderID = folder.id }
            FolderNestingItems(session: session, windowModel: windowModel, folder: folder)
            Divider()
            Button("Delete Folder") { withAnimation(.easeInOut(duration: 0.15)) { session.deleteFolder(folder.id) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(folder.isCollapsed ? "Collapsed" : "Expanded")
        // A tap gesture alone does not answer the accessibility press.
        .accessibilityAction { toggleCollapsed() }
    }

    /// A click in the name field while renaming edits the name instead.
    private func toggleCollapsed() {
        guard !isRenaming else { return }
        withAnimation(.easeInOut(duration: 0.2)) { session.toggleCollapsed(ofFolder: folder.id) }
    }
}

/// A folder's New Folder Inside, Move to Folder, and Move Out of Folder. The menu asks the folder tree as it builds, and gets the window model as a value rather than from the environment.
private struct FolderNestingItems: View {
    @ObservedObject var session: BrowserSession
    let windowModel: BrowserWindowModel
    let folder: TabFolder

    var body: some View {
        let tree = session.folderTree
        Button("New Folder Inside") { withAnimation(.easeInOut(duration: 0.15)) { windowModel.addFolder(inside: folder.id) } }
            .disabled(!tree.canAddFolder(inside: folder.id))
        MoveToFolderMenu(lists: [tree.moveTargets(forFolder: folder.id)]) { target in
            withAnimation(.easeInOut(duration: 0.15)) { session.moveFolder(folder.id, into: target) }
        }
        if folder.parentID != nil {
            Button("Move Out of Folder") { withAnimation(.easeInOut(duration: 0.15)) { session.moveFolderOut(folder.id) } }
        }
    }
}

/// Move to Folder for a tab or a folder: a submenu that mirrors the folder tree, one list after another with a divider between them, and lists only the moves `FolderTree` allows. A folder that holds listed folders is a submenu whose first item moves into the folder itself. Without a move to offer, the item is left out.
struct MoveToFolderMenu: View {
    let lists: [[FolderTree.MoveTarget]]
    let move: (UUID) -> Void

    var body: some View {
        let lists = lists.filter { !$0.isEmpty }
        if !lists.isEmpty {
            Menu("Move to Folder") {
                ForEach(lists.indices, id: \.self) { index in
                    if index > 0 { Divider() }
                    MoveTargetItems(targets: lists[index], move: move)
                }
            }
        }
    }
}

/// One level of Move to Folder's targets.
private struct MoveTargetItems: View {
    let targets: [FolderTree.MoveTarget]
    let move: (UUID) -> Void

    var body: some View {
        ForEach(targets) { target in
            if target.inside.isEmpty {
                Button(target.folder.name) { move(target.folder.id) }
            } else {
                Menu(target.folder.name) {
                    if target.takesItem {
                        Button(target.folder.name) { move(target.folder.id) }
                        Divider()
                    }
                    MoveTargetItems(targets: target.inside, move: move)
                }
            }
        }
    }
}
