// The menu bar's Plugins menu shows commands from enabled plugins in the active window's Persona.
// It groups commands under their plugin names and follows the active window, current space, and plugins.
// It gives each new set of items to shortcut settings, which assign a command's shortcut unless another command uses it.
import AppKit
import Browsing
import Combine
import Plugins
import Preferences

@MainActor
final class PluginsMenu: NSObject, NSMenuItemValidation {
    private let session: BrowserSession
    private let menu = NSMenu(title: localized("Plugins"))
    /// The menu bar's item for the menu, hidden while the menu has no items.
    private let menuBarItem = NSMenuItem(title: localized("Plugins"), action: nil, keyEquivalent: "")
    /// The command of each item, by the identifier the item carries.
    private var commands: [String: PluginCommandRef] = [:]
    private var subscription: AnyCancellable?

    init(session: BrowserSession) {
        self.session = session
        super.init()
        menuBarItem.submenu = menu
        menuBarItem.isHidden = true
    }

    /// Adds the menu to the menu bar before `followingMenu`, the Window menu, once the shortcut settings manage the menu bar, and fills it. While no browser window is open, it shows the default Persona's items.
    func install(in menuBar: NSMenu, before followingMenu: NSMenu) {
        menuBar.insertItem(menuBarItem, at: menuBar.items.firstIndex { $0.submenu === followingMenu } ?? menuBar.numberOfItems)
        let session = session
        // The values arrive before the session and the windows change, so each step reads the value it receives.
        subscription = session.$windows
            .map { windows -> AnyPublisher<Persona.ID, Never> in
                guard let window = windows.first else { return Just(Persona.defaultID).eraseToAnyPublisher() }
                return window.$currentSpaceID
                    .map { id in session.spaces.first { $0.id == id }?.resolvedPersonaID ?? Persona.defaultID }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .map { id in MainActor.assumeIsolated { session.plugins(in: id) }.$contributions }
            .switchToLatest()
            .map { $0.menuSections(at: .pluginsMenu) }
            .removeDuplicates()
            .sink { [weak self] sections in MainActor.assumeIsolated { self?.show(sections) } }
    }

    /// Replaces the menu's items: one section per plugin under its name, each item with its command's shortcut as its default.
    private func show(_ sections: [PluginMenuSection]) {
        menu.removeAllItems()
        commands = [:]
        for section in sections {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: section.pluginName))
            for entry in section.items {
                let item = NSMenuItem(title: entry.title, action: #selector(runCommand(_:)), keyEquivalent: entry.shortcut?.keyEquivalent ?? "")
                item.keyEquivalentModifierMask = entry.shortcut?.modifierFlags ?? []
                item.target = self
                // The shortcut settings key the user's choice for the item by it.
                let identifier = entry.command.plugin.rawValue + "/" + entry.command.command
                item.representedObject = identifier
                commands[identifier] = entry.command
                menu.addItem(item)
            }
        }
        menuBarItem.isHidden = sections.isEmpty
        ShortcutSettings.shared.manageChangingMenu(menu)
    }

    /// A page command: it runs on the active window's selected tab.
    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String, let command = commands[identifier] else { return }
        let event = NSApp.currentEvent
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let isShortcut = event?.type == .keyDown && !sender.keyEquivalent.isEmpty
            && event?.charactersIgnoringModifiers?.lowercased() == sender.keyEquivalent.lowercased()
            && event?.modifierFlags.intersection(shortcutModifiers) == sender.keyEquivalentModifierMask.intersection(shortcutModifiers)
        session.activeWindow?.runPluginCommand(command, source: isShortcut ? .shortcut : .menu)
    }

    /// Plugin commands need a browser window.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        session.activeWindow != nil
    }
}
