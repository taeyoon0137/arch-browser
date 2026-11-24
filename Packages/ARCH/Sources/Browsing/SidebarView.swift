// The sidebar frame holds its column, top navigation row, space-page swipe, trailing resize handle, control fills, and shared environment values.
// The library pushes the column aside. `BrowserWindowView` places the sidebar in a window, docked or floating as a card.
import AppKit
import SwiftUI

/// Translucent fills for sidebar controls. They lighten the window material in both appearances instead of covering it with an opaque color. A row under the pointer takes `hover`; a small borderless button under the pointer takes `buttonHover`, which stays visible on a hovered or selected row, and one that is on, as the Library button while the library is open, `buttonOn`.
enum SidebarFill {
    case field, hover, selected, buttonHover, buttonOn

    func color(in scheme: ColorScheme) -> Color {
        switch (self, scheme) {
        case (.buttonHover, _): return .primary.opacity(0.08)
        case (.buttonOn, _): return .primary.opacity(0.1)
        case (.field, .dark): return .white.opacity(0.07)
        case (.field, _): return .black.opacity(0.05)
        case (.hover, .dark): return .white.opacity(0.05)
        case (.hover, _): return .black.opacity(0.04)
        case (.selected, .dark): return .white.opacity(0.13)
        case (.selected, _): return .white.opacity(0.8)
        }
    }
}

/// The opacity of the icon and title of a sidebar item whose page is not open, so open pages stand out: a tab without its page, as one restored from the last session before a window shows it or one unloaded since (bookmark rules 4 and 5), and a favorite without an open page.
enum SidebarDimming {
    static let unopened = 0.5
}

/// The sidebar of a main window: the top row, the space pages, and the bottom bar, with the library beside them. `BrowserWindowView` places it.
struct SidebarView: View {
    static let defaultWidth: CGFloat = 250
    /// The top row needs about 231 points: the window buttons end 79 points in, and its four buttons, gaps, spacer, and trailing inset take 140 more inside the margins.
    static let minWidth: CGFloat = 240
    /// Leaves the page at least as wide as the sidebar in the smallest window.
    static let maxWidth: CGFloat = 400
    static let widthKey = "ARCHSidebarWidth"
    static func clampedWidth(_ width: Double) -> CGFloat { min(max(CGFloat(width), minWidth), maxWidth) }
    /// The margin between the sidebar's edges and its controls.
    static let inset: CGFloat = 6
    /// The space between the sidebar's rows, such as below the top row and above the bottom bar, which the library and the line beside it repeat.
    static let rowSpacing: CGFloat = 8
    /// The margin below the bottom bar.
    static let bottomMargin: CGFloat = 10
    /// Spring of the sidebar's moves: the space pages after a swipe or a change of space, the sidebar sliding in or out, docked or as a card, the library, the page reader, and the window buttons' slide.
    static let pageSpring = Animation.spring(response: 0.35, dampingFraction: 0.88)
    /// How long a move with `pageSpring` takes to come to rest, for a change that waits until the move ends, such as the card giving way to the docked sidebar. Change it with the spring's response.
    static let pageSpringSettleDelay: TimeInterval = 0.4

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
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            // Swipes over the bottom bar stay with it, so its symbols can scroll when there are many.
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                if let tab = windowModel.selectedTab {
                    SelectedTabHeaderView(session: session, tab: tab, windowButtons: windowButtons)
                } else {
                    // Without a tab the controls stay in place; the address pill opens a new tab.
                    SidebarTopRow(windowButtons: windowButtons)
                    AddressPillView(session: session, tab: nil)
                }
                // Persona groups and their space pages reach the sidebar's edges. Clip before the negative margin, which would move the clip inward and cut off a lifted tab's shadow.
                SidebarSpaceContent(session: session, translation: swipeTranslation)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 6)
                .clipped()
                .padding(.horizontal, -Self.inset)
                .modifier(SidebarDropTarget())
            }
            // The swipe area reaches the sidebar's edges and the gap above the bar. Disable it when the library pushes the sidebar aside, as it then extends over the page.
            .background(SpaceSwipeView(isEnabled: !windowModel.isLibraryVisible, onChange: swipeChanged, onEnd: swipeEnded).padding(.horizontal, -Self.inset).padding(.bottom, -Self.rowSpacing))
            SidebarBottomBar(session: session)
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, Self.bottomMargin)
        // Opening or closing the library by menu or shortcut releases it from any current swipe.
        .onChange(of: windowModel.isLibraryVisible) { isSwipingLibrary = false }
    }
}

/// Each Persona shares one grid across its space pages. The grid stays fixed within that group and moves with the pages when another Persona comes into view.
struct SidebarSpaceContent: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    @Environment(\.sidebarWidth) private var width
    let translation: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
            let index = session.spaces.firstIndex { $0.id == windowModel.currentSpaceID } ?? 0
            let position = CGFloat(index) * width - translation
            HStack(alignment: .top, spacing: 0) {
                ForEach(session.personas) { persona in
                    let spaces = session.spaces(in: persona.id)
                    let start = session.spaces.firstIndex { $0.resolvedPersonaID == persona.id } ?? 0
                    let isCurrentPersona = persona.id == windowModel.personaID
                    let favorites = session.favorites(in: persona.id)
                    let hidesLastTile = !sidebarDrag.isSettling && favorites.count == 1
                        && sidebarDrag.item == .favorite(favorites[0].id) && sidebarDrag.favoriteGap == nil
                    VStack(alignment: .leading, spacing: 0) {
                        if let first = spaces.first {
                            FavoritesGridView(session: session, personaID: persona.id,
                                              spaceID: isCurrentPersona ? windowModel.currentSpaceID : first.id,
                                              viewport: isCurrentPersona ? viewport : .zero, availableHeight: proxy.size.height)
                                .padding(.horizontal, SidebarView.inset)
                                .padding(.bottom, favorites.isEmpty || hidesLastTile ? 0 : FavoriteTileLayout.gridHeaderSpacing + SidebarView.rowSpacing)
                                .frame(width: width)
                                // Follow the visible space within this Persona, stopping at either end of its group.
                                .modifier(PersonaGridOffset(position: position, start: CGFloat(start) * width, travel: CGFloat(max(0, spaces.count - 1)) * width))
                                .allowsHitTesting(isCurrentPersona)
                                .accessibilityHidden(!isCurrentPersona)
                        }
                        GeometryReader { page in
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(spaces) { space in
                                    let isCurrent = space.id == windowModel.currentSpaceID
                                    SpaceTabsView(session: session, space: space, pageHeight: page.size.height)
                                        .frame(width: width, alignment: .topLeading)
                                        // Clipping alone does not keep offscreen pages from receiving clicks or accessibility actions.
                                        .allowsHitTesting(isCurrent)
                                        .accessibilityElement(children: isCurrent ? .contain : .ignore)
                                        .accessibilityHidden(!isCurrent)
                                }
                            }
                        }
                    }
                    .animation(SidebarDragState.motion, value: session.favorites(in: persona.id).map(\.id))
                    .frame(width: CGFloat(spaces.count) * width, alignment: .leading)
                }
            }
            .onPreferenceChange(FavoriteBarFramesKey.self) { sidebarDrag.favoriteBarFrames = $0 }
            .offset(x: -position)
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            .animation(SidebarView.pageSpring, value: windowModel.currentSpaceID)
        }
    }
}

/// Clamp the animated page position so a multi-space switch keeps the grid fixed until the viewport reaches its Persona's edge.
private struct PersonaGridOffset: GeometryEffect {
    var position: CGFloat
    let start: CGFloat
    let travel: CGFloat

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: min(max(0, position - start), travel), y: 0))
    }
}

/// Receives a swipe from the sidebar: travel while the fingers move, then travel and velocity when they lift.
struct SidebarSwipeHandlers {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void
}

/// The library opens to the sidebar's left and pushes it aside. When docked, the column draws `libraryWidening` past its own width, the gap around the dividing line and `libraryPeek`, while it keeps the sidebar's width in the window's layout: the page keeps its size and moves aside by that distance (`BrowserWindowView`). The library takes the sidebar's width; the sidebar's first `libraryPeek` points stay visible, dimmed and still, as does the page, until a click on either or a swipe brings them back. When floating, the library fills the card.
struct SidebarColumn: View {
    /// About a quarter of the narrowest sidebar.
    static let libraryPeek: CGFloat = 60
    /// The space on each side of the line between the library and the sidebar, beyond their own margins.
    static let dividerMargin: CGFloat = 8
    /// How far the docked column reaches past its width while the library is open, which is how far the page moves aside.
    static let libraryWidening: CGFloat = 2 * dividerMargin + libraryPeek
    /// How much the open library dims what it pushes aside: the sidebar's visible part and the page.
    static let displacedDimming: Double = 0.5

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
    private var widening: CGFloat { isFloating ? 0 : Self.libraryWidening }

    var body: some View {
        HStack(spacing: 0) {
            LibraryPanel(session: session, windowButtons: windowButtons)
                .frame(width: libraryWidth)
                .allowsHitTesting(progress > 0)
                .accessibilityHidden(progress == 0)
            // The line sits in the middle of the gap, from below the window buttons' row to above the bottom bar, at the sidebar's spacing from each.
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
                .padding(.top, SidebarTopRow.topPadding(below: windowButtons) + SidebarTopRow.height + SidebarView.rowSpacing)
                .padding(.bottom, SidebarView.bottomMargin + SidebarBottomBar.height + SidebarView.rowSpacing)
                .frame(width: gap)
            SidebarView(session: session, windowButtons: windowButtons,
                        librarySwipe: SidebarSwipeHandlers(changed: { swipeReveal = min(travel, max(0, $0)) },
                                                           ended: { distance, velocity in finishLibrarySwipe(opens: distance > travel * 0.3 || velocity > 300) }))
                .frame(width: width)
                .environment(\.libraryReveal, progress)
                .opacity(1 - Self.displacedDimming * progress)
                .allowsHitTesting(progress == 0)
                .accessibilityHidden(progress > 0)
                .overlay {
                    if windowModel.isLibraryVisible, !isFloating {
                        Color.clear
                            .frame(width: peek)
                            .contentShape(Rectangle())
                            .onTapGesture { finishLibrarySwipe(opens: false) }
                            .accessibilityElement()
                            .accessibilityLabel(localized("Show Sidebar"))
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
        // The window lays the column out at the sidebar's width; the open library's widening draws past it, where the page has moved aside.
        .frame(width: width, alignment: .leading)
        // While fingers move the library, the page follows them; otherwise it follows `isLibraryVisible`.
        .preference(key: LibrarySwipePushKey.self, value: isFloating ? nil : swipeReveal.map { widening * $0 / travel })
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

/// How far a swipe that moves the docked library has pushed the page aside, or nil while no swipe moves it.
struct LibrarySwipePushKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// The sidebar's top row and address pill for the selected tab. It observes the tab directly, so the controls follow navigation within the page.
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

    /// The space above the row, which centers it on the window buttons. The library and the small window's top row keep the same line.
    static func topPadding(below windowButtons: WindowButtonMetrics) -> CGFloat {
        max(0, windowButtons.centerY - height / 2)
    }

    @EnvironmentObject private var windowModel: BrowserWindowModel
    let windowButtons: WindowButtonMetrics
    var tab: Tab?

    var body: some View {
        HStack(spacing: 4) {
            SidebarIconButton(symbol: "sidebar.left", label: windowModel.isSidebarVisible ? localized("Hide Sidebar") : localized("Show Sidebar"), shortcut: shortcut("toggleSidebar"), action: windowModel.toggleSidebar)
            Spacer()
            // The navigation buttons touch and end 4 points in, as the address pill's buttons below do, so the two rows' buttons line up.
            HStack(spacing: 0) {
                SidebarIconButton(symbol: "chevron.left", label: localized("Back"), shortcut: shortcut("goBack"), action: windowModel.goBack).disabled(tab?.canGoBack != true)
                SidebarIconButton(symbol: "chevron.right", label: localized("Forward"), shortcut: shortcut("goForward"), action: windowModel.goForward).disabled(tab?.canGoForward != true)
                if tab?.isLoading == true {
                    SidebarIconButton(symbol: "xmark", label: localized("Stop Loading"), shortcut: shortcut("stopLoading"), action: windowModel.stopLoading)
                } else {
                    // Disabled where Reload Page is, as under an internal page, which it does not reach.
                    SidebarIconButton(symbol: "arrow.clockwise", label: localized("Reload"), shortcut: shortcut("reload"), action: windowModel.reload).disabled(!windowModel.canReload)
                }
            }
        }
        .frame(height: Self.height)
        // The sidebar's margin comes on top of this, so the row starts one margin past the last traffic light.
        .padding(.leading, windowButtons.trailingEdge ?? 0)
        .padding(.trailing, 4)
        .padding(.top, Self.topPadding(below: windowButtons))
    }

    private func shortcut(_ action: String) -> String? { windowModel.session.menuShortcut(action) }
}

/// A borderless symbol button that shows a soft highlight under the pointer. `label` names it in its tooltip, after which comes its `shortcut` when it has one, and for VoiceOver.
struct SidebarIconButton: View {
    let symbol: String
    let label: String
    var shortcut: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering && isEnabled ? SidebarFill.buttonHover.color(in: colorScheme) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }
}

/// The environment key behind `sidebarWidth`.
private struct SidebarWidthKey: EnvironmentKey {
    static let defaultValue = SidebarView.defaultWidth
}

/// The environment key behind `sidebarIsFloating`.
private struct SidebarIsFloatingKey: EnvironmentKey {
    static let defaultValue = false
}

/// The environment key behind `isDraggingTab`.
private struct IsDraggingTabKey: EnvironmentKey {
    static let defaultValue = false
}

/// The environment key behind `addressPillPull`.
private struct AddressPillPullKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

/// The environment key behind `libraryReveal`.
private struct LibraryRevealKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
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

    /// Set in a space's tab list while one of its tab or folder rows is dragged, and on the lifted row.
    var isDraggingTab: Bool {
        get { self[IsDraggingTabKey.self] }
        set { self[IsDraggingTabKey.self] = newValue }
    }

    /// How far the address pill has moved toward the palette it opened. The pill is hidden while it is moved.
    var addressPillPull: CGSize {
        get { self[AddressPillPullKey.self] }
        set { self[AddressPillPullKey.self] = newValue }
    }

    /// How far the library has pushed the sidebar aside, from 0 when closed to 1 when open, following a swipe.
    var libraryReveal: CGFloat {
        get { self[LibraryRevealKey.self] }
        set { self[LibraryRevealKey.self] = newValue }
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

    /// The view of `SidebarResizeHandle`: it shows the resize pointer and turns a drag into new widths for `onResize`.
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
