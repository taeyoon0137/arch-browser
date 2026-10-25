// The site settings popover's section for the web extensions of the tab's Persona: a row for each enabled extension with an action, with the action's icon, label, and badge for the tab. A click closes the popover and runs the action, which shows the extension's popup from the site settings button or tells the extension of the click.
import Extensions
import SwiftUI

struct WebExtensionActionsSection: View {
    @ObservedObject var webExtensions: WebExtensionRuntime
    @ObservedObject var tab: Tab
    /// Closes the popover, so that the popup takes its place.
    let close: () -> Void

    var body: some View {
        let items = webExtensions.actions(for: tab.webContents)
        if !items.isEmpty {
            SiteSettingsSection(title: "Extensions", note: tab.engineKind == .webKit
                ? "Opens an extension\u{2019}s popup, or lets the extension act on this page."
                : "Extensions run on WebKit tabs. Switch this tab to WebKit to use them.") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { row(for: $0) }
                }
            }
        }
    }

    /// An action that the tab's engine does not run, or that its extension switched off for the tab, shows dimmed.
    private func row(for item: WebExtensionActionItem) -> some View {
        Button {
            close()
            webExtensions.performAction(of: item.id, for: tab.webContents)
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let icon = item.action?.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                    }
                }
                .frame(width: 16, height: 16)
                Text(item.action?.label ?? item.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge = item.action?.badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.action?.isEnabled != true)
        .help(item.name)
    }
}
