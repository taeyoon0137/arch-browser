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
                    let width = SidebarView.clampedWidth(sidebarWidth)
                    SidebarView(session: session, windowButtons: windowButtons)
                        .frame(width: width)
                        // The handle covers the gap between the sidebar's controls and the page: the sidebar's own margin and the part of the gap outside it.
                        .overlay(alignment: .trailing) {
                            SidebarResizeHandle(width: width) { sidebarWidth = Double(SidebarView.clampedWidth($0)) }
                                .frame(width: Self.sidebarGap)
                                .offset(x: Self.sidebarGap - SidebarView.inset)
                        }
                        .environment(\.sidebarWidth, width)
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
                // Give each mode its own view identity to reset the typed text and initial address.
                CommandPaletteView(session: session, mode: mode)
                    .id(mode)
                    .transition(.commandPalette(from: session.commandPaletteOrigin))
            }
        }
        // The transitions carry their own timing; this makes every palette change animate.
        .animation(.paletteIn(from: session.commandPaletteOrigin), value: session.commandPaletteMode)
        .background(SpaceBackgroundView(tint: session.currentSpace.tint.color))
        .background(WindowButtonsReader { windowButtons = $0 })
        // Hiding or showing the sidebar slides it and widens or narrows the page.
        .animation(SidebarView.pageSpring, value: session.isSidebarVisible)
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
                SidebarView(session: session, windowButtons: buttons)
                    .frame(width: width)
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

    /// Keeps the card out while the pointer is over it, or while a menu, popover, or sheet opened from it, or the command palette, is open.
    private func checkPeek() {
        let isInUse = isPointerOverSidebar || session.commandPaletteMode != nil || RunLoop.main.currentMode == .eventTracking
            || NSApp.windows.contains { $0.isVisible && ($0.parent != nil || $0.attachedSheet != nil) }
        if isInUse { return scheduleCheckOfPeek() }
        withAnimation(SidebarView.pageSpring) { isSidebarPeeking = false }
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
    @Environment(\.sidebarWidth) private var width
    /// How far the space pages follow the fingers during a swipe, in points.
    @State private var swipeTranslation: CGFloat = 0
    @State private var swipePassesHalfway = false

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
        swipeTranslation = pageTranslation(for: travel)
        let passesHalfway = abs(swipeTranslation) > width / 2
        if passesHalfway != swipePassesHalfway {
            swipePassesHalfway = passesHalfway
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Moves to the neighboring space when the swipe went far or fast enough, otherwise returns to the current one.
    private func swipeEnded(_ travel: CGFloat, velocity: CGFloat) {
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
                // The library pushes the favorites and space pages out toward the page. Both reach the sidebar's edges so that they slide in from outside it.
                ZStack {
                    if session.isLibraryVisible {
                        LibraryView(session: session)
                            .padding(.horizontal, Self.inset)
                            .transition(.move(edge: .leading))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if !session.favorites.isEmpty {
                                FavoritesGridView(session: session)
                                    .padding(.horizontal, Self.inset)
                            }
                            SpacePagesView(session: session, translation: swipeTranslation)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .trailing))
                    }
                }
                .padding(.top, 6)
                .padding(.horizontal, -Self.inset)
                .clipped()
            }
            // The swipe area reaches the sidebar's edges and the gap above the bar.
            .background(SpaceSwipeView(onChange: swipeChanged, onEnd: swipeEnded).padding(.horizontal, -Self.inset).padding(.bottom, -8))
            SidebarBottomBar(session: session)
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 10)
        .animation(Self.pageSpring, value: session.isLibraryVisible)
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
                    .padding(.horizontal, SidebarView.inset)
                    .frame(width: width)
                    // Clipping hides the other pages but does not stop them from taking clicks over the page beside the sidebar.
                    .allowsHitTesting(isCurrent)
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

    var body: some View {
        let pinned = session.tabs(in: space.id, pinned: true)
        let open = session.tabs(in: space.id, pinned: false)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SpaceHeaderView(session: session, space: space)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                ForEach(pinned) { tab in
                    TabRowView(session: session, tab: tab)
                }
                if !pinned.isEmpty {
                    Divider().padding(.vertical, 4).padding(.horizontal, 10)
                }
                NewTabButton(action: { session.showCommandPalette(.newTab, from: .sidebar) })
                ForEach(open) { tab in
                    TabRowView(session: session, tab: tab)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

struct TabRowView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var isSelected: Bool { tab.id == session.selectedTabID }

    private var fill: Color {
        if isSelected { return SidebarFill.selected.color(in: colorScheme) }
        return isHovering ? SidebarFill.hover.color(in: colorScheme) : .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(tab: tab)
                .frame(width: 18, height: 18)
            Text(tab.displayTitle)
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isHovering {
                TabCloseButton { session.requestCloseTab(tab) }
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

    private var symbols: some View {
        HStack(spacing: 4) {
            ForEach(session.spaces) { space in
                let isCurrent = space.id == session.currentSpaceID && !session.isLibraryVisible
                Button(action: { session.switchToSpace(space.id) }) {
                    Image(systemName: space.symbol)
                        .font(.system(size: isCurrent ? 12 : 9))
                        .foregroundStyle(isCurrent ? space.tint.color : Color.secondary.opacity(0.6))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { SpaceMenuItems(session: session, space: space) }
                .help(space.name)
                .accessibilityLabel(space.name)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .id(space.id)
            }
        }
    }

    var body: some View {
        ZStack {
            HStack {
                LibraryButton(session: session)
                Spacer(minLength: 0)
            }
            // The symbols and the new space button are centered as one group, as if the library button were not there.
            HStack(spacing: 2) {
                // Too many symbols to fit scroll sideways instead of covering the buttons or widening the sidebar.
                ViewThatFits(in: .horizontal) {
                    symbols
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) { symbols }
                            .onAppear { proxy.scrollTo(session.currentSpaceID) }
                            .onChange(of: session.currentSpaceID) { id in withAnimation { proxy.scrollTo(id) } }
                    }
                }
                NewSpaceButton(action: session.addSpace)
            }
            .frame(maxWidth: groupWidth)
            // An optical correction beside the page: the group looks centered 4 points right of the true center. The floating sidebar keeps the true center.
            .offset(x: isFloating ? 0 : 4)
        }
        .frame(height: 28)
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
                .frame(width: 26, height: 26)
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
