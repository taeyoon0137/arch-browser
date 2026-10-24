// A folder's row in a space's tab list, above the folder's indented tabs. `SpaceTabsView` places the row and reports its frame, so a dragged tab can find it.
import SwiftUI

/// Clicking the row collapses or expands the folder, and Rename Folder in its context menu edits the name in place. The row lights up while a dragged tab is over it, as a space's symbol does.
struct TabFolderRowView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let folder: TabFolder
    @EnvironmentObject private var tabDrag: TabDragState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isDraggingTab) private var isDraggingTab
    @State private var isHovering = false

    private var isRenaming: Bool { windowModel.renamingFolderID == folder.id }
    private var isDropTarget: Bool { tabDrag.targetFolderID == folder.id }

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
