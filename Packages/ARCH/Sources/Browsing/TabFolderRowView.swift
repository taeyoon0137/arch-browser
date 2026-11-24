// A folder row sits above its indented folders and tabs in a space's list. An agent folder also shows its waiting step below the row.
// Folder and tab rows share the Move to Folder submenu. `SpaceTabsView` places, indents, and drags the folder row.
// It reports only the row's frame so a dragged tab or folder can find the drop target.
import Agent
import SwiftUI

/// Clicking the row collapses or expands the folder, Rename Folder in its context menu edits the name in place, and the menu's folder items nest it (bookmark rule 6). The row lights up while a dragged tab or folder is over it and would go into the folder, as a space's symbol does. An agent folder's menu shows its session's commands (`SessionFolderMenu`), or Keep Tabs for an outside client's folder.
struct TabFolderRowView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let folder: TabFolder
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isDraggingTab) private var isDraggingTab
    @Environment(\.spaceTheme) private var theme
    @State private var isHovering = false
    @State private var deleting: AgentSession?

    init(session: BrowserSession, folder: TabFolder) {
        _session = ObservedObject(wrappedValue: session)
        self.folder = folder
    }

    private var isRenaming: Bool { windowModel.renamingFolderID == folder.id }
    private var isDropTarget: Bool { sidebarDrag.targetFolderID == folder.id }
    private var dropColor: Color { theme.symbolColor(for: windowModel.currentSpace.tint) }
    /// The folder's symbol uses its color like a space symbol, falling back to the sidebar's text color when it is too close to the wash.
    private var symbolColor: Color {
        if isDropTarget { return dropColor }
        return folder.tint.map { theme.symbolColor(for: $0) } ?? .secondary
    }

    /// Rows ignore the pointer while a tab or folder is dragged over them; the folder under it lights up instead.
    private var fill: Color {
        if isDropTarget { return dropColor.opacity(0.15) }
        return isHovering && !isDraggingTab ? SidebarFill.hover.color(in: colorScheme) : .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(symbolColor)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            if isRenaming {
                SidebarNameField(placeholder: localized("Folder Name"), name: folder.name,
                                 onRename: { windowModel.renameFolder(folder.id, to: $0) }, onEnd: { windowModel.endRenamingFolder(folder.id) })
            } else {
                if let owner = windowModel.agentSession(of: folder) {
                    SessionFolderState(owner: owner)
                }
                Text(folder.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(folder.isCollapsed ? 0 : 90))
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
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
            if let owner = folder.agentSessionID.flatMap({ session.agents?.session(withID: $0) }) {
                SessionFolderMenu(owner: owner, perform: { action in
                    Task { await windowModel.perform(action, on: folder, reviewed: owner) }
                }, rename: { windowModel.renamingFolderID = folder.id }, delete: { deleting = owner })
                .disabled(windowModel.agentSession(of: folder) == nil)
            } else {
                // An agent folder's tabs are the agent's until the user keeps them, which makes the folder an ordinary one.
                if folder.isAgentFolder { Button(localized("Keep Tabs")) { session.keepTabs(ofFolder: folder.id) } }
                Button(localized("Rename Folder")) { windowModel.renamingFolderID = folder.id }
                if !folder.isAgentFolder { FolderColorPicker(session: session, folder: folder) }
                FolderNestingItems(session: session, windowModel: windowModel, folder: folder)
                Divider()
                Button(localized("Delete Folder")) { withAnimation(.easeInOut(duration: 0.15)) { session.deleteFolder(folder.id) } }
            }
        }
        .confirmAgentSessionDeletion($deleting) { owner in
            Task { await windowModel.perform(.deleteSession, on: folder, reviewed: owner) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(folder.isCollapsed ? localized("Collapsed") : localized("Expanded"))
        // A tap gesture alone does not answer the accessibility press.
        .accessibilityAction { toggleCollapsed() }
    }

    /// A click in the name field while renaming edits the name instead, and the release that ends a drag of the row leaves the folder as it was.
    private func toggleCollapsed() {
        guard !isRenaming, sidebarDrag.item == nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) { session.toggleCollapsed(ofFolder: folder.id) }
    }
}

/// An expanded empty folder's child row, highlighted while it accepts a dragged tab.
struct EmptyFolderRow: View {
    let folderID: UUID
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        let isDropTarget = sidebarDrag.tabID != nil && sidebarDrag.targetFolderID == folderID
        Text(localized("Empty Folder"))
            .font(.system(size: 14))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 36)
            .padding(.trailing, 6)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDropTarget ? theme.symbolColor(for: windowModel.currentSpace.tint).opacity(0.15) : .clear))
    }
}

/// The agent session's status text on its folder's row, which follows the session as it changes.
private struct SessionFolderState: View {
    @ObservedObject var owner: AgentSession

    var body: some View {
        Text(owner.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// The step an agent folder's session waits on, under the folder's row and outside its frame, so that the line is neither a drop target nor a handle for dragging the folder (docs/agents.md, Approval interface): the first waiting card's sentence and Review, which opens the session's panel at its cards, where the user answers with the card's facts, capture, and exact text in view. It shows beside the page and never over it.
struct SessionFolderStepLine: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let folder: TabFolder

    var body: some View {
        if let owner = windowModel.agentSession(of: folder), let approvals = session.agents?.approvals {
            SessionFolderCards(approvals: approvals, ownerID: owner.id) {
                Task { await windowModel.perform(.show, on: folder, reviewed: owner) }
            }
        }
    }

    /// The first waiting card's sentence and how many of the owner's cards wait, or nil when none does.
    static func waitingStep(in approvals: AgentApprovals, of ownerID: UUID) -> (sentence: String, count: Int)? {
        let waiting = approvals.pending.filter { $0.ownerID == ownerID }
        return waiting.first.map { ($0.action, waiting.count) }
    }
}

/// The first waiting approval card's sentence and Review under an agent folder's row; `SessionFolderStepLine` shows it.
private struct SessionFolderCards: View {
    @ObservedObject var approvals: AgentApprovals
    let ownerID: UUID
    let review: () -> Void

    var body: some View {
        if let step = SessionFolderStepLine.waitingStep(in: approvals, of: ownerID) {
            // The sidebar's second lines, as a connected client's access and the library's download actions, are 11 points.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(step.sentence)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button(step.count > 1 ? localized("Review \(step.count)") : localized("Review"), action: review)
                    .buttonStyle(.link)
                    .accessibilityLabel(step.count > 1 ? localized("Review \(step.count) requests") : localized("Review the request"))
            }
            .font(.system(size: 11))
            // Under the folder's name, past its symbol.
            .padding(.leading, 36)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
        }
    }
}

/// The agent session's commands in its folder's context menu: Show Session, Stop, Keep Tabs, Rename Folder, and Delete Session….
private struct SessionFolderMenu: View {
    @ObservedObject var owner: AgentSession
    let perform: (BrowserWindowModel.AgentFolderAction) -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(localized("Show Session")) { perform(.show) }
        Button(localized("Stop")) { perform(.stop) }.disabled(!owner.isTurnRunning)
        Button(localized("Keep Tabs")) { perform(.keepTabs) }
        Button(localized("Rename Folder"), action: rename)
        Divider()
        Button(localized("Delete Session…"), role: .destructive, action: delete)
    }
}

/// A folder's Color submenu: None, then the space menu's tints with Automatic first.
private struct FolderColorPicker: View {
    @ObservedObject var session: BrowserSession
    let folder: TabFolder

    var body: some View {
        Picker(localized("Color"), selection: Binding(get: { folder.tint }, set: { session.setTint($0, ofFolder: folder.id) })) {
            Text(localized("None")).tag(SpaceTint?.none)
            Divider()
            ForEach([SpaceTint.automatic] + SpaceTint.colors, id: \.self) { tint in
                Text(tint.title).tag(SpaceTint?.some(tint))
            }
        }
    }
}

/// A folder's New Folder Inside, Move to Folder, Move Out of Folder, and Move to Space, which an agent folder lacks because it stays where its agent works. The menu asks the folder tree as it builds, and gets the window model as a value rather than from the environment.
private struct FolderNestingItems: View {
    @ObservedObject var session: BrowserSession
    let windowModel: BrowserWindowModel
    let folder: TabFolder

    var body: some View {
        let tree = session.folderTree
        Button(localized("New Folder Inside")) { withAnimation(.easeInOut(duration: 0.15)) { windowModel.addFolder(inside: folder.id) } }
            .disabled(!tree.canAddFolder(inside: folder.id))
        MoveToFolderMenu(lists: [tree.moveTargets(forFolder: folder.id)]) { target in
            withAnimation(.easeInOut(duration: 0.15)) { session.moveFolder(folder.id, into: target) }
        }
        if folder.parentID != nil {
            Button(localized("Move Out of Folder")) { withAnimation(.easeInOut(duration: 0.15)) { session.moveFolderOut(folder.id) } }
        }
        if !folder.isAgentFolder {
            MoveToSpaceMenu(sections: session.spaceMoveSections { session.spaceMoveRefusal(ofFolder: folder.id, toPersona: $0) }, currentSpaceID: folder.spaceID) { target in
                withAnimation(.easeInOut(duration: 0.15)) { session.moveFolder(folder.id, toSpace: target, windowsFollow: false) }
            } moveToNewSpace: { personaID in
                withAnimation(.easeInOut(duration: 0.15)) { session.moveFolderToNewSpace(folder.id, in: personaID) }
            }
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
            Menu(localized("Move to Folder")) {
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
