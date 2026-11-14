// The AppKit window of one browser window. The session creates each one as it opens a window and releases it once the window closes.
import AppKit
import Combine
import SwiftUI

/// The AppKit window of one `BrowserWindowModel`: a titled window with an empty unified toolbar that hosts `BrowserWindowView`, or `SmallWindowView` for a small window. It reports becoming main and closing to the session, records the frame that the saved session keeps, and gives the window the title that the Window menu and Mission Control show.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: BrowserWindowModel
    private var titleObserver: AnyCancellable?
    /// Set from the start of the transition into full screen until the window is back, while its frame is not the one to keep.
    private var isInFullScreen = false
    /// Posted with the window when it cannot enter full screen, for which AppKit posts no notification of its own.
    static let didFailToEnterFullScreenNotification = Notification.Name("ARCHWindowDidFailToEnterFullScreen")

    /// How far a saved frame must reach onto a screen's visible area, across and down, for the window to open there.
    private static let minimumVisibleLength: CGFloat = 100

    /// Builds the window hidden: at the model's saved frame, kept on a screen; without one, at `source`'s size and cascaded from it, or at the kind's default size without a source or while the source is in full screen, a main window centered and a small window centered on the screen with the pointer.
    init(model: BrowserWindowModel, cascadingFrom source: NSWindow?) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: model.kind.defaultContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
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
        } else if let source, !source.styleMask.contains(.fullScreen) {
            window.setFrame(source.frame, display: false)
            // The first call places the window on the source and returns the next cascade point, where the second places it within the screen.
            window.cascadeTopLeft(from: window.cascadeTopLeft(from: NSPoint(x: source.frame.minX, y: source.frame.maxY)))
        } else {
            window.setContentSize(model.kind.defaultContentSize)
            switch model.kind {
            case .main: window.center()
            case .small: window.setFrame(Self.centeredFrame(size: window.frame.size, pointer: NSEvent.mouseLocation, screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) }), display: false)
            }
        }
        super.init(window: window)
        window.delegate = self
        model.nsWindow = window
        model.restorableFrame = window.frame
        // The model announces a change before it makes it, so the title is read on the next turn of the run loop.
        titleObserver = Publishers.Merge3(model.objectWillChange, model.session.$spaces.map { _ in }, model.session.$personas.map { _ in })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateTitle() }
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrowserWindowController is created with a window model")
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

    /// Where a small window opens without another small window to cascade from: at `size`, at most the screen's visible area, centered on the visible area of the screen whose frame holds `pointer`, or of the main screen, the first, when none does.
    static func centeredFrame(size: CGSize, pointer: CGPoint, screens: [(frame: CGRect, visibleFrame: CGRect)]) -> CGRect {
        guard let screen = screens.first(where: { $0.frame.contains(pointer) }) ?? screens.first else { return CGRect(origin: .zero, size: size) }
        return frame(of: size, centeredIn: screen.visibleFrame)
    }

    /// `size`, at most `area`'s, centered in `area`.
    private static func frame(of size: CGSize, centeredIn area: CGRect) -> CGRect {
        let fitted = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        return CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// The title bar hides the title. The Window menu and Mission Control show it, with the window's Persona and current space as `title(tabTitle:spaceName:place:)` builds it. While an internal page covers the page area, the title names that page, as the page area and the address pill do, not the tab under it.
    private func updateTitle() {
        guard let window else { return }
        let space = model.currentSpace
        let title = Self.title(tabTitle: model.internalPage?.title ?? model.selectedTab?.displayTitle, spaceName: space.name, place: model.session.displayedPlace(ofPersona: space.resolvedPersonaID, space: space))
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
        model.session.windowWillClose(model)
    }

    /// The next sheet of a tab on the window's screen can show once a sheet has left the window, the tab's own or another, such as a Persona's name prompt or the print panel. AppKit lets go of the sheet only after this call, so the queue looks on the next turn of the run loop.
    func windowDidEndSheet(_ notification: Notification) {
        let sheets = model.session.sheets
        DispatchQueue.main.async { sheets.showNext() }
    }

    func windowDidMove(_ notification: Notification) {
        recordFrame()
    }

    func windowDidResize(_ notification: Notification) {
        recordFrame()
    }

    /// Keeps the window's frame for the saved session, which then saves, except in full screen, where the frame from before stays. Full screen is not restored, so the window opens at that frame next time.
    private func recordFrame() {
        guard let window, !isInFullScreen, window.frame != model.restorableFrame else { return }
        model.restorableFrame = window.frame
        model.session.scheduleSave()
    }

    // Full screen hides the traffic lights, so the toolbar would only cover the sidebar's top row there.
    func windowWillEnterFullScreen(_ notification: Notification) {
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
        case .small: NSSize(width: 900, height: 640)
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
