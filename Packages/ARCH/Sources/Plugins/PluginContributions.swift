// What plugins add to the interface and to pages, and the index of the contributions of a Persona's enabled plugins. Each contribution keeps the plugin that adds it, so the interface can name the plugin wherever the contribution appears.
import ARCHEngine
import Foundation

public struct PluginContributions: Hashable, Sendable {
    public var commands: [PluginCommand]
    public var menuItems: [PluginMenuItem]
    public var sidebarItems: [PluginSidebarItem]
    /// The fields of the plugin's form in Settings ▸ Plugins.
    public var settings: [PluginSetting]
    public var pageScripts: [PluginPageScript]

    public init(commands: [PluginCommand] = [], menuItems: [PluginMenuItem] = [], sidebarItems: [PluginSidebarItem] = [],
                settings: [PluginSetting] = [], pageScripts: [PluginPageScript] = []) {
        self.commands = commands
        self.menuItems = menuItems
        self.sidebarItems = sidebarItems
        self.settings = settings
        self.pageScripts = pageScripts
    }
}

/// A script that runs in each document whose address one of its patterns and one of the plugin's granted sites cover, on both engines. It reaches its plugin through `arch`: `arch.send(value)` returns a promise of the reply from `Plugin.receive(_:)`, and `arch.onMessage(listener)` receives the values posted to the page's main frame.
public struct PluginPageScript: Hashable, Sendable {
    public var matches: [MatchPattern]
    /// Addresses the script skips although `matches` covers them.
    public var excludes: [MatchPattern]
    /// JavaScript, run as the body of a function. A source that does not parse as a function body on its own never runs. A script plugin's comes from a file of its package.
    public var source: String
    public var runAt: EnginePageScriptInjectionTime
    /// Whether the script also runs in the frames inside a page.
    public var allFrames: Bool

    public init(matches: [MatchPattern], excludes: [MatchPattern] = [], source: String, runAt: EnginePageScriptInjectionTime = .documentEnd, allFrames: Bool = false) {
        self.matches = matches
        self.excludes = excludes
        self.source = source
        self.runAt = runAt
        self.allFrames = allFrames
    }

    /// Whether the patterns cover `url`: one of `matches` does and none of `excludes`. Keep it in step with the guard of `engineScript(world:sites:)`.
    func covers(_ url: URL) -> Bool {
        matches.contains { $0.matches(url) } && !excludes.contains { $0.matches(url) }
    }
}

/// A command the command palette lists when the typed text matches its title or keywords. Menu items and sidebar items run commands too.
public struct PluginCommand: Identifiable, Hashable, Sendable {
    /// Belongs to the plugin, so two plugins can use the same identifier.
    public var id: String
    public var title: String
    /// An SF Symbols name for the command's row.
    public var symbol: String?
    /// Words the palette matches besides the title.
    public var keywords: [String]
    /// The shortcut of the command's first item in the Plugins menu, which the index adds when the manifest lists none there. The user can change it in Settings ▸ Shortcuts.
    public var shortcut: PluginShortcut?

    public init(id: String, title: String, symbol: String? = nil, keywords: [String] = [], shortcut: PluginShortcut? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.keywords = keywords
        self.shortcut = shortcut
    }
}

/// What the user opened the page context menu on.
public enum PluginPageContext: String, Hashable, Sendable {
    /// The page itself: no link, image, media, selected text, or field.
    case page
    case link, image, selection, editable
}

extension Set where Element == PluginPageContext {
    /// The contexts of a click: its link, image, selected text, and field, or the page where it has none of those and no media.
    public init(_ element: EngineContextMenuElement) {
        self = []
        if element.linkURL != nil { insert(.link) }
        if element.imageURL != nil { insert(.image) }
        if element.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { insert(.selection) }
        if element.isEditable { insert(.editable) }
        if isEmpty, element.mediaURL == nil { insert(.page) }
    }
}

public enum PluginMenuLocation: Hashable, Sendable {
    /// The Plugins menu in the menu bar. Its commands run on the active window's selected tab.
    case pluginsMenu
    /// The page context menu, when the click has one of the contexts. The command runs on the page's tab and receives what the user clicked on.
    case pageContextMenu(Set<PluginPageContext>)
    /// A tab row's context menu in the sidebar. The command runs on that tab.
    case tabContextMenu
    /// A space's menu. The command runs on the window's selected tab and receives the space.
    case spaceMenu
}

/// A menu item that runs one of the plugin's commands.
public struct PluginMenuItem: Hashable, Sendable {
    public var command: String
    public var location: PluginMenuLocation
    /// The command's title when nil.
    public var title: String?

    public init(command: String, location: PluginMenuLocation, title: String? = nil) {
        self.command = command
        self.location = location
        self.title = title
    }
}

/// A row below the favorites with a symbol, a title, and the badge the plugin sets.
public struct PluginSidebarItem: Identifiable, Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        /// Runs one of the plugin's commands on the window's selected tab.
        case command(String)
        /// Shows the plugin's panel for the item, from `Plugin.panel(for:)`, in a popover beside the row.
        case panel
    }

    /// Belongs to the plugin, so two plugins can use the same identifier.
    public var id: String
    public var title: String
    /// An SF Symbols name.
    public var symbol: String
    public var action: Action

    public init(id: String, title: String, symbol: String, action: Action) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.action = action
    }
}

/// A field of the plugin's form in Settings ▸ Plugins. The plugin reads the value through `PluginContext.setting(_:)`, or a secret through `PluginContext.secrets`, under the field's key.
public struct PluginSetting: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case toggle(default: Bool)
        case text(default: String)
        /// A number within `range` when it has one.
        case number(default: Double, range: ClosedRange<Double>?)
        /// One of `options`, which the form shows as they are written.
        case choice(default: String, options: [String])
        /// Kept in the Keychain; the form never shows the value.
        case secret
    }

    /// Belongs to the plugin, so two plugins can use the same key.
    public var key: String
    public var id: String { key }
    public var title: String
    /// A sentence the form shows below the title.
    public var help: String?
    public var kind: Kind

    public init(key: String, title: String, help: String? = nil, kind: Kind) {
        self.key = key
        self.title = title
        self.help = help
        self.kind = kind
    }
}

extension PluginSetting.Kind {
    /// The value before the user changes it; nil for a secret, which has no value in storage.
    var defaultValue: PluginValue? {
        switch self {
        case let .toggle(value): return .bool(value)
        case let .text(value), let .choice(value, _): return .string(value)
        case let .number(value, _): return .number(value)
        case .secret: return nil
        }
    }

    /// Whether `value` suits the field: a Boolean for a toggle, text for a text field, a number within the range for a number, and one of the options for a choice.
    func accepts(_ value: PluginValue) -> Bool {
        switch (self, value) {
        case (.toggle, .bool), (.text, .string): return true
        case let (.number(_, range), .number(number)): return range?.contains(number) ?? true
        case let (.choice(_, options), .string(option)): return options.contains(option)
        default: return false
        }
    }
}

/// Names one plugin's command for `PluginManager.run(_:_:)`.
public struct PluginCommandRef: Hashable, Sendable {
    public let plugin: PluginID
    public let command: String

    public init(plugin: PluginID, command: String) {
        self.plugin = plugin
        self.command = command
    }
}

/// A contribution with the plugin that adds it.
public struct Attributed<Item: Sendable>: Sendable {
    public let plugin: PluginID
    public let pluginName: String
    public let item: Item
}

extension Attributed where Item == PluginCommand {
    public var ref: PluginCommandRef { PluginCommandRef(plugin: plugin, command: item.id) }
}

extension Attributed where Item == PluginSidebarItem {
    /// Unique among the index's sidebar items.
    public var id: String { plugin.rawValue + "/" + item.id }
}

/// A menu item as a menu shows it.
public struct PluginMenuEntry: Hashable, Sendable {
    public let command: PluginCommandRef
    /// The item's title, or its command's.
    public let title: String
    /// The command's shortcut, which the Plugins menu gives the item; nil for a later item of the same command there.
    public let shortcut: PluginShortcut?
}

/// One plugin's items at a menu location, which the menu shows together under the plugin's name.
public struct PluginMenuSection: Hashable, Sendable {
    public let pluginName: String
    public let items: [PluginMenuEntry]
}

/// The contributions of enabled plugins, in the order the manager registered the plugins.
public struct PluginContributionIndex: Sendable {
    private let commands: [Attributed<PluginCommand>]
    private let menuItems: [Attributed<LocatedEntry>]
    public let sidebarItems: [Attributed<PluginSidebarItem>]
    /// The page scripts as the engines run them, for every web contents of the Persona. Each runs in its plugin's world, and only in documents whose address one of its patterns and one of the plugin's granted sites cover. A script whose source is not a function body on its own is left out.
    public let pageScripts: [EnginePageScript]

    /// A menu item with its location.
    private struct LocatedEntry: Sendable {
        let location: PluginMenuLocation
        let entry: PluginMenuEntry
    }

    /// The plugins that are enabled and that their runtimes can run contribute, a pair once: through its version installed first while that one contributes, otherwise through the other, whose runtime runs each command with the version for the invocation's tab. The contributing version also brings the commands of the other version that its own lacks while the other is enabled (`InstalledPlugin.commands(among:)`), as an action that only the other has. Menu items and sidebar items whose commands the plugin does not contribute are left out. A command with a shortcut and no item in the Plugins menu gets one there, after the plugin's own, so that the shortcut has an item to run and Settings ▸ Shortcuts lists it. Of a command's items in the Plugins menu, only the first has the shortcut, since Settings ▸ Shortcuts lists and changes only that one.
    @MainActor
    init(_ plugins: [InstalledPlugin]) {
        var enabled: [InstalledPlugin] = []
        for plugin in plugins where plugin.isEnabled && plugin.unavailability == nil && !enabled.contains(where: { $0.id == plugin.counterpart }) {
            enabled.append(plugin)
        }
        commands = enabled.flatMap { plugin in plugin.commands(among: plugins).map { plugin.attributed($0) } }
        menuItems = enabled.flatMap { plugin in
            let contributions = plugin.manifest.contributions
            let commands = plugin.commands(among: plugins)
            var inPluginsMenu: Set<String> = []
            let listed = contributions.menuItems.compactMap { item -> LocatedEntry? in
                guard let command = commands.first(where: { $0.id == item.command }) else { return nil }
                let repeatsPluginsMenuItem = item.location == .pluginsMenu && !inPluginsMenu.insert(command.id).inserted
                return LocatedEntry(location: item.location, entry: PluginMenuEntry(command: PluginCommandRef(plugin: plugin.id, command: command.id), title: item.title ?? command.title,
                                                                                    shortcut: repeatsPluginsMenuItem ? nil : command.shortcut))
            }
            let forShortcuts = commands.filter { $0.shortcut != nil && !inPluginsMenu.contains($0.id) }.map { command in
                LocatedEntry(location: .pluginsMenu, entry: PluginMenuEntry(command: PluginCommandRef(plugin: plugin.id, command: command.id), title: command.title, shortcut: command.shortcut))
            }
            return (listed + forShortcuts).map { plugin.attributed($0) }
        }
        sidebarItems = enabled.flatMap { plugin in
            let commands = plugin.commands(among: plugins)
            return plugin.manifest.contributions.sidebarItems.filter { item in
                guard case let .command(id) = item.action else { return true }
                return commands.contains { $0.id == id }
            }.map { plugin.attributed($0) }
        }
        pageScripts = enabled.flatMap { plugin in
            plugin.manifest.contributions.pageScripts.compactMap { $0.engineScript(world: plugin.id.pageScriptWorld, sites: plugin.grant.sites) }
        }
    }

    /// The commands for which every word of `text` starts a word of the title or of a keyword, ignoring case and diacritics. Text without words matches none.
    public func paletteCommands(matching text: String) -> [Attributed<PluginCommand>] {
        let query = Self.words(in: text)
        guard !query.isEmpty else { return [] }
        return commands.filter { command in
            let words = Self.words(in: command.item.title) + command.item.keywords.flatMap(Self.words(in:))
            return query.allSatisfy { part in words.contains { $0.hasPrefix(part) } }
        }
    }

    /// The items at a location, one section per plugin. For the page context menu, `location` names the contexts of the click, and an item shows when it lists one of them.
    public func menuSections(at location: PluginMenuLocation) -> [PluginMenuSection] {
        let entries = menuItems.filter { located in
            if case let .pageContextMenu(clicked) = location, case let .pageContextMenu(listed) = located.item.location {
                return !clicked.isDisjoint(with: listed)
            }
            return located.item.location == location
        }
        // The entries of each plugin are next to each other, in registration order.
        var sections: [PluginMenuSection] = []
        for located in entries {
            if let last = sections.last, last.items.first?.command.plugin == located.plugin {
                sections[sections.count - 1] = PluginMenuSection(pluginName: last.pluginName, items: last.items + [located.item.entry])
            } else {
                sections.append(PluginMenuSection(pluginName: located.pluginName, items: [located.item.entry]))
            }
        }
        return sections
    }

    private static func words(in text: String) -> [Substring] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
    }
}

extension InstalledPlugin {
    func attributed<Item: Sendable>(_ item: Item) -> Attributed<Item> {
        Attributed(plugin: id, pluginName: manifest.name, item: item)
    }

    /// The commands that the plugin contributes and runs, with `plugins` the manager's list: its manifest's, then, in a pair, those of its other version whose identifiers its own lacks, while that version is enabled and its runtime can run it, so that a pair whose action only one version has lists it under either. A web extension plugin runs such a command with the version for the invocation's tab, as it runs its own.
    func commands(among plugins: [InstalledPlugin]) -> [PluginCommand] {
        let own = manifest.contributions.commands
        guard let counterpart, let other = plugins.first(where: { $0.id == counterpart && $0.isEnabled && $0.unavailability == nil }) else { return own }
        return own + other.manifest.contributions.commands.filter { command in !own.contains { $0.id == command.id } }
    }
}
