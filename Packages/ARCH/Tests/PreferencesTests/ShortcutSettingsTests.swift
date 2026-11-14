// The shortcuts of a menu whose items change while the app runs, as the Plugins menu's do: where Settings lists its commands, which default shortcuts and choices give way to other commands', and that the user's choices reach new items.
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
    private let minimize = Self.item("Minimize", action: "minimize:", key: "m", modifiers: .command)

    init() {
        // Without a global shortcut, the tests register no hot key.
        defaults.store.set(["newTabFromAnyApp": [String: Any]()], forKey: ShortcutSettings.defaultsKey)
        settings = ShortcutSettings(defaults: defaults.store)
        menuBar.addItem(Self.menuBarItem("Edit", [copy]))
        menuBar.addItem(Self.menuBarItem("Plugins", menu: pluginsMenu))
        menuBar.addItem(Self.menuBarItem("Window", [minimize]))
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
        #expect(try command("First ▸ Copy Plain").shortcutOwner == "Copy")
        #expect(try command("First ▸ Read").shortcutOwner == nil)
        #expect(try command("Second ▸ Read Aloud").shortcutOwner == "First ▸ Read")
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
        #expect(try command("First ▸ Copy Plain").shortcutOwner == nil)
        #expect(items.copyPlain.keyEquivalent == "c" && items.copyPlain.keyEquivalentModifierMask == .command)
    }

    @Test func givesChoicesWayToAppCommandsChosenWhileTheItemWasAway() throws {
        let shortcut = KeyShortcut(key: "m", modifiers: [.command, .option])
        _ = fillPluginsMenu()
        settings.setShortcut(shortcut, for: try command("First ▸ Read"))
        // Another Persona's Plugins menu lacks the item, so Settings asks nothing before Minimize takes the shortcut.
        pluginsMenu.removeAllItems()
        settings.manageChangingMenu(pluginsMenu)
        settings.setShortcut(shortcut, for: try command("Minimize"))
        let items = fillPluginsMenu()
        #expect(try command("First ▸ Read").shortcutOwner == "Minimize" && settings.shortcut(for: try command("First ▸ Read")) == nil)
        #expect(items.read.keyEquivalent.isEmpty)
        #expect(minimize.keyEquivalent == "m" && minimize.keyEquivalentModifierMask == [.command, .option])
        // Read no longer has ⌃⌥R, so Read Aloud takes its default.
        #expect(items.readAloud.keyEquivalent == "r" && items.readAloud.keyEquivalentModifierMask == [.control, .option])
    }

    /// Restoring a default that another command took after Replace asks again rather than giving both commands the shortcut.
    @Test func restoringADefaultThatAnotherCommandUsesAsksFirst() throws {
        let commandC = KeyShortcut(key: "c", modifiers: .command)
        let (copyCommand, minimizeCommand) = (try command("Copy"), try command("Minimize"))
        settings.setShortcut(nil, for: copyCommand)
        settings.setShortcut(commandC, for: minimizeCommand)
        #expect(settings.resetShortcut(for: copyCommand)?.title == "Minimize")
        #expect(settings.shortcut(for: copyCommand) == nil && copy.keyEquivalent.isEmpty)
        #expect(settings.shortcut(for: minimizeCommand) == commandC)
        settings.setShortcut(nil, for: minimizeCommand)
        #expect(settings.resetShortcut(for: copyCommand) == nil)
        #expect(settings.shortcut(for: copyCommand) == commandC && !settings.isChanged(copyCommand))
    }

    @Test func givesTheFirstOfTwoItemsAChoiceTheyShare() throws {
        let shortcut = KeyShortcut(key: "x", modifiers: [.control, .option])
        let items = fillPluginsMenu()
        // As choices made in two Personas, each of whose Plugins menus has one of the items.
        settings.setShortcut(shortcut, for: try command("Second ▸ Read Aloud"))
        settings.setShortcut(shortcut, for: try command("First ▸ Read"))
        #expect(try command("Second ▸ Read Aloud").shortcutOwner == "First ▸ Read")
        #expect(items.read.keyEquivalent == "x" && items.readAloud.keyEquivalent.isEmpty)
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

/// Defaults of their own for one test, named after the checkout and the test and emptied when it starts and when it ends. macOS keeps an empty file for a removed domain, so each test reuses its name on every run in a checkout.
private final class TemporaryDefaults {
    private let name = "test.arch.shortcuts.\(checkoutID).\(Test.current.map { String($0.name.prefix { $0 != "(" }) } ?? UUID().uuidString)"
    let store: UserDefaults

    init() {
        store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
    }

    deinit {
        store.removePersistentDomain(forName: name)
    }
}

/// A part of the defaults names that stays the same on every run in a checkout and differs between checkouts, so that runs in two checkouts at the same time keep apart, while SwiftPM runs one command at a time in a checkout's build folder: a hash of this file's path.
private let checkoutID = String(#filePath.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 36)
