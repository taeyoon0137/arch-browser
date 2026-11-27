// Measures the window's leading titlebar controls so the sidebar also leaves room for system status indicators.
import AppKit
import SwiftUI

/// Positions measured from the window's top-leading corner.
struct WindowButtonMetrics: Equatable {
    /// The vertical center of the buttons.
    var centerY: CGFloat = 20
    /// The trailing edge reserved by AppKit for the leading controls, or nil in full screen.
    var trailingEdge: CGFloat? = 70
}

/// Reports where the window's traffic light buttons sit to `onChange`, through a `WindowButtonsReaderView`.
struct WindowButtonsReader: NSViewRepresentable {
    let onChange: (WindowButtonMetrics) -> Void

    func makeNSView(context: Context) -> WindowButtonsReaderView {
        let view = WindowButtonsReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowButtonsReaderView, context: Context) {
        view.onChange = onChange
    }
}

/// Measures the window's buttons as the view joins a window, as the window resizes or enters and leaves full screen, and as the buttons settle, and reports each change.
final class WindowButtonsReaderView: NSView {
    /// Posted with the window when its buttons finish sliding with the sidebar.
    static let buttonsDidSettleNotification = Notification.Name("ARCHWindowButtonsDidSettle")

    var onChange: ((WindowButtonMetrics) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastMetrics: WindowButtonMetrics?
    private var buttonFrames: (close: CGRect, zoom: CGRect, titlebar: CGRect?)?
    private var measuredWindowSize: CGSize?
    private var keepsButtonsHiddenForFullscreen = false

    // A window that closes releases its views without moving them out of it first.
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        buttonFrames = nil
        measuredWindowSize = nil
        keepsButtonsHiddenForFullscreen = false
        guard let window else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.keepsButtonsHiddenForFullscreen = true
            self?.buttonFrames = nil
            self?.measuredWindowSize = nil
            self?.report(WindowButtonMetrics(trailingEdge: nil))
        })
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in self?.measure() })
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in self?.measure(updatingButtonFrames: false) })
        observers.append(center.addObserver(forName: Self.buttonsDidSettleNotification, object: window, queue: .main) { [weak self] _ in self?.measure() })
        // The app shows its toolbar again after leaving full screen or failing to enter it, which moves the buttons, so the measurement waits for that layout.
        for name in [NSWindow.didExitFullScreenNotification, BrowserWindowController.didFailToEnterFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.keepsButtonsHiddenForFullscreen = false
                DispatchQueue.main.async {
                    self?.window?.layoutIfNeeded()
                    self?.measure()
                }
            })
        }
        measure()
    }

    private func measure(updatingButtonFrames: Bool = true) {
        guard let window else { return }
        guard !keepsButtonsHiddenForFullscreen, !window.styleMask.contains(.fullScreen) else { return report(WindowButtonMetrics(trailingEdge: nil)) }
        // Display updates can arrive during the sidebar's button slide. Keep its resting
        // geometry until a resize/fullscreen/settle measurement, while status children stay live.
        if updatingButtonFrames || buttonFrames == nil || measuredWindowSize != window.frame.size {
            // In full screen the buttons move to another title bar window.
            guard let close = window.standardWindowButton(.closeButton), let zoom = window.standardWindowButton(.zoomButton),
                  close.window === window, zoom.window === window else { return }
            let closeFrame = close.convert(close.bounds, to: nil)
            let zoomFrame = zoom.convert(zoom.bounds, to: nil)
            if closeFrame.minX >= 0, zoomFrame.minX >= 0 {
                buttonFrames = (closeFrame, zoomFrame, close.superview.map { $0.convert($0.bounds, to: nil) })
                measuredWindowSize = window.frame.size
            }
        }
        guard let buttonFrames else { return }
        let closeFrame = buttonFrames.close
        let zoomFrame = buttonFrames.zoom
        var trailingEdge = zoomFrame.maxX
        if let titlebarFrame = buttonFrames.titlebar {
            let buttonFrame = closeFrame.union(zoomFrame)
            // System status controls can occupy a child window over the standard buttons.
            // Reserve only children contained in this titlebar and overlapping that group.
            for child in window.childWindows ?? [] where child.isVisible && child.alphaValue > 0 {
                let frame = window.convertFromScreen(child.frame)
                if titlebarFrame.contains(frame), frame.intersects(buttonFrame) {
                    trailingEdge = max(trailingEdge, frame.maxX)
                }
            }
        }
        report(WindowButtonMetrics(centerY: window.frame.height - closeFrame.midY,
                                   trailingEdge: trailingEdge))
    }

    private func report(_ metrics: WindowButtonMetrics) {
        guard metrics != lastMetrics else { return }
        lastMetrics = metrics
        // Measurements arrive during layout; SwiftUI state changes wait for the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in self?.onChange?(metrics) }
    }
}
