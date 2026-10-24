// The shortcuts of the menu bar's commands and the global shortcut, with the user's changes saved in `UserDefaults` under `ARCHShortcuts`.
import AppKit

/// A command whose shortcut the user can change: a menu bar item, or the global shortcut.
struct ShortcutCommand: Identifiable {
    /// The action's selector name, with the tag or represented string that tells apart items sharing an action. Saved choices are keyed by it.
    let id: String
    /// The top-level menu's title; empty for the global shortcut.
    let menu: String
    /// The item's title after the titles of its submenus.
    let title: String
    let defaultShortcut: KeyShortcut?
    fileprivate let item: NSMenuItem?
    /// Hidden items that give the action a second key, such as ⌘= for Zoom In. They keep that key only while the command keeps its default.
    fileprivate var aliases: [(item: NSMenuItem, shortcut: KeyShortcut)] = []

    var isGlobal: Bool { item == nil }

    func accepts(_ shortcut: KeyShortcut) -> Bool {
        isGlobal ? shortcut.suitsGlobal : shortcut.suitsMenu
    }
}

/// Applies the user's shortcuts to the menu bar and registers the global shortcut. The app builds the menu bar once at launch, then hands it over with `manage(_:)`, which keeps its key equivalents as the defaults.
@MainActor
public final class ShortcutSettings: ObservableObject {
    public static let shared = ShortcutSettings()
    static let defaultsKey = "ARCHShortcuts"
    /// Brings Arch forward and opens the new tab palette from any app.
    static let globalCommand = ShortcutCommand(id: "newTabFromAnyApp", menu: "", title: "New Tab from Any App", defaultShortcut: KeyShortcut(key: " ", modifiers: .option, keyCode: 49), item: nil)

    /// Runs when the global shortcut is pressed.
    public var onGlobalShortcut: () -> Void = {}
    @Published private(set) var commands: [ShortcutCommand] = []
    /// Why the system refused the global shortcut, or `nil` while it is registered or the user removed it.
    @Published private(set) var globalShortcutError: String?
    /// The choice for each command the user changed; a `nil` choice removes the command's shortcut.
    @Published private var choices: [String: KeyShortcut?]
    /// While Settings records a shortcut, the global shortcut is unregistered so that its key reaches the recorder.
    var isRecording = false {
        didSet { if isRecording != oldValue { registerGlobalShortcut() } }
    }

    private let defaults: UserDefaults
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.onGlobalShortcut() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: Any]] ?? [:]
        choices = saved.mapValues { KeyShortcut(propertyList: $0) }
    }

    /// Lists the menu bar's commands, applies the saved choices to their items, and registers the global shortcut.
    public func manage(_ menuBar: NSMenu) {
        var commands: [ShortcutCommand] = []
        for menuItem in menuBar.items {
            guard let menu = menuItem.submenu else { continue }
            collect(menu, menuTitle: menuItem.title, path: [], into: &commands)
        }
        self.commands = commands
        commands.forEach(apply)
        registerGlobalShortcut()
    }

    /// The command's current shortcut, or `nil` when it has none.
    func shortcut(for command: ShortcutCommand) -> KeyShortcut? {
        if let choice = choices[command.id] { return choice }
        return command.defaultShortcut
    }

    func isChanged(_ command: ShortcutCommand) -> Bool {
        choices.keys.contains(command.id)
    }

    /// Gives the command `shortcut`, or no shortcut for `nil`. Choosing the default forgets the change.
    func setShortcut(_ shortcut: KeyShortcut?, for command: ShortcutCommand) {
        if shortcut == command.defaultShortcut {
            choices.removeValue(forKey: command.id)
        } else {
            choices.updateValue(shortcut, forKey: command.id)
        }
        defaults.set(choices.mapValues { $0?.propertyList ?? [:] }, forKey: Self.defaultsKey)
        apply(command)
    }

    func resetShortcut(for command: ShortcutCommand) {
        setShortcut(command.defaultShortcut, for: command)
    }

    /// Another command that uses `shortcut`, if any. A hidden twin's key belongs to its command while the command keeps its default.
    func command(using shortcut: KeyShortcut, except command: ShortcutCommand) -> ShortcutCommand? {
        ([Self.globalCommand] + commands).first { other in
            other.id != command.id && (self.shortcut(for: other) == shortcut || (!isChanged(other) && other.aliases.contains { $0.shortcut == shortcut }))
        }
    }

    // MARK: Menu bar

    /// Adds the items of `menu` and its submenus that run an action. A hidden item becomes an alias of the visible item before it with the same action; another item that repeats an action keeps its built-in key and is not listed.
    private func collect(_ menu: NSMenu, menuTitle: String, path: [String], into commands: inout [ShortcutCommand]) {
        for item in menu.items where !item.isSeparatorItem {
            if let submenu = item.submenu {
                collect(submenu, menuTitle: menuTitle, path: path + [item.title], into: &commands)
                continue
            }
            guard let action = item.action else { continue }
            let id = Self.commandID(of: item, action: action)
            if let index = commands.firstIndex(where: { $0.id == id }) {
                if item.isHidden, let shortcut = KeyShortcut(menuItem: item) { commands[index].aliases.append((item, shortcut)) }
                continue
            }
            guard !item.isHidden else { continue }
            let title = (path + [item.title]).joined(separator: " \u{25B8} ")
            commands.append(ShortcutCommand(id: id, menu: menuTitle, title: title, defaultShortcut: KeyShortcut(menuItem: item), item: item))
        }
    }

    /// The action's name, with the item's tag or represented string when it has one, such as `selectTab:#3` or `chooseAppearance:#dark`.
    private static func commandID(of item: NSMenuItem, action: Selector) -> String {
        var id = NSStringFromSelector(action)
        if item.tag != 0 { id += "#\(item.tag)" }
        if let value = item.representedObject as? String { id += "#\(value)" }
        return id
    }

    private func apply(_ command: ShortcutCommand) {
        guard let item = command.item else { return registerGlobalShortcut() }
        let shortcut = self.shortcut(for: command)
        item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
        let keepsAliases = !isChanged(command)
        for alias in command.aliases {
            alias.item.keyEquivalent = keepsAliases ? alias.shortcut.menuKeyEquivalent : ""
        }
    }

    // MARK: Global shortcut

    private func registerGlobalShortcut() {
        hotKey.unregister()
        guard !isRecording else { return }
        globalShortcutError = nil
        guard let shortcut = self.shortcut(for: Self.globalCommand), let keyCode = shortcut.keyCode else { return }
        let status = hotKey.register(keyCode: keyCode, modifiers: shortcut.modifiers)
        if status == GlobalHotKey.inUseStatus {
            globalShortcutError = "Another app uses this shortcut."
        } else if status != noErr {
            globalShortcutError = "macOS did not accept this shortcut (error \(status))."
        }
    }
}
