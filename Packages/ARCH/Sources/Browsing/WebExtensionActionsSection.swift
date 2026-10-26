// The site settings popover's section for the web extensions of the tab's Persona: a row for each enabled extension with an action, a pair once, with the action's icon, label, and badge for the tab. A click closes the popover and runs the action, which shows the extension's popup from the site settings button or tells the extension of the click. An extension that the engine kept from running on the tab's site, as Chromium keeps one whose sites wait for a click, offers Allow on This Site. On a tab whose engine runs extensions but none of a plugin's versions, the row says where the plugin runs and, while the plugin asks for that engine's version, offers Install <Engine> Version… and Dismiss.
import ARCHEngine
import Extensions
import Plugins
import SwiftUI

struct WebExtensionActionsSection: View {
    let session: BrowserSession
    @ObservedObject var webExtensions: WebExtensionRuntime
    @ObservedObject var tab: Tab
    /// Closes the popover, so that the popup takes its place.
    let close: () -> Void

    var body: some View {
        let items = webExtensions.actions(for: tab.webContents)
        if !items.isEmpty {
            let engines = Set(webExtensions.engines.keys)
            SiteSettingsSection(title: "Extensions", note: engines.contains(tab.engineKind)
                ? "Opens an extension\u{2019}s popup, or lets the extension act on this page."
                : "Extensions run on \(Self.names(engines)) tabs. Switch this tab to \(Self.names(engines, joinedBy: "or")) to use them.") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { row(for: $0, engineRunsExtensions: engines.contains(tab.engineKind)) }
                }
            }
        }
    }

    /// An action that the tab's engine does not run, or that its extension switched off for the tab, shows dimmed.
    private func row(for item: WebExtensionActionItem, engineRunsExtensions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
                    Text(item.action.flatMap { $0.label.isEmpty ? nil : $0.label } ?? item.name)
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
            if item.wantsSiteAccess {
                Button("Allow on This Site") {
                    close()
                    webExtensions.grantSiteAccess(of: item.id, for: tab.webContents)
                }
                .controlSize(.small)
                .padding(.leading, 24)
            }
            if engineRunsExtensions, !item.engines.contains(tab.engineKind), let note = PluginPackage.runsNote(on: item.engines) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note)
                    if item.asksForVersion {
                        let engine = tab.engineKind
                        Text("Its developer may offer a separate version for \(engine.displayName).")
                        HStack {
                            Button("Install \(engine.displayName) Version\u{2026}") {
                                close()
                                session.installEngineVersion?(tab.personaID, item.id, engine)
                            }
                            Button("Dismiss") { session.plugins(in: tab.personaID).dismissVersionNote(of: item.id, for: engine) }
                        }
                        .controlSize(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
            }
        }
    }

    /// The engines' names in the order of `EngineKind`, such as "WebKit" or "WebKit and Chromium".
    private static func names(_ engines: Set<EngineKind>, joinedBy conjunction: String = "and") -> String {
        EngineKind.allCases.filter(engines.contains).map(\.displayName).joined(separator: " \(conjunction) ")
    }
}
