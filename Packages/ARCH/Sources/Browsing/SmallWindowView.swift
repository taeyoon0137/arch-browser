// The content of a small window, which opens for a link from another app while Arch is in the background, for a page that a small window's page or preview opens, and for an extension's `windows.create`: one row on the line of the traffic light buttons with the page's site and controls, and below it the page area over the window material with the tint of the tab's space. The window shows only its own tab; find, prompt cards, page fullscreen, the docked developer tools, the page reader, the agent panel, and the palette that edits the address work here, and sidebar commands go to the main window.
import SwiftUI

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
        .coordinateSpace(name: BrowserWindowView.coordinateSpace)
        .environmentObject(windowModel)
        .background(SpaceBackgroundView())
        .modifier(SpaceThemeModifier(tint: windowModel.currentSpace.tint))
        .background(WindowButtonsReader { windowButtons = $0 })
        .ignoresSafeArea()
        .frame(minWidth: BrowserWindowKind.small.minimumContentSize.width, minHeight: BrowserWindowKind.small.minimumContentSize.height)
    }
}

/// The small window's controls on the line of the traffic light buttons: the page's icon, the address pill's symbol for the page, and its site, which open the palette to edit the address, then back, forward, reload or stop, share, and Move to Main Window. While an internal page covers the tab, the row names that page, as the address pill does. In full screen, where the traffic lights hide, the row starts at the page's margin.
private struct SmallWindowTopRow: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    /// Observed so that the controls follow navigation within the page.
    @ObservedObject var tab: Tab
    let windowButtons: WindowButtonMetrics
    @State private var isHoveringSite = false

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
        let extensionName = self.extensionName
        let siteName = self.siteName(extensionName: extensionName)
        HStack(spacing: 4) {
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
                    Text(siteName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                // The row's buttons show the same fill under the pointer.
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHoveringSite ? 0.08 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringSite = $0 }
            .help(windowModel.internalPage?.address ?? tab.url?.absoluteString ?? "")
            .accessibilityLabel(extensionName.map(AddressPillView.accessibilityLabel(ofExtensionPage:)) ?? siteName)
            if !windowModel.isSelectedPageCovered {
                TemporaryEngineLabel(tab: tab)
            }
            Spacer(minLength: 8)
            SidebarIconButton(symbol: "chevron.left", label: "Back", shortcut: session.menuShortcut("goBack"), action: windowModel.goBack).disabled(!tab.canGoBack)
            SidebarIconButton(symbol: "chevron.right", label: "Forward", shortcut: session.menuShortcut("goForward"), action: windowModel.goForward).disabled(!tab.canGoForward)
            if tab.isLoading {
                SidebarIconButton(symbol: "xmark", label: "Stop Loading", shortcut: session.menuShortcut("stopLoading"), action: windowModel.stopLoading)
            } else {
                SidebarIconButton(symbol: "arrow.clockwise", label: "Reload", shortcut: session.menuShortcut("reload"), action: windowModel.reload).disabled(!windowModel.canReload)
            }
            LibraryButton(session: session, activityOnly: true)
            LowPowerModeIndicator()
            SidebarIconButton(symbol: "square.and.arrow.up", label: "Share", action: windowModel.shareSelectedPage)
                .disabled(!windowModel.canShareSelectedPage)
                .background(SiteControlAnchor(windowModel: windowModel, button: \.shareButtonView))
            SidebarIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Move to Main Window", shortcut: session.menuShortcut("moveToMainWindow")) {
                session.moveToMainWindow(windowModel)
            }
        }
        .frame(height: SidebarTopRow.height)
        .padding(.leading, (windowButtons.trailingEdge ?? 0) + BrowserWindowView.pageMargin)
        .padding(.trailing, BrowserWindowView.pageMargin)
        .padding(.top, SidebarTopRow.topPadding(below: windowButtons))
    }
}
