// What plugins add to the interface, and the index of the contributions of a Persona's enabled plugins. Each contribution keeps the plugin that adds it, so the interface can name the plugin wherever the contribution appears.
import Foundation

public struct PluginContributions: Hashable, Sendable {
    public var commands: [PluginCommand]

    public init(commands: [PluginCommand] = []) {
        self.commands = commands
    }
}

/// A command the command palette lists when the typed text matches its title or keywords.
public struct PluginCommand: Identifiable, Hashable, Sendable {
    /// Belongs to the plugin, so two plugins can use the same identifier.
    public var id: String
    public var title: String
    /// An SF Symbols name for the command's row.
    public var symbol: String?
    /// Words the palette matches besides the title.
    public var keywords: [String]

    public init(id: String, title: String, symbol: String? = nil, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.keywords = keywords
    }
}

/// Names one plugin's command for `PluginManager.run(_:_:)`.
public struct PluginCommandRef: Hashable, Sendable {
    public let plugin: PluginID
    public let command: String
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

/// The contributions of enabled plugins, in the order the manager registered the plugins.
public struct PluginContributionIndex: Sendable {
    private let commands: [Attributed<PluginCommand>]

    init(_ plugins: [InstalledPlugin]) {
        commands = plugins.filter(\.isEnabled).flatMap { plugin in
            plugin.manifest.contributions.commands.map { Attributed(plugin: plugin.id, pluginName: plugin.manifest.name, item: $0) }
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

    private static func words(in text: String) -> [Substring] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
    }
}
