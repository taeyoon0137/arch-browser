// The site settings popover's Extensions group for the web extensions of the tab's Persona: on a Web Store page, first the store's row, Install This Extension… or, while the Persona has the page's extension installed, its name with Installed; then a row for each enabled extension with an action, and for one without while the engine keeps it from the tab's site, a pair once, with the action's icon, label, and badge for the tab. A click closes the popover and runs the action, which shows the extension's popup from the site settings button or tells the extension of the click. An extension that the engine kept from running on the tab's site, as Chromium keeps one whose sites wait for a click, offers Allow on This Site. On a tab whose engine runs extensions but none of a plugin's versions, the row says where the plugin runs and, while the plugin asks for that engine's version, offers Install <Engine> Version… and Dismiss, side by side or, where they do not fit, one above the other.
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
            let engineRunsExtensions = engines.contains(tab.engineKind)
            SiteSettingsGroup("Extensions", footnote: items.isEmpty
                ? storeRow.map { row in
                    guard case .installed = row else { return row.note }
                    let space = session.spaces.first { $0.id == tabSpace }
                    let place = session.displayedPlace(ofPersona: tab.personaID, space: space) ?? space?.name ?? "this Persona"
                    return "Manage it for \(place) in Settings ▸ Plugins."
                }
                : engineRunsExtensions
                ? "Opens an extension\u{2019}s popup, or lets the extension act on this page."
                : "Extensions run on \(Self.names(engines)) tabs. Switch this tab to \(Self.names(engines, joinedBy: "or")) to use them.") {
                let rows = VStack(alignment: .leading, spacing: 0) {
                    if let storeRow { row(for: storeRow) }
                    ForEach(items) { item in
                        if storeRow != nil || item.id != items.first?.id { SiteSettingsDivider() }
                        row(for: item, engineRunsExtensions: engineRunsExtensions)
                    }
                }
                // As tall as the rows up to 260 points, about eight actions; more scroll inside the box, so that the popover stays on the screen.
                ViewThatFits(in: .vertical) {
                    rows
                    // Rows scrolled past the box's edge and the scroll bar end at its corners.
                    ScrollView { rows }
                        .clipShape(RoundedRectangle(cornerRadius: SiteSettingsMetrics.boxCornerRadius, style: .continuous))
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

    /// Install This Extension… closes the popover and opens the store sheet in Settings ▸ Plugins for the tab's Persona and space; an installed extension's row only names it, with Installed at its end.
    @ViewBuilder private func row(for storeRow: WebStorePageRow) -> some View {
        switch storeRow {
        case let .install(id):
            SiteSettingsRow(symbol: "arrow.down.circle", title: storeRow.title, action: {
                close()
                session.installFromWebStore?(tab.personaID, tabSpace, id)
            })
            .disabled(session.installFromWebStore == nil)
        case .installed:
            SiteSettingsRow(symbol: "checkmark.circle", title: storeRow.title, detail: "Installed")
        }
    }

    /// The action's row, and below it at the label's edge, where they apply, Allow on This Site and the note on the engines the plugin runs on.
    private func row(for item: WebExtensionActionItem, engineRunsExtensions: Bool) -> some View {
        let runsNote = engineRunsExtensions && !item.engines.contains(tab.engineKind) ? PluginPackage.runsNote(on: item.engines) : nil
        return VStack(alignment: .leading, spacing: 0) {
            ExtensionActionRow(item: item) {
                close()
                webExtensions.performAction(of: item.id, for: tab.webContents)
            }
            if item.wantsSiteAccess || runsNote != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if item.wantsSiteAccess {
                        Button("Allow on This Site") {
                            close()
                            webExtensions.grantSiteAccess(of: item.id, for: tab.webContents)
                        }
                        .controlSize(.small)
                    }
                    if let runsNote {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(runsNote)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if item.asksForVersion {
                                let engine = tab.engineKind
                                Text("Its developer may offer a separate version for \(engine.displayName).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                let install = Button("Install \(engine.displayName) Version\u{2026}") {
                                    close()
                                    session.installEngineVersion?(tab.personaID, tabSpace, item.id, engine)
                                }
                                let dismiss = Button("Dismiss") { session.plugins(in: tab.personaID).dismissVersionNote(of: item.id, for: engine) }
                                // Side by side the two take about all of the row, so a scroll bar that stays visible would cut them short.
                                ViewThatFits(in: .horizontal) {
                                    HStack { install; dismiss }
                                    VStack(alignment: .leading, spacing: 6) { install; dismiss }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.leading, SiteSettingsMetrics.labelInset)
                .padding(.trailing, SiteSettingsMetrics.rowPadding)
                .padding(.bottom, 10)
            }
        }
    }

    /// The engines' names in the order of `EngineKind`, such as "WebKit" or "WebKit and Chromium".
    private static func names(_ engines: Set<EngineKind>, joinedBy conjunction: String = "and") -> String {
        EngineKind.allCases.filter(engines.contains).map(\.displayName).joined(separator: " \(conjunction) ")
    }
}

/// An action's icon, label, and badge for the tab as a button row of the box. An action that the tab's engine does not run, or that its extension switched off for the tab, shows dimmed and takes no fill.
private struct ExtensionActionRow: View {
    let item: WebExtensionActionItem
    let action: () -> Void

    var body: some View {
        let title = item.action.flatMap { $0.label.isEmpty ? nil : $0.label } ?? item.name
        let badge = item.action.flatMap { $0.badgeText.isEmpty ? nil : $0.badgeText }
        SiteSettingsRow(title: title, help: item.name, action: action) {
            if let icon = item.action?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "puzzlepiece.extension")
            }
        } accessory: {
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
        }
        .disabled(item.action?.isEnabled != true)
        .accessibilityValue(badge ?? "")
    }
}

/// Reads which extension a store page's address or typed text names (`docs/web-store.md`, Install flow): `WebStore`'s readers, or in tests readers with hosts that stand in for the store's.
struct WebStoreReader {
    var page: (URL) -> String? = WebStore.extensionID(in:)
    var text: (String) -> String? = WebStore.extensionID(from:)

    static let store = WebStoreReader()
}

/// The Web Store row at the top of the popover's Extensions group on a store page (`docs/web-store.md`, Entry points), which names no Persona.
enum WebStorePageRow: Equatable {
    /// Install This Extension…, for the extension's identifier.
    case install(String)
    /// The name of the Persona's plugin of the page's extension, which the row shows with Installed.
    case installed(String)

    /// The row for a tab at `pageURL`, or nil when it is not a store page. `installedName` names the tab's Persona's plugin of an extension identifier, or gives nil while it has none.
    init?(pageURL: URL?, installedName: (String) -> String?, reader: WebStoreReader = .store) {
        guard let pageURL, let id = reader.page(pageURL) else { return nil }
        self = installedName(id).map(Self.installed) ?? .install(id)
    }

    var title: String {
        switch self {
        case .install: return "Install This Extension\u{2026}"
        case let .installed(name): return name
        }
    }

    /// The group's footnote while the row is its only one.
    var note: String {
        switch self {
        case .install: return "Opens the extension\u{2019}s review in Settings before it installs."
        case .installed: return "Manage it for this Persona in Settings \u{25B8} Plugins."
        }
    }
}
