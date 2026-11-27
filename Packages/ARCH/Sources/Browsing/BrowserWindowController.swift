// The AppKit window of one browser window. The session creates each one as it opens a window and releases it once the window closes.
import AppKit
import Combine
import QuartzCore
import SwiftUI

/// The AppKit window of one `BrowserWindowModel`: a titled window with an empty unified toolbar that hosts `BrowserWindowView`, or `SmallWindowView` for a small window. It reports becoming main and closing to the session, records the frame that the saved session keeps, and gives the window the title that the Window menu and Mission Control show.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: BrowserWindowModel
    private let smallPresentationSourcePoint: CGPoint
    private var titleObserver: AnyCancellable?
    private var previewSourceEventMonitor: Any?
    private var smallPresentation: NSPanel?
    private var smallPresentationCompletion: DispatchWorkItem?
    /// Consumed by the next show; only the URL-creation path has a new page without existing pixels to preserve.
    var isInitialSmallPresentation = false
    /// Set from the start of the transition into full screen until the window is back, while its frame is not the one to keep.
    private var isInFullScreen = false
    /// Posted with the window when it cannot enter full screen, for which AppKit posts no notification of its own.
    static let didFailToEnterFullScreenNotification = Notification.Name("ARCHWindowDidFailToEnterFullScreen")

    /// How far a saved frame must reach onto a screen's visible area, across and down, for the window to open there.
    private static let minimumVisibleLength: CGFloat = 100
    /// Only the small window's geometry is remembered; its page and tab are never restored.
    private static let smallWindowFrameKey = "ARCHSmallWindowFrame"

    /// Builds the window hidden at its saved frame. A small window cascades from another small window or centers its remembered size on the pointer; a main window cascades from `source` or centers at its default size.
    init(model: BrowserWindowModel, cascadingFrom source: NSWindow?) {
        self.model = model
        smallPresentationSourcePoint = NSEvent.mouseLocation
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: model.kind.defaultContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        if model.isPrivate {
            window.appearance = NSAppearance(named: .darkAqua)
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar gives the title bar the standard height of the system's own apps and centers the traffic light buttons in it, on the line of the sidebar's top row. A small window's toolbar is compact, as in the system's small windows, so its title bar and row stay thin.
        window.toolbar = NSToolbar(identifier: "Main")
        window.toolbarStyle = model.kind == .small ? .unifiedCompact : .unified
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        // The sidebar takes the place of window tabs, and the session, not AppKit, decides what windows open at launch.
        window.tabbingMode = .disallowed
        window.isRestorable = false
        // The controller owns the window, which goes with it.
        window.isReleasedWhenClosed = false
        window.contentViewController = Self.contentViewController(for: model)
        window.contentMinSize = model.kind.minimumContentSize
        if let frame = model.restorableFrame {
            window.setFrame(Self.restoredFrame(frame, screens: NSScreen.screens.map(\.visibleFrame)), display: false)
        } else if model.kind == .small {
            // Installing the hosting controller may replace the initial content size.
            window.setContentSize(model.kind.defaultContentSize)
            let savedFrame = UserDefaults.standard.string(forKey: Self.smallWindowFrameKey).map(NSRectFromString)
            let rememberedFrame: CGRect? = savedFrame.flatMap { frame in
                frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
                    && frame.width > 0 && frame.height > 0 ? frame : nil
            }
            let cascadeSource = source.flatMap { $0.styleMask.contains(.fullScreen) ? nil : $0 }
            let preferredSize = rememberedFrame?.size ?? model.kind.defaultContentSize
            let preferredFrame = cascadeSource?.frame.offsetBy(dx: 30, dy: -30)
                ?? CGRect(x: smallPresentationSourcePoint.x - preferredSize.width / 2,
                          y: smallPresentationSourcePoint.y - preferredSize.height / 2,
                          width: preferredSize.width, height: preferredSize.height)
            let screenPoint = cascadeSource?.screen.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
                ?? smallPresentationSourcePoint
            window.setFrame(Self.smallWindowFrame(size: model.kind.defaultContentSize, pointer: screenPoint,
                                                 screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) },
                                                 preferredFrame: preferredFrame), display: false)
        } else if let source, !source.styleMask.contains(.fullScreen) {
            window.setFrame(source.frame, display: false)
            // The first call places the window on the source and returns the next cascade point, where the second places it within the screen.
            window.cascadeTopLeft(from: window.cascadeTopLeft(from: NSPoint(x: source.frame.minX, y: source.frame.maxY)))
        } else {
            window.setContentSize(model.kind.defaultContentSize)
            window.center()
        }
        super.init(window: window)
        window.delegate = self
        model.nsWindow = window
        model.restorableFrame = window.frame
        previewSourceEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.model.recordPreviewSourceEvent(event)
            return event
        }
        // The model announces a change before it makes it, so the title is read on the next turn of the run loop.
        titleObserver = Publishers.Merge3(model.objectWillChange, model.session.$spaces.map { _ in }, model.session.$personas.map { _ in })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateTitle() }
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        if let previewSourceEventMonitor { NSEvent.removeMonitor(previewSourceEventMonitor) }
    }

    /// Grow the small window's presentation from its opening point without resizing the page or changing its saved frame.
    override func showWindow(_ sender: Any?) {
        let isInitialPresentation = isInitialSmallPresentation
        isInitialSmallPresentation = false
        guard model.kind == .small, let window, !window.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            super.showWindow(sender)
            return
        }
        window.alphaValue = 0
        super.showWindow(sender)
        // Loading callbacks may not have arrived for a newly created page yet.
        // Existing pages keep their live pixels, including when a popup is still loading.
        if isInitialPresentation,
           let presentationView = window.contentView?.superview ?? window.contentView {
            presentationView.layoutSubtreeIfNeeded()
            if let bitmap = presentationView.bitmapImageRepForCachingDisplay(in: presentationView.bounds) {
                presentationView.cacheDisplay(in: presentationView.bounds, to: bitmap)
                if let image = bitmap.cgImage {
                    animateSmallWindow(image: image, in: window)
                    return
                }
            }
        }
        // Existing pages and presentations that cannot be cached use the supported live crossfade.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        } completionHandler: { [weak window] in
            window?.alphaValue = 1
        }
    }

    private func animateSmallWindow(image: CGImage, in window: NSWindow) {
        let destination = window.frame
        let source = smallPresentationSourcePoint
        let scale = 20 / destination.width
        let sourceRect = CGRect(x: source.x - 10, y: source.y - destination.height * scale / 2,
                                width: 20, height: destination.height * scale)
        // Leave enough transparent surface for the full-bleed shadow's blur and downward offset.
        let shadowRadius: CGFloat = 22
        let shadowOffset: CGFloat = 14
        let shadowExtent = 3 * shadowRadius + shadowOffset
        let canvas = destination.union(sourceRect).insetBy(dx: -shadowExtent, dy: -shadowExtent)
        let panel = NSPanel(contentRect: canvas, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        let surface = NSView(frame: CGRect(origin: .zero, size: canvas.size))
        surface.wantsLayer = true
        panel.contentView = surface
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: destination.size)
        layer.position = CGPoint(x: destination.midX - canvas.minX, y: destination.midY - canvas.minY)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.475
        layer.shadowRadius = shadowRadius
        layer.shadowOffset = CGSize(width: 0, height: -shadowOffset)
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let content = CALayer()
        content.frame = layer.bounds
        content.contents = image
        content.contentsScale = window.backingScaleFactor
        content.cornerRadius = 10
        content.masksToBounds = true
        layer.addSublayer(content)
        surface.layer?.addSublayer(layer)
        var initial = CATransform3DMakeTranslation(source.x - destination.midX, source.y - destination.midY, 0)
        initial = CATransform3DScale(initial, scale, scale, 1)
        let spring = CASpringAnimation(keyPath: "transform")
        let frequency = 2 * Double.pi / 0.18
        spring.mass = 1
        spring.stiffness = frequency * frequency
        spring.damping = 2 * 0.885 * frequency
        spring.duration = spring.settlingDuration
        spring.fromValue = NSValue(caTransform3D: initial)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let opacity = CASpringAnimation(keyPath: "opacity")
        opacity.mass = spring.mass
        opacity.stiffness = spring.stiffness
        opacity.damping = spring.damping
        opacity.duration = spring.duration
        opacity.fromValue = 0
        opacity.toValue = 1
        layer.add(spring, forKey: "ARCHSmallWindowPresentationTransform")
        layer.add(opacity, forKey: "ARCHSmallWindowPresentationOpacity")
        smallPresentation = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        let completion = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.smallPresentation === panel else { return }
            self.finishSmallPresentation()
        }
        smallPresentationCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + spring.duration, execute: completion)
    }

    private func finishSmallPresentation(restoringWindow: Bool = true) {
        smallPresentationCompletion?.cancel()
        smallPresentationCompletion = nil
        guard let panel = smallPresentation else { return }
        smallPresentation = nil
        if restoringWindow { window?.alphaValue = 1 }
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
    }

    /// The window's content: the main window's sidebar and page, or the small window's row and page.
    private static func contentViewController(for model: BrowserWindowModel) -> NSViewController {
        switch model.kind {
        case .main: hostingController(BrowserWindowView(session: model.session, window: model))
        case .small: hostingController(SmallWindowView(session: model.session, window: model))
        }
    }

    private static func hostingController(_ rootView: some View) -> NSViewController {
        let controller = NSHostingController(rootView: rootView)
        controller.sizingOptions = []
        return controller
    }

    /// Where a window with the saved `frame` opens, given the screens' visible areas with the main screen first: at `frame` while it reaches far enough onto one of them, as it does unless its display is gone. Otherwise at the same size, at most the main screen's, centered on the main screen.
    static func restoredFrame(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        let isOnScreen = screens.contains { screen in
            let overlap = screen.intersection(frame)
            return overlap.width >= minimumVisibleLength && overlap.height >= minimumVisibleLength
        }
        guard !isOnScreen, let main = screens.first else { return frame }
        return self.frame(of: frame.size, centeredIn: main)
    }

    /// Constrains remembered or cascaded geometry to a screen's visible area with a 20-point margin. With no preferred frame, the initial rectangle has zero origin and the default size.
    static func smallWindowFrame(size: CGSize, pointer: CGPoint, screens: [(frame: CGRect, visibleFrame: CGRect)], preferredFrame: CGRect? = nil) -> CGRect {
        let requested = preferredFrame ?? CGRect(origin: .zero, size: size)
        guard let screen = screens.first(where: { $0.frame.contains(pointer) }) ?? screens.first else { return requested }
        guard screen.visibleFrame.width > 40, screen.visibleFrame.height > 40 else { return frame(of: requested.size, centeredIn: screen.visibleFrame) }
        let area = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        let fitted = CGSize(width: min(requested.width, area.width), height: min(requested.height, area.height))
        return CGRect(x: min(max(requested.midX - fitted.width / 2, area.minX), area.maxX - fitted.width),
                      y: min(max(requested.midY - fitted.height / 2, area.minY), area.maxY - fitted.height),
                      width: fitted.width, height: fitted.height)
    }

    /// `size`, at most `area`'s, centered in `area`.
    private static func frame(of size: CGSize, centeredIn area: CGRect) -> CGRect {
        let fitted = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        return CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// The title bar hides the title. The Window menu and Mission Control show it, with the window's Persona and current space as `title(tabTitle:spaceName:place:)` builds it, and the selected tab's title as its row shows it (`Tab.shownTitle`). While an internal page covers the page area, the title names that page, as the page area and the address pill do, not the tab under it.
    private func updateTitle() {
        guard let window else { return }
        if model.isPrivate {
            window.title = Self.title(tabTitle: model.selectedTab?.shownTitle, spaceName: localized("Private Browsing"), place: localized("Private Browsing"))
            return
        }
        let space = model.currentSpace
        let title = Self.title(tabTitle: model.internalPage?.title ?? model.selectedTab?.shownTitle, spaceName: space.name, place: model.session.displayedPlace(ofPersona: space.resolvedPersonaID, space: space))
        if window.title != title { window.title = title }
    }

    /// A window's title: `tabTitle`, the selected tab's title or the internal page's while one is open, followed by `place`, the window's Persona and current space, as "Example Domain — Work / Research", or without either title `place` alone. With one Persona, `place` is nil, and the title is the tab's or page's title or the space's name.
    nonisolated static func title(tabTitle: String?, spaceName: String, place: String?) -> String {
        guard let tabTitle else { return place ?? spaceName }
        return place.map { "\(tabTitle) \u{2014} \($0)" } ?? tabTitle
    }

    func windowDidBecomeMain(_ notification: Notification) {
        model.session.windowDidBecomeMain(model)
    }

    /// A small window closes with its tab, which goes to the closed list once its page agrees, so that a page can ask to stay. The session closes the window when the tab closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.kind == .small, let tab = model.selectedTab else { return true }
        model.session.requestCloseTab(tab)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        finishSmallPresentation(restoringWindow: false)
        if model.kind == .small { recordFrame() }
        model.session.windowWillClose(model)
    }

    func windowDidMove(_ notification: Notification) {
        finishSmallPresentation()
        recordFrame()
    }

    func windowDidResize(_ notification: Notification) {
        finishSmallPresentation()
        recordFrame()
    }

    func windowWillMiniaturize(_ notification: Notification) {
        finishSmallPresentation()
    }

    /// Keeps the window's frame for the saved session, which then saves, except in full screen, where the frame from before stays. Full screen is not restored, so the window opens at that frame next time.
    private func recordFrame() {
        guard !model.isPrivate, let window, !isInFullScreen else { return }
        if model.kind == .small {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.smallWindowFrameKey)
        }
        guard window.frame != model.restorableFrame else { return }
        model.restorableFrame = window.frame
        model.session.scheduleSave()
    }

    // Full screen hides the traffic lights, so the toolbar would only cover the sidebar's top row there.
    func windowWillEnterFullScreen(_ notification: Notification) {
        finishSmallPresentation()
        if model.kind == .small { recordFrame() }
        isInFullScreen = true
        window?.toolbar?.isVisible = false
    }

    // The window stays as it was when it cannot enter full screen, and the views that prepared for full screen hear of it.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isInFullScreen = false
        window.toolbar?.isVisible = true
        NotificationCenter.default.post(name: Self.didFailToEnterFullScreenNotification, object: window)
    }

    // AppKit restores the toolbar's full screen state while it exits, so the toolbar returns once the window is back.
    func windowDidExitFullScreen(_ notification: Notification) {
        isInFullScreen = false
        window?.toolbar?.isVisible = true
        recordFrame()
    }
}

extension BrowserWindowKind {
    /// The size of a window without a saved frame that cascades from no other.
    var defaultContentSize: NSSize {
        switch self {
        case .main: NSSize(width: 1200, height: 800)
        case .small: NSSize(width: 1185, height: 832)
        }
    }

    /// The smallest content the user can resize the window to.
    var minimumContentSize: NSSize {
        switch self {
        case .main: NSSize(width: 800, height: 500)
        case .small: NSSize(width: 480, height: 360)
        }
    }
}
