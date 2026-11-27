// Either window kind shows its selected tab or the split view containing it. A split view has two to four panes, each with one tab.
// The selected tab is the focused pane for the address pill, find bar, and menus. Clicking another pane selects its tab.
// A pane shown in another window becomes a placeholder. Each pane can remove its tab, and a sidebar drag onto a pane opens beside it.
// `BrowserSession` keeps each space's split view.
import Agent
import SwiftUI

/// The page area of either kind of window: the window's panes, or the empty page frame with no tab open, at `margins` from the window's edges and controls, with the preview panel over it and room beside it for docked developer tools. While the selected page fills the window in fullscreen, only its pane shows, without margins, and the window enters full screen with it. A pane whose page another window shows holds a placeholder, because a page's view has one superview (window rule 1).
struct PageAreaView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Receives the panes' frames, so that a tab dragged from the sidebar can open beside one; nil in a window without a sidebar. The page area itself does not change during a drag.
    let sidebarDrag: SidebarDragState?
    let margins: EdgeInsets
    /// How far the window has gone into full screen for a page, so that it leaves full screen again with the page.
    @State private var pageFullScreen = PageFullScreen.none
    /// Relative room beyond each pane's controls, kept while this window changes focus or size.
    @State private var paneWeights: [UUID: CGFloat] = [:]
    /// Keep a measured overflow requirement until the bar closes, avoiding resize feedback.
    @State private var findBarRequiredWidth: CGFloat = 0

    /// The window's full screen that a page asked for.
    private enum PageFullScreen {
        case none
        /// On the way in. A page that leaves fullscreen meanwhile takes the window out once it is in, not during the transition. Failing to enter ends it.
        case entering
        case entered
    }

    var body: some View {
        let isPageFullscreen = windowModel.isPageFullscreen
        let isCoveredByPreview = windowModel.preview?.isPresentationReady == true && !windowModel.isPreviewDismissing
        let shouldReduceMotion = reduceMotion
        panes(isPageFullscreen: isPageFullscreen)
            // Recede the existing page without changing its native viewport or ownership.
            .visualEffect { content, geometry in
                content
                    .scaleEffect(x: isCoveredByPreview && !shouldReduceMotion ? max(0, geometry.size.width - 18) / max(1, geometry.size.width) : 1,
                                 y: isCoveredByPreview && !shouldReduceMotion ? max(0, geometry.size.height - 18) / max(1, geometry.size.height) : 1)
                    .opacity(isCoveredByPreview ? 0.3 : 1)
            }
            .animation(reduceMotion ? nil : .spring(response: isCoveredByPreview ? 0.225 : 0.245,
                                                   dampingFraction: isCoveredByPreview ? 0.895 : 0.865,
                                                   blendDuration: 0), value: isCoveredByPreview)
            .accessibilityHidden(windowModel.preview != nil)
            // A preview floats over the whole page area, whatever its panes.
            .overlay {
                if let preview = windowModel.preview {
                    PagePreviewOverlay(preview: preview)
                        .id(ObjectIdentifier(preview))
                }
            }
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
                GeometryReader { geometry in
                    let paneIDs = panes.map(\.id)
                    let room = max(0, geometry.size.width - BrowserWindowView.pageMargin * CGFloat(panes.count - 1))
                    let minimum = min(PaneCloseButton.clearance * 2, room / CGFloat(panes.count))
                    // Physical space may limit the reservation; keep the other panes' controls clear first.
                    let selectedMinimum = windowModel.isFindBarVisible && findBarRequiredWidth > 0 && panes.count > 1
                        ? min(max(minimum, findBarRequiredWidth + PaneCloseButton.clearance + 16), room - minimum * CGFloat(panes.count - 1))
                        : minimum
                    let minimums = paneIDs.map { $0 == windowModel.selectedTabID ? selectedMinimum : minimum }
                    let flexible = max(0, room - minimums.reduce(0, +))
                    let knownWeights = paneIDs.compactMap { paneWeights[$0] }.map { max(0, $0) }
                    let knownTotal = knownWeights.reduce(0, +)
                    let average = knownTotal / CGFloat(max(1, knownWeights.count))
                    let weights = knownTotal > 0 ? paneIDs.map { max(0, paneWeights[$0] ?? average) } : Array(repeating: CGFloat(1), count: panes.count)
                    let total = weights.reduce(0, +)
                    let proportions = total > 0 ? weights.map { $0 / total } : Array(repeating: 1 / CGFloat(panes.count), count: panes.count)
                    let widths = zip(minimums, proportions).map { minimum, proportion in minimum + flexible * proportion }
                    let resize: (Int, CGFloat) -> Void = { index, proposedWidth in
                        // A drag belongs to the exact pane order in which it began.
                        guard !windowModel.isPageFullscreen, windowModel.paneTabs.map(\.id) == paneIDs, flexible > 0 else { return }
                        let pairWidth = widths[index] + widths[index + 1]
                        let leadingWidth = min(max(proposedWidth, minimums[index]), pairWidth - minimums[index + 1])
                        var updated = paneWeights
                        for (id, proportion) in zip(paneIDs, proportions) { updated[id] = proportion }
                        updated[paneIDs[index]] = (leadingWidth - minimums[index]) / flexible
                        updated[paneIDs[index + 1]] = (pairWidth - leadingWidth - minimums[index + 1]) / flexible
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { paneWeights = updated }
                    }

                    HStack(spacing: 0) {
                        ForEach(Array(panes.enumerated()), id: \.element.id) { index, tab in
                            Group {
                                if windowModel.shows(tab) {
                                    PagePaneView(session: session, prompts: session.prompts, tab: tab, isSplit: panes.count > 1, isPageFullscreen: isPageFullscreen)
                                } else {
                                    ShownElsewherePaneView(tab: tab, isSplit: panes.count > 1)
                                }
                            }
                            .frame(width: widths[index])
                            // A pane appears and leaves at once, as a page does when another tab is selected.
                            .transition(.identity)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: PaneFramesKey.self, value: [PaneFrame(tabID: tab.id, frame: proxy.frame(in: .named(BrowserWindowView.coordinateSpace)))])
                            })

                            if index < panes.count - 1 {
                                SidebarResizeHandle(width: widths[index]) { resize(index, $0) }
                                    .frame(width: BrowserWindowView.pageMargin)
                                    .frame(maxHeight: .infinity)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(localized("Resize Split View"))
                                    .accessibilityValue(Text(Double(widths[index] / max(1, room)), format: .percent.precision(.fractionLength(0))))
                                    .accessibilityAdjustableAction { direction in
                                        switch direction {
                                        case .increment: resize(index, widths[index] + BrowserWindowView.pageMargin * 2)
                                        case .decrement: resize(index, widths[index] - BrowserWindowView.pageMargin * 2)
                                        @unknown default: break
                                        }
                                    }
                                    // Replacing the group cancels the old handle's drag origin.
                                    .id(paneIDs)
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .onPreferenceChange(PaneFramesKey.self) { sidebarDrag?.paneFrames = $0 }
        .onPreferenceChange(FindBarRequiredWidthKey.self) { measurement in
            let width = measurement.requiredWidth
            if windowModel.isFindBarVisible, width > findBarRequiredWidth { findBarRequiredWidth = width }
        }
        .onChange(of: windowModel.isFindBarVisible) { _, isVisible in
            if !isVisible { findBarRequiredWidth = 0 }
        }
    }
}

/// One tab's page in its rounded frame, with the crash notice and, for the selected tab, the internal page, the region capture overlay, the find bar, and the question popover, and above them the tab's prompt card, which waits while an internal page or the preview panel covers the page. In a split view, a click on the page selects its tab, the selected tab's pane has a ring in the space's tint, and each pane has a close control, which stays above the card, and the card leaves it room.
private struct PagePaneView: View {
    @ObservedObject var session: BrowserSession
    /// Observed so that VoiceOver leaves the page under a card.
    @ObservedObject var prompts: TabPromptQueue
    @EnvironmentObject private var windowModel: BrowserWindowModel
    /// Observed so that the pane shows the new view when the tab switches engines.
    @ObservedObject var tab: Tab
    let isSplit: Bool
    let isPageFullscreen: Bool
    @Environment(\.spaceTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelected: Bool { tab.id == windowModel.selectedTabID }
    private var cornerRadius: CGFloat { isPageFullscreen ? 0 : PageFrameShape.cornerRadius }
    /// Whether the region capture overlay covers the pane. The find bar, the question popover, and the close control then hide, so that they neither cover the overlay's hint nor take its drags.
    private var isCapturingRegion: Bool { isSelected && windowModel.regionCaptureTabID == tab.id && windowModel.internalPage == nil }

    var body: some View {
        let isOnScreen = windowModel.tabsOnScreen.contains { $0.id == tab.id }
        // The preview panel floats over every pane.
        let isCovered = (isSelected && windowModel.internalPage != nil) || windowModel.preview != nil
        let showsCard = PromptPresentation.shownPrompt(in: prompts, tabID: tab.id, isOnScreen: isOnScreen, isCovered: isCovered) != nil
        WebContentsHostView(contentView: tab.webContents.view, cornerRadius: cornerRadius, onClick: isSplit ? selectTab : nil, hidesPageFromAccessibility: showsCard || windowModel.preview != nil)
            .background(PageBackgroundView(isEmpty: false))
            .overlay { PageCrashNoticeView(tab: tab) }
            .overlay { if isSelected { InternalPageOverlay() } }
            .overlay {
                if isCapturingRegion {
                    CaptureRegionOverlay(windowModel: windowModel, pageView: tab.webContents.view, cornerRadius: cornerRadius)
                }
            }
            .overlay(frameBorder.allowsHitTesting(false))
            // An agent tab whose session's turn runs gets a thin frame in the margin around its page, outside the page area.
            .overlay {
                if !isPageFullscreen, let owner = tab.agentOwnerID.flatMap({ session.agents?.session(withID: $0) }) {
                    AgentActingFrame(owner: owner).allowsHitTesting(false)
                }
            }
            // The find bar and the question popover act on the selected tab, so they float over that pane's top trailing corner, the popover below the bar. In a narrow pane they keep clear of its leading edge and of a split view pane's close control. A region capture hides them without closing them, so that their fields do not take the focus again when it ends, and so does a prompt card, under which they wait, going and coming back with its dimming.
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    let hidesPanels = isCapturingRegion || showsCard
                    VStack(alignment: .trailing, spacing: 8) {
                        if windowModel.isFindBarVisible {
                            FindBarView()
                        }
                        PageQuestionLayer(session: session)
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    .padding(.leading, isSplit ? PaneCloseButton.clearance : 16)
                    .opacity(hidesPanels ? 0 : 1)
                    .allowsHitTesting(!hidesPanels)
                    .disabled(isCapturingRegion)
                    .accessibilityHidden(hidesPanels)
                    .animation(PromptMotion.scrim(reduceMotion: reduceMotion), value: showsCard)
                }
            }
            .overlay {
                PanePromptLayer(prompts: prompts, tab: tab, isOnScreen: isOnScreen, isFocusedPane: isSelected, isCovered: isCovered,
                                cornerRadius: cornerRadius, leadingClearance: isSplit ? PaneCloseButton.clearance : 0, selectPane: selectTab)
            }
            .overlay(alignment: .topLeading) {
                if isSplit, !isCapturingRegion {
                    PaneCloseButton { windowModel.closePane(tab) }
                        .padding(PaneCloseButton.inset)
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

/// The frame around an agent tab's page while its session's turn runs and the user has not taken the session over (docs/agents.md, Sidebar and attention): a 2-point ring in the space's tint, the color of a split view's focus ring, 2 points outside the page frame, in the window's margin, so it never covers the page.
private struct AgentActingFrame: View {
    @ObservedObject var owner: AgentSession
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        if owner.isTurnRunning, !owner.isTakenOver, !owner.hasEnded {
            PageFrameShape().inset(by: -3).stroke(theme.tint, lineWidth: 2)
                .accessibilityHidden(true)
        }
    }
}

/// Stands in for a pane whose tab another window shows, the selected tab's among them once another window took it (open decision 5). Show Other Window brings that window forward; Show Here selects the tab, which takes its page back to this window (window rule 2); a click elsewhere in the pane leaves it where it is. In a split view, the pane keeps its close control.
private struct ShownElsewherePaneView: View {
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @ObservedObject var tab: Tab
    let isSplit: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(tab.shownTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("This tab is shown in another window.", bundle: .module)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(localized("Show Other Window")) { windowModel.showWindowShowing(tab) }
                Button(localized("Show Here")) { windowModel.selectTab(tab.id) }
            }
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
                    .padding(PaneCloseButton.inset)
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
    /// The control's distance from the pane's top leading corner.
    static let inset: CGFloat = 6
    static let diameter: CGFloat = 20
    /// How far the control reaches from the pane's leading edge.
    static var reach: CGFloat { inset + diameter }
    /// The room that a prompt card and the find bar leave at the pane's leading edge: the control's reach and, past it, the gap the control keeps from the edge, so that neither touches the control or its shadow.
    static var clearance: CGFloat { reach + inset }

    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: Self.diameter, height: Self.diameter)
                // A solid background: a material over the engine's view cannot sample it.
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor)))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .help(localized("Remove from Split View"))
        .accessibilityLabel(localized("Remove from Split View"))
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
    @MainActor func splitDrop(of tab: Tab, at point: CGPoint, in windowModel: BrowserWindowModel) -> SplitDrop? {
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

/// Shows where a tab dragged over the page area opens in split view, over the half of the pane on the side it takes, in the current space's tint, as the focused pane's ring over the same pages.
struct SplitDropIndicator: View {
    @ObservedObject var sidebarDrag: SidebarDragState
    @Environment(\.spaceTheme) private var theme

    /// How far the indicator sits inside the half of the pane. Its corners are the pane's, less this, so they stay concentric with the pane's.
    static let inset: CGFloat = 4

    var body: some View {
        if let frame = sidebarDrag.splitDrop?.frame {
            let shape = RoundedRectangle(cornerRadius: PageFrameShape.cornerRadius - Self.inset, style: .continuous)
            shape
                .fill(theme.tint.opacity(0.15))
                .overlay(shape.strokeBorder(theme.tint.opacity(0.6), lineWidth: 2))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
