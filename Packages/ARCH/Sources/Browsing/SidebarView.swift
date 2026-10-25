// The sidebar's frame: its column, which the library pushes aside, the top row with the sidebar and navigation buttons, the swipe between space pages, the resize handle along its trailing edge, the fills of its controls, and the environment values its views share. `BrowserWindowView` places it in the window, docked or floating as a card.
import AppKit
import SwiftUI

/// Translucent fills for sidebar controls. They lighten the window material in both appearances instead of covering it with an opaque color.
enum SidebarFill {
    case field, hover, selected

    func color(in scheme: ColorScheme) -> Color {
        switch (self, scheme) {
        case (.field, .dark): return .white.opacity(0.07)
        case (.field, _): return .black.opacity(0.05)
        case (.hover, .dark): return .white.opacity(0.05)
        case (.hover, _): return .black.opacity(0.04)
        case (.selected, .dark): return .white.opacity(0.13)
        case (.selected, _): return .white.opacity(0.8)
        }
    }
}

struct SidebarView: View {
    static let defaultWidth: CGFloat = 250
    /// The top row needs about 235 points: the window buttons end 79 points in, and its four buttons, gaps, and spacer take 144 more inside the margins.
    static let minWidth: CGFloat = 240
    /// Leaves the page at least as wide as the sidebar in the smallest window.
    static let maxWidth: CGFloat = 400
    static let widthKey = "ARCHSidebarWidth"
    static func clampedWidth(_ width: Double) -> CGFloat { min(max(CGFloat(width), minWidth), maxWidth) }
    /// The margin between the sidebar's edges and its controls.
    static let inset: CGFloat = 6
    /// Spring that settles the space pages after a swipe or a change of space.
    static let pageSpring = Animation.spring(response: 0.35, dampingFraction: 0.88)

    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let windowButtons: WindowButtonMetrics
    /// Handles a swipe past the first space to open the library.
    var librarySwipe: SidebarSwipeHandlers?
    @Environment(\.sidebarWidth) private var width
    /// How far the space pages follow the fingers during a swipe, in points.
    @State private var swipeTranslation: CGFloat = 0
    @State private var swipePassesHalfway = false
    /// Set while a swipe moves the library instead of the space pages.
    @State private var isSwipingLibrary = false

    private var currentIndex: Int {
        session.spaces.firstIndex { $0.id == windowModel.currentSpaceID } ?? 0
    }

    /// Limits a swipe to one page and resists past the first and last spaces.
    private func pageTranslation(for travel: CGFloat) -> CGFloat {
        let hasPage = travel > 0 ? currentIndex > 0 : currentIndex < session.spaces.count - 1
        return hasPage ? max(-width, min(width, travel)) : travel / 4
    }

    private func swipeChanged(_ travel: CGFloat) {
        guard !windowModel.isLibraryVisible else { return }
        if let librarySwipe, isSwipingLibrary || (currentIndex == 0 && travel > 0) {
            isSwipingLibrary = true
            swipeTranslation = 0
            librarySwipe.changed(travel)
            return
        }
        swipeTranslation = pageTranslation(for: travel)
        let passesHalfway = abs(swipeTranslation) > width / 2
        if passesHalfway != swipePassesHalfway {
            swipePassesHalfway = passesHalfway
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Moves to the neighboring space when the swipe went far or fast enough, otherwise returns to the current one.
    private func swipeEnded(_ travel: CGFloat, velocity: CGFloat) {
        if isSwipingLibrary, let librarySwipe {
            isSwipingLibrary = false
            librarySwipe.ended(travel, velocity)
            return
        }
        // The library may have opened during the swipe; the pages go back to rest behind it.
        guard !windowModel.isLibraryVisible else {
            swipeTranslation = 0
            swipePassesHalfway = false
            return
        }
        let translation = pageTranslation(for: travel)
        let isFling = abs(velocity) > 300
        var target = currentIndex
        if translation < 0, translation < -width * 0.3 || (isFling && velocity < 0), currentIndex < session.spaces.count - 1 {
            target += 1
        } else if translation > 0, translation > width * 0.3 || (isFling && velocity > 0), currentIndex > 0 {
            target -= 1
        }
        swipePassesHalfway = false
        withAnimation(Self.pageSpring) {
            swipeTranslation = 0
            if target != currentIndex { windowModel.switchToSpace(session.spaces[target].id) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Swipes over the bottom bar stay with it, so its symbols can scroll when there are many.
            VStack(alignment: .leading, spacing: 8) {
                if let tab = windowModel.selectedTab {
                    SelectedTabHeaderView(session: session, tab: tab, windowButtons: windowButtons)
                } else {
                    // Without a tab the controls stay in place; the address pill opens a new tab.
                    SidebarTopRow(windowButtons: windowButtons)
                    AddressPillView(session: session, tab: nil)
                }
                // Space pages reach the sidebar's edges to slide in from outside. Clip before the negative margin, which would move the clip inward and cut off a lifted tab's shadow.
                VStack(alignment: .leading, spacing: 8) {
                    if !session.favorites(in: windowModel.personaID).isEmpty {
                        FavoritesGridView(session: session)
                            .padding(.horizontal, Self.inset)
                            .transition(.opacity)
                    }
                    PluginSidebarItemsView(plugins: windowModel.plugins)
                    SpacePagesView(session: session, translation: swipeTranslation)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 6)
                .clipped()
                .padding(.horizontal, -Self.inset)
                .modifier(SidebarDropTarget())
            }
            // The swipe area reaches the sidebar's edges and the gap above the bar. Disable it when the library pushes the sidebar aside, as it then extends over the page.
            .background(SpaceSwipeView(isEnabled: !windowModel.isLibraryVisible, onChange: swipeChanged, onEnd: swipeEnded).padding(.horizontal, -Self.inset).padding(.bottom, -8))
            SidebarBottomBar(session: session)
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 10)
        // Opening or closing the library by menu or shortcut releases it from any current swipe.
        .onChange(of: windowModel.isLibraryVisible) { isSwipingLibrary = false }
    }
}

/// Receives a swipe from the sidebar: travel while the fingers move, then travel and velocity when they lift.
struct SidebarSwipeHandlers {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void
}

/// The library opens to the sidebar's left and pushes it aside. When docked, the column widens by `libraryPeek` and the gap around the dividing line. The library takes the sidebar's width; the sidebar's first `libraryPeek` points stay visible, dimmed and still, until a click or swipe brings it back. When floating, the library fills the card.
struct SidebarColumn: View {
    /// About a quarter of the narrowest sidebar.
    static let libraryPeek: CGFloat = 60
    /// The space on each side of the line between the library and the sidebar, beyond their own margins.
    static let dividerMargin: CGFloat = 8

    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let windowButtons: WindowButtonMetrics
    let width: CGFloat
    var isFloating = false
    var onResize: (CGFloat) -> Void = { _ in }
    /// How far a swipe has opened the library, from 0 to its width, while the fingers are down.
    @State private var swipeReveal: CGFloat?

    private var libraryWidth: CGFloat { width }
    private var peek: CGFloat { isFloating ? 0 : Self.libraryPeek }
    private var gap: CGFloat { 2 * Self.dividerMargin }
    /// How far the library moves in: its width and the gap after it.
    private var travel: CGFloat { libraryWidth + gap }
    private var reveal: CGFloat { swipeReveal ?? (windowModel.isLibraryVisible ? travel : 0) }
    private var progress: CGFloat { reveal / travel }
    /// How much the docked column widens while the library is open.
    private var widening: CGFloat { isFloating ? 0 : gap + peek }

    var body: some View {
        HStack(spacing: 0) {
            LibraryPanel(session: session, windowButtons: windowButtons)
                .frame(width: libraryWidth)
                .allowsHitTesting(progress > 0)
                .accessibilityHidden(progress == 0)
            // The line sits in the middle of the gap, from below the window buttons' row to above the button row.
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
                .padding(.top, windowButtons.centerY + SidebarTopRow.height / 2 + 8)
                .padding(.bottom, 10 + 28 + 8)
                .frame(width: gap)
            SidebarView(session: session, windowButtons: windowButtons,
                        librarySwipe: SidebarSwipeHandlers(changed: { swipeReveal = min(travel, max(0, $0)) },
                                                           ended: { distance, velocity in finishLibrarySwipe(opens: distance > travel * 0.3 || velocity > 300) }))
                .frame(width: width)
                .opacity(1 - 0.5 * progress)
                .allowsHitTesting(progress == 0)
                .accessibilityHidden(progress > 0)
                .overlay {
                    if windowModel.isLibraryVisible, !isFloating {
                        Color.clear
                            .frame(width: peek)
                            .contentShape(Rectangle())
                            .onTapGesture { finishLibrarySwipe(opens: false) }
                            .accessibilityElement()
                            .accessibilityLabel("Show Sidebar")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { finishLibrarySwipe(opens: false) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
        }
        .offset(x: reveal - travel)
        .frame(width: width + widening * progress, alignment: .leading)
        .clipped()
        // Clicks reach only what the clip shows.
        .contentShape(Rectangle())
        // A swipe over the open library or displaced sidebar closes the library.
        .background(SpaceSwipeView(isEnabled: windowModel.isLibraryVisible,
                                   onChange: { distance in swipeReveal = min(travel, max(0, travel + distance)) },
                                   onEnd: { distance, velocity in finishLibrarySwipe(opens: !(distance < -travel * 0.3 || velocity < -300)) }))
        // The handle covers the gap between the sidebar's controls and the page, including the sidebar's margin and the gap outside it.
        .overlay(alignment: .trailing) {
            if progress == 0, !isFloating {
                SidebarResizeHandle(width: width, onResize: onResize)
                    .frame(width: BrowserWindowView.sidebarGap)
                    .offset(x: BrowserWindowView.sidebarGap - SidebarView.inset)
            }
        }
        .animation(SidebarView.pageSpring, value: windowModel.isLibraryVisible)
        .environment(\.sidebarWidth, width)
        .onChange(of: windowModel.isLibraryVisible) { swipeReveal = nil }
        // On a strong tint, the sidebar's text and icons may take the other appearance to stay readable.
        .modifier(SidebarAppearance())
    }

    private func finishLibrarySwipe(opens: Bool) {
        withAnimation(SidebarView.pageSpring) {
            swipeReveal = nil
            windowModel.isLibraryVisible = opens
        }
    }
}

// Observes the selected tab directly so the controls reflect navigation within the page.
struct SelectedTabHeaderView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    let windowButtons: WindowButtonMetrics

    var body: some View {
        SidebarTopRow(windowButtons: windowButtons, tab: tab)
        AddressPillView(session: session, tab: tab)
    }
}

/// The sidebar button and the navigation buttons, on the line of the window's traffic light buttons. In full screen, where those buttons hide, the sidebar button takes their place.
struct SidebarTopRow: View {
    static let height: CGFloat = 30

    @EnvironmentObject private var windowModel: BrowserWindowModel
    let windowButtons: WindowButtonMetrics
    var tab: Tab?

    var body: some View {
        HStack(spacing: 4) {
            SidebarIconButton(symbol: "sidebar.left", label: windowModel.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", action: windowModel.toggleSidebar)
            Spacer()
            SidebarIconButton(symbol: "chevron.left", label: "Back", action: windowModel.goBack).disabled(tab?.canGoBack != true)
            SidebarIconButton(symbol: "chevron.right", label: "Forward", action: windowModel.goForward).disabled(tab?.canGoForward != true)
            if tab?.isLoading == true {
                SidebarIconButton(symbol: "xmark", label: "Stop Loading", action: windowModel.stopLoading)
            } else {
                SidebarIconButton(symbol: "arrow.clockwise", label: "Reload", action: windowModel.reload).disabled(tab == nil)
            }
        }
        .frame(height: Self.height)
        // The sidebar's margin comes on top of this, so the row starts one margin past the last traffic light.
        .padding(.leading, windowButtons.trailingEdge ?? 0)
        .padding(.top, max(0, windowButtons.centerY - Self.height / 2))
    }
}

/// A borderless symbol button that shows a soft highlight under the pointer. `label` names it in its tooltip, after which comes its `shortcut` when it has one, and for VoiceOver.
struct SidebarIconButton: View {
    let symbol: String
    let label: String
    var shortcut: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }
}

private struct SidebarWidthKey: EnvironmentKey {
    static let defaultValue = SidebarView.defaultWidth
}

private struct SidebarIsFloatingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct IsDraggingTabKey: EnvironmentKey {
    static let defaultValue = false
}

private struct AddressPillPullKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

extension EnvironmentValues {
    /// The sidebar width used to lay out the space pages and bottom bar.
    var sidebarWidth: CGFloat {
        get { self[SidebarWidthKey.self] }
        set { self[SidebarWidthKey.self] = newValue }
    }

    /// Set inside the hidden sidebar while it floats over the page.
    var sidebarIsFloating: Bool {
        get { self[SidebarIsFloatingKey.self] }
        set { self[SidebarIsFloatingKey.self] = newValue }
    }

    /// Set in a space's tab list while one of its tabs is dragged.
    var isDraggingTab: Bool {
        get { self[IsDraggingTabKey.self] }
        set { self[IsDraggingTabKey.self] = newValue }
    }

    /// How far the address pill has moved toward the palette it opened. The pill is hidden while it is moved.
    var addressPillPull: CGSize {
        get { self[AddressPillPullKey.self] }
        set { self[AddressPillPullKey.self] = newValue }
    }
}

/// A strip along the sidebar's trailing edge that shows the resize pointer and reports the new width during a drag.
struct SidebarResizeHandle: NSViewRepresentable {
    let width: CGFloat
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.width = width
        view.onResize = onResize
    }

    final class HandleView: NSView {
        var width: CGFloat = 0
        var onResize: ((CGFloat) -> Void)?
        /// The starting position in the window and sidebar width.
        private var dragStart: (x: CGFloat, width: CGFloat)?

        // A drag here resizes the sidebar instead of moving the window.
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = (event.locationInWindow.x, width)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            onResize?(dragStart.width + event.locationInWindow.x - dragStart.x)
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
        }
    }
}
