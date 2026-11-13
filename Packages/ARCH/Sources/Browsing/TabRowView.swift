// A tab's row in the sidebar and its parts: the icon, the name field that renames a tab or folder in place, the close button and the badges shown in its place, the Command key state that shows the shortcut numbers, and the new tab row.
import AppKit
import SwiftUI

struct TabRowView: View {
    /// Observed, not only used by the actions: the split view fill, the shortcut number, and the folder menu come from the session's lists, which the window model does not republish.
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
                Text(tab.displayTitle)
                    .font(.system(size: 14))
                    .lineLimit(1)
            }
            if tab.isAudible {
                TabAudioBadge()
            }
            Spacer(minLength: 0)
            // The tab waits for the user's answer to a prompt, shown or not.
            TabPromptIndicator(prompts: session.prompts, tabID: tab.id)
            // Show the close button under the pointer; otherwise, holding Command shows the row's ⌘-number shortcut in its place, and an unread tab shows a dot there.
            if showsHover {
                TabCloseButton { session.requestCloseTab(tab) }
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
        // The row truncates long titles, so the tooltip has the whole title and the address.
        .help([tab.displayTitle, tab.url?.absoluteString].compactMap { $0 }.joined(separator: "\n"))
        .onTapGesture { windowModel.selectTab(tab.id) }
        // The first click selects the tab at once; the second starts renaming it.
        .simultaneousGesture(TapGesture(count: 2).onEnded { windowModel.renamingTabID = tab.id })
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename Tab") {
                windowModel.selectTab(tab.id)
                windowModel.renamingTabID = tab.id
            }
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { session.togglePinned(tab) }
            Button("Add to Favorites") { session.addFavorite(tab) }.disabled(tab.url == nil)
            Button("Open in Split View") { windowModel.openInSplitView(tab) }.disabled(!windowModel.canOpenInSplitView(tab))
            Divider()
            Button("Add to New Folder") { withAnimation(.easeInOut(duration: 0.15)) { windowModel.addToNewFolder(tab) } }
            let otherFolders = tab.spaceID.map { session.folders(in: $0).filter { $0.id != tab.folderID } } ?? []
            if !otherFolders.isEmpty {
                Menu("Move to Folder") {
                    ForEach(otherFolders) { folder in
                        Button(folder.name) { withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(tab.id, toFolder: folder.id) } }
                    }
                }
            }
            if tab.folderID != nil {
                Button("Remove from Folder") { withAnimation(.easeInOut(duration: 0.15)) { session.removeFromFolder(tab) } }
            }
            Divider()
            Button("Close Tab") { session.requestCloseTab(tab) }
            PluginMenuSections(plugins: session.plugins(in: tab.personaID), location: .tabContextMenu) { windowModel.runPluginCommand($0, onTab: tab) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // A tap gesture alone does not answer the accessibility press, so VoiceOver could not select the tab.
        .accessibilityAction { windowModel.selectTab(tab.id) }
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

struct TabCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help("Close Tab")
        .accessibilityLabel("Close Tab")
    }
}

struct TabIconView: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
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
