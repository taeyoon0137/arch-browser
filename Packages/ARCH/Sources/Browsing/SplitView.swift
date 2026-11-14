// The page area and split view. The page area of either kind of window shows the selected tab, or the split view it belongs to: two to four tabs side by side, each in its own pane. The selected tab is the focused pane, which the address pill, the find bar, and the menus act on, and a click in another pane selects that pane's tab. A pane whose tab another window shows holds a placeholder instead. Each pane of a split view has a control that takes its tab out, and a tab dragged from the sidebar onto a pane opens beside it. The session keeps each space's split view (`BrowserSession`, Split view).
import SwiftUI

/// The page area of either kind of window: the window's panes, or the empty page frame with no tab open, at `margins` from the window's edges and controls, with the preview panel over it and room beside it for docked developer tools. While the selected page fills the window in fullscreen, only its pane shows, without margins, and the window enters full screen with it. A pane whose page another window shows holds a placeholder, because a page's view has one superview (window rule 1).
struct PageAreaView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    /// Receives the panes' frames, so that a tab dragged from the sidebar can open beside one; nil in a window without a sidebar. The page area itself does not change during a drag.
    let sidebarDrag: SidebarDragState?
    let margins: EdgeInsets
    /// How far the window has gone into full screen for a page, so that it leaves full screen again with the page.
    @State private var pageFullScreen = PageFullScreen.none

    /// The window's full screen that a page asked for.
    private enum PageFullScreen {
        case none
        /// On the way in. A page that leaves fullscreen meanwhile takes the window out once it is in, not during the transition. Failing to enter ends it.
        case entering
        case entered
    }

    var body: some View {
        let isPageFullscreen = windowModel.isPageFullscreen
        panes(isPageFullscreen: isPageFullscreen)
            // A preview floats over the whole page area, whatever its panes.
            .overlay { if let preview = windowModel.preview { PagePreviewPanel(preview: preview) } }
            .padding(isPageFullscreen ? EdgeInsets() : margins)
            .modifier(DevToolsDockSpace(dock: windowModel.devToolsDock, isHidden: isPageFullscreen, margins: margins))
            // A page that enters fullscreen takes the window into full screen and leaves it with the page; leaving the window's full screen ends the page's.
            .onChange(of: isPageFullscreen) { _, isFullscreen in
                guard let window = windowModel.nsWindow else { return }
                if isFullscreen, pageFullScreen == .none, !window.styleMask.contains(.fullScreen) {
                    pageFullScreen = .entering
                    window.toggleFullScreen(nil)
                } else if !isFullscreen, pageFullScreen == .entered {
                    pageFullScreen = .none
                    if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
                guard let window = notification.object as? NSWindow, window === windowModel.nsWindow, pageFullScreen == .entering else { return }
                if windowModel.isPageFullscreen {
                    pageFullScreen = .entered
                } else {
                    pageFullScreen = .none
                    window.toggleFullScreen(nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: BrowserWindowController.didFailToEnterFullScreenNotification)) { notification in
                if notification.object as? NSWindow === windowModel.nsWindow { pageFullScreen = .none }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
                guard notification.object as? NSWindow === windowModel.nsWindow else { return }
                pageFullScreen = .none
                if windowModel.isPageFullscreen { windowModel.exitPageFullscreen() }
            }
    }

    private func panes(isPageFullscreen: Bool) -> some View {
        let panes = isPageFullscreen ? windowModel.selectedTab.map { [$0] } ?? [] : windowModel.paneTabs
        return Group {
            if panes.isEmpty {
                PageBackgroundView(isEmpty: true)
                    .overlay { InternalPageOverlay() }
                    .overlay(PageFrameShape().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
            } else {
                HStack(spacing: BrowserWindowView.pageMargin) {
                    ForEach(panes) { tab in
                        Group {
                            if windowModel.shows(tab) {
                                PagePaneView(session: session, tab: tab, isSplit: panes.count > 1, isPageFullscreen: isPageFullscreen)
                            } else {
                                ShownElsewherePaneView(tab: tab, isSplit: panes.count > 1)
                            }
                        }
                        // A pane appears and leaves at once, as a page does when another tab is selected.
                        .transition(.identity)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: PaneFramesKey.self, value: [PaneFrame(tabID: tab.id, frame: proxy.frame(in: .named(BrowserWindowView.coordinateSpace)))])
                        })
                    }
                }
            }
        }
        .onPreferenceChange(PaneFramesKey.self) { sidebarDrag?.paneFrames = $0 }
    }
}

/// One tab's page in its rounded frame, with the crash notice and, for the selected tab, the internal page, the region capture overlay, the find bar, and the question popover. In a split view, a click on the page selects its tab, the selected tab's pane has a ring in the space's tint, and each pane has a close control.
private struct PagePaneView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    /// Observed so that the pane shows the new view when the tab switches engines.
    @ObservedObject var tab: Tab
    let isSplit: Bool
    let isPageFullscreen: Bool
    @Environment(\.spaceTheme) private var theme

    private var isSelected: Bool { tab.id == windowModel.selectedTabID }
    private var cornerRadius: CGFloat { isPageFullscreen ? 0 : PageFrameShape.cornerRadius }
    /// Whether the region capture overlay covers the pane. The find bar, the question popover, and the close control then hide, so that they neither cover the overlay's hint nor take its drags.
    private var isCapturingRegion: Bool { isSelected && windowModel.regionCaptureTabID == tab.id && windowModel.internalPage == nil }

    var body: some View {
        WebContentsHostView(contentView: tab.webContents.view, cornerRadius: cornerRadius, onClick: isSplit ? selectTab : nil)
            .background(PageBackgroundView(isEmpty: false))
            .overlay { PageCrashNoticeView(tab: tab) }
            .overlay { if isSelected { InternalPageOverlay() } }
            .overlay {
                if isCapturingRegion {
                    CaptureRegionOverlay(windowModel: windowModel, pageView: tab.webContents.view, cornerRadius: cornerRadius)
                }
            }
            .overlay(frameBorder.allowsHitTesting(false))
            // The find bar and the question popover act on the selected tab, so they float over that pane's top trailing corner, the popover below the bar. In a narrow pane they keep clear of its leading edge and of a split view pane's close control. A region capture hides them without closing them, so that their fields do not take the focus again when it ends.
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    VStack(alignment: .trailing, spacing: 8) {
                        if windowModel.isFindBarVisible {
                            FindBarView()
                        }
                        PageQuestionLayer(session: session)
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    .padding(.leading, isSplit ? 32 : 16)
                    .opacity(isCapturingRegion ? 0 : 1)
                    .allowsHitTesting(!isCapturingRegion)
                    .disabled(isCapturingRegion)
                    .accessibilityHidden(isCapturingRegion)
                }
            }
            .overlay(alignment: .topLeading) {
                if isSplit, !isCapturingRegion {
                    PaneCloseButton { windowModel.closePane(tab) }
                        .padding(6)
                }
            }
    }

    /// The ring that marks the focused pane of a split view, or the faint edge of any other page frame, which fullscreen drops.
    @ViewBuilder private var frameBorder: some View {
        if isSplit, isSelected {
            PageFrameShape().strokeBorder(theme.tint, lineWidth: 2)
        } else {
            PageFrameShape().strokeBorder(Color.primary.opacity(isPageFullscreen ? 0 : 0.08))
        }
    }

    /// Selecting the tab again would close an internal page over it.
    private func selectTab() {
        if windowModel.selectedTabID != tab.id { windowModel.selectTab(tab.id) }
    }
}

/// Stands in for a pane whose tab another window shows. Show Here selects the tab, which moves its page to this window (window rule 2); a click elsewhere in the pane leaves it where it is. In a split view, the pane keeps its close control.
private struct ShownElsewherePaneView: View {
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @ObservedObject var tab: Tab
    let isSplit: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(tab.displayTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text("This tab is shown in another window.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Show Here") { windowModel.selectTab(tab.id) }
                .controlSize(.large)
                .padding(.top, 6)
        }
        // A narrow pane wraps the line, centered like the rest.
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PageBackgroundView(isEmpty: true))
        .overlay(PageFrameShape().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
        .overlay(alignment: .topLeading) {
            if isSplit {
                PaneCloseButton { windowModel.closePane(tab) }
                    .padding(6)
            }
        }
    }
}

/// The internal page over the selected tab's pane, or over the empty page frame with no tab open.
private struct InternalPageOverlay: View {
    @EnvironmentObject private var windowModel: BrowserWindowModel

    var body: some View {
        if let page = windowModel.internalPage {
            InternalPageView(page: page)
                .clipShape(PageFrameShape())
        }
    }
}

/// Takes a pane's tab out of the split view. The tab stays open in the sidebar.
private struct PaneCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                // A solid background: a material over the engine's view cannot sample it.
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor)))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .help("Remove from Split View")
        .accessibilityLabel("Remove from Split View")
    }
}

// MARK: Dropping a tab on the page area

/// A pane's frame in the window, reported by the page area for a tab dragged over it.
struct PaneFrame: Equatable {
    let tabID: UUID
    let frame: CGRect
}

/// Where a dragged tab opens in split view: its index among the panes on screen, and the half of the pane under the pointer that shows the place.
struct SplitDrop: Equatable {
    let index: Int
    let frame: CGRect
}

/// The panes' frames, left to right.
private struct PaneFramesKey: PreferenceKey {
    static let defaultValue: [PaneFrame] = []

    static func reduce(value: inout [PaneFrame], nextValue: () -> [PaneFrame]) {
        value += nextValue()
    }
}

extension SidebarDragState {
    /// Where `tab` released at `point` opens in split view: before the pane under the pointer over its leading half, after it over its trailing half. `nil` when the tab cannot join the panes on screen, or when a pane would stay where it is.
    func splitDrop(of tab: Tab, at point: CGPoint, in windowModel: BrowserWindowModel) -> SplitDrop? {
        guard let paneIndex = paneFrames.firstIndex(where: { $0.frame.contains(point) }) else { return nil }
        let frame = paneFrames[paneIndex].frame
        let isLeading = point.x < frame.midX
        let index = isLeading ? paneIndex : paneIndex + 1
        if let current = paneFrames.firstIndex(where: { $0.tabID == tab.id }) {
            guard index != current, index != current + 1 else { return nil }
        } else if !windowModel.canOpenInSplitView(tab) {
            return nil
        }
        let halves = frame.divided(atDistance: frame.width / 2, from: .minXEdge)
        return SplitDrop(index: index, frame: (isLeading ? halves.slice : halves.remainder).insetBy(dx: SplitDropIndicator.inset, dy: SplitDropIndicator.inset))
    }
}

/// Shows where a tab dragged over the page area opens in split view, over the half of the pane on the side it takes.
struct SplitDropIndicator: View {
    @ObservedObject var sidebarDrag: SidebarDragState

    /// How far the indicator sits inside the half of the pane. Its corners are the pane's, less this, so they stay concentric with the pane's.
    static let inset: CGFloat = 4

    var body: some View {
        if let frame = sidebarDrag.splitDrop?.frame {
            let shape = RoundedRectangle(cornerRadius: PageFrameShape.cornerRadius - Self.inset, style: .continuous)
            shape
                .fill(Color.accentColor.opacity(0.15))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
