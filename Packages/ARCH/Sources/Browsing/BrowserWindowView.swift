// Main window content. The system's translucent window material fills the window with a faint wash of the current space's tint. The sidebar sits over it and contains navigation, the address field, favorites, the current space's tabs or the library, and the library button with the space switcher. The page fills the remaining space with nothing above it.
import AppKit
import ARCHEngine
import SwiftUI

public struct BrowserWindowView: View {
    @ObservedObject var session: BrowserSession
    @State private var windowButtons = WindowButtonMetrics()
    /// The sidebar's width, set by dragging its trailing edge.
    @AppStorage(SidebarView.widthKey) private var sidebarWidth = Double(SidebarView.defaultWidth)
    /// Set while the hidden sidebar is out over the page.
    @State private var isSidebarPeeking = false
    /// The next check of whether the peeking sidebar should stay out.
    @State private var peekCheck: DispatchWorkItem?
    @State private var windowReference = WindowReference()

    public init(session: BrowserSession) {
        self.session = session
    }

    /// The margin between the page and the window's edges.
    static let pageMargin: CGFloat = 8
    /// The space between the sidebar's controls and the page.
    static let sidebarGap: CGFloat = 8

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if session.isSidebarVisible {
                    SidebarColumn(session: session, windowButtons: windowButtons, width: SidebarView.clampedWidth(sidebarWidth)) {
                        sidebarWidth = Double(SidebarView.clampedWidth($0))
                    }
                    .transition(.move(edge: .leading))
                }
                WebContentsHostView(contentView: session.selectedTab?.webContents.view)
                    .background(PageBackgroundView(isEmpty: session.selectedTab == nil))
                    .overlay { if let tab = session.selectedTab { PageCrashNoticeView(tab: tab) } }
                    .overlay(PageFrameShape().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
                    // The sidebar's own margin is part of the gap beside it.
                    .padding(EdgeInsets(top: Self.pageMargin, leading: session.isSidebarVisible ? Self.sidebarGap - SidebarView.inset : Self.pageMargin,
                                        bottom: Self.pageMargin, trailing: Self.pageMargin))
            }
            if !session.isSidebarVisible {
                peekingSidebar
            }
            if session.isFindBarVisible {
                FindBarView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 20)
                    .padding(.trailing, 24)
            }
            if session.commandPaletteMode != nil {
                Color.black.opacity(0.15)
                    .onTapGesture { session.dismissCommandPalette() }
                    .transition(.commandPaletteDimming(from: session.commandPaletteOrigin))
            }
            if let mode = session.commandPaletteMode {
                // Each opening gets its own view, so a palette reopened while the last one leaves starts fresh: typed text reset and the field focused.
                CommandPaletteView(session: session, mode: mode)
                    .id(session.commandPaletteGeneration)
                    .transition(.commandPalette(from: session.commandPaletteOrigin))
            }
        }
        // The transitions carry their own timing; this makes every palette change animate.
        .animation(.paletteIn(from: session.commandPaletteOrigin), value: session.commandPaletteMode)
        .background(SpaceBackgroundView(tint: session.currentSpace.tint.color))
        .background(WindowButtonsReader { windowButtons = $0 })
        // Hiding or showing the sidebar, or the library pushing it aside, slides it and widens or narrows the page.
        .animation(SidebarView.pageSpring, value: session.isSidebarVisible)
        .animation(SidebarView.pageSpring, value: session.isLibraryVisible)
        // The window buttons sit on the sidebar, so they hide with it and come back while it peeks. Full screen keeps its own.
        .background(WindowButtonsVisibility(isHidden: windowButtons.trailingEdge != nil && !session.isSidebarVisible && !isSidebarPeeking, reference: windowReference))
        .onChange(of: session.isSidebarVisible) { isVisible in
            peekCheck?.cancel()
            isSidebarPeeking = false
            // Hidden from under the pointer, the sidebar comes back out over the page once it has slid away.
            if !isVisible, isPointerOverSidebar {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if !session.isSidebarVisible { peekSidebar() } }
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 800, minHeight: 500)
    }

    /// With the sidebar hidden, a strip along the window's leading edge brings it out over the page as a card.
    private var peekingSidebar: some View {
        let width = SidebarView.clampedWidth(sidebarWidth)
        // The window buttons keep their place, so the card's top edge sits one sidebar margin above the top row on their line, and the row moves by the card's offset.
        let hasButtons = windowButtons.trailingEdge != nil
        let top = hasButtons ? max(0, windowButtons.centerY - SidebarTopRow.height / 2 - SidebarView.inset) : Self.pageMargin
        let buttons = hasButtons ? WindowButtonMetrics(centerY: windowButtons.centerY - top, trailingEdge: windowButtons.trailingEdge.map { $0 - Self.pageMargin }) : windowButtons
        return ZStack(alignment: .leading) {
            Color.clear
                .frame(width: Self.pageMargin)
                .contentShape(Rectangle())
                .onHover { if $0 { peekSidebar() } }
            if isSidebarPeeking {
                SidebarColumn(session: session, windowButtons: buttons, width: width, isFloating: true)
                    .background {
                        ZStack {
                            PageFrameShape().fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.25), radius: 16, y: 4)
                            SpaceBackgroundView(tint: session.currentSpace.tint.color, cornerRadius: PageFrameShape.cornerRadius)
                        }
                    }
                    .overlay(PageFrameShape().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
                    .contentShape(PageFrameShape())
                    .padding(EdgeInsets(top: top, leading: Self.pageMargin, bottom: Self.pageMargin, trailing: 0))
                    .environment(\.sidebarWidth, width)
                    .environment(\.sidebarIsFloating, true)
                    .transition(.move(edge: .leading))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func peekSidebar() {
        peekCheck?.cancel()
        if !isSidebarPeeking {
            withAnimation(SidebarView.pageSpring) { isSidebarPeeking = true }
        }
        scheduleCheckOfPeek()
    }

    // The pointer is checked rather than tracked, because a card that slides in under the pointer gets no hover until the pointer leaves it.
    private func scheduleCheckOfPeek() {
        let work = DispatchWorkItem { checkPeek() }
        peekCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Keeps the card out while the pointer is over it, while text in it is being edited, or while a menu, popover, or sheet opened from it, or the command palette, is open. In full screen the window's toolbar lives in a child window, which does not count.
    private func checkPeek() {
        let window = windowReference.window
        let hasOpenChild = window?.attachedSheet != nil
            || (window?.childWindows ?? []).contains { $0.isVisible && !NSStringFromClass(type(of: $0)).contains("FullScreen") }
        let isEditingText = session.renamingSpaceID != nil || window?.firstResponder is NSText
        let isInUse = isPointerOverSidebar || isEditingText || session.commandPaletteMode != nil || RunLoop.main.currentMode == .eventTracking || hasOpenChild
        if isInUse { return scheduleCheckOfPeek() }
        withAnimation(SidebarView.pageSpring) { isSidebarPeeking = false }
        // A library opened in the card goes with it, once the card is out of sight, so the card comes back with the sidebar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !session.isSidebarVisible, !isSidebarPeeking, session.isLibraryVisible else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { session.isLibraryVisible = false }
        }
    }

    /// Whether the pointer is within the window over the sidebar's place along its leading edge.
    private var isPointerOverSidebar: Bool {
        guard let window = windowReference.window, let content = window.contentView else { return false }
        let point = window.mouseLocationOutsideOfEventStream
        return point.x >= 0 && point.x <= Self.pageMargin + SidebarView.clampedWidth(sidebarWidth) && point.y >= 0 && point.y <= content.bounds.height
    }
}

/// Holds the window for code that runs outside the view's updates.
final class WindowReference {
    weak var window: NSWindow?
}

/// Hides or shows the window's close, minimize, and zoom buttons, and records the window in `reference`.
struct WindowButtonsVisibility: NSViewRepresentable {
    let isHidden: Bool
    let reference: WindowReference

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let isHidden = isHidden
        let reference = reference
        // The view has no window during its first update.
        DispatchQueue.main.async {
            reference.window = view.window
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                view.window?.standardWindowButton(type)?.isHidden = isHidden
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

/// Shows the system's translucent window material, the one Apple's own sidebars use, under a faint wash of the space's tint.
struct SpaceBackgroundView: View {
    let tint: Color
    var cornerRadius: CGFloat = 0

    var body: some View {
        ZStack {
            WindowMaterialView(cornerRadius: cornerRadius)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.08), tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .animation(.easeInOut(duration: 0.25), value: tint)
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

/// Fills the page frame: the window background under a page, or, when no tab is open, the window's material and the space's tint a little darker than the sidebar.
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

extension SpaceTint {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .green: return .green
        case .teal: return .teal
        case .gray: return .gray
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
    /// Takes a swipe past the first space, which brings the library in. The floating sidebar has none.
    var librarySwipe: SidebarSwipeHandlers?
    @Environment(\.sidebarWidth) private var width
    /// How far the space pages follow the fingers during a swipe, in points.
    @State private var swipeTranslation: CGFloat = 0
    @State private var swipePassesHalfway = false
    /// Set while the current swipe moves the library rather than the space pages.
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
                // The space pages reach the sidebar's edges so that they slide in from outside it. The clip comes before the negative margin, which would otherwise move it in to the margin's line and cut a lifted tab's shadow.
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
            }
            // The swipe area reaches the sidebar's edges and the gap above the bar. It rests while the library has pushed the sidebar aside, because its area then reaches over the page.
            .background(SpaceSwipeView(isEnabled: !session.isLibraryVisible, onChange: swipeChanged, onEnd: swipeEnded).padding(.horizontal, -Self.inset).padding(.bottom, -8))
            SidebarBottomBar(session: session)
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 10)
        // The library may open or close by menu or shortcut during a swipe; the swipe then lets go of it.
        .onChange(of: session.isLibraryVisible) { _ in isSwipingLibrary = false }
    }
}

/// Receives a swipe that the sidebar hands on: the travel while the fingers move, then the travel and the velocity when they lift.
struct SidebarSwipeHandlers {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void
}

/// The sidebar with the library to its left. Opening the library pushes the whole sidebar aside. Docked, the column widens by `libraryPeek`, the library takes the sidebar's width, set off by a line, and the pushed sidebar keeps its first `libraryPeek` points in view, dimmed and still, until a click or a swipe brings it back. Floating, the library takes the whole card.
struct SidebarColumn: View {
    /// About a quarter of the narrowest sidebar.
    static let libraryPeek: CGFloat = 60

    @ObservedObject var session: BrowserSession
    let windowButtons: WindowButtonMetrics
    let width: CGFloat
    var isFloating = false
    var onResize: (CGFloat) -> Void = { _ in }
    /// How far a swipe has brought the library in, from 0 to the library's width, while the fingers are down.
    @State private var swipeReveal: CGFloat?

    private var libraryWidth: CGFloat { width }
    private var peek: CGFloat { isFloating ? 0 : Self.libraryPeek }
    private var reveal: CGFloat { swipeReveal ?? (session.isLibraryVisible ? libraryWidth : 0) }
    private var progress: CGFloat { reveal / libraryWidth }

    var body: some View {
        HStack(spacing: 0) {
            LibraryPanel(session: session, windowButtons: windowButtons)
                .frame(width: libraryWidth)
                .allowsHitTesting(progress > 0)
                .accessibilityHidden(progress == 0)
                // The line runs beside the library's contents, between its title row and its button row.
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
                        .padding(.top, windowButtons.centerY + SidebarTopRow.height / 2 + 8)
                        .padding(.bottom, 10 + 28 + 8)
                }
            SidebarView(session: session, windowButtons: windowButtons,
                        librarySwipe: SidebarSwipeHandlers(changed: { swipeReveal = min(libraryWidth, max(0, $0)) },
                                                           ended: { travel, velocity in finishLibrarySwipe(opens: travel > libraryWidth * 0.3 || velocity > 300) }))
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
        .offset(x: reveal - libraryWidth)
        .frame(width: width + peek * progress, alignment: .leading)
        .clipped()
        // Clicks reach only what the clip shows.
        .contentShape(Rectangle())
        // A swipe over the open library or the pushed sidebar takes the library away again.
        .background(SpaceSwipeView(isEnabled: session.isLibraryVisible,
                                   onChange: { travel in swipeReveal = min(libraryWidth, max(0, libraryWidth + travel)) },
                                   onEnd: { travel, velocity in finishLibrarySwipe(opens: !(travel < -libraryWidth * 0.3 || velocity < -300)) }))
        // The handle covers the gap between the sidebar's controls and the page: the sidebar's own margin and the part of the gap outside it.
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

/// Shows the site's host. Clicking it opens the command palette with the full address, or for a new tab when no tab is open. The button at its end opens the site settings.
struct AddressPillView: View {
    @ObservedObject var session: BrowserSession
    /// `nil` when no tab is open.
    let tab: Tab?
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingSiteSettings = false

    private var url: URL? { tab?.url }

    private var host: String {
        guard let host = url?.host else { return "Search or enter address" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var symbol: String {
        guard let url else { return "magnifyingglass" }
        return url.scheme == "https" ? "lock.fill" : "globe"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { session.focusCommandBar(from: .sidebar) }) {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url?.absoluteString ?? "")
            .accessibilityLabel(host)
            SidebarIconButton(symbol: "slider.horizontal.3", label: "Site Settings") { isShowingSiteSettings.toggle() }
                .padding(.trailing, 4)
                .popover(isPresented: $isShowingSiteSettings, arrowEdge: .bottom) {
                    SiteSettingsView(session: session, tab: tab)
                }
        }
        .font(.system(size: 14))
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SidebarFill.field.color(in: colorScheme)))
    }
}

/// The site settings popover: the engine of the current tab and the engine for new tabs.
struct SiteSettingsView: View {
    @ObservedObject var session: BrowserSession
    let tab: Tab?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let tab {
                TabEngineSection(session: session, tab: tab)
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

/// Shows favorites as a grid of site icons. All spaces share the same favorites.
struct FavoritesGridView: View {
    @ObservedObject var session: BrowserSession
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(session.favorites) { favorite in
                FavoriteTileView(favorite: favorite, isActive: session.selectedTab?.url?.host == favorite.url.host)
                    .onTapGesture { session.openFavorite(favorite) }
                    .accessibilityAction { session.openFavorite(favorite) }
                    .contextMenu {
                        Button("Remove from Favorites") { session.removeFavorite(favorite) }
                    }
            }
        }
    }
}

struct FavoriteTileView: View {
    let favorite: Favorite
    let isActive: Bool
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
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .help(favorite.title)
            .accessibilityElement()
            .accessibilityLabel(favorite.title)
            .accessibilityAddTraits(.isButton)
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

/// Shows a space's pinned tabs first, followed by the new tab row and the remaining tabs.
struct SpaceTabsView: View {
    @ObservedObject var session: BrowserSession
    let space: Space
    @Environment(\.colorScheme) private var colorScheme
    /// The tab being dragged to a new place, while the drag lasts and while it settles.
    @State private var drag: TabDrag?
    /// Set while a row's drag gesture is under way. It resets on its own when the gesture is cancelled, as when its row goes away.
    @GestureState private var isDragGestureActive = false
    /// Each tab row's frame in the list, for finding the row under the pointer and the place a dropped tab settles into.
    @State private var rowFrames: [UUID: CGRect] = [:]

    private static let coordinateSpace = "SpaceTabs"

    /// One row of the list. The pinned and the open tabs share one list, so a tab keeps its row, and its drag, when it crosses between them.
    private enum Item: Identifiable {
        case tab(Tab)
        case divider
        case newTab

        var id: String {
            switch self {
            case .tab(let tab): return tab.id.uuidString
            case .divider: return "divider"
            case .newTab: return "new-tab"
            }
        }
    }

    private struct TabDrag {
        let id: UUID
        /// The pointer's height in the list.
        var pointerY: CGFloat
        /// How far below the row's top the pointer took hold of it.
        let grabOffset: CGFloat
        /// Set once the pointer lets go, while the row moves into its place.
        var isSettling = false
    }

    private var items: [Item] {
        let pinned = session.tabs(in: space.id, pinned: true)
        let open = session.tabs(in: space.id, pinned: false)
        return pinned.map(Item.tab) + (pinned.isEmpty ? [] : [.divider]) + [.newTab] + open.map(Item.tab)
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
                    case .tab(let tab):
                        row(for: tab)
                    case .divider:
                        Divider().padding(.vertical, 4).padding(.horizontal, 10)
                    case .newTab:
                        NewTabButton(action: { session.showCommandPalette(.newTab, from: .sidebar) })
                    }
                }
            }
            // The margin sits inside the scroll view, which clips at its edges, so a lifted row's shadow has room at the sides.
            .padding(.horizontal, SidebarView.inset)
            .environment(\.isDraggingTab, drag != nil)
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(TabRowFramesKey.self) { rowFrames = $0 }
            // A cancelled gesture never reports its end, so the drag is dropped once the gesture is gone and nothing is settling.
            .onChange(of: isDragGestureActive) { isActive in
                guard !isActive else { return }
                DispatchQueue.main.async {
                    if !isDragGestureActive, drag?.isSettling == false { drag = nil }
                }
            }
            .overlay(alignment: .topLeading) { draggedRow }
        }
        .scrollIndicators(.never)
    }

    /// While its tab is dragged, a row leaves an empty, dimmed place in the list.
    private func row(for tab: Tab) -> some View {
        let isDragged = drag?.id == tab.id
        return TabRowView(session: session, tab: tab)
            .opacity(isDragged ? 0 : 1)
            .background {
                if isDragged {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06))
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TabRowFramesKey.self, value: [tab.id: proxy.frame(in: .named(Self.coordinateSpace))])
            })
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.coordinateSpace))
                .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
                .onChanged { dragChanged(tab, $0) }
                .onEnded { _ in dragEnded() })
    }

    /// The dragged tab follows the pointer above the list. On release it moves into its place before the list shows it there.
    @ViewBuilder private var draggedRow: some View {
        if let drag, let tab = session.tabs.first(where: { $0.id == drag.id }), let frame = rowFrames[drag.id] {
            TabRowView(session: session, tab: tab)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SidebarFill.selected.color(in: colorScheme)))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                .frame(width: frame.width)
                .offset(x: frame.minX, y: drag.isSettling ? frame.minY : drag.pointerY - drag.grabOffset)
                .allowsHitTesting(false)
        }
    }

    private func dragChanged(_ tab: Tab, _ value: DragGesture.Value) {
        guard drag?.isSettling != true else { return }
        if drag?.id != tab.id {
            drag = TabDrag(id: tab.id, pointerY: value.location.y, grabOffset: value.startLocation.y - (rowFrames[tab.id]?.minY ?? value.startLocation.y))
        }
        drag?.pointerY = value.location.y
        // The row under the pointer gives up its place to the dragged tab, with a light haptic for each new place.
        let tabs = session.tabs(in: space.id, pinned: true) + session.tabs(in: space.id, pinned: false)
        guard let target = tabs.first(where: { $0.id != tab.id && rowFrames[$0.id].map { ($0.minY...$0.maxY).contains(value.location.y) } == true }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { session.moveTab(tab.id, to: target) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func dragEnded() {
        guard drag != nil else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { drag?.isSettling = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { drag = nil }
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
    /// Rows a dragged tab passes over do not react to the pointer.
    private var showsHover: Bool { isHovering && !isDraggingTab }

    private var fill: Color {
        if isSelected { return SidebarFill.selected.color(in: colorScheme) }
        return showsHover ? SidebarFill.hover.color(in: colorScheme) : .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(tab: tab)
                .frame(width: 18, height: 18)
            Text(tab.displayTitle)
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 0)
            // The close button comes first under the pointer; otherwise holding Command shows the row's ⌘-number shortcut in its place.
            if showsHover {
                TabCloseButton { session.requestCloseTab(tab) }
            } else if commandKey.showsShortcuts, let number = session.shortcutNumber(for: tab) {
                TabShortcutBadge(number: number)
                    .transition(.modifier(active: BlurFade(isHidden: true), identity: BlurFade(isHidden: false)))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
        // Only the light appearance lifts the selected row; in the dark one its lighter fill is enough.
        .shadow(color: .black.opacity(isSelected && colorScheme == .light ? 0.08 : 0), radius: 1.5, y: 0.5)
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTabID = tab.id }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { session.togglePinned(tab) }
            Button("Add to Favorites") { session.addFavorite(tab) }.disabled(tab.url == nil)
            Divider()
            Button("Close Tab") { session.requestCloseTab(tab) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // A tap gesture alone does not answer the accessibility press, so VoiceOver could not select the tab.
        .accessibilityAction { session.selectedTabID = tab.id }
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

/// Fades and blurs a view in and out.
struct BlurFade: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: isHidden ? 4 : 0)
            .opacity(isHidden ? 0 : 1)
    }
}

/// Follows whether Command alone is held while the app is active. The shortcut numbers show once it has been held for a moment, so a quick ⌘-shortcut does not flash them, and go as soon as it is released.
final class CommandKeyState: ObservableObject {
    static let shared = CommandKeyState()
    @Published private(set) var showsShortcuts = false
    private var pendingShow: DispatchWorkItem?

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setDown(Self.isCommandAlone(event.modifierFlags))
            return event
        }
        // The app gets no key events while another app is active, so a release there would go unseen.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setDown(false)
        }
        // Modifier changes while a menu tracks reach no monitor, so the keys are read again when it closes.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: show)
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: space.symbol)
                .font(.system(size: 10))
                .foregroundStyle(space.tint.color)
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

    var body: some View {
        Button("Rename Space") {
            session.switchToSpace(space.id)
            session.renamingSpaceID = space.id
        }
        Picker("Color", selection: Binding(get: { space.tint }, set: { session.setTint($0, ofSpace: space.id) })) {
            ForEach(SpaceTint.allCases, id: \.self) { tint in
                Text(tint.rawValue.capitalized).tag(tint)
            }
        }
        Picker("Icon", selection: Binding(get: { space.symbol }, set: { session.setSymbol($0, ofSpace: space.id) })) {
            ForEach(Space.symbolChoices, id: \.symbol) { choice in
                Label(choice.name, systemImage: choice.symbol).tag(choice.symbol)
            }
        }
        Divider()
        Button("Move Left") { session.moveSpace(space.id, by: -1) }
            .disabled(index == 0)
        Button("Move Right") { session.moveSpace(space.id, by: 1) }
            .disabled(index == session.spaces.count - 1)
        Divider()
        Button("New Space", action: session.addSpace)
        Button("Delete Space") { session.deleteSpace(space.id) }
            .disabled(session.spaces.count < 2)
    }
}

/// The library button at the leading end, and one symbol per space in the middle with the new space button floating after them.
struct SidebarBottomBar: View {
    @ObservedObject var session: BrowserSession
    @Environment(\.sidebarWidth) private var width
    @Environment(\.sidebarIsFloating) private var isFloating

    /// The widest the symbols and the new space button may grow together while staying centered: each side keeps room for the 30-point library button and its gap, so the group never reaches it.
    private var groupWidth: CGFloat { width - 2 * SidebarView.inset - 2 * (30 + 4) }

    /// The width each symbol and the new space button take, close enough that the row reads as one group.
    fileprivate static let itemWidth: CGFloat = 18
    private static let stripSpace = "SpaceStrip"

    /// The symbols followed by the new space button. When the row scrolls, each item shrinks toward the ends of the strip, so nothing shows cut off there.
    private func strip(shrinksAtEdges: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(session.spaces) { space in
                let isCurrent = space.id == session.currentSpaceID
                Button(action: { session.switchToSpace(space.id) }) {
                    Image(systemName: space.symbol)
                        .font(.system(size: isCurrent ? 12 : 9))
                        .foregroundStyle(isCurrent ? space.tint.color : Color.secondary.opacity(0.6))
                        .frame(width: Self.itemWidth, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(EdgeShrink(isActive: shrinksAtEdges, stripWidth: groupWidth, coordinateSpace: Self.stripSpace))
                .contextMenu { SpaceMenuItems(session: session, space: space) }
                .help(space.name)
                .accessibilityLabel(space.name)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .id(space.id)
            }
            NewSpaceButton(action: session.addSpace)
                .modifier(EdgeShrink(isActive: shrinksAtEdges, stripWidth: groupWidth, coordinateSpace: Self.stripSpace))
        }
        // In the scrolling strip the first and last items can scroll clear of the shrinking ends.
        .padding(.horizontal, shrinksAtEdges ? EdgeShrink.distance : 0)
    }

    var body: some View {
        ZStack {
            HStack {
                LibraryButton(session: session)
                Spacer(minLength: 0)
            }
            // The symbols and the new space button are centered as one group, as if the library button were not there. Too many to fit scroll sideways together instead of covering the library button or widening the sidebar.
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
            // An optical correction beside the page: the group looks centered 2 points right of the true center. The floating sidebar keeps the true center.
            .offset(x: isFloating ? 0 : 2)
        }
        .frame(height: 28)
    }
}

/// Scales an item of a scrolling strip down from three items before either end of the strip, to nothing at the end itself.
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

/// A small, dim plus, so the new space button reads as part of the row of symbols rather than as a toolbar button.
private struct NewSpaceButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(isHovering ? 1 : 0.6))
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

extension EnvironmentValues {
    /// The sidebar's current width, which the space pages and the bottom bar lay out against.
    var sidebarWidth: CGFloat {
        get { self[SidebarWidthKey.self] }
        set { self[SidebarWidthKey.self] = newValue }
    }

    /// Set inside the sidebar that peeks out over the page while the sidebar is hidden.
    var sidebarIsFloating: Bool {
        get { self[SidebarIsFloatingKey.self] }
        set { self[SidebarIsFloatingKey.self] = newValue }
    }

    /// Set in a space's tab list while one of its tabs is dragged.
    var isDraggingTab: Bool {
        get { self[IsDraggingTabKey.self] }
        set { self[IsDraggingTabKey.self] = newValue }
    }
}

/// The strip along the sidebar's trailing edge. It shows the resize pointer, and dragging it reports the width the sidebar would have.
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
        /// Where the drag started in the window, and the width then.
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
