// The AppKit window of one browser window. The session creates each one as it opens a window and releases it once the window closes.
import AppKit
import Combine
import SwiftUI

/// The AppKit window of one `BrowserWindowModel`: a titled window with an empty unified toolbar that hosts `BrowserWindowView`. It reports becoming main and closing to the session, records the frame that the saved session keeps, and gives the window the title that the Window menu and Mission Control show.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: BrowserWindowModel
    private var titleObserver: AnyCancellable?
    /// Set from the start of the transition into full screen until the window is back, while its frame is not the one to keep.
    private var isInFullScreen = false

    /// The size of a window without a saved frame that cascades from no other.
    private static let defaultContentSize = NSSize(width: 1200, height: 800)
    /// How far a saved frame must reach onto a screen's visible area, across and down, for the window to open there.
    private static let minimumVisibleLength: CGFloat = 100

    /// Builds the window hidden: at the model's saved frame, kept on a screen; without one, at `source`'s size and cascaded from it, or centered at the default size without a source or while the source is in full screen.
    init(model: BrowserWindowModel, cascadingFrom source: NSWindow?) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar gives the title bar the standard height of the system's own apps and centers the traffic light buttons in it, on the sidebar's top row.
        window.toolbar = NSToolbar(identifier: "Main")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        // The sidebar takes the place of window tabs, and the session, not AppKit, decides what windows open at launch.
        window.tabbingMode = .disallowed
        window.isRestorable = false
        // The controller owns the window, which goes with it.
        window.isReleasedWhenClosed = false
        let hostingController = NSHostingController(rootView: BrowserWindowView(session: model.session, window: model))
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 800, height: 500)
        if let frame = model.restorableFrame {
            window.setFrame(Self.restoredFrame(frame, screens: NSScreen.screens.map(\.visibleFrame)), display: false)
        } else if let source, !source.styleMask.contains(.fullScreen) {
            window.setFrame(source.frame, display: false)
            // The first call places the window on the source and returns the next cascade point, where the second places it within the screen.
            window.cascadeTopLeft(from: window.cascadeTopLeft(from: NSPoint(x: source.frame.minX, y: source.frame.maxY)))
        } else {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }
        super.init(window: window)
        window.delegate = self
        model.nsWindow = window
        model.restorableFrame = window.frame
        // The model announces a change before it makes it, so the title is read on the next turn of the run loop.
        titleObserver = Publishers.Merge(model.objectWillChange, model.session.$spaces.map { _ in })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateTitle() }
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrowserWindowController is created with a window model")
    }

    /// Where a window with the saved `frame` opens, given the screens' visible areas with the main screen first: at `frame` while it reaches far enough onto one of them, as it does unless its display is gone. Otherwise at the same size, at most the main screen's, centered on the main screen.
    static func restoredFrame(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        let isOnScreen = screens.contains { screen in
            let overlap = screen.intersection(frame)
            return overlap.width >= minimumVisibleLength && overlap.height >= minimumVisibleLength
        }
        guard !isOnScreen, let main = screens.first else { return frame }
        let size = CGSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        return CGRect(x: main.midX - size.width / 2, y: main.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The title bar hides the title. The Window menu and Mission Control show it: the selected tab's title, or the space's name with no tab selected.
    private func updateTitle() {
        guard let window else { return }
        let title = model.selectedTab?.displayTitle ?? model.currentSpace.name
        if window.title != title { window.title = title }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        model.session.windowDidBecomeMain(model)
    }

    func windowWillClose(_ notification: Notification) {
        model.session.windowWillClose(model)
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

    // The window stays as it was when it cannot enter full screen.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isInFullScreen = false
        window.toolbar?.isVisible = true
    }

    // AppKit restores the toolbar's full screen state while it exits, so the toolbar returns once the window is back.
    func windowDidExitFullScreen(_ notification: Notification) {
        isInFullScreen = false
        window?.toolbar?.isVisible = true
        recordFrame()
    }
}
