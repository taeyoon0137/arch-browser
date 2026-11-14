// Settings ▸ Shortcuts: the global shortcut and every menu bar command, plugin commands among them, each with a button that records a new shortcut and one that restores the default.
import AppKit
import SwiftUI

/// Clicking a shortcut records the next key pressed with its modifiers: Escape cancels and Delete removes the shortcut. A shortcut that another command uses, recorded or restored as a default, moves only after the user confirms.
struct ShortcutsSection: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @State private var recording: ShortcutCommand?
    /// The modifiers held while recording, shown in place of the shortcut.
    @State private var heldModifiers: NSEvent.ModifierFlags = []
    @State private var recordingWindow: NSWindow?
    @State private var keyMonitor: Any?
    @State private var conflict: Conflict?

    var body: some View {
        Form {
            Section {
                row(ShortcutSettings.globalCommand)
                if let error = shortcuts.globalShortcutError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            } footer: {
                // A grouped form's footer is trailing-aligned and primary by default.
                Text("Brings Arch forward and opens the new tab palette while another app is in front. To change a shortcut, click it and press the new keys; Escape cancels and Delete removes the shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(menuGroups) { group in
                Section(group.title) {
                    ForEach(group.commands) { row($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth, height: 520)
        .onDisappear(perform: stopRecording)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = recordingWindow, notification.object as? NSWindow === window { stopRecording() }
        }
        .alert(conflict.map { "\($0.shortcut.displayName) is already used by \($0.owner.title)." } ?? "", isPresented: isShowingConflict, presenting: conflict) { conflict in
            Button("Replace") {
                shortcuts.setShortcut(nil, for: conflict.owner)
                shortcuts.setShortcut(conflict.shortcut, for: conflict.command)
            }
            Button("Cancel", role: .cancel) {}
        } message: { conflict in
            Text("Replacing it leaves \(conflict.owner.title) without a shortcut.")
        }
    }

    /// A command whose shortcut another command has says so below its title.
    private func row(_ command: ShortcutCommand) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                if shortcuts.isChanged(command) {
                    Button {
                        if let owner = shortcuts.resetShortcut(for: command), let shortcut = command.defaultShortcut {
                            conflict = Conflict(command: command, shortcut: shortcut, owner: owner)
                        }
                    } label: {
                        Label("Restore Default", systemImage: "arrow.uturn.backward")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Restore Default")
                }
                Button { startRecording(command) } label: {
                    Text(label(for: command))
                        .frame(minWidth: 84)
                }
            }
        } label: {
            Text(command.title)
            if let owner = command.shortcutOwner, let shortcut = shortcuts.preferredShortcut(for: command) {
                Text("\(shortcut.displayName) is used by \(owner).")
            }
        }
    }

    private func label(for command: ShortcutCommand) -> String {
        if recording?.id == command.id {
            return heldModifiers.isEmpty ? "Type Shortcut" : KeyShortcut.symbols(for: heldModifiers)
        }
        return shortcuts.shortcut(for: command)?.displayName ?? "None"
    }

    /// The menu commands under their top-level menus, in menu bar order.
    private var menuGroups: [MenuGroup] {
        var groups: [MenuGroup] = []
        for command in shortcuts.commands {
            if groups.last?.title == command.menu {
                groups[groups.count - 1].commands.append(command)
            } else {
                groups.append(MenuGroup(title: command.menu, commands: [command]))
            }
        }
        return groups
    }

    private var isShowingConflict: Binding<Bool> {
        Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })
    }

    // MARK: Recording

    /// Clicking the shortcut being recorded cancels it. The monitor runs before menus see the key, so a shortcut in use is recorded rather than run.
    private func startRecording(_ command: ShortcutCommand) {
        guard recording?.id != command.id else { return stopRecording() }
        recording = command
        heldModifiers = []
        shortcuts.isRecording = true
        guard keyMonitor == nil else { return }
        recordingWindow = NSApp.keyWindow
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.window === recordingWindow else { return event }
            if event.type == .flagsChanged {
                heldModifiers = event.modifierFlags.intersection(KeyShortcut.modifierMask)
                return event
            }
            record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        guard let command = recording else { return stopRecording() }
        let modifiers = event.modifierFlags.intersection(KeyShortcut.modifierMask)
        // Escape, then Delete and Forward Delete.
        if modifiers.isEmpty, event.keyCode == 53 { return stopRecording() }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            stopRecording()
            return shortcuts.setShortcut(nil, for: command)
        }
        guard let shortcut = KeyShortcut(event: event), command.accepts(shortcut) else { return NSSound.beep() }
        stopRecording()
        if let owner = shortcuts.command(using: shortcut, except: command) {
            conflict = Conflict(command: command, shortcut: shortcut, owner: owner)
        } else {
            shortcuts.setShortcut(shortcut, for: command)
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = nil
        recordingWindow = nil
        shortcuts.isRecording = false
    }
}

private struct MenuGroup: Identifiable {
    let title: String
    var commands: [ShortcutCommand]
    var id: String { title }
}

/// A recorded shortcut that `owner` already uses, waiting for the user to confirm the move.
private struct Conflict {
    let command: ShortcutCommand
    let shortcut: KeyShortcut
    let owner: ShortcutCommand
}
