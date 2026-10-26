// Measures where the window's traffic light buttons sit so that the sidebar's top row can line up with them. The measurement follows window resizes and full screen, where the buttons hide.
import AppKit
import SwiftUI

/// Positions measured from the window's top-leading corner.
struct WindowButtonMetrics: Equatable {
    /// The vertical center of the buttons.
    var centerY: CGFloat = 20
    /// The trailing edge of the last button, or nil while the buttons are hidden in full screen.
    var trailingEdge: CGFloat? = 70
}

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

final class WindowButtonsReaderView: NSView {
    /// Posted with the window when its buttons finish sliding with the sidebar.
    static let buttonsDidSettleNotification = Notification.Name("ARCHWindowButtonsDidSettle")

    var onChange: ((WindowButtonMetrics) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastMetrics: WindowButtonMetrics?

    // A window that closes releases its views without moving them out of it first.
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.report(WindowButtonMetrics(trailingEdge: nil))
        })
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in self?.measure() })
        observers.append(center.addObserver(forName: Self.buttonsDidSettleNotification, object: window, queue: .main) { [weak self] _ in self?.measure() })
        // The app shows its toolbar again after leaving full screen or failing to enter it, which moves the buttons, so the measurement waits for that layout.
        for name in [NSWindow.didExitFullScreenNotification, BrowserWindowController.didFailToEnterFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.window?.layoutIfNeeded()
                    self?.measure()
                }
            })
        }
        measure()
    }

    private func measure() {
        guard let window else { return }
        guard !window.styleMask.contains(.fullScreen) else { return report(WindowButtonMetrics(trailingEdge: nil)) }
        // In full screen the buttons move to a separate title bar window, so only buttons in this window count.
        guard let close = window.standardWindowButton(.closeButton), let zoom = window.standardWindowButton(.zoomButton),
              close.window === window, zoom.window === window else { return }
        let closeFrame = close.convert(close.bounds, to: nil)
        let zoomFrame = zoom.convert(zoom.bounds, to: nil)
        report(WindowButtonMetrics(centerY: window.frame.height - closeFrame.midY, trailingEdge: zoomFrame.maxX))
    }

    private func report(_ metrics: WindowButtonMetrics) {
        guard metrics != lastMetrics else { return }
        lastMetrics = metrics
        // Measurements arrive during layout; SwiftUI state changes wait for the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in self?.onChange?(metrics) }
    }
}
