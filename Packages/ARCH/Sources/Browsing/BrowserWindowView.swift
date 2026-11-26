// Main window content sits over translucent window material tinted by the current space (`SpaceTheme.swift`).
// `SidebarView.swift` contains navigation, the address pill, favorites, current-space tabs or library, and the bottom bar's library button and space switcher.
// Those parts live in `AddressPillView.swift`, `FavoritesGridView.swift`, `SpaceTabsView.swift`, `TabRowView.swift`, and `SidebarBottomBar.swift`.
// The selected page or its `SplitView.swift` fills the remaining area with nothing above it. This file also holds window buttons, the page frame, and backgrounds.
import AppKit
import SwiftUI

/// Arranges the sidebar, page, panels, and transient overlays of a browser window.
public struct BrowserWindowView: View {
    @ObservedObject var session: BrowserSession
    /// The window this view shows. Its subviews read it from the environment.
    @ObservedObject var windowModel: BrowserWindowModel
    @State private var windowButtons = WindowButtonMetrics()
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
    /// How far a swipe that moves the docked library has pushed the page, while it does.
    @State private var librarySwipePush: CGFloat?
    @StateObject private var sidebarDrag = SidebarDragState()

    public init(session: BrowserSession, window: BrowserWindowModel) {
        self.session = session
        windowModel = window
    }

    /// The margin between the page and the window's edges.
    static let pageMargin: CGFloat = 8
    /// The space between the sidebar's controls and the page.
    static let sidebarGap: CGFloat = 8
    /// The window's coordinate space, shared by the tab rows and the lifted row that follows a drag.
    static let coordinateSpace = "BrowserWindow"
    /// The floating card sits at the page's 8-point margin, so its corners match the page frame's, concentric with the window's corner. Larger corners would leave a sliver of the page showing outside the card's curve where the two frames meet.
    static let cardCornerRadius = PageFrameShape.cornerRadius

    /// The sidebar's own margin is part of the gap beside it.
    private var pageMargins: EdgeInsets {
        EdgeInsets(top: Self.pageMargin, leading: windowModel.isSidebarVisible ? Self.sidebarGap - SidebarView.inset : Self.pageMargin, bottom: Self.pageMargin, trailing: Self.pageMargin)
    }

    /// How far the open library pushes the page aside. The page keeps its size, so it moves rather than narrows.
    private var libraryPush: CGFloat {
        guard !windowModel.isPrivate, windowModel.isSidebarVisible, !windowModel.isPageFullscreen else { return 0 }
        return librarySwipePush ?? (windowModel.isLibraryVisible ? SidebarColumn.libraryWidening : 0)
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if windowModel.isSidebarVisible, !windowModel.isPageFullscreen {
                    SidebarColumn(session: session, windowButtons: windowButtons, width: SidebarView.clampedWidth(sidebarWidth)) {
                        sidebarWidth = Double(SidebarView.clampedWidth($0))
                    }
                    // Docking the floating card keeps the sidebar where the card was; only the page resizes.
                    .transition(isSidebarPeeking ? .identity : .move(edge: .leading))
                }
                // While the library is open, the page and the panel beside it move aside at their size, dimmed and still, as the sidebar's visible part is; a click on them closes the library.
                HStack(spacing: 0) {
                    PageAreaView(session: session, sidebarDrag: sidebarDrag, margins: pageMargins)
                        // In the page's own corner, so an agent panel or page reader beside the page keeps its controls.
                        .overlay(alignment: .bottomTrailing) {
                            if !windowModel.isPrivate, !windowModel.isSidebarVisible, !isSidebarPeeking, !windowModel.isPageFullscreen {
                                LibraryButton(session: session, activityOnly: true)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(2 * Self.pageMargin)
                            }
                        }
                    if !windowModel.isPrivate, !windowModel.isPageFullscreen {
                        if windowModel.agentPanel != nil {
                            AgentPanelColumn(session: session)
                        } else {
                            PageReaderColumn(session: session)
                        }
                    }
                }
                .offset(x: libraryPush)
                .opacity(1 - SidebarColumn.displacedDimming * libraryPush / SidebarColumn.libraryWidening)
                .allowsHitTesting(libraryPush == 0)
                .overlay {
                    if libraryPush > 0 {
                        Color.clear
                            .contentShape(Rectangle())
                            .offset(x: libraryPush)
                            .onTapGesture { withAnimation(SidebarView.pageSpring) { windowModel.isLibraryVisible = false } }
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityHidden(libraryPush > 0)
            }
            if !windowModel.isSidebarVisible || isSidebarPeeking, !windowModel.isPageFullscreen {
                peekingSidebar
            }
            SplitDropIndicator(sidebarDrag: sidebarDrag)
            TabDragLayer(session: session, sidebarDrag: sidebarDrag)
                .modifier(SidebarAppearance())
            SidebarItemDragLayer(session: session, sidebarDrag: sidebarDrag)
                .modifier(SidebarAppearance())
            CommandPaletteLayer(session: session, addressPillFrame: addressPillFrame, windowWidth: windowSize.width, addressPillPull: $addressPillPull)
            if windowModel.isTabSwitcherVisible {
                TabSwitcherView(session: session)
            }
        }
        .overlay(alignment: .bottom) { SiteRuleToastView(window: windowModel) }
        .coordinateSpace(name: Self.coordinateSpace)
        .environmentObject(sidebarDrag)
        .environmentObject(windowModel)
        .environment(\.addressPillPull, addressPillPull)
        .onPreferenceChange(AddressPillFrameKey.self) { addressPillFrame = $0 }
        // When the fingers lift, the page settles with the library's spring.
        .onPreferenceChange(LibrarySwipePushKey.self) { push in
            if push == nil { withAnimation(SidebarView.pageSpring) { librarySwipePush = nil } } else { librarySwipePush = push }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { windowSize = proxy.size }
                .onChange(of: proxy.size) { windowSize = $1 }
        })
        .background(SpaceBackgroundView())
        .modifier(SpaceThemeModifier(tint: windowModel.isPrivate ? .gray : windowModel.currentSpace.tint, isPrivate: windowModel.isPrivate))
        .preferredColorScheme(windowModel.isPrivate ? .dark : nil)
        .background(WindowButtonsReader { windowButtons = $0 })
        // Showing, hiding, or pushing the sidebar aside for the library slides it and resizes the page.
        .animation(SidebarView.pageSpring, value: windowModel.isSidebarVisible)
        .animation(SidebarView.pageSpring, value: windowModel.isLibraryVisible)
        // The window buttons slide away with the sidebar and return with it or with the card. Full screen uses its own buttons.
        .background(WindowButtonsVisibility(isHidden: windowButtons.trailingEdge != nil && !windowModel.isSidebarVisible && !isSidebarPeeking,
                                            slideDistance: windowButtons.trailingEdge == nil ? nil : SidebarView.clampedWidth(sidebarWidth) + Self.pageMargin,
                                            reference: windowReference))
        // Full screen adds or removes the toolbar's child window, which must not hold the card open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification).merge(with: NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification))) { notification in
            if notification.object as? NSWindow === windowReference.window { recordChildWindows() }
        }
        // Hiding the sidebar only slides it away; the card appears when the pointer next reaches the window's edge.
        .onChange(of: windowModel.isSidebarVisible) { _, isVisible in
            peekCheck?.cancel()
            guard isVisible, isSidebarPeeking else { return isSidebarPeeking = false }
            withAnimation(SidebarView.pageSpring) { isCardDocking = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + SidebarView.pageSpringSettleDelay) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isSidebarPeeking = false
                    isCardDocking = false
                }
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: BrowserWindowKind.main.minimumContentSize.width, minHeight: BrowserWindowKind.main.minimumContentSize.height)
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

    /// Reveals the floating sidebar card and starts checking when it should close.
    private func peekSidebar() {
        guard !windowModel.isSidebarVisible else { return }
        peekCheck?.cancel()
        if !isSidebarPeeking {
            recordChildWindows()
            withAnimation(SidebarView.pageSpring) { isSidebarPeeking = true }
        }
        scheduleCheckOfPeek()
    }

    /// Remembers child windows already open before the sidebar card appears.
    private func recordChildWindows() {
        childWindowsBeforePeek = Set((windowReference.window?.childWindows ?? []).map(ObjectIdentifier.init))
    }

    // Check rather than track the pointer: a card sliding under it gets no hover until the pointer leaves.
    /// Schedules another check of whether the sidebar card is still in use.
    private func scheduleCheckOfPeek() {
        let work = DispatchWorkItem { checkPeek() }
        peekCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Keeps the card visible while hovered, while its text is edited, while one of its tabs, favorites, or space symbols is dragged, or while its menu, popover, sheet, or the command palette is open. Child windows that were there before do not count, and neither does a prompt card's field, which is no text of the sidebar's.
    private func checkPeek() {
        let window = windowReference.window
        let hasOpenChild = window?.attachedSheet != nil
            || (window?.childWindows ?? []).contains { $0.isVisible && !childWindowsBeforePeek.contains(ObjectIdentifier($0)) }
        let isEditingText = windowModel.renamingSpaceID != nil || windowModel.renamingTabID != nil || windowModel.renamingFolderID != nil
            || (window?.firstResponder is NSText && windowModel.focusedPromptTabID == nil)
        let isInUse = isPointerOverSidebar || isEditingText || windowModel.commandPaletteMode != nil || sidebarDrag.item != nil || RunLoop.main.currentMode == .eventTracking || hasOpenChild
        if isInUse { return scheduleCheckOfPeek() }
        withAnimation(SidebarView.pageSpring) { isSidebarPeeking = false }
        // Close the card's library after the card disappears, so the card reopens showing the sidebar.
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarView.pageSpringSettleDelay) {
            guard !windowModel.isSidebarVisible, !isSidebarPeeking, windowModel.isLibraryVisible else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { windowModel.isLibraryVisible = false }
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

    /// Tracks window button positions and supersedes earlier slide completions.
    final class Coordinator {
        var isHidden: Bool?
        /// The buttons' resting positions, recorded while they slide.
        var restingOrigins: [NSWindow.ButtonType: NSPoint] = [:]
        /// Counts slides so an earlier slide's completion does not affect a later slide.
        var generation = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    /// Moves the standard window buttons with the sidebar when their visibility changes.
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
            if !theme.isPrivate {
                WindowMaterialView(cornerRadius: cornerRadius)
            }
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: theme.backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing))
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
                    .accessibilityHidden(true)
                Text("This page stopped working", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                Text("Reload to open it again.", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button(localized("Reload"), action: tab.reloadAfterCrash)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            // A narrow pane wraps the lines, centered like the rest, inside the margin of the placeholder for a tab shown elsewhere.
            .multilineTextAlignment(.center)
            .padding(20)
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
