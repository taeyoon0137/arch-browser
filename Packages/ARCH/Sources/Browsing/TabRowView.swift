// A tab's row in the sidebar and its parts: the icon, the name field that renames a tab or folder in place, the buttons under the pointer (close or, for a pinned tab, unload, for a live folder item's tab, dismiss, and back to a pinned tab's saved page) and the badges shown in their place, the Command key state that shows the shortcut numbers, and the new tab row.
import AppKit
import LiveFolders
import SwiftUI

struct TabRowView: View {
    /// Observed, not only used by the actions: the split view fill, the shortcut number, and the folder items come from the session's lists, which the window model does not republish.
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @ObservedObject var tab: Tab
    @ObservedObject private var commandKey = CommandKeyState.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isDraggingTab) private var isDraggingTab
    @State private var isHovering = false

    private var isSelected: Bool { tab.id == windowModel.selectedTabID }
    /// Rows ignore the pointer while a tab is dragged over them.
    private var showsHover: Bool { isHovering && !isDraggingTab }

    private var fill: Color {
        if isSelected { return SidebarFill.selected.color(in: colorScheme) }
        // The other panes of the split view on screen show a lighter selection.
        if windowModel.isInSplitViewOnScreen(tab) { return SidebarFill.selected.color(in: colorScheme).opacity(0.5) }
        return showsHover ? SidebarFill.hover.color(in: colorScheme) : .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(tab: tab)
                .frame(width: 18, height: 18)
            if windowModel.renamingTabID == tab.id {
                SidebarNameField(placeholder: "Tab Name", name: tab.displayTitle,
                                 onRename: { windowModel.renameTab(tab.id, to: $0) }, onEnd: { windowModel.endRenaming(tab.id) })
            } else {
                // A tab without its page, as a restored or unloaded one, shows its title in secondary text, so the sidebar shows which tabs have pages.
                Text(tab.displayTitle)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .foregroundStyle(tab.isLoaded ? HierarchicalShapeStyle.primary : .secondary)
            }
            if tab.isAudible {
                TabAudioBadge()
            }
            Spacer(minLength: 0)
            // Show the close button under the pointer, after a back button while a pinned tab is off its saved site (bookmark rule 3); a pinned tab's close button unloads it and shows only while it has its page (bookmark rule 4). Otherwise, holding Command shows the row's ⌘-number shortcut in its place, and an unread tab shows a dot there.
            if showsHover {
                HStack(spacing: 2) {
                    if tab.isOffSavedSite, let saved = tab.savedPage {
                        TabRowButton(symbol: "arrow.uturn.backward", label: "Go Back to Saved Page", help: "Go Back to \(saved.url.absoluteString)") { session.goBackToSavedPage(tab) }
                    }
                    if tab.liveItemID != nil {
                        // Closing an item's tab dismisses the item (live folder rule 4).
                        TabRowButton(symbol: "xmark", label: "Dismiss", help: "Dismiss") { session.requestCloseTab(tab) }
                    } else if !tab.isPinned {
                        TabRowButton(symbol: "xmark", label: "Close Tab", help: "Close Tab") { session.requestCloseTab(tab) }
                    } else if tab.isLoaded {
                        TabRowButton(symbol: "minus", label: "Unload Tab", help: "Unload") { session.requestCloseTab(tab) }
                    }
                }
            } else if commandKey.showsShortcuts, let number = windowModel.shortcutNumber(for: tab) {
                TabShortcutBadge(number: number)
                    .transition(.modifier(active: BlurFade(isHidden: true), identity: BlurFade(isHidden: false)))
            } else if tab.isUnread {
                TabUnreadDot()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
        // Only the light appearance lifts the selected row; in the dark one its lighter fill is enough.
        .shadow(color: .black.opacity(isSelected && colorScheme == .light ? 0.08 : 0), radius: 1.5, y: 0.5)
        .contentShape(Rectangle())
        // The row truncates long titles, so the tooltip has the whole title and the address, and for a GitHub item what its row cannot show.
        .help(([tab.displayTitle] + (tab.liveItem?.gitHub.map(Self.details) ?? []) + [tab.url?.absoluteString].compactMap { $0 }).joined(separator: "\n"))
        .onTapGesture { windowModel.selectTab(tab.id) }
        // The first click selects the tab at once; the second starts renaming it.
        .simultaneousGesture(TapGesture(count: 2).onEnded { windowModel.renamingTabID = tab.id })
        .onHover { isHovering = $0 }
        .contextMenu {
            if tab.liveItemID != nil {
                LiveItemTabItems(session: session, windowModel: windowModel, tab: tab)
            } else {
                menuItems
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // A tap gesture alone does not answer the accessibility press, so VoiceOver could not select the tab.
        .accessibilityAction { windowModel.selectTab(tab.id) }
    }

    /// A GitHub item's detail line ("owner/repo #123 · author"), its review decision, the state of its checks, and a conflict, for its row's tooltip.
    static func details(of item: GitHubItem) -> [String] {
        var lines = [item.detail]
        switch item.reviewDecision {
        case .approved?: lines.append("Approved")
        case .changesRequested?: lines.append("Changes requested")
        case .reviewRequired?: lines.append("Review required")
        case nil: break
        }
        switch item.checks {
        case .success?: lines.append("Checks passed")
        case .failure?, .error?: lines.append("Checks failed")
        case .pending?, .expected?: lines.append("Checks running")
        case nil: break
        }
        if item.mergeable == .conflicting { lines.append("Has conflicts") }
        return lines
    }

    /// The menu of a tab that is no live folder item's.
    @ViewBuilder private var menuItems: some View {
        Button("Rename Tab") {
            windowModel.selectTab(tab.id)
            windowModel.renamingTabID = tab.id
        }
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { session.togglePinned(tab) }
        Button("Add to Favorites") { session.addFavorite(tab) }.disabled(tab.url == nil)
        Button("Open in Split View") { windowModel.openInSplitView(tab) }.disabled(!windowModel.canOpenInSplitView(tab))
        Divider()
        // A pinned tab's saved page (bookmark rules 2 and 3). Go Back shows only while the tab is off it.
        if tab.isPinned {
            if session.isOffSavedPage(tab) {
                Button("Go Back to Saved Page") { session.goBackToSavedPage(tab) }
            }
            Button("Use Current Page as Saved Page") { session.useCurrentPageAsSavedPage(tab) }.disabled(!session.canUseCurrentPageAsSavedPage(tab))
            Button("Edit Saved Address\u{2026}") { windowModel.promptToEditSavedAddress(of: tab) }
        }
        Button("Copy Address") { tab.url.map(BrowserSession.copyAddress) }.disabled(tab.url == nil)
        Button("Duplicate") { withAnimation(.easeInOut(duration: 0.15)) { windowModel.duplicate(tab) } }
        Divider()
        TabFolderItems(session: session, windowModel: windowModel, tab: tab)
        Divider()
        // Closing a pinned tab unloads it; Delete Tab takes it out of the sidebar into the closed list (bookmark rule 4).
        Button("Close Tab") { session.requestCloseTab(tab) }
        if tab.isPinned {
            Button("Delete Tab") { session.requestDeleteTab(tab) }
        }
        PluginMenuSections(plugins: session.plugins(in: tab.personaID), location: .tabContextMenu) { windowModel.runPluginCommand($0, onTab: tab) }
    }
}

/// A live folder item's tab's menu (`docs/bookmarks.md`, Live folders ▸ Interface): Mark as Read or Mark as Unread, Dismiss, Rename Tab, Copy Address, Go Back to Saved Page while off it, Open in Split View, Add to Favorites, and Move to Folder, which takes the tab out of its folder. The source owns the saved page, so the saved page items that change it are left out, and the tab never joins the closed list, so it has no Delete Tab.
private struct LiveItemTabItems: View {
    @ObservedObject var session: BrowserSession
    let windowModel: BrowserWindowModel
    @ObservedObject var tab: Tab

    var body: some View {
        Button(tab.isUnread ? "Mark as Read" : "Mark as Unread") { session.setRead(tab.isUnread, ofItemTab: tab) }
        Button("Dismiss") { session.requestCloseTab(tab) }
        Divider()
        Button("Rename Tab") {
            windowModel.selectTab(tab.id)
            windowModel.renamingTabID = tab.id
        }
        Button("Copy Address") { tab.url.map(BrowserSession.copyAddress) }.disabled(tab.url == nil)
        if session.isOffSavedPage(tab) {
            Button("Go Back to Saved Page") { session.goBackToSavedPage(tab) }
        }
        Divider()
        Button("Open in Split View") { windowModel.openInSplitView(tab) }.disabled(!windowModel.canOpenInSplitView(tab))
        Button("Add to Favorites") { session.addFavorite(tab) }.disabled(tab.url == nil)
        let tree = session.folderTree
        MoveToFolderMenu(lists: [tree.moveTargets(forTab: tab, pinned: true), tree.moveTargets(forTab: tab, pinned: false)]) { folderID in
            withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(tab.id, toFolder: folderID) }
        }
        PluginMenuSections(plugins: session.plugins(in: tab.personaID), location: .tabContextMenu) { windowModel.runPluginCommand($0, onTab: tab) }
    }
}

/// A tab row's Add to New Folder, which makes the folder where the tab is, Move to Folder, listing the pinned list's folders before the open list's, and Move Out of Folder, which moves the tab up one level. The menu asks the folder tree as it builds, and gets the window model as a value rather than from the environment.
private struct TabFolderItems: View {
    @ObservedObject var session: BrowserSession
    let windowModel: BrowserWindowModel
    let tab: Tab

    var body: some View {
        let tree = session.folderTree
        Button("Add to New Folder") { withAnimation(.easeInOut(duration: 0.15)) { windowModel.addToNewFolder(tab) } }
            .disabled(!tree.canAddFolder(inside: tab.folderID))
        MoveToFolderMenu(lists: [tree.moveTargets(forTab: tab, pinned: true), tree.moveTargets(forTab: tab, pinned: false)]) { folderID in
            withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(tab.id, toFolder: folderID) }
        }
        if tab.folderID != nil {
            Button("Move Out of Folder") { withAnimation(.easeInOut(duration: 0.15)) { session.moveOutOfFolder(tab) } }
        }
    }
}

/// Edits a tab's or folder's name in place. Return or leaving the field passes the name to `onRename`, which decides what an empty name means, and Escape cancels. An unedited name changes nothing.
struct SidebarNameField: View {
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let placeholder: String
    /// The current name, which the field starts with.
    let name: String
    let onRename: (String) -> Void
    /// Ends editing without a new name.
    let onEnd: () -> Void
    @State private var draftName = ""
    /// `name` when the field opened. A tab's page can change its title meanwhile.
    @State private var initialName = ""
    /// Set once the field has passed on its name or was cancelled. Return ends renaming, which takes the focus away and then removes the field, and neither passes the name again.
    @State private var isFinished = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isFocused)
            .onSubmit(commit)
            .onExitCommand {
                isFinished = true
                onEnd()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            // Selecting another tab or space leaves the field focused, so the name is saved here.
            .onChange(of: windowModel.selectedTabID) { commit() }
            .onAppear {
                initialName = name
                draftName = initialName
                DispatchQueue.main.async { isFocused = true }
            }
            // Hiding the sidebar or opening the library removes the field without moving focus.
            .onDisappear(perform: commit)
    }

    /// Keeps the typed name even when renaming has moved on to another tab or folder.
    private func commit() {
        guard !isFinished else { return }
        isFinished = true
        if draftName == initialName { return onEnd() }
        onRename(draftName)
    }
}

/// The number of a tab's ⌘-number shortcut, shown in the close button's place.
struct TabShortcutBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Color.primary.opacity(0.08)))
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

/// A speaker after a tab's title while its page plays sound.
struct TabAudioBadge: View {
    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Playing Audio")
    }
}

/// A dot in the close button's place on a tab that a page opened and the user has not selected yet.
struct TabUnreadDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .frame(width: 22, height: 22)
            .accessibilityLabel("Unread")
    }
}

/// Fades and blurs a view in and out.
struct BlurFade: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: isHidden ? 4 : 0)
            .opacity(isHidden ? 0 : 1)
    }
}

/// Tracks whether Command alone is held while the app is active. Shortcut numbers appear after a brief hold, so quick ⌘-shortcuts do not flash them, and disappear on release.
final class CommandKeyState: ObservableObject {
    static let shared = CommandKeyState()
    @Published private(set) var showsShortcuts = false
    private var pendingShow: DispatchWorkItem?

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setDown(Self.isCommandAlone(event.modifierFlags))
            return event
        }
        // The app receives no key events while inactive, so it cannot detect a release in another app.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setDown(false)
        }
        // Monitors receive no modifier changes while a menu tracks. Read the keys again when it closes.
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setDown(Self.isCommandAlone(NSEvent.modifierFlags))
        }
    }

    /// Caps Lock and the like do not count.
    private static func isCommandAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .shift, .option, .control, .function]) == .command
    }

    private func setDown(_ isDown: Bool) {
        pendingShow?.cancel()
        pendingShow = nil
        guard isDown else {
            if showsShortcuts { withAnimation(.easeOut(duration: 0.12)) { showsShortcuts = false } }
            return
        }
        let show = DispatchWorkItem { [weak self] in
            guard Self.isCommandAlone(NSEvent.modifierFlags) else { return }
            withAnimation(.easeOut(duration: 0.18)) { self?.showsShortcuts = true }
        }
        pendingShow = show
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: show)
    }
}

/// A round button at the end of a tab row under the pointer, such as Close Tab or the way back to a pinned tab's saved page.
struct TabRowButton: View {
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// A tab's icon: a spinner while it loads, its page's icon, or a globe without one. A live folder item's tab without its page shows its GitHub item's state, or its feed folder's icon, or the feed symbol until that loads, since it requests no icon from the item's site.
struct TabIconView: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else if !tab.isLoaded, let item = tab.liveItem?.gitHub {
            let state = Self.symbol(for: item)
            Image(systemName: state.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state.color)
                .accessibilityLabel(state.label)
        } else if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else if !tab.isLoaded, tab.liveItem != nil {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    /// The symbol, color, and spoken name of a GitHub item's state (`docs/bookmarks.md`, Items as tabs).
    static func symbol(for item: GitHubItem) -> (name: String, color: Color, label: String) {
        switch (item.kind, item.state) {
        case (.pullRequest, .open): return ("arrow.triangle.pull", .green, "Open Pull Request")
        case (.pullRequest, .draft): return ("arrow.triangle.pull", .gray, "Draft Pull Request")
        case (.pullRequest, .merged): return ("arrow.triangle.merge", .purple, "Merged Pull Request")
        case (.pullRequest, .closed): return ("xmark.circle", .red, "Closed Pull Request")
        case (.issue, .closed), (.issue, .merged): return ("checkmark.circle", .purple, "Closed Issue")
        case (.issue, .open), (.issue, .draft): return ("circle.circle", .green, "Open Issue")
        }
    }
}

struct NewTabButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text("New Tab")
                    .font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovering ? SidebarFill.hover.color(in: colorScheme) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
    }
}
