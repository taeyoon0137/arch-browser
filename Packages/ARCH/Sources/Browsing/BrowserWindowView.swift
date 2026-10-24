// Main window content. The system's translucent window material fills the window with a wash of the current space's tint (`SpaceTheme.swift`). The sidebar sits over it and contains navigation, the address field, favorites, the current space's tabs or the library, and the library button with the space switcher. The page area fills the remaining space with nothing above it: the selected tab's page, or the split view it belongs to (`SplitView.swift`).
import AppKit
import ARCHEngine
import SwiftUI

public struct BrowserWindowView: View {
    @ObservedObject var session: BrowserSession
    @State private var windowButtons = WindowButtonMetrics()
    /// The displayed palette mode. It stays set while the palette closes because removal transitions do not run in this window. A state change fades out the palette and its dimming, then the window removes both.
    @State private var shownPaletteMode: CommandPaletteMode?
    @State private var isPaletteLeaving = false
    /// Set after the hidden warm-up palette is drawn.
    @State private var isPaletteWarm = false
    /// The palette's entry motion, fixed when it opens.
    @State private var paletteMotion = PaletteMotion()
    /// How far the address pill's contents have moved toward the palette.
    @State private var addressPillPull = CGSize.zero
    /// The address pill's frame in the window.
    @State private var addressPillFrame: CGRect?
    @State private var windowSize = CGSize.zero
    /// The sidebar's width, set by dragging its trailing edge.
    @AppStorage(SidebarView.widthKey) private var sidebarWidth = Double(SidebarView.defaultWidth)
    /// Set while the hidden sidebar floats over the page.
    @State private var isSidebarPeeking = false
    /// Set while the card docks: it stays above the narrowing page, then gives way to the docked sidebar beneath it.
    @State private var isCardDocking = false
    /// The next check of whether the floating sidebar should stay visible.
    @State private var peekCheck: DispatchWorkItem?
    /// The window's child windows when the card appeared or the window last changed full screen, such as the full screen toolbar's. Only child windows opened after that, like the card's popovers, keep the card visible.
    @State private var childWindowsBeforePeek: Set<ObjectIdentifier> = []
    @State private var windowReference = WindowReference()
    @StateObject private var tabDrag = TabDragState()
    /// Set when the window entered full screen for a page, so that it leaves full screen again with the page.
    @State private var enteredFullScreenForPage = false

    public init(session: BrowserSession) {
        self.session = session
    }

    /// The margin between the page and the window's edges.
    static let pageMargin: CGFloat = 8
    /// The space between the sidebar's controls and the page.
    static let sidebarGap: CGFloat = 8
    /// The window's coordinate space, shared by the tab rows and the lifted row that follows a drag.
    static let coordinateSpace = "BrowserWindow"
    /// The floating card's corners match the window's own 16-point corners rather than the page's.
    static let cardCornerRadius: CGFloat = 16

    /// While the selected tab's page is in fullscreen, it fills the window without the sidebar or margins.
    private var isPageFullscreen: Bool { session.fullscreenTabID != nil && session.fullscreenTabID == session.selectedTabID }

    /// The sidebar's own margin is part of the gap beside it.
    private var pageMargins: EdgeInsets {
        EdgeInsets(top: Self.pageMargin, leading: session.isSidebarVisible ? Self.sidebarGap - SidebarView.inset : Self.pageMargin, bottom: Self.pageMargin, trailing: Self.pageMargin)
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if session.isSidebarVisible, !isPageFullscreen {
                    SidebarColumn(session: session, windowButtons: windowButtons, width: SidebarView.clampedWidth(sidebarWidth)) {
                        sidebarWidth = Double(SidebarView.clampedWidth($0))
                    }
                    // Docking the floating card keeps the sidebar where the card was; only the page resizes.
                    .transition(isSidebarPeeking ? .identity : .move(edge: .leading))
                }
                PageAreaView(session: session, tabDrag: tabDrag, isPageFullscreen: isPageFullscreen)
                    .padding(isPageFullscreen ? EdgeInsets() : pageMargins)
                    .modifier(DevToolsDockSpace(dock: session.devToolsDock, isHidden: isPageFullscreen, margins: pageMargins))
                if !isPageFullscreen {
                    PageReaderColumn(session: session, assistant: session.pageAssistant)
                }
            }
            if !session.isSidebarVisible || isSidebarPeeking, !isPageFullscreen {
                peekingSidebar
            }
            SplitDropIndicator(tabDrag: tabDrag)
            TabDragLayer(session: session, tabDrag: tabDrag)
                .modifier(SidebarAppearance())
            SidebarItemDragLayer(session: session, tabDrag: tabDrag)
                .modifier(SidebarAppearance())
            if shownPaletteMode != nil {
                Color.black.opacity(isPaletteLeaving ? 0 : 0.15)
                    .onTapGesture { session.dismissCommandPalette() }
                    .transition(.opacity)
            }
            // Drawing a hidden palette once at launch builds the text field, material, and fonts before the first visible palette opens. Otherwise, that palette would appear only after its arrival animation ends.
            if !isPaletteWarm {
                CommandPaletteView(session: session, mode: .newTab, isWarmUp: true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isPaletteWarm = true } }
            }
            if let mode = shownPaletteMode {
                // Each opening gets a fresh view, with reset text and a focused field, even if the previous palette is still leaving.
                CommandPaletteView(session: session, mode: mode, isLeaving: isPaletteLeaving, arrivalOffset: paletteMotion.arrival,
                                   onArrival: { addressPillPull = paletteMotion.pull })
                    .id(session.commandPaletteGeneration)
            }
            if session.isTabSwitcherVisible {
                TabSwitcherView(session: session)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .environmentObject(tabDrag)
        .environment(\.addressPillPull, addressPillPull)
        .onPreferenceChange(AddressPillFrameKey.self) { addressPillFrame = $0 }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { windowSize = proxy.size }
                .onChange(of: proxy.size) { windowSize = $0 }
        })
        .onAppear { shownPaletteMode = session.commandPaletteMode }
        .onChange(of: session.commandPaletteMode) { mode in
            guard mode == nil else {
                isPaletteLeaving = false
                paletteMotion = PaletteMotion(origin: session.commandPaletteOrigin, pill: addressPillFrame, windowWidth: windowSize.width)
                if paletteMotion.pull == .zero { withAnimation(.paletteIn(from: .addressPill)) { addressPillPull = .zero } }
                return withAnimation(.paletteIn(from: session.commandPaletteOrigin)) { shownPaletteMode = mode }
            }
            withAnimation(.paletteOut) { isPaletteLeaving = true }
            // The pill's contents return as the palette leaves.
            withAnimation(.paletteIn(from: .addressPill)) { addressPillPull = .zero }
            let generation = session.commandPaletteGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Animation.paletteOutDuration) {
                // A palette reopened during this delay has a new generation and stays until it finishes closing.
                guard session.commandPaletteGeneration == generation else { return }
                shownPaletteMode = nil
                isPaletteLeaving = false
            }
        }
        .background(SpaceBackgroundView())
        .modifier(SpaceThemeModifier(tint: session.currentSpace.tint))
        .background(WindowButtonsReader { windowButtons = $0 })
        // Showing, hiding, or pushing the sidebar aside for the library slides it and resizes the page.
        .animation(SidebarView.pageSpring, value: session.isSidebarVisible)
        .animation(SidebarView.pageSpring, value: session.isLibraryVisible)
        // The window buttons slide away with the sidebar and return with it or with the card. Full screen uses its own buttons.
        .background(WindowButtonsVisibility(isHidden: windowButtons.trailingEdge != nil && !session.isSidebarVisible && !isSidebarPeeking,
                                            slideDistance: windowButtons.trailingEdge == nil ? nil : SidebarView.clampedWidth(sidebarWidth) + Self.pageMargin,
                                            reference: windowReference))
        // A page that enters fullscreen takes the window into full screen and leaves it with the page; leaving the window's full screen ends the page's.
        .onChange(of: isPageFullscreen) { isFullscreen in
            guard let window = windowReference.window else { return }
            let isWindowFullScreen = window.styleMask.contains(.fullScreen)
            if isFullscreen, !isWindowFullScreen {
                enteredFullScreenForPage = true
                window.toggleFullScreen(nil)
            } else if !isFullscreen, enteredFullScreenForPage {
                enteredFullScreenForPage = false
                if isWindowFullScreen { window.toggleFullScreen(nil) }
            }
        }
        // Full screen adds or removes the toolbar's child window, which must not hold the card open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            if notification.object as? NSWindow === windowReference.window { recordChildWindows() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard notification.object as? NSWindow === windowReference.window else { return }
            recordChildWindows()
            enteredFullScreenForPage = false
            if isPageFullscreen { session.exitPageFullscreen() }
        }
        // Hiding the sidebar only slides it away; the card appears when the pointer next reaches the window's edge.
        .onChange(of: session.isSidebarVisible) { isVisible in
            peekCheck?.cancel()
            guard isVisible, isSidebarPeeking else { return isSidebarPeeking = false }
            withAnimation(SidebarView.pageSpring) { isCardDocking = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isSidebarPeeking = false
                    isCardDocking = false
                }
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 800, minHeight: 500)
    }

    /// A strip along the window's leading edge reveals the hidden sidebar as a card over the page.
    private var peekingSidebar: some View {
        let width = SidebarView.clampedWidth(sidebarWidth)
        // At rest the window buttons keep their place. The card starts one sidebar margin above their row, which shifts by the card's offset. While docking, the card takes the docked sidebar's metrics.
        let hasButtons = windowButtons.trailingEdge != nil
        let leading = isCardDocking ? 0 : Self.pageMargin
        let top = hasButtons ? max(0, windowButtons.centerY - SidebarTopRow.height / 2 - SidebarView.inset) : leading
        let buttons = hasButtons ? WindowButtonMetrics(centerY: windowButtons.centerY - top, trailingEdge: windowButtons.trailingEdge.map { $0 - leading }) : windowButtons
        return ZStack(alignment: .leading) {
            Color.clear
                .frame(width: Self.pageMargin)
                .contentShape(Rectangle())
                .onHover { if $0 { peekSidebar() } }
                // A drag from another app gets no hover, so its arrival shows the card for the drop.
                .onDrop(of: SidebarDropTarget.types, isTargeted: Binding(get: { false }, set: { if $0 { peekSidebar() } })) { _ in false }
            if isSidebarPeeking {
                // While docking, the card moves to the docked sidebar's place and loses its shadow and edge.
                SidebarColumn(session: session, windowButtons: buttons, width: width, isFloating: true)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(isCardDocking ? 0 : 0.25), radius: 16, y: 4)
                            SpaceBackgroundView(cornerRadius: Self.cardCornerRadius)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(isCardDocking ? 0 : 0.08)).allowsHitTesting(false))
                    .contentShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
                    .padding(EdgeInsets(top: top, leading: leading, bottom: leading, trailing: 0))
                    .environment(\.sidebarWidth, width)
                    .environment(\.sidebarIsFloating, true)
                    // The window buttons travel the same distance.
                    .transition(.offset(x: -(width + Self.pageMargin)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func peekSidebar() {
        guard !session.isSidebarVisible else { return }
        peekCheck?.cancel()
        if !isSidebarPeeking {
            recordChildWindows()
            withAnimation(SidebarView.pageSpring) { isSidebarPeeking = true }
        }
        scheduleCheckOfPeek()
    }

    private func recordChildWindows() {
        childWindowsBeforePeek = Set((windowReference.window?.childWindows ?? []).map(ObjectIdentifier.init))
    }

    // Check rather than track the pointer: a card sliding under it gets no hover until the pointer leaves.
    private func scheduleCheckOfPeek() {
        let work = DispatchWorkItem { checkPeek() }
        peekCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Keeps the card visible while hovered, while its text is edited, while one of its tabs, favorites, or space symbols is dragged, or while its menu, popover, sheet, or the command palette is open. Child windows that were there before, and the docked developer tools, do not count.
    private func checkPeek() {
        let window = windowReference.window
        let hasOpenChild = window?.attachedSheet != nil
            || (window?.childWindows ?? []).contains { $0.isVisible && $0 !== session.devToolsDock.window && !childWindowsBeforePeek.contains(ObjectIdentifier($0)) }
        let isEditingText = session.renamingSpaceID != nil || session.renamingTabID != nil || session.renamingFolderID != nil || window?.firstResponder is NSText
        let isInUse = isPointerOverSidebar || isEditingText || session.commandPaletteMode != nil || tabDrag.item != nil || RunLoop.main.currentMode == .eventTracking || hasOpenChild
        if isInUse { return scheduleCheckOfPeek() }
        withAnimation(SidebarView.pageSpring) { isSidebarPeeking = false }
        // Close the card's library after the card disappears, so the card reopens showing the sidebar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !session.isSidebarVisible, !isSidebarPeeking, session.isLibraryVisible else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { session.isLibraryVisible = false }
        }
    }

    /// Whether the pointer is inside the window over the sidebar's area along its leading edge.
    private var isPointerOverSidebar: Bool {
        guard let window = windowReference.window, let content = window.contentView else { return false }
        let point = window.mouseLocationOutsideOfEventStream
        return point.x >= 0 && point.x <= Self.pageMargin + SidebarView.clampedWidth(sidebarWidth) && point.y >= 0 && point.y <= content.bounds.height
    }
}

/// Holds the window for code outside view updates.
final class WindowReference {
    weak var window: NSWindow?
}

/// Shows or hides the window's close, minimize, and zoom buttons and records the window in `reference`. On macOS 15 and later, the buttons use the sidebar's spring to slide `slideDistance` points toward the leading side as they hide and back as they appear. At rest, they stay where AppKit placed them.
struct WindowButtonsVisibility: NSViewRepresentable {
    let isHidden: Bool
    /// `nil` shows and hides the buttons in place.
    let slideDistance: CGFloat?
    let reference: WindowReference

    private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    final class Coordinator {
        var isHidden: Bool?
        /// The buttons' resting positions, recorded while they slide.
        var restingOrigins: [NSWindow.ButtonType: NSPoint] = [:]
        /// Counts slides so an earlier slide's completion does not affect a later slide.
        var generation = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let isHidden = isHidden
        let slideDistance = slideDistance
        let reference = reference
        let coordinator = context.coordinator
        // The view has no window during its first update.
        DispatchQueue.main.async {
            reference.window = view.window
            guard let window = view.window else { return }
            let buttons = Self.types.compactMap { type in window.standardWindowButton(type).map { (type, $0) } }
            let wasHidden = coordinator.isHidden
            coordinator.isHidden = isHidden
            // An update that changes nothing does not interrupt a slide.
            if wasHidden == isHidden, slideDistance != nil, !coordinator.restingOrigins.isEmpty { return }
            guard let wasHidden, wasHidden != isHidden, let distance = slideDistance, #available(macOS 15, *) else {
                // A slide in progress must not apply its final state afterwards.
                coordinator.generation += 1
                for (type, button) in buttons {
                    if let origin = coordinator.restingOrigins[type] { button.setFrameOrigin(origin) }
                    button.isHidden = isHidden
                }
                coordinator.restingOrigins = [:]
                return
            }
            if coordinator.restingOrigins.isEmpty {
                for (type, button) in buttons { coordinator.restingOrigins[type] = button.frame.origin }
            }
            coordinator.generation += 1
            let generation = coordinator.generation
            let origins = coordinator.restingOrigins
            func origin(of type: NSWindow.ButtonType, hidden: Bool) -> NSPoint? {
                origins[type].map { hidden ? NSPoint(x: $0.x - distance, y: $0.y) : $0 }
            }
            // Appearing buttons start out of sight. Showing a button lays out the title bar again and resets every button's position, so they move only after all are shown.
            let appearing = buttons.filter { !isHidden && $0.1.isHidden }
            appearing.forEach { $0.1.isHidden = false }
            for (type, button) in appearing {
                if let start = origin(of: type, hidden: true) { button.setFrameOrigin(start) }
            }
            NSAnimationContext.animate(SidebarView.pageSpring) {
                for (type, button) in buttons {
                    if let end = origin(of: type, hidden: isHidden) { button.animator().setFrameOrigin(end) }
                }
            } completion: {
                guard coordinator.generation == generation else { return }
                for (type, button) in buttons {
                    button.isHidden = isHidden
                    if let rest = origins[type] { button.setFrameOrigin(rest) }
                }
                coordinator.restingOrigins = [:]
                // A resize during the slide measured the buttons away from their resting positions.
                NotificationCenter.default.post(name: WindowButtonsReaderView.buttonsDidSettleNotification, object: window)
            }
        }
    }
}

/// The rounded frame of the page, concentric with the window's corner (about 17 points with the unified toolbar) 8 points away. `WebContentsHostView` clips the engine's view with the same radius.
struct PageFrameShape: InsettableShape {
    static let cornerRadius: CGFloat = 9
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: Self.cornerRadius - insetAmount, style: .continuous).path(in: rect.insetBy(dx: insetAmount, dy: insetAmount))
    }

    func inset(by amount: CGFloat) -> PageFrameShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// Shows the system's translucent window material, the one Apple's own sidebars use, under a wash of the current space's tint at the theme's strength.
struct SpaceBackgroundView: View {
    var cornerRadius: CGFloat = 0
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        ZStack {
            WindowMaterialView(cornerRadius: cornerRadius)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [theme.tint.opacity(theme.strength.opacities.start), theme.tint.opacity(theme.strength.opacities.end)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .animation(.easeInOut(duration: 0.25), value: theme)
    }
}

/// Blends with what lies behind the window and turns opaque while the window is inactive, as the system's sidebars do.
struct WindowMaterialView: NSViewRepresentable {
    var material = NSVisualEffectView.Material.sidebar
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.layer?.cornerRadius = cornerRadius
    }
}

/// Covers a page whose process quit and did not come back, with a way to load it again.
struct PageCrashNoticeView: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.hasCrashed {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("This page stopped working")
                    .font(.system(size: 15, weight: .semibold))
                Text("Reload to open it again.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button("Reload", action: tab.reloadAfterCrash)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PageFrameShape().fill(Color(nsColor: .windowBackgroundColor)))
        }
    }
}

/// Fills the page frame: the window background under a page, or, with no tab open, the window material and space tint, slightly darker than the sidebar.
struct PageBackgroundView: View {
    let isEmpty: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isEmpty {
            PageFrameShape().fill(Color.black.opacity(colorScheme == .dark ? 0.12 : 0.05))
        } else {
            PageFrameShape().fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }
}

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
        session.spaces.firstIndex { $0.id == session.currentSpaceID } ?? 0
    }

    /// Limits a swipe to one page and resists past the first and last spaces.
    private func pageTranslation(for travel: CGFloat) -> CGFloat {
        let hasPage = travel > 0 ? currentIndex > 0 : currentIndex < session.spaces.count - 1
        return hasPage ? max(-width, min(width, travel)) : travel / 4
    }

    private func swipeChanged(_ travel: CGFloat) {
        guard !session.isLibraryVisible else { return }
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
        guard !session.isLibraryVisible else {
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
            if target != currentIndex { session.switchToSpace(session.spaces[target].id) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Swipes over the bottom bar stay with it, so its symbols can scroll when there are many.
            VStack(alignment: .leading, spacing: 8) {
                if let tab = session.selectedTab {
                    SelectedTabHeaderView(session: session, tab: tab, windowButtons: windowButtons)
                } else {
                    // Without a tab the controls stay in place; the address pill opens a new tab.
                    SidebarTopRow(session: session, windowButtons: windowButtons)
                    AddressPillView(session: session, tab: nil)
                }
                // Space pages reach the sidebar's edges to slide in from outside. Clip before the negative margin, which would move the clip inward and cut off a lifted tab's shadow.
                VStack(alignment: .leading, spacing: 8) {
                    if !session.favorites.isEmpty {
                        FavoritesGridView(session: session)
                            .padding(.horizontal, Self.inset)
                    }
                    SpacePagesView(session: session, translation: swipeTranslation)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 6)
                .clipped()
                .padding(.horizontal, -Self.inset)
                .modifier(SidebarDropTarget(session: session))
            }
            // The swipe area reaches the sidebar's edges and the gap above the bar. Disable it when the library pushes the sidebar aside, as it then extends over the page.
            .background(SpaceSwipeView(isEnabled: !session.isLibraryVisible, onChange: swipeChanged, onEnd: swipeEnded).padding(.horizontal, -Self.inset).padding(.bottom, -8))
            SidebarBottomBar(session: session)
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 10)
        // Opening or closing the library by menu or shortcut releases it from any current swipe.
        .onChange(of: session.isLibraryVisible) { _ in isSwipingLibrary = false }
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
    private var reveal: CGFloat { swipeReveal ?? (session.isLibraryVisible ? travel : 0) }
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
                    if session.isLibraryVisible, !isFloating {
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
        .background(SpaceSwipeView(isEnabled: session.isLibraryVisible,
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
        .animation(SidebarView.pageSpring, value: session.isLibraryVisible)
        .environment(\.sidebarWidth, width)
        .onChange(of: session.isLibraryVisible) { _ in swipeReveal = nil }
        // On a strong tint, the sidebar's text and icons may take the other appearance to stay readable.
        .modifier(SidebarAppearance())
    }

    private func finishLibrarySwipe(opens: Bool) {
        withAnimation(SidebarView.pageSpring) {
            swipeReveal = nil
            session.isLibraryVisible = opens
        }
    }
}

// Observes the selected tab directly so the controls reflect navigation within the page.
struct SelectedTabHeaderView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    let windowButtons: WindowButtonMetrics

    var body: some View {
        SidebarTopRow(session: session, windowButtons: windowButtons, tab: tab)
        AddressPillView(session: session, tab: tab)
    }
}

/// The sidebar button and the navigation buttons, on the line of the window's traffic light buttons. In full screen, where those buttons hide, the sidebar button takes their place.
struct SidebarTopRow: View {
    static let height: CGFloat = 30

    @ObservedObject var session: BrowserSession
    let windowButtons: WindowButtonMetrics
    var tab: Tab?

    var body: some View {
        HStack(spacing: 4) {
            SidebarIconButton(symbol: "sidebar.left", label: session.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", action: session.toggleSidebar)
            Spacer()
            SidebarIconButton(symbol: "chevron.left", label: "Back", action: session.goBack).disabled(tab?.canGoBack != true)
            SidebarIconButton(symbol: "chevron.right", label: "Forward", action: session.goForward).disabled(tab?.canGoForward != true)
            if tab?.isLoading == true {
                SidebarIconButton(symbol: "xmark", label: "Stop Loading", action: session.stopLoading)
            } else {
                SidebarIconButton(symbol: "arrow.clockwise", label: "Reload", action: session.reload).disabled(tab == nil)
            }
        }
        .frame(height: Self.height)
        // The sidebar's margin comes on top of this, so the row starts one margin past the last traffic light.
        .padding(.leading, windowButtons.trailingEdge ?? 0)
        .padding(.top, max(0, windowButtons.centerY - Self.height / 2))
    }
}

/// A borderless symbol button that shows a soft highlight under the pointer. `label` names it in its tooltip and for VoiceOver.
struct SidebarIconButton: View {
    let symbol: String
    let label: String
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
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Shows the site's host. Clicking it opens the command palette with the full address, or for a new tab when no tab is open. The buttons at its end share the page and open the site settings. While the palette it opened is visible, the pill's contents move out toward it.
struct AddressPillView: View {
    @ObservedObject var session: BrowserSession
    /// `nil` when no tab is open.
    let tab: Tab?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.addressPillPull) private var pull
    @State private var isShowingSiteSettings = false

    private var url: URL? { tab?.url }

    /// The site's host, a local file's name, or the whole address of a page without a host, such as `about:blank`.
    private var host: String {
        if let page = session.internalPage { return page.address }
        guard let url else { return "Search or enter address" }
        if url.isFileURL { return url.lastPathComponent }
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var symbol: String {
        if session.internalPage != nil { return "flag" }
        guard let url else { return "magnifyingglass" }
        if url.isFileURL { return "doc" }
        return url.scheme == "https" ? "lock.fill" : "globe"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { session.focusCommandBar(from: .addressPill) }) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(host)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(url == nil ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                .offset(pull)
                // The contents leave through the pill's edges without crossing the buttons at its end. Only the contents are clipped, so the focus ring stays visible.
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url?.absoluteString ?? "")
            .accessibilityLabel(host)
            SidebarIconButton(symbol: "square.and.arrow.up", label: "Share", action: session.shareSelectedPage)
                .disabled(!session.canShareSelectedPage)
                .background(ShareButtonAnchor(session: session))
            SidebarIconButton(symbol: "slider.horizontal.3", label: "Site Settings") { isShowingSiteSettings.toggle() }
                .padding(.trailing, 4)
                .popover(isPresented: $isShowingSiteSettings, arrowEdge: .bottom) {
                    SiteSettingsView(session: session, tab: tab) { isShowingSiteSettings = false }
                }
        }
        .font(.system(size: 14))
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SidebarFill.field.color(in: colorScheme)))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: AddressPillFrameKey.self, value: proxy.frame(in: .named(BrowserWindowView.coordinateSpace)))
        })
    }
}

/// Marks the share button for the picker. The docked sidebar and the floating card each have one; the one that joined the window last is the one on screen.
struct ShareButtonAnchor: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.session = session
    }

    final class AnchorView: NSView {
        // Only joining the window registers the view, so an update of the other anchor does not take over.
        weak var session: BrowserSession? {
            didSet { if oldValue == nil, window != nil { session?.shareButtonView = self } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { session?.shareButtonView = self }
        }

        // Clicks go to the button above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The system share picker for one page. Its preview shows the page's title and icon, and services that take a subject, such as Mail, get the title.
final class PageSharePicker: NSObject, NSSharingServicePickerDelegate {
    private let picker: NSSharingServicePicker
    private let title: String

    init(url: URL, title: String, icon: NSImage?) {
        self.title = title
        picker = NSSharingServicePicker(items: [NSPreviewRepresentingActivityItem(item: url as NSURL, title: title, image: nil, icon: icon)])
        super.init()
        picker.delegate = self
    }

    func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        picker.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        service?.subject = title
    }
}

/// The palette's entry motion: where it starts and how far the address pill's contents move toward it.
struct PaletteMotion {
    var arrival = CommandPaletteAppearance.offset(from: .keyboard)
    var pull = CGSize.zero

    init() {}

    /// From the address pill, the palette moves along the line from the pill's center to the search field's center. The pill's contents move in the same direction until they leave the pill.
    init(origin: CommandPaletteOrigin, pill: CGRect?, windowWidth: CGFloat) {
        guard origin == .addressPill, let pill, windowWidth > 0 else {
            arrival = CommandPaletteAppearance.offset(from: origin)
            return
        }
        let dx = windowWidth / 2 - pill.midX
        let dy = CommandPaletteView.top + CommandPaletteView.fieldHeight / 2 - pill.midY
        let length = max((dx * dx + dy * dy).squareRoot(), 1)
        let (ux, uy) = (dx / length, dy / length)
        arrival = CGSize(width: -ux * 40, height: -uy * 40)
        let travel = min(pill.width / max(abs(ux), 0.01), pill.height / max(abs(uy), 0.01))
        pull = CGSize(width: ux * travel, height: uy * travel)
    }
}

private struct AddressPillFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// The site settings popover: the engine of the current tab, clearing its site's data, whether AI features may send its pages, and the engine for new tabs.
struct SiteSettingsView: View {
    @ObservedObject var session: BrowserSession
    let tab: Tab?
    /// Closes the popover, so that it does not stay over the sheet it opens.
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let tab {
                TabEngineSection(session: session, tab: tab)
                SiteSettingsSection(title: "Site data", note: "Removes the site\u{2019}s cookies and stored data from both engines and signs you out of it.") {
                    Button("Clear Site Data\u{2026}") {
                        close()
                        session.confirmClearSiteData()
                    }
                    .disabled(!session.canClearSiteData)
                }
                PageAISiteSection(tab: tab)
            }
            SiteSettingsSection(title: "New tabs", note: "Tabs that a page opens use that page\u{2019}s engine.") {
                Picker("New tabs", selection: Binding(get: { session.defaultEngine }, set: { session.defaultEngine = $0 })) {
                    ForEach(session.availableEngines, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

// Observes the tab so the picker follows the switch.
struct TabEngineSection: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab

    var body: some View {
        SiteSettingsSection(title: "This tab", note: "Switching loads the page again in the other engine.") {
            Picker("This tab", selection: Binding(get: { tab.engineKind }, set: { session.switchEngine(of: tab, to: $0) })) {
                ForEach(session.availableEngines, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
    }
}

struct SiteSettingsSection<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
                .pickerStyle(.segmented)
                .labelsHidden()
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shows favorites shared by all spaces as a grid of site icons. A favorite that has a tab of its own is marked as open, and clicking it selects that tab. Dragging a tile moves it among the others.
struct FavoritesGridView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var tabDrag: TabDragState
    /// Each tile's frame in the window, used to find the tile under a dragged favorite.
    @State private var tileFrames: [UUID: CGRect] = [:]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        let selectedFavoriteID = session.selectedFavoriteID
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(session.favorites) { favorite in
                FavoriteTileView(favorite: favorite, isActive: favorite.id == selectedFavoriteID, isOpen: session.hasTab(favorite))
                    // The release that ends a drag does not also open the favorite.
                    .onTapGesture { if tabDrag.item == nil { session.openFavorite(favorite) } }
                    .accessibilityAction { session.openFavorite(favorite) }
                    .contextMenu {
                        Button("Close") { session.closeFavorite(favorite) }
                            .disabled(!session.hasTab(favorite))
                        Divider()
                        Button("Remove from Favorites") { session.removeFavorite(favorite) }
                    }
                    .modifier(SidebarItemDrag(item: .favorite(favorite.id), cornerRadius: 13) { reorder(favorite, at: $0) })
            }
        }
        .onPreferenceChange(SidebarItemFramesKey.self) { tileFrames = $0 }
    }

    /// The tile under the pointer makes room for the dragged favorite, with a light haptic at each new position.
    private func reorder(_ favorite: Favorite, at location: CGPoint) {
        guard let target = session.favorites.first(where: { $0.id != favorite.id && tileFrames[$0.id]?.contains(location) == true }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { session.moveFavorite(favorite.id, to: target) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

struct FavoriteTileView: View {
    let favorite: Favorite
    /// Set while the favorite's tab is selected.
    let isActive: Bool
    /// Set while the favorite has a tab of its own, which a dot below the tile shows, as the Dock does for an open app.
    let isOpen: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var icon: NSImage?
    @State private var isHovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill((isActive ? SidebarFill.selected : SidebarFill.field).color(in: colorScheme))
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SidebarFill.hover.color(in: colorScheme).opacity(isHovering && !isActive ? 1 : 0)))
            .aspectRatio(1.5, contentMode: .fit)
            .overlay {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            // The dot sits in the gap below the tile, nearer the tile than the row below it; a short tile has no room for it under the icon.
            .overlay(alignment: .bottom) {
                if isOpen {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 4, height: 4)
                        .offset(y: 5)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .help(favorite.title)
            .accessibilityElement()
            .accessibilityLabel(favorite.title)
            .accessibilityValue(isOpen ? "Open" : "")
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .onAppear {
                guard icon == nil, let url = FaviconLoader.defaultIconURL(for: favorite.url) else { return }
                FaviconLoader.load(url) { icon = $0 }
            }
    }
}

/// Lays out one page per space side by side and shows the current space's page. During a swipe the pages follow the fingers; a change of space slides them into place.
struct SpacePagesView: View {
    @ObservedObject var session: BrowserSession
    let translation: CGFloat
    @Environment(\.sidebarWidth) private var width

    var body: some View {
        let index = session.spaces.firstIndex { $0.id == session.currentSpaceID } ?? 0
        HStack(spacing: 0) {
            ForEach(session.spaces) { space in
                let isCurrent = space.id == session.currentSpaceID
                SpaceTabsView(session: session, space: space)
                    .frame(width: width)
                    // Clipping hides the other pages but does not stop them from taking clicks over the page beside the sidebar, or from reaching assistive apps.
                    .allowsHitTesting(isCurrent)
                    .accessibilityElement(children: isCurrent ? .contain : .ignore)
                    .accessibilityHidden(!isCurrent)
            }
        }
        .offset(x: -CGFloat(index) * width + translation)
        .frame(width: width, alignment: .leading)
        .clipped()
        .animation(SidebarView.pageSpring, value: session.currentSpaceID)
    }
}

/// Shows a space's pinned tabs first, followed by the remaining tabs and the new tab row. Each of the two lists starts with its folders, each followed by its tabs unless collapsed.
struct SpaceTabsView: View {
    @ObservedObject var session: BrowserSession
    let space: Space
    @EnvironmentObject private var tabDrag: TabDragState
    /// Set during a row's drag gesture. Resets automatically if the gesture is cancelled, such as when its row disappears.
    @GestureState private var isDragGestureActive = false
    /// Each tab and folder row's frame in the window, used to find the row under the pointer and the dropped tab's destination.
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// The visible part of the list in the window. Rows scrolled out of sight lie outside it.
    @State private var listFrame = CGRect.zero
    /// Identifies this list as the owner of a drag it started, since each space and the floating card has its own list.
    @State private var dragOwner = UUID()

    /// How long the lifted row's shadow and the slot's dimming take to appear and disappear.
    private static let liftDuration = TabDragState.liftDuration
    /// How far a folder's tabs sit in from its row.
    private static let folderIndent: CGFloat = 12

    /// Pinned and open tabs share one list, so a tab keeps its row and drag when moving between them or into and out of a folder.
    private enum Item: Identifiable {
        case folder(TabFolder)
        case tab(Tab, isInFolder: Bool)
        case divider
        case newTab

        var id: String {
            switch self {
            case .folder(let folder): return folder.id.uuidString
            case .tab(let tab, _): return tab.id.uuidString
            case .divider: return "divider"
            case .newTab: return "new-tab"
            }
        }
    }

    private var items: [Item] {
        let pinned = listItems(pinned: true)
        return pinned + (pinned.isEmpty ? [] : [.divider]) + listItems(pinned: false) + [.newTab]
    }

    /// The pinned or open list: each folder followed by its tabs, then the tabs outside folders. A collapsed folder still shows its selected tab, and a tab dragged into it until release, so that the drag keeps its row.
    private func listItems(pinned: Bool) -> [Item] {
        let folders = session.folders(in: space.id, pinned: pinned).flatMap { folder in
            let shown = session.tabs(in: folder).filter { !folder.isCollapsed || $0.id == session.selectedTabID || ($0.id == tabDrag.tabID && !tabDrag.isSettling) }
            return [Item.folder(folder)] + shown.map { Item.tab($0, isInFolder: true) }
        }
        return folders + session.tabsOutsideFolders(in: space.id, pinned: pinned).map { Item.tab($0, isInFolder: false) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SpaceHeaderView(session: session, space: space)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                ForEach(items) { item in
                    switch item {
                    case .folder(let folder):
                        TabFolderRowView(session: session, folder: folder)
                            .background(frameReader(for: folder.id))
                    case .tab(let tab, let isInFolder):
                        row(for: tab)
                            .padding(.leading, isInFolder ? Self.folderIndent : 0)
                    case .divider:
                        Divider().padding(.vertical, 4).padding(.horizontal, 10)
                    case .newTab:
                        NewTabButton(action: { session.showCommandPalette(.newTab, from: .sidebar) })
                    }
                }
            }
            // The scroll view clips at its edges. Keeping the margin inside it leaves room for the selected row's shadow.
            .padding(.horizontal, SidebarView.inset)
            .environment(\.isDraggingTab, tabDrag.tabID != nil)
            .onPreferenceChange(TabRowFramesKey.self) { rowFrames = $0 }
            // A cancelled gesture never reports its end. Drop the drag once the gesture is gone and nothing is settling.
            .onChange(of: isDragGestureActive) { isActive in
                guard !isActive else { return }
                DispatchQueue.main.async {
                    if !isDragGestureActive, !tabDrag.isSettling { tabDrag.end(ownedBy: dragOwner) }
                }
            }
        }
        .scrollIndicators(.never)
        .background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
            Color.clear
                .onAppear { listFrame = frame }
                .onChange(of: frame) { listFrame = $0 }
        })
        // Hiding the sidebar or the card mid-drag removes the list without ending its gesture.
        .onDisappear { tabDrag.end(ownedBy: dragOwner) }
    }

    /// A dragged tab leaves an empty, dimmed slot in the list.
    private func row(for tab: Tab) -> some View {
        let isDragged = tabDrag.tabID == tab.id
        return TabRowView(session: session, tab: tab)
            .opacity(isDragged ? 0 : 1)
            .background {
                if isDragged {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(tabDrag.isLifted ? 0.06 : 0))
                }
            }
            .background(frameReader(for: tab.id))
            // Dragging in the name field selects text instead.
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(BrowserWindowView.coordinateSpace))
                .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
                .onChanged { dragChanged(tab, $0) }
                .onEnded { _ in dragEnded() }, including: session.renamingTabID == tab.id ? .subviews : .all)
    }

    /// Reports a tab's or folder's row frame in the window.
    private func frameReader(for id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: TabRowFramesKey.self, value: [id: proxy.frame(in: .named(BrowserWindowView.coordinateSpace))])
        }
    }

    /// The lifted row follows the pointer anywhere in the window. Only a pointer over the visible list moves the tab.
    private func dragChanged(_ tab: Tab, _ value: DragGesture.Value) {
        guard !tabDrag.isSettling, tabDrag.item == nil || (tabDrag.tabID == tab.id && tabDrag.owner == dragOwner), let frame = rowFrames[tab.id] else { return }
        if tabDrag.item == nil {
            tabDrag.begin(.tab(tab.id), frame: frame, grabbedAt: value.startLocation, owner: dragOwner)
            // The row appears without a shadow, which then fades in.
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: Self.liftDuration)) { tabDrag.isLifted = true } }
        }
        tabDrag.move(to: value.location)
        let isOverList = listFrame.contains(value.location)
        // Another space's symbol, or another folder's row, under the pointer lights up and takes the tab on release. The rows do not make room for it.
        setDropTarget(\.targetSpaceID, to: tabDrag.space(at: value.location).flatMap { $0 == tab.spaceID ? nil : $0 })
        setDropTarget(\.targetFolderID, to: isOverList ? session.folders(in: space.id).first { $0.id != tab.folderID && rowFrames[$0.id]?.contains(value.location) == true }?.id : nil)
        // Over the page area beside the list, the pane under the pointer shows where the tab opens in split view.
        setDropTarget(\.splitDrop, to: tabDrag.targetSpaceID == nil && value.location.x > listFrame.maxX ? tabDrag.splitDrop(of: tab, at: value.location, in: session) : nil)
        // The row under the pointer makes room for the dragged tab, with a light haptic at each new position.
        let tabs = session.tabs(in: space.id, pinned: true) + session.tabs(in: space.id, pinned: false)
        guard isOverList, let target = tabs.first(where: { $0.id != tab.id && rowFrames[$0.id]?.contains(value.location) == true }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(tab.id, to: target) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Lights up a drop target newly under the dragged tab, with a light haptic, or turns off the one it left.
    private func setDropTarget<Target: Equatable>(_ keyPath: ReferenceWritableKeyPath<TabDragState, Target?>, to target: Target?) {
        guard tabDrag[keyPath: keyPath] != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { tabDrag[keyPath: keyPath] = target }
        if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// On release, the lifted row returns to its slot, wherever the pointer is, and its shadow fades out before the tab reappears in the list.
    private func dragEnded() {
        guard tabDrag.owner == dragOwner, let id = tabDrag.tabID, let slot = rowFrames[id] else { return tabDrag.end(ownedBy: dragOwner) }
        // Over another space's symbol, the tab goes after that space's own tabs and the lifted row shrinks into the symbol.
        if let spaceID = tabDrag.targetSpaceID {
            withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(id, toSpace: spaceID) }
            return tabDrag.settle(intoSpace: spaceID, ownedBy: dragOwner)
        }
        // Over a folder's row, the tab goes after the folder's own tabs and the lifted row shrinks into the folder's row.
        if let folderID = tabDrag.targetFolderID, let folderRow = rowFrames[folderID] {
            withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(id, toFolder: folderID) }
            return tabDrag.settle(shrinkingInto: folderRow, ownedBy: dragOwner)
        }
        // Over the page area, the tab opens in split view, and its row returns to its slot.
        if let drop = tabDrag.splitDrop, let tab = session.tabs.first(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.15)) { tabDrag.splitDrop = nil }
            session.openInSplitView(tab, at: drop.index)
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            tabDrag.isSettling = true
            tabDrag.frame = slot
        }
        withAnimation(.easeInOut(duration: Self.liftDuration)) { tabDrag.isLifted = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftDuration) { [owner = dragOwner] in tabDrag.end(ownedBy: owner) }
    }
}

/// The tab row, favorite, or space symbol lifted by a drag. The window draws it above the sidebar and the page, so it can follow the pointer out of the list.
final class TabDragState: ObservableObject {
    /// The dragged item.
    @Published private(set) var item: SidebarDragItem?
    /// The lifted row's frame in the window.
    @Published var frame: CGRect = .zero
    /// Set after release, while the row returns to its slot.
    @Published var isSettling = false
    /// Shows the lifted row's shadow and backing and the slot's dimming.
    @Published var isLifted = false
    /// The other space whose symbol is under a dragged tab. Releasing the tab there moves it to that space.
    @Published var targetSpaceID: UUID?
    /// The folder whose row is under a dragged tab. Releasing the tab there adds it to the folder.
    @Published var targetFolderID: UUID?
    /// Set while a tab released over a space's symbol or a folder's row shrinks into it.
    @Published var isEntering = false
    /// Where a tab released over the page area opens in split view.
    @Published var splitDrop: SplitDrop?
    /// Each space symbol's frame in the window and the strip's visible part, reported by the bottom bar on screen.
    var spaceSymbolFrames: [UUID: CGRect] = [:]
    var spaceStripFrame = CGRect.zero
    /// The page area's panes, left to right, reported by the page area.
    var paneFrames: [PaneFrame] = []
    /// The list or item that started the drag.
    private(set) var owner: UUID?
    /// The pointer's position in the row when the drag started.
    private var grabOffset: CGSize = .zero

    /// The dragged tab.
    var tabID: UUID? {
        if case .tab(let id) = item { return id }
        return nil
    }

    func begin(_ item: SidebarDragItem, frame: CGRect, grabbedAt point: CGPoint, owner: UUID) {
        self.item = item
        self.owner = owner
        self.frame = frame
        grabOffset = CGSize(width: point.x - frame.minX, height: point.y - frame.minY)
    }

    func move(to point: CGPoint) {
        frame.origin = CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height)
    }

    /// Ends the drag if `owner` started it, so a list cannot end another list's drag.
    func end(ownedBy owner: UUID) {
        guard self.owner == owner else { return }
        item = nil
        self.owner = nil
        isSettling = false
        isLifted = false
        targetSpaceID = nil
        targetFolderID = nil
        isEntering = false
        splitDrop = nil
    }
}

/// Draws the lifted tab row at the pointer.
struct TabDragLayer: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tabDrag: TabDragState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let id = tabDrag.tabID, let tab = session.tabs.first(where: { $0.id == id }) {
            // Over the page the row needs a backing of its own.
            TabRowView(session: session, tab: tab)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SidebarFill.selected.color(in: colorScheme)).opacity(tabDrag.isLifted ? 1 : 0))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial).opacity(tabDrag.isLifted ? 1 : 0))
                .shadow(color: .black.opacity(tabDrag.isLifted ? 0.18 : 0), radius: 5, y: 2)
                // A tab released over a space's symbol or a folder's row shrinks into it.
                .scaleEffect(tabDrag.isEntering ? 0.2 : 1)
                .opacity(tabDrag.isEntering ? 0 : 1)
                .environment(\.isDraggingTab, true)
                .frame(width: tabDrag.frame.width, height: tabDrag.frame.height)
                .offset(x: tabDrag.frame.minX, y: tabDrag.frame.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct TabRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct TabRowView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    @ObservedObject private var commandKey = CommandKeyState.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isDraggingTab) private var isDraggingTab
    @State private var isHovering = false

    private var isSelected: Bool { tab.id == session.selectedTabID }
    /// Rows ignore the pointer while a tab is dragged over them.
    private var showsHover: Bool { isHovering && !isDraggingTab }

    private var fill: Color {
        if isSelected { return SidebarFill.selected.color(in: colorScheme) }
        // The other panes of the split view on screen show a lighter selection.
        if session.isInSplitViewOnScreen(tab) { return SidebarFill.selected.color(in: colorScheme).opacity(0.5) }
        return showsHover ? SidebarFill.hover.color(in: colorScheme) : .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(tab: tab)
                .frame(width: 18, height: 18)
            if session.renamingTabID == tab.id {
                SidebarNameField(session: session, placeholder: "Tab Name", name: tab.displayTitle,
                                 onRename: { session.renameTab(tab.id, to: $0) }, onEnd: { session.endRenaming(tab.id) })
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 14))
                    .lineLimit(1)
            }
            if tab.isAudible {
                TabAudioBadge()
            }
            Spacer(minLength: 0)
            // Show the close button under the pointer; otherwise, holding Command shows the row's ⌘-number shortcut in its place, and an unread tab shows a dot there.
            if showsHover {
                TabCloseButton { session.requestCloseTab(tab) }
            } else if commandKey.showsShortcuts, let number = session.shortcutNumber(for: tab) {
                TabShortcutBadge(number: number)
                    .transition(.modifier(active: BlurFade(isHidden: true), identity: BlurFade(isHidden: false)))
            } else if tab.isUnread {
                TabUnreadDot()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
        // Only the light appearance lifts the selected row; in the dark one its lighter fill is enough.
        .shadow(color: .black.opacity(isSelected && colorScheme == .light ? 0.08 : 0), radius: 1.5, y: 0.5)
        .contentShape(Rectangle())
        // The row truncates long titles, so the tooltip has the whole title and the address.
        .help([tab.displayTitle, tab.url?.absoluteString].compactMap { $0 }.joined(separator: "\n"))
        .onTapGesture { session.selectedTabID = tab.id }
        // The first click selects the tab at once; the second starts renaming it.
        .simultaneousGesture(TapGesture(count: 2).onEnded { session.renamingTabID = tab.id })
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename Tab") {
                session.selectedTabID = tab.id
                session.renamingTabID = tab.id
            }
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { session.togglePinned(tab) }
            Button("Add to Favorites") { session.addFavorite(tab) }.disabled(tab.url == nil)
            Button("Open in Split View") { session.openInSplitView(tab) }.disabled(!session.canOpenInSplitView(tab))
            Divider()
            Button("Add to New Folder") { withAnimation(.easeInOut(duration: 0.15)) { session.addToNewFolder(tab) } }
            let otherFolders = tab.spaceID.map { session.folders(in: $0).filter { $0.id != tab.folderID } } ?? []
            if !otherFolders.isEmpty {
                Menu("Move to Folder") {
                    ForEach(otherFolders) { folder in
                        Button(folder.name) { withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(tab.id, toFolder: folder.id) } }
                    }
                }
            }
            if tab.folderID != nil {
                Button("Remove from Folder") { withAnimation(.easeInOut(duration: 0.15)) { session.removeFromFolder(tab) } }
            }
            Divider()
            Button("Close Tab") { session.requestCloseTab(tab) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // A tap gesture alone does not answer the accessibility press, so VoiceOver could not select the tab.
        .accessibilityAction { session.selectedTabID = tab.id }
    }
}

/// Edits a tab's or folder's name in place. Return or leaving the field passes the name to `onRename`, which decides what an empty name means, and Escape cancels. An unedited name changes nothing.
struct SidebarNameField: View {
    @ObservedObject var session: BrowserSession
    let placeholder: String
    /// The current name, which the field starts with.
    let name: String
    let onRename: (String) -> Void
    /// Ends editing without a new name.
    let onEnd: () -> Void
    @State private var draftName = ""
    /// `name` when the field opened. A tab's page can change its title meanwhile.
    @State private var initialName = ""
    @State private var isCancelled = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isFocused)
            .onSubmit(commit)
            .onExitCommand {
                isCancelled = true
                onEnd()
            }
            .onChange(of: isFocused) { focused in
                if !focused { commit() }
            }
            // Selecting another tab or space leaves the field focused, so the name is saved here.
            .onChange(of: session.selectedTabID) { _ in commit() }
            .onAppear {
                initialName = name
                draftName = initialName
                DispatchQueue.main.async { isFocused = true }
            }
            // Hiding the sidebar or opening the library removes the field without moving focus.
            .onDisappear(perform: commit)
    }

    /// Keeps the typed name even when renaming has moved on to another tab or folder.
    private func commit() {
        guard !isCancelled else { return }
        if draftName == initialName { return onEnd() }
        onRename(draftName)
    }
}

/// The number of a tab's ⌘-number shortcut, shown in the close button's place.
struct TabShortcutBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Color.primary.opacity(0.08)))
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

/// A speaker after a tab's title while its page plays sound.
struct TabAudioBadge: View {
    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Playing Audio")
    }
}

/// A dot in the close button's place on a tab that a page opened and the user has not selected yet.
struct TabUnreadDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .frame(width: 22, height: 22)
            .accessibilityLabel("Unread")
    }
}

/// Fades and blurs a view in and out.
struct BlurFade: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: isHidden ? 4 : 0)
            .opacity(isHidden ? 0 : 1)
    }
}

/// Tracks whether Command alone is held while the app is active. Shortcut numbers appear after a brief hold, so quick ⌘-shortcuts do not flash them, and disappear on release.
final class CommandKeyState: ObservableObject {
    static let shared = CommandKeyState()
    @Published private(set) var showsShortcuts = false
    private var pendingShow: DispatchWorkItem?

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setDown(Self.isCommandAlone(event.modifierFlags))
            return event
        }
        // The app receives no key events while inactive, so it cannot detect a release in another app.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setDown(false)
        }
        // Monitors receive no modifier changes while a menu tracks. Read the keys again when it closes.
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setDown(Self.isCommandAlone(NSEvent.modifierFlags))
        }
    }

    /// Caps Lock and the like do not count.
    private static func isCommandAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .shift, .option, .control, .function]) == .command
    }

    private func setDown(_ isDown: Bool) {
        pendingShow?.cancel()
        pendingShow = nil
        guard isDown else {
            if showsShortcuts { withAnimation(.easeOut(duration: 0.12)) { showsShortcuts = false } }
            return
        }
        let show = DispatchWorkItem { [weak self] in
            guard Self.isCommandAlone(NSEvent.modifierFlags) else { return }
            withAnimation(.easeOut(duration: 0.18)) { self?.showsShortcuts = true }
        }
        pendingShow = show
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: show)
    }
}

struct TabCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help("Close Tab")
        .accessibilityLabel("Close Tab")
    }
}

struct TabIconView: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct NewTabButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text("New Tab")
                    .font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovering ? SidebarFill.hover.color(in: colorScheme) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
    }
}

/// The space's symbol and name above its tabs, with a button for the space menu. Double-clicking the name renames the space in place.
struct SpaceHeaderView: View {
    @ObservedObject var session: BrowserSession
    let space: Space
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: space.symbol)
                .font(.system(size: 10))
                .foregroundStyle(theme.symbolColor(for: space.tint))
            if session.renamingSpaceID == space.id {
                TextField("Space Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($isNameFocused)
                    .onSubmit { session.renameSpace(space.id, to: draftName) }
                    .onExitCommand { session.renamingSpaceID = nil }
                    .onChange(of: isNameFocused) { focused in
                        if !focused, session.renamingSpaceID == space.id { session.renameSpace(space.id, to: draftName) }
                    }
                    .onAppear {
                        draftName = space.name
                        DispatchQueue.main.async { isNameFocused = true }
                    }
                    // Opening the library or hiding the sidebar removes the field without moving focus, so the name is kept here.
                    .onDisappear {
                        if session.renamingSpaceID == space.id { session.renameSpace(space.id, to: draftName) }
                    }
            } else {
                Text(space.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { session.renamingSpaceID = space.id }
            }
            Spacer(minLength: 0)
            Menu {
                SpaceMenuItems(session: session, space: space)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Space Options")
            .accessibilityLabel("Space Options")
        }
        .frame(height: 22)
        // Another space's page takes over the keyboard, so the name in this one is kept.
        .onChange(of: session.currentSpaceID) { id in
            if id != space.id, session.renamingSpaceID == space.id { session.renameSpace(space.id, to: draftName) }
        }
    }
}

/// The space menu, shared by the button beside a space's name and the context menu of its symbol at the bottom of the sidebar.
struct SpaceMenuItems: View {
    @ObservedObject var session: BrowserSession
    let space: Space

    private var index: Int? { session.spaces.firstIndex { $0.id == space.id } }
    private var homeURL: URL? { session.spaces.first { $0.id == space.id }?.homeURL }

    var body: some View {
        Button("Rename Space") {
            session.switchToSpace(space.id)
            session.renamingSpaceID = space.id
        }
        // Automatic follows the system accent color; the others are the space's own color.
        Picker("Theme", selection: Binding(get: { space.tint }, set: { session.setTint($0, ofSpace: space.id) })) {
            ForEach([SpaceTint.automatic] + SpaceTint.colors, id: \.self) { tint in
                Text(tint.title).tag(tint)
            }
        }
        Picker("Icon", selection: Binding(get: { space.symbol }, set: { session.setSymbol($0, ofSpace: space.id) })) {
            ForEach(Space.symbolChoices, id: \.symbol) { choice in
                Label(choice.name, systemImage: choice.symbol).tag(choice.symbol)
            }
        }
        Divider()
        Button("Set Current Page as Home") { session.setCurrentPageAsHome(ofSpace: space.id) }
            .disabled(!session.canSetCurrentPageAsHome)
        Button("Clear Home") { session.clearHome(ofSpace: space.id) }
            .disabled(homeURL == nil)
        Divider()
        Button("Move Left") { session.moveSpace(space.id, by: -1) }
            .disabled(index == 0)
        Button("Move Right") { session.moveSpace(space.id, by: 1) }
            .disabled(index == session.spaces.count - 1)
        Divider()
        Button("New Folder") { withAnimation(.easeInOut(duration: 0.15)) { session.addFolder(toSpace: space.id) } }
        Button("New Space", action: session.addSpace)
        Button("Delete Space") { session.deleteSpace(space.id) }
            .disabled(session.spaces.count < 2)
    }
}

/// The library button at the leading end, and one symbol per space in the middle with the new space button floating after them. Dragging a symbol moves its space among the others; a tab dragged over another space's symbol lights it up.
struct SidebarBottomBar: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var tabDrag: TabDragState
    @Environment(\.sidebarWidth) private var width
    @Environment(\.sidebarIsFloating) private var isFloating
    @Environment(\.spaceTheme) private var theme

    /// The maximum centered width of the symbols and new space button. Each side reserves room for the 30-point library button and its gap to avoid overlap.
    private var groupWidth: CGFloat { width - 2 * SidebarView.inset - 2 * (30 + 4) }

    /// Width shared by each symbol and the new space button, keeping the row visually grouped.
    fileprivate static let itemWidth: CGFloat = 18
    private static let stripSpace = "SpaceStrip"

    /// Three items show at full size: the current space and its neighbors, or the three at the end nearest it. The others shrink with their distance from those three.
    private func scale(at index: Int) -> CGFloat {
        let count = session.spaces.count + 1
        let current = session.spaces.firstIndex { $0.id == session.currentSpaceID } ?? 0
        let first = max(0, min(current - 1, count - 3))
        let distance = index < first ? first - index : max(0, index - (first + 2))
        return max(0.3, pow(0.7, CGFloat(distance)))
    }

    /// The symbols followed by the new space button. When scrolling, items also shrink toward the strip's ends so none appears cut off.
    private func strip(shrinksAtEdges: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(session.spaces.enumerated()), id: \.element.id) { index, space in
                let isCurrent = space.id == session.currentSpaceID
                let isTabTarget = tabDrag.targetSpaceID == space.id
                // The release that ends a drag of the symbol does not also switch spaces.
                Button(action: { if tabDrag.item == nil { session.switchToSpace(space.id) } }) {
                    Image(systemName: space.symbol)
                        .font(.system(size: isCurrent ? 12 : 9))
                        .foregroundStyle(isCurrent || isTabTarget ? theme.symbolColor(for: space.tint) : Color.secondary.opacity(0.6))
                        .scaleEffect(scale(at: index) * (isTabTarget ? 1.4 : 1))
                        .frame(width: Self.itemWidth, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(EdgeShrink(isActive: shrinksAtEdges, stripWidth: groupWidth, coordinateSpace: Self.stripSpace))
                .modifier(SidebarItemDrag(item: .space(space.id), cornerRadius: 6) { reorder(space, at: $0) })
                .contextMenu { SpaceMenuItems(session: session, space: space) }
                .help(space.name)
                .accessibilityLabel(space.name)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .id(space.id)
            }
            NewSpaceButton(scale: scale(at: session.spaces.count), action: session.addSpace)
                .modifier(EdgeShrink(isActive: shrinksAtEdges, stripWidth: groupWidth, coordinateSpace: Self.stripSpace))
        }
        .animation(SidebarView.pageSpring, value: session.currentSpaceID)
        .animation(.easeInOut(duration: 0.15), value: session.spaces.map(\.id))
        // Let the first and last items scroll clear of the shrinking ends.
        .padding(.horizontal, shrinksAtEdges ? EdgeShrink.distance : 0)
    }

    /// The symbol under the pointer makes room for the dragged space, with a light haptic at each new position. Only the strip animates the move; the space pages move at once, so the current page stays in view.
    private func reorder(_ space: Space, at location: CGPoint) {
        guard let id = tabDrag.space(at: location), id != space.id, let target = session.spaces.first(where: { $0.id == id }) else { return }
        session.moveSpace(space.id, to: target)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    var body: some View {
        ZStack {
            HStack {
                LibraryButton(session: session)
                Spacer(minLength: 0)
            }
            // Center the symbols and new space button as one group, ignoring the library button. If they do not fit, scroll them together without covering the library button or widening the sidebar.
            ViewThatFits(in: .horizontal) {
                strip(shrinksAtEdges: false)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { strip(shrinksAtEdges: true) }
                        .coordinateSpace(name: Self.stripSpace)
                        .onAppear { proxy.scrollTo(session.currentSpaceID, anchor: .center) }
                        .onChange(of: session.currentSpaceID) { id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .frame(maxWidth: groupWidth)
            // Dragged spaces and tabs find a symbol only in the strip's visible part.
            .background(GeometryReader { proxy in
                let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
                Color.clear
                    .onAppear { tabDrag.spaceStripFrame = frame }
                    .onChange(of: frame) { tabDrag.spaceStripFrame = $0 }
            })
            .onPreferenceChange(SidebarItemFramesKey.self) { tabDrag.spaceSymbolFrames = $0 }
            // An optical correction beside the page: the group looks centered 2 points right of its true center. The floating sidebar uses the true center.
            .offset(x: isFloating ? 0 : 2)
        }
        .frame(height: 28)
    }
}

/// Shrinks a scrolling item starting three items from either end of the strip, reaching zero at the end.
private struct EdgeShrink: ViewModifier {
    static let distance = 3 * (SidebarBottomBar.itemWidth + 2)

    let isActive: Bool
    let stripWidth: CGFloat
    let coordinateSpace: String

    @ViewBuilder func body(content: Content) -> some View {
        if isActive {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(coordinateSpace))
                let nearest = min(frame.midX, stripWidth - frame.midX)
                content.scaleEffect(max(0, min(1, nearest / Self.distance)))
            }
            .frame(width: SidebarBottomBar.itemWidth, height: 26)
        } else {
            content
        }
    }
}

/// A small, dim plus makes the new space button look like part of the symbols row rather than a toolbar button.
private struct NewSpaceButton: View {
    let scale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(isHovering ? 1 : 0.6))
                .scaleEffect(scale)
                .frame(width: SidebarBottomBar.itemWidth, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("New Space")
        .accessibilityLabel("New Space")
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

    /// How far the address pill's contents have moved toward the palette it opened.
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
