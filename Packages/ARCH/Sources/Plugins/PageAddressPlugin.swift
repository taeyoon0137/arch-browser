// A built-in plugin that copies a tab's address, from the command palette, the Plugins menu and its shortcut, the page's context menu, and a tab row's context menu, as the address or as a Markdown link. It is the smallest complete plugin: a manifest that declares what it adds and the permissions it needs, and code that acts only through its context.
import Foundation

@MainActor
/// Copies the selected tab's address or Markdown link through the plugin context.
public final class PageAddressPlugin: BuiltInPlugin {
    public static let manifest = PluginManifest(
        id: PluginID(rawValue: "xyz.taeyoon.arch.page-address")!,
        name: localized("Page Address"),
        version: "1.0",
        summary: localized("Copies the address of a tab."),
        // `tabs` reveals the tab's title and address to the plugin; `clipboard` lets it copy them.
        permissions: [.tabs, .clipboard],
        contributions: PluginContributions(
            commands: [
                // The shortcut is valid, so it parses.
                PluginCommand(id: "copy", title: localized("Copy Page Address"), symbol: "link", keywords: ["url", "link"], shortcut: try! PluginShortcut("shift+cmd+c")),
            ],
            menuItems: [
                PluginMenuItem(command: "copy", location: .pluginsMenu),
                PluginMenuItem(command: "copy", location: .pageContextMenu([.page])),
                PluginMenuItem(command: "copy", location: .tabContextMenu, title: localized("Copy Address")),
            ],
            settings: [
                PluginSetting(key: markdownKey, title: localized("Copy as a Markdown link"), help: localized("Copies the page\u{2019}s title with its address, such as [Arch](https://example.com/)."), kind: .toggle(default: false)),
            ]
        )
    )
    public static let isOnByDefault = true

    private static let markdownKey = "markdown"

    private var context: (any PluginContext)?

    public init() {}

    public func activate(in context: any PluginContext) async throws {
        self.context = context
    }

    /// Throws `noPage` and copies nothing when the invocation has no page, so the manager beeps and the clipboard keeps its contents.
    public func run(_ command: String, _ invocation: PluginInvocation) async throws {
        guard let context, let tab = invocation.tab, let url = tab.url else { throw PluginError.noPage }
        let asMarkdown = context.setting(Self.markdownKey) == .bool(true)
        try context.copyToClipboard(asMarkdown ? Self.markdownLink(title: tab.title, url: url) : url.absoluteString)
    }

    /// `[title](address)`, with the characters that would end either part escaped. A page without a title shows its address as the link's text.
    static func markdownLink(title: String?, url: URL) -> String {
        let address = url.absoluteString
        let text = (title.flatMap { $0.isEmpty ? nil : $0 } ?? address).replacingOccurrences(of: "\n", with: " ")
        return "[\(escape(text, ["\\", "[", "]"]))](\(escape(address, ["\\", "(", ")"])))"
    }

    /// Puts a backslash before each of `characters`, the backslash first so that the added ones stay single.
    private static func escape(_ text: String, _ characters: [String]) -> String {
        characters.reduce(text) { $0.replacingOccurrences(of: $1, with: "\\" + $1) }
    }
}
