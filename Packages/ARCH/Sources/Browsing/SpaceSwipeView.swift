// Tracks two-finger horizontal trackpad swipes over the sidebar and reports how far the fingers have moved, so the sidebar's space pages can follow them. A local event monitor sees the scroll events before the sidebar's views do, so the swipe also works over the tab list, and vertical scrolling passes through untouched.
import AppKit
import SwiftUI

struct SpaceSwipeView: NSViewRepresentable {
    /// When disabled, no new swipe starts and scroll events pass through.
    var isEnabled = true
    /// Receives the horizontal finger travel in points while a swipe is in progress. Positive values mean the fingers moved right.
    let onChange: (_ translation: CGFloat) -> Void
    /// Receives the final travel and the finger velocity in points per second when the fingers lift.
    let onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeNSView(context: Context) -> SpaceSwipeNSView {
        let view = SpaceSwipeNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SpaceSwipeNSView, context: Context) {
        view.isEnabled = isEnabled
        view.onChange = onChange
        view.onEnd = onEnd
    }
}

final class SpaceSwipeNSView: NSView {
    var isEnabled = true
    var onChange: ((CGFloat) -> Void)?
    var onEnd: ((CGFloat, CGFloat) -> Void)?
    private var monitor: Any?
    /// Each gesture locks to the axis of its first few points of travel.
    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var isTracking = false
    private var travel = CGSize.zero
    private var velocity: CGFloat = 0
    private var lastTimestamp: TimeInterval = 0

    // Clicks reach the sidebar's controls; this view only watches scroll events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    /// Returns the event to pass it on, or nil to consume it as part of a horizontal swipe.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.hasPreciseScrollingDeltas, event.window === window else { return event }
        // Disabling stops only new swipes; the view still handles an existing swipe's end and momentum.
        if event.phase == .began {
            isTracking = isEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
            axis = .undecided
            travel = .zero
            velocity = 0
            lastTimestamp = event.timestamp
        }
        // The momentum that follows a swipe must not scroll anything else.
        if !event.momentumPhase.isEmpty { return axis == .horizontal ? nil : event }
        guard isTracking else { return event }
        // With natural scrolling the deltas follow the fingers; otherwise they run the other way.
        let deltaX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        travel.width += deltaX
        travel.height += event.scrollingDeltaY
        if axis == .undecided, max(abs(travel.width), abs(travel.height)) > 6 {
            axis = abs(travel.width) > abs(travel.height) ? .horizontal : .vertical
        }
        guard axis == .horizontal else { return event }
        let interval = event.timestamp - lastTimestamp
        if interval > 0, deltaX != 0 {
            velocity = velocity * 0.6 + deltaX / CGFloat(interval) * 0.4
        }
        lastTimestamp = event.timestamp
        if event.phase == .ended || event.phase == .cancelled {
            isTracking = false
            onEnd?(travel.width, event.phase == .cancelled ? 0 : velocity)
        } else {
            onChange?(travel.width)
        }
        return nil
    }
}
