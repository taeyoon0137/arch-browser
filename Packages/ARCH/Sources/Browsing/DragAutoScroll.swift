// Scrolls a list while a drag holds the pointer near its top or bottom edge: `DragAutoScroll` holds the bands and the speed, and `DragAutoScroller` scrolls the scroll view that encloses it once per display frame. A space's list uses it for its lifted tab and folder rows (`SpaceTabsView.swift`).
import AppKit
import SwiftUI

/// The bands inside a list's ends where a drag scrolls it, and how fast.
enum DragAutoScroll {
    /// The height of the band inside each end of the list's visible frame.
    static let band: CGFloat = 32
    /// The step at the list's edge, in points per sixtieth of a second, so that the list scrolls as fast at any display refresh rate.
    static let maxStep: CGFloat = 12

    /// How far the list scrolls in `interval` seconds with the pointer at `point` in its visible frame: toward the top for a negative step and toward the bottom for a positive one. Outside the list and between the bands the step is 0. In a band it grows with the square of the pointer's depth, from 0 at the band's inner edge to `maxStep` per sixtieth of a second at the list's edge. A list shorter than two bands splits its height between them. `point` and `visible` share a coordinate space whose y grows downward.
    static func step(at point: CGPoint, in visible: CGRect, over interval: TimeInterval = 1.0 / 60) -> CGFloat {
        guard visible.contains(point) else { return 0 }
        let band = min(Self.band, visible.height / 2)
        let fromTop = point.y - visible.minY, fromBottom = visible.maxY - point.y
        let frames = CGFloat(interval * 60)
        if fromTop < band { return -maxStep * eased(1 - fromTop / band) * frames }
        if fromBottom < band { return maxStep * eased(1 - fromBottom / band) * frames }
        return 0
    }

    /// The part of `step` that the list can scroll from `offset`, its distance from its top, where `limit` is the offset that shows its end: nothing past either end, and nothing further down from an offset already past `limit`.
    static func distance(_ step: CGFloat, from offset: CGFloat, limit: CGFloat) -> CGFloat {
        step > 0 ? max(0, min(step, limit - offset)) : min(0, max(step, -offset))
    }

    private static func eased(_ depth: CGFloat) -> CGFloat { depth * depth }
}

/// Placed in a SwiftUI `ScrollView`'s content, scrolls the `NSScrollView` that AppKit hosts it in while `point` is in a band of `visible` (`DragAutoScroll`), once per display frame of the view's screen (`NSView.displayLink(target:selector:)`), up to `limit`, the offset that shows the content's end. It stops when `point` leaves the bands or turns nil, or the list reaches that end, and reports each frame's distance to `onScroll` as it scrolls, positive toward the bottom, where the content moves up under the pointer. Without an enclosing scroll view it does nothing.
struct DragAutoScroller: NSViewRepresentable {
    /// The pointer of the drag that scrolls the list, or nil while none does.
    let point: CGPoint?
    /// The list's visible frame, in `point`'s coordinate space.
    let visible: CGRect
    let limit: CGFloat
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollerView { ScrollerView() }

    func updateNSView(_ view: ScrollerView, context: Context) {
        view.onScroll = onScroll
        view.update(point: point, visible: visible, limit: limit)
    }

    static func dismantleNSView(_ view: ScrollerView, coordinator: ()) {
        view.update(point: nil, visible: .zero, limit: 0)
    }

    final class ScrollerView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private(set) var point: CGPoint?
        private var visible = CGRect.zero
        private var limit: CGFloat = 0
        private var link: CADisplayLink?

        // Clicks, scrolls, and drops reach the views around it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Runs the display link while the view is in a window and the list can scroll toward the band under the pointer, and stops it otherwise.
        func update(point: CGPoint?, visible: CGRect, limit: CGFloat) {
            self.point = point
            self.visible = visible
            self.limit = limit
            if window != nil, let scrollView = enclosingScrollView, distance(over: 1.0 / 60, in: scrollView) != 0 { start() } else { stop() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            update(point: point, visible: visible, limit: limit)
        }

        /// Scrolls the enclosing scroll view by the step for `interval` seconds and returns the distance, 0 if there is none or no scroll view encloses this view.
        @discardableResult
        func advance(over interval: TimeInterval) -> CGFloat {
            guard let scrollView = enclosingScrollView else { return 0 }
            let clip = scrollView.contentView
            let moved = distance(over: interval, in: scrollView)
            guard moved != 0 else { return 0 }
            // Reported first, so that the content's new frames, however soon SwiftUI reports them, come after it.
            onScroll?(moved)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + moved))
            scrollView.reflectScrolledClipView(clip)
            return moved
        }

        /// How far the step for `interval` seconds scrolls `scrollView` from where it is: 0 with the pointer outside the bands, with the list at that end, or in a scroll view whose content, unlike SwiftUI's, is not flipped.
        private func distance(over interval: TimeInterval, in scrollView: NSScrollView) -> CGFloat {
            guard let point, scrollView.contentView.isFlipped else { return 0 }
            let step = DragAutoScroll.step(at: point, in: visible, over: interval)
            return DragAutoScroll.distance(step, from: scrollView.contentView.bounds.minY + scrollView.contentInsets.top, limit: limit)
        }

        private func start() {
            guard link == nil else { return }
            let link = displayLink(target: self, selector: #selector(frameDidArrive))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        private func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func frameDidArrive(_ link: CADisplayLink) {
            let interval = link.targetTimestamp - link.timestamp
            if advance(over: interval > 0 ? interval : 1.0 / 60) == 0 { stop() }
        }
    }
}
