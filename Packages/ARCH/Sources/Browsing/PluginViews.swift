// What the plugins of a window's Persona add to the sidebar: rows below the favorites that run a command or open the plugin's panel in a popover, and their items in the menus that SwiftUI builds, the tab rows' context menus and the space menu.
import AppKit
import Plugins
import SwiftUI

/// The sidebar items of the manager's enabled plugins, in the order the plugins registered. Without items it shows nothing and takes no space.
struct PluginSidebarItemsView: View {
    @ObservedObject var plugins: PluginManager

    var body: some View {
        let items = plugins.contributions.sidebarItems
        if !items.isEmpty {
            VStack(spacing: 2) {
                ForEach(items, id: \.id) { PluginSidebarItemRow(plugins: plugins, item: $0) }
            }
        }
    }
}

/// A sidebar item's symbol, title, and badge. Its tooltip names the plugin that adds it.
private struct PluginSidebarItemRow: View {
    @ObservedObject var plugins: PluginManager
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let item: Attributed<PluginSidebarItem>
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var anchor = PluginPanelAnchor()

    var body: some View {
        let badge = plugins.badge(on: item)
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: item.item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(item.item.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovering ? SidebarFill.hover.color(in: colorScheme) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(PluginPanelAnchorView(anchor: anchor))
        .onHover { isHovering = $0 }
        // On a second line, as a tab row's address: parentheses in the sidebar's tooltips hold a shortcut.
        .help("\(item.item.title)\n\(item.pluginName)")
        .accessibilityLabel(item.item.title)
        .accessibilityValue(badge ?? "")
    }

    /// A command runs on the window's selected tab. A panel opens beside the row once the plugin hands it over and closes with a click outside it, Escape, a click on the row, or its own end.
    private func open() {
        switch item.item.action {
        case let .command(id):
            windowModel.runPluginCommand(PluginCommandRef(plugin: item.plugin, command: id))
        case .panel:
            anchor.showPanel { await plugins.panel(for: item) }
        }
    }
}

/// The row's view, which its panel's popover points at, and the popover from when it shows until it has closed.
@MainActor
private final class PluginPanelAnchor: NSObject, NSPopoverDelegate {
    weak var view: NSView?
    private var popover: NSPopover?
    /// Whether the row waits for its plugin to hand over the panel.
    private var isRequestingPanel = false
    /// When the popover last began to close, in the time base of event timestamps.
    private var closedAt: TimeInterval = 0

    /// Shows the panel that `request` returns in a popover beside the row, which closes when the panel ends. A click while the row waits for the panel, while the popover shows or closes, or that closed the popover shows nothing more.
    func showPanel(_ request: @escaping @MainActor () async -> NSViewController?) {
        guard !isRequestingPanel, popover == nil, !isClosingClick else { return }
        isRequestingPanel = true
        Task {
            let panel = await request()
            isRequestingPanel = false
            guard let panel, let view, view.window != nil else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = panel
            popover.delegate = self
            // A panel that ends while it shows, as a script plugin's does once its instance stops, can do nothing more.
            (panel as? any PluginEndingPanel)?.onEnd = { [weak popover] in popover?.performClose(nil) }
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
            self.popover = popover
        }
    }

    /// Whether the click the row handles is the one that closed the popover. The popover begins to close as a click outside it goes down, and the row acts on the click as it comes up, which can be after the popover has closed.
    private var isClosingClick: Bool {
        guard let event = NSApp.currentEvent else { return false }
        return event.timestamp - closedAt < NSEvent.doubleClickInterval
    }

    func popoverWillClose(_ notification: Notification) {
        closedAt = ProcessInfo.processInfo.systemUptime
    }

    /// Releases the popover and with it the panel, which the plugin makes anew for the next opening.
    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}

private struct PluginPanelAnchorView: NSViewRepresentable {
    let anchor: PluginPanelAnchor

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        anchor.view = view
    }

    final class AnchorView: NSView {
        // Clicks go to the row above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The plugins' items at a location in a SwiftUI menu, one section per plugin under the plugin's name, after the menu's own items.
struct PluginMenuSections: View {
    @ObservedObject var plugins: PluginManager
    let location: PluginMenuLocation
    let run: @MainActor (PluginCommandRef) -> Void

    var body: some View {
        ForEach(plugins.contributions.menuSections(at: location), id: \.self) { section in
            Section(section.pluginName) {
                ForEach(section.items, id: \.self) { entry in
                    Button(entry.title) { run(entry.command) }
                }
            }
        }
    }
}
