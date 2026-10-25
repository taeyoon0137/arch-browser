// The shortcuts of a menu whose items change while the app runs, as the Plugins menu's do: where Settings lists its commands, which default shortcuts give way to other commands', and that the user's choices reach new items.
import AppKit
import Testing
@testable import Preferences

@MainActor
@Suite struct ChangingMenuShortcutTests {
    private let defaults = TemporaryDefaults()
    private let settings: ShortcutSettings
    private let menuBar = NSMenu()
    private let pluginsMenu = NSMenu(title: "Plugins")
    private let copy = Self.item("Copy", action: "copy:", key: "c", modifiers: .command)

    init() {
        // Without a global shortcut, the tests register no hot key.
        defaults.store.set(["newTabFromAnyApp": [String: Any]()], forKey: ShortcutSettings.defaultsKey)
        settings = ShortcutSettings(defaults: defaults.store)
        menuBar.addItem(Self.menuBarItem("Edit", [copy]))
        menuBar.addItem(Self.menuBarItem("Plugins", menu: pluginsMenu))
        menuBar.addItem(Self.menuBarItem("Window", [Self.item("Minimize", action: "minimize:", key: "m", modifiers: .command)]))
        settings.manage(menuBar)
    }

    /// Two plugins: the first's Copy Plain wants ⌘C, which Edit ▸ Copy has, and its Read wants ⌃⌥R, which the second plugin's Read Aloud wants too.
    private func fillPluginsMenu() -> (copyPlain: NSMenuItem, read: NSMenuItem, readAloud: NSMenuItem) {
        let items = (Self.pluginItem("Copy Plain", "first/copy", key: "c", modifiers: .command),
                     Self.pluginItem("Read", "first/read", key: "r", modifiers: [.control, .option]),
                     Self.pluginItem("Read Aloud", "second/read", key: "r", modifiers: [.control, .option]))
        let entries: [NSMenuItem] = [.sectionHeader(title: "First"), items.0, items.1, .separator(), .sectionHeader(title: "Second"), items.2]
        pluginsMenu.removeAllItems()
        entries.forEach(pluginsMenu.addItem)
        settings.manageChangingMenu(pluginsMenu)
        return items
    }

    private func command(_ title: String) throws -> ShortcutCommand {
        try #require(settings.commands.first { $0.title == title })
    }

    @Test func listsTheMenusCommandsInMenuBarOrderUnderTheirSections() {
        _ = fillPluginsMenu()
        #expect(settings.commands.map(\.menu) == ["Edit", "Plugins", "Plugins", "Plugins", "Window"])
        #expect(settings.commands.map(\.title) == ["Copy", "First ▸ Copy Plain", "First ▸ Read", "Second ▸ Read Aloud", "Minimize"])
    }

    @Test func givesDefaultsWayToAppCommandsAndEarlierItems() throws {
        let items = fillPluginsMenu()
        #expect(try command("First ▸ Copy Plain").defaultOwner == "Copy")
        #expect(try command("First ▸ Read").defaultOwner == nil)
        #expect(try command("Second ▸ Read Aloud").defaultOwner == "First ▸ Read")
        #expect(items.copyPlain.keyEquivalent.isEmpty && items.readAloud.keyEquivalent.isEmpty)
        #expect(items.read.keyEquivalent == "r" && items.read.keyEquivalentModifierMask == [.control, .option])
        #expect(copy.keyEquivalent == "c")
    }

    @Test func givesTheUsersChoicesToNewItems() throws {
        _ = fillPluginsMenu()
        settings.setShortcut(KeyShortcut(key: "x", modifiers: [.control, .option]), for: try command("Second ▸ Read Aloud"))
        let items = fillPluginsMenu()
        #expect(items.readAloud.keyEquivalent == "x" && items.readAloud.keyEquivalentModifierMask == [.control, .option])
        #expect(items.read.keyEquivalent == "r")
    }

    @Test func freesADefaultWhenItsOwnerChanges() throws {
        let items = fillPluginsMenu()
        settings.setShortcut(KeyShortcut(key: "k", modifiers: .command), for: try command("Copy"))
        #expect(try command("First ▸ Copy Plain").defaultOwner == nil)
        #expect(items.copyPlain.keyEquivalent == "c" && items.copyPlain.keyEquivalentModifierMask == .command)
    }

    private static func item(_ title: String, action: String, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// Plugin items share one action and differ in the identifier they carry, as the Plugins menu's do.
    private static func pluginItem(_ title: String, _ identifier: String, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = item(title, action: "runCommand:", key: key, modifiers: modifiers)
        item.representedObject = identifier
        return item
    }

    private static func menuBarItem(_ title: String, _ items: [NSMenuItem] = [], menu: NSMenu? = nil) -> NSMenuItem {
        let menu = menu ?? NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Defaults of their own for one test, removed when the test ends.
private final class TemporaryDefaults {
    private let name = "ArchPreferencesTests-\(UUID().uuidString)"
    let store: UserDefaults

    init() {
        store = UserDefaults(suiteName: name)!
    }

    deinit {
        store.removePersistentDomain(forName: name)
    }
}
