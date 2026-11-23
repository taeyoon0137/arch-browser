// A folder row sits above its indented folders and tabs in a space's list. An agent folder also shows its waiting step below the row.
// Folder and tab rows share the Move to Folder submenu. `SpaceTabsView` places, indents, and drags the folder row.
// It reports only the row's frame so a dragged tab or folder can find the drop target.
import Agent
import LiveFolders
import SwiftUI

/// Clicking the row collapses or expands the folder, Rename Folder in its context menu edits the name in place, and the menu's folder items nest it (bookmark rule 6). The row lights up while a dragged tab or folder is over it and would go into the folder, as a space's symbol does. A live folder's row shows its source's symbol, its unread items' count, a progress indicator in the chevron's place while it refreshes, and a warning symbol after a failed refresh, and its menu has the live folder's commands (`docs/bookmarks.md`, Live folders ▸ Interface). An agent folder's menu shows its session's commands (`SessionFolderMenu`), or Keep Tabs for an outside client's folder.
struct TabFolderRowView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let folder: TabFolder
    /// The live folders' statuses, which change with each refresh apart from the session.
    @ObservedObject private var statuses: LiveFolderStatuses
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isDraggingTab) private var isDraggingTab
    @Environment(\.spaceTheme) private var theme
    @State private var isHovering = false
    @State private var deleting: AgentSession?

    init(session: BrowserSession, folder: TabFolder) {
        _session = ObservedObject(wrappedValue: session)
        self.folder = folder
        _statuses = ObservedObject(wrappedValue: session.liveFolderStatuses)
    }

    private var isRenaming: Bool { windowModel.renamingFolderID == folder.id }
    private var isDropTarget: Bool { sidebarDrag.targetFolderID == folder.id }
    private var status: LiveFolderStatus { statuses[folder.id] }
    private var dropColor: Color { theme.symbolColor(for: windowModel.currentSpace.tint) }

    /// A feed's or GitHub's symbol for a live folder, in place of the folder symbol.
    private var symbol: String {
        switch folder.live?.source {
        case .feed?: return "dot.radiowaves.up.forward"
        case .gitHub?: return "arrow.triangle.pull"
        case nil: return "folder"
        }
    }

    /// Rows ignore the pointer while a tab or folder is dragged over them; the folder under it lights up instead.
    private var fill: Color {
        if isDropTarget { return dropColor.opacity(0.15) }
        return isHovering && !isDraggingTab ? SidebarFill.hover.color(in: colorScheme) : .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDropTarget ? dropColor : .secondary)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            if isRenaming {
                SidebarNameField(placeholder: "Folder Name", name: folder.name,
                                 onRename: { windowModel.renameFolder(folder.id, to: $0) }, onEnd: { windowModel.endRenamingFolder(folder.id) })
            } else {
                if let owner = windowModel.agentSession(of: folder) {
                    SessionFolderState(owner: owner)
                }
                Text(folder.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if folder.live != nil, status.unreadCount > 0 {
                    Text("\(status.unreadCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: 0)
            // A status mark, drawn as a tab row's sound and prompt marks are.
            if folder.live != nil, let error = status.error {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(Self.failureHelp(error, nextAttempt: status.nextAttempt))
                    .accessibilityLabel(localized("Refresh Failed"))
            }
            // In the close button's place on a tab row.
            if folder.live != nil, status.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 22, height: 22)
                    .accessibilityLabel(localized("Refreshing"))
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folder.isCollapsed ? 0 : 90))
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
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
                if folder.live != nil {
                    Button(localized("Refresh Now")) { session.refreshLiveFolder(folder.id) }
                    Button(localized("Mark All as Read")) { session.markAllAsRead(inLiveFolder: folder.id) }
                        .disabled(status.unreadCount == 0)
                    if status.dismissedCount > 0 {
                        Button(localized("Show Dismissed Items (\(status.dismissedCount))")) { withAnimation(.easeInOut(duration: 0.15)) { session.showDismissedItems(inLiveFolder: folder.id) } }
                    }
                    Button(localized("Edit Live Folder\u{2026}")) { windowModel.showEditLiveFolderSheet(folder.id) }
                    Divider()
                }
                // An agent folder's tabs are the agent's until the user keeps them, which makes the folder an ordinary one.
                if folder.isAgentFolder { Button(localized("Keep Tabs")) { session.keepTabs(ofFolder: folder.id) } }
                Button(localized("Rename Folder")) { windowModel.renamingFolderID = folder.id }
                FolderNestingItems(session: session, windowModel: windowModel, folder: folder)
                Divider()
                if folder.live != nil {
                    Button(localized("Convert to Folder")) { session.convertToFolder(folder.id) }
                }
                Button(localized("Delete Folder")) { withAnimation(.easeInOut(duration: 0.15)) { session.deleteFolder(folder.id) } }
            }
        }
        .confirmAgentSessionDeletion($deleting) { owner in
            Task { await windowModel.perform(.deleteSession, on: folder, reviewed: owner) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(accessibilityValue)
        // A tap gesture alone does not answer the accessibility press.
        .accessibilityAction { toggleCollapsed() }
    }

    private var accessibilityValue: String {
        let state = folder.isCollapsed ? "Collapsed" : "Expanded"
        guard folder.live != nil, status.unreadCount > 0 else { return state }
        return "\(state), \(status.unreadCount) unread"
    }

    /// The warning symbol's tooltip: the failure and when the timer tries again.
    static func failureHelp(_ error: String, nextAttempt: Date?) -> String {
        guard let nextAttempt else { return error }
        let date = Calendar.current.isDateInToday(nextAttempt) ? Date.FormatStyle.DateStyle.omitted : .abbreviated
        return "\(error)\nNext attempt: \(nextAttempt.formatted(date: date, time: .shortened))"
    }

    /// A click in the name field while renaming edits the name instead, and the release that ends a drag of the row leaves the folder as it was.
    private func toggleCollapsed() {
        guard !isRenaming, sidebarDrag.item == nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) { session.toggleCollapsed(ofFolder: folder.id) }
    }
}

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
                Button(step.count > 1 ? "Review \(step.count)" : "Review", action: review)
                    .buttonStyle(.link)
                    .accessibilityLabel(step.count > 1 ? "Review \(step.count) requests" : "Review the request")
            }
            .font(.system(size: 11))
            // Under the folder's name, past its symbol.
            .padding(.leading, 36)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
        }
    }
}

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

/// A folder's New Folder Inside, Move to Folder, and Move Out of Folder. The menu asks the folder tree as it builds, and gets the window model as a value rather than from the environment.
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
