// The site settings popover's section for the web extensions of the tab's Persona: on a Web Store page, first the store's row, Install This Extension… or, while the Persona has the page's extension installed, its name; then a row for each enabled extension with an action, and for one without while the engine keeps it from the tab's site, a pair once, with the action's icon, label, and badge for the tab. A click closes the popover and runs the action, which shows the extension's popup from the site settings button or tells the extension of the click. An extension that the engine kept from running on the tab's site, as Chromium keeps one whose sites wait for a click, offers Allow on This Site. On a tab whose engine runs extensions but none of a plugin's versions, the row says where the plugin runs and, while the plugin asks for that engine's version, offers Install <Engine> Version… and Dismiss.
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
    /// The window of the popover, whose current space a favorite's tab shows in.
    @EnvironmentObject private var windowModel: BrowserWindowModel

    var body: some View {
        let items = webExtensions.actions(for: tab.webContents)
        let storeRow = WebStorePageRow(pageURL: tab.url, installedName: installedName)
        if !items.isEmpty || storeRow != nil {
            let engines = Set(webExtensions.engines.keys)
            SiteSettingsSection(title: "Extensions", note: items.isEmpty
                ? storeRow?.note ?? ""
                : engines.contains(tab.engineKind)
                ? "Opens an extension\u{2019}s popup, or lets the extension act on this page."
                : "Extensions run on \(Self.names(engines)) tabs. Switch this tab to \(Self.names(engines, joinedBy: "or")) to use them.") {
                let rows = VStack(alignment: .leading, spacing: 2) {
                    if let storeRow { row(for: storeRow) }
                    ForEach(items) { row(for: $0, engineRunsExtensions: engines.contains(tab.engineKind)) }
                }
                // As tall as the rows up to 260 points, about ten actions; more scroll, so that the popover stays on the screen. The scroll view's inset keeps the hover fill, which reaches past the section's edges, from being clipped.
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows.padding(.horizontal, ExtensionActionRow.fillOverhang) }
                        .padding(.horizontal, -ExtensionActionRow.fillOverhang)
                }
                .frame(maxHeight: 260)
            }
        }
    }

    /// The space a review that starts from the tab names with its Persona: the tab's, or for a favorite's tab the window's current space (Persona rule 7).
    private var tabSpace: Space.ID? {
        BrowserWindowModel.sheetSpace(ofTabIn: tab.spaceID, personaID: tab.personaID, spaces: session.spaces, currentSpace: windowModel.currentSpace)?.id
    }

    /// The name of the tab's Persona's plugin of the extension, a pair's name for a version of one.
    private func installedName(of id: String) -> String? {
        let plugins = session.plugins(in: tab.personaID)
        guard let installed = WebStoreInstaller.installedPlugin(of: id, among: plugins.plugins) else { return nil }
        return plugins.leadVersion(of: installed.id)?.manifest.name ?? installed.manifest.name
    }

    /// Install This Extension… closes the popover and opens the store sheet in Settings ▸ Plugins for the tab's Persona and space; an installed extension's row only names it.
    @ViewBuilder private func row(for storeRow: WebStorePageRow) -> some View {
        switch storeRow {
        case let .install(id):
            Button(storeRow.title) {
                close()
                session.installFromWebStore?(tab.personaID, tabSpace, id)
            }
            .disabled(session.installFromWebStore == nil)
            .padding(.bottom, 4)
        case .installed:
            Text(storeRow.title)
                .foregroundStyle(.secondary)
                .frame(minHeight: 24)
        }
    }

    /// The action's row, and below it, where they apply, Allow on This Site and the note on the engines the plugin runs on.
    private func row(for item: WebExtensionActionItem, engineRunsExtensions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ExtensionActionRow(item: item) {
                close()
                webExtensions.performAction(of: item.id, for: tab.webContents)
            }
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
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.asksForVersion {
                        let engine = tab.engineKind
                        Text("Its developer may offer a separate version for \(engine.displayName).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Install \(engine.displayName) Version\u{2026}") {
                                close()
                                session.installEngineVersion?(tab.personaID, tabSpace, item.id, engine)
                            }
                            Button("Dismiss") { session.plugins(in: tab.personaID).dismissVersionNote(of: item.id, for: engine) }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    /// The engines' names in the order of `EngineKind`, such as "WebKit" or "WebKit and Chromium".
    private static func names(_ engines: Set<EngineKind>, joinedBy conjunction: String = "and") -> String {
        EngineKind.allCases.filter(engines.contains).map(\.displayName).joined(separator: " \(conjunction) ")
    }
}

/// An action's icon, label, and badge for the tab, with the hover fill of the app's other plain buttons, which reaches past the section's edges so that the icon stays on the section's leading edge. An action that the tab's engine does not run, or that its extension switched off for the tab, shows dimmed and takes no fill.
private struct ExtensionActionRow: View {
    /// How far the hover fill reaches past each side of the row.
    static let fillOverhang: CGFloat = 4

    let item: WebExtensionActionItem
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let isEnabled = item.action?.isEnabled == true
        let title = item.action.flatMap { $0.label.isEmpty ? nil : $0.label } ?? item.name
        let badge = item.action.flatMap { $0.badgeText.isEmpty ? nil : $0.badgeText }
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let icon = item.action?.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                    }
                }
                .frame(width: 16, height: 16)
                Text(title)
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
            .padding(.horizontal, Self.fillOverhang)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(item.name)
        .accessibilityLabel(title)
        .accessibilityValue(badge ?? "")
        // Last, so that the pointer's hover and click areas are the fill's.
        .padding(.horizontal, -Self.fillOverhang)
    }
}

/// Reads which extension a store page's address or typed text names (`docs/web-store.md`, Install flow): `WebStore`'s readers, or in tests readers with hosts that stand in for the store's.
struct WebStoreReader {
    var page: (URL) -> String? = WebStore.extensionID(in:)
    var text: (String) -> String? = WebStore.extensionID(from:)

    static let store = WebStoreReader()
}

/// The Web Store row at the top of the popover's extensions section on a store page (`docs/web-store.md`, Entry points), which names no Persona.
enum WebStorePageRow: Equatable {
    /// Install This Extension…, for the extension's identifier.
    case install(String)
    /// The name of the Persona's plugin of the page's extension.
    case installed(String)

    /// The row for a tab at `pageURL`, or nil when it is not a store page. `installedName` names the tab's Persona's plugin of an extension identifier, or gives nil while it has none.
    init?(pageURL: URL?, installedName: (String) -> String?, reader: WebStoreReader = .store) {
        guard let pageURL, let id = reader.page(pageURL) else { return nil }
        self = installedName(id).map(Self.installed) ?? .install(id)
    }

    var title: String {
        switch self {
        case .install: return "Install This Extension\u{2026}"
        case let .installed(name): return "\u{201C}\(name)\u{201D} is installed."
        }
    }

    /// The section's note while the row is its only one.
    var note: String {
        switch self {
        case .install: return "Opens the extension\u{2019}s review in Settings before it installs."
        case .installed: return "Manage it for this Persona in Settings \u{25B8} Plugins."
        }
    }
}
