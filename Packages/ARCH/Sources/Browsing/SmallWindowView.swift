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

/// The small window's controls on the line of the traffic light buttons: the page's icon and site, which open the palette to edit the address, then back, forward, reload or stop, share, and Move to Main Window. In full screen, where the traffic lights hide, the row starts at the page's margin.
private struct SmallWindowTopRow: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    /// Observed so that the controls follow navigation within the page.
    @ObservedObject var tab: Tab
    let windowButtons: WindowButtonMetrics

    private var siteName: String {
        windowModel.internalPage?.address ?? tab.url.map(AddressPillView.siteName(of:)) ?? tab.pageTitle
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { windowModel.focusCommandBar() } label: {
                HStack(spacing: 6) {
                    TabIconView(tab: tab)
                        .frame(width: 16, height: 16)
                    Text(siteName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.url?.absoluteString ?? "")
            .accessibilityLabel(siteName)
            Spacer(minLength: 8)
            SidebarIconButton(symbol: "chevron.left", label: "Back", action: windowModel.goBack).disabled(!tab.canGoBack)
            SidebarIconButton(symbol: "chevron.right", label: "Forward", action: windowModel.goForward).disabled(!tab.canGoForward)
            if tab.isLoading {
                SidebarIconButton(symbol: "xmark", label: "Stop Loading", action: windowModel.stopLoading)
            } else {
                SidebarIconButton(symbol: "arrow.clockwise", label: "Reload", action: windowModel.reload)
            }
            LowPowerModeIndicator()
            SidebarIconButton(symbol: "square.and.arrow.up", label: "Share", action: windowModel.shareSelectedPage)
                .disabled(!windowModel.canShareSelectedPage)
                .background(SiteControlAnchor(windowModel: windowModel, button: \.shareButtonView))
            SidebarIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Move to Main Window", shortcut: session.moveToMainWindowShortcut()) {
                session.moveToMainWindow(windowModel)
            }
        }
        .frame(height: SidebarTopRow.height)
        .padding(.leading, (windowButtons.trailingEdge ?? 0) + BrowserWindowView.pageMargin)
        .padding(.trailing, BrowserWindowView.pageMargin)
        .padding(.top, SidebarTopRow.topPadding(below: windowButtons))
    }
}
