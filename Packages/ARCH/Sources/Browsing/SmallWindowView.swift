// A small window opens for a link from another app while Arch is in the background, a page opened by its page or preview, or an extension's `windows.create`.
// Its top bar holds the page's site, controls, and Persona / Space. Below, the page sits over material tinted by the tab's space.
// The window shows one tab. Find, prompt cards, page fullscreen, docked developer tools, reader, agent panel, and address palette work there. Sidebar commands go to the main window.
import ARCHEngine
import SwiftUI

/// The contents of a small window; `BrowserWindowController` hosts it.
struct SmallWindowView: View {
    @ObservedObject var session: BrowserSession
    /// The window this view shows. Its subviews read it from the environment.
    @ObservedObject var windowModel: BrowserWindowModel
    @State private var windowButtons = WindowButtonMetrics()

    init(session: BrowserSession, window: BrowserWindowModel) {
        self.session = session
        windowModel = window
    }

    /// The page keeps the main window's margin on its sides and bottom, and half of it below the row at the top, which keeps the small window's bar thin.
    private static let pageMargins = EdgeInsets(top: BrowserWindowView.pageMargin / 2, leading: BrowserWindowView.pageMargin, bottom: BrowserWindowView.pageMargin, trailing: BrowserWindowView.pageMargin)

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if !windowModel.isPageFullscreen, let tab = windowModel.selectedTab {
                    SmallWindowTopRow(session: session, tab: tab, windowButtons: windowButtons)
                        .modifier(SidebarAppearance())
                }
                HStack(spacing: 0) {
                    PageAreaView(session: session, sidebarDrag: nil, margins: Self.pageMargins)
                    if !windowModel.isPageFullscreen {
                        if windowModel.agentPanel != nil {
                            AgentPanelColumn(session: session)
                        } else {
                            PageReaderColumn(session: session)
                        }
                    }
                }
            }
            CommandPaletteLayer(session: session)
        }
        .overlay(alignment: .bottom) { SiteRuleToastView(window: windowModel) }
        .coordinateSpace(name: BrowserWindowView.coordinateSpace)
        .environmentObject(windowModel)
        .background(SpaceBackgroundView())
        .modifier(SpaceThemeModifier(tint: windowModel.currentSpace.tint))
        .background(WindowButtonsReader { windowButtons = $0 })
        .ignoresSafeArea()
        .frame(minWidth: BrowserWindowKind.small.minimumContentSize.width, minHeight: BrowserWindowKind.small.minimumContentSize.height)
    }
}

/// The small window's controls on the line of the traffic light buttons: the page's icon, the address pill's symbol for the page, and its site, which open the palette to edit the address, then back, forward, reload or stop, share, and Open in Main Window. While an internal page covers the tab, the row names that page, as the address pill does. In full screen, where the traffic lights hide, the row starts at the page's margin.
private struct SmallWindowTopRow: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    /// Observed so that the controls follow navigation within the page.
    @ObservedObject var tab: Tab
    let windowButtons: WindowButtonMetrics
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHoveringSite = false
    @State private var pageMenuAnchor = SmallWindowMenuAnchor()
    @Environment(\.spaceTheme) private var theme

    /// The name of the web extension whose page the tab shows (`AddressPillView.extensionName(ofPageAt:in:session:)`), unless an internal page covers it.
    private var extensionName: String? {
        guard windowModel.internalPage == nil, let url = tab.url else { return nil }
        return AddressPillView.extensionName(ofPageAt: url, in: tab, session: session)
    }

    /// The internal page's address, the name of the extension whose page it is, the page's site, or the page's title without an address.
    private func siteName(extensionName: String?) -> String {
        windowModel.internalPage?.address ?? extensionName ?? tab.url.map(AddressPillView.siteName(of:)) ?? tab.pageTitle
    }

    var body: some View {
        GeometryReader { proxy in
            row(compact: proxy.size.width < 640)
        }
        .frame(height: SidebarTopRow.height + SidebarTopRow.topPadding(below: windowButtons))
    }

    private func row(compact: Bool) -> some View {
        let extensionName = self.extensionName
        let siteName = self.siteName(extensionName: extensionName)
        return HStack(spacing: 4) {
            SmallWindowPlaceMenu(session: session, tab: tab)
                .frame(minWidth: 96, maxWidth: 220)
                .layoutPriority(1)
            Button { windowModel.focusCommandBar() } label: {
                HStack(spacing: 6) {
                    // The icon belongs to the tab, which an internal page hides.
                    if windowModel.internalPage == nil {
                        TabIconView(tab: tab)
                            .frame(width: 16, height: 16)
                    }
                    // As wide as the globe, the widest of the symbols but the extension's, which takes a point of the spacing on each side, so that the site keeps its place between secure and insecure pages and an extension's, as in the address pill.
                    Image(systemName: AddressPillView.symbol(for: tab.url, internalPage: windowModel.internalPage, isExtensionPage: extensionName != nil))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text(siteName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                // The row's buttons show the same fill under the pointer.
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHoveringSite ? SidebarFill.buttonHover.color(in: colorScheme) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringSite = $0 }
            .help(windowModel.internalPage?.address ?? tab.url?.absoluteString ?? "")
            .accessibilityLabel(extensionName.map(AddressPillView.accessibilityLabel(ofExtensionPage:)) ?? siteName)
            if !compact, !windowModel.isSelectedPageCovered {
                TemporaryEngineLabel(tab: tab)
            }
            Spacer(minLength: 8)
            if !compact {
                SidebarIconButton(symbol: "chevron.left", label: localized("Back"), shortcut: session.menuShortcut("goBack"), action: windowModel.goBack).disabled(!tab.canGoBack)
                SidebarIconButton(symbol: "chevron.right", label: localized("Forward"), shortcut: session.menuShortcut("goForward"), action: windowModel.goForward).disabled(!tab.canGoForward)
                if tab.isLoading {
                    SidebarIconButton(symbol: "xmark", label: localized("Stop Loading"), shortcut: session.menuShortcut("stopLoading"), action: windowModel.stopLoading)
                } else {
                    SidebarIconButton(symbol: "arrow.clockwise", label: localized("Reload"), shortcut: session.menuShortcut("reload"), action: windowModel.reload).disabled(!windowModel.canReload)
                }
            }
            LibraryButton(session: session, activityOnly: true)
            LowPowerModeIndicator()
            if compact {
                pageMenu
            } else {
                SidebarIconButton(symbol: "square.and.arrow.up", label: localized("Share"), action: windowModel.shareSelectedPage)
                    .disabled(!windowModel.canShareSelectedPage)
                    .background(SiteControlAnchor(windowModel: windowModel, button: \.shareButtonView))
            }
            SidebarIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: localized("Open in Main Window"), shortcut: session.menuShortcut("moveToMainWindow")) {
                session.moveToMainWindow(windowModel)
            }
        }
        .frame(height: SidebarTopRow.height)
        .padding(.leading, (windowButtons.trailingEdge ?? 0) + BrowserWindowView.pageMargin)
        .padding(.trailing, BrowserWindowView.pageMargin)
        .padding(.top, SidebarTopRow.topPadding(below: windowButtons))
        .overlay(alignment: .bottom) {
            theme.tint.opacity(0.25)
                .frame(height: 1)
                .padding(.horizontal, BrowserWindowView.pageMargin)
                .allowsHitTesting(false)
        }
    }

    private var pageMenu: some View {
        Button {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(EngineActionMenuItem(localized("Back"), isEnabled: tab.canGoBack, handler: windowModel.goBack))
            menu.addItem(EngineActionMenuItem(localized("Forward"), isEnabled: tab.canGoForward, handler: windowModel.goForward))
            if tab.isLoading {
                menu.addItem(EngineActionMenuItem(localized("Stop Loading"), handler: windowModel.stopLoading))
            } else {
                menu.addItem(EngineActionMenuItem(localized("Reload"), isEnabled: windowModel.canReload, handler: windowModel.reload))
            }
            menu.addItem(.separator())
            menu.addItem(EngineActionMenuItem(localized("Share"), isEnabled: windowModel.canShareSelectedPage, handler: windowModel.shareSelectedPage))
            if !windowModel.isSelectedPageCovered, let explanation = TemporaryEngineLabel.explanation(for: tab) {
                menu.addItem(.separator())
                menu.addItem(EngineActionMenuItem(explanation, isEnabled: false, handler: {}))
            }
            pageMenuAnchor.show(menu)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(SmallWindowMenuAnchorView(anchor: pageMenuAnchor))
        .help(localized("Page Actions"))
        .accessibilityLabel(localized("Page Actions"))
        .background(SiteControlAnchor(windowModel: windowModel, button: \.shareButtonView))
    }

}

/// The small window always names its own space, even when the default Persona is the only one.
struct SmallWindowIdentity {
    let space: Space
    let personaName: String
    let label: String

    init(space: Space, personas: [Persona]) {
        self.space = space
        personaName = personas.first { $0.id == space.resolvedPersonaID }?.name ?? ""
        label = BrowserSession.displayedPlace(ofPersona: space.resolvedPersonaID, space: space, among: personas)
            ?? (personaName.isEmpty ? space.name : "\(personaName) / \(space.name)")
    }
}

extension BrowserWindowModel {
    var smallWindowIdentity: SmallWindowIdentity {
        SmallWindowIdentity(space: currentSpace, personas: session.personas)
    }
}

/// The identity uses the sidebar space header's typography and tint. Its menu selects any Persona / Space or keeps this site in regular windows.
private struct SmallWindowPlaceMenu: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @ObservedObject var tab: Tab
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.spaceTheme) private var theme
    @State private var isHovering = false
    @State private var menuAnchor = SmallWindowMenuAnchor()

    var body: some View {
        let identity = windowModel.smallWindowIdentity
        Button {
            menuAnchor.show(SmallWindowMenus.places(session: session, window: windowModel, tab: tab))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: identity.space.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.symbolColor(for: identity.space.tint))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(identity.personaName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minWidth: min(36, ceil((identity.personaName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)), alignment: .leading)
                    Text("/")
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    Text(identity.space.name)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.system(size: 13))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? SidebarFill.buttonHover.color(in: colorScheme) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(SmallWindowMenuAnchorView(anchor: menuAnchor))
        .onHover { isHovering = $0 }
        .help(identity.label)
        .accessibilityLabel(identity.label)
    }
}

/// Native menu items keep the destination action and checkmark together.
@MainActor enum SmallWindowMenus {
    static func places(session: BrowserSession, window: BrowserWindowModel, tab: Tab) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(EngineActionMenuItem(localized("Always Open This Site in a Regular Window"),
                                         isEnabled: !window.isSelectedPageCovered && RegularWindowSites.host(from: tab.url) != nil) {
            session.alwaysOpenSmallWindowSiteInRegularWindow(window)
        })
        menu.addItem(.separator())
        for space in session.spaces {
            let destination = SmallWindowIdentity(space: space, personas: session.personas)
            let item = EngineActionMenuItem(destination.label) { session.moveSmallWindow(window, toSpace: space.id) }
            item.state = space.id == window.currentSpaceID ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// The title-bar controls use ordinary buttons to open native menus below their anchors.
@MainActor private final class SmallWindowMenuAnchor {
    weak var view: NSView?

    func show(_ menu: NSMenu) {
        guard let view, view.window != nil else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: view.bounds.minY), in: view)
    }
}

private struct SmallWindowMenuAnchorView: NSViewRepresentable {
    let anchor: SmallWindowMenuAnchor

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) { anchor.view = view }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
