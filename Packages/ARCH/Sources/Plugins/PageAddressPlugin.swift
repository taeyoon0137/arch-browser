// A built-in plugin that copies the selected tab's address from the command palette. It is the smallest complete plugin: a manifest that declares one command and the permissions the command needs, and code that acts only through its context.
import Foundation

@MainActor
public final class PageAddressPlugin: BuiltInPlugin {
    public static let manifest = PluginManifest(
        id: PluginID(rawValue: "local.arch.browser.page-address")!,
        name: "Page Address",
        version: "1.0",
        summary: "Copies the address of the selected tab.",
        // `tabs` reveals the tab's address to the plugin; `clipboard` lets it copy the address.
        permissions: [.tabs, .clipboard],
        contributions: PluginContributions(commands: [
            PluginCommand(id: "copy", title: "Copy Page Address", symbol: "link", keywords: ["url", "link"]),
        ])
    )
    public static let isOnByDefault = true

    private var context: (any PluginContext)?

    public init() {}

    public func activate(in context: any PluginContext) async throws {
        self.context = context
    }

    /// Copies nothing when the invocation has no page.
    public func run(_ command: String, _ invocation: PluginInvocation) async throws {
        guard let address = invocation.tab?.url?.absoluteString else { return }
        try context?.copyToClipboard(address)
    }
}
