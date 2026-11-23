// A drag scrolls a list while the pointer stays near its top or bottom edge.
// `DragAutoScroll` defines edge bands, speed, and pixel steps. `DragAutoScroller` moves the enclosing scroll view once per display frame and reports each move during the drag.
// A space's list uses it for lifted tab and folder rows (`SpaceTabsView.swift`).
import AppKit
import SwiftUI

/// The bands inside a list's ends where a drag scrolls it, and how fast.
enum DragAutoScroll {
    /// The height of the band inside each end of the list's visible frame.
    static let band: CGFloat = 32
    /// The step at the list's edge, in points per sixtieth of a second, so that the list scrolls as fast at any display refresh rate.
    static let maxStep: CGFloat = 12
    /// How far a drag that starts in a band moves toward that band's edge before the band scrolls the list.
    static let armingDistance: CGFloat = 8

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

    /// Whether a drag that started at `start` and has its pointer at `point` scrolls the list from a band: once the pointer is outside the band the drag started in, or `armingDistance` points nearer that band's edge than `start`. A drag that starts outside both bands scrolls the list at once. So a row grabbed in a band, such as the last one showing, moves a place or two without the list scrolling under it.
    static func arms(from start: CGPoint, at point: CGPoint, in visible: CGRect) -> Bool {
        let startStep = step(at: start, in: visible)
        if startStep < 0 { return step(at: point, in: visible) >= 0 || point.y <= start.y - armingDistance }
        if startStep > 0 { return step(at: point, in: visible) <= 0 || point.y >= start.y + armingDistance }
        return true
    }

    /// The part of `step` that the list can scroll from `offset`, its distance from its top, where `limit` is the offset that shows its end: nothing past either end, and nothing further down from an offset already past `limit`.
    static func distance(_ step: CGFloat, from offset: CGFloat, limit: CGFloat) -> CGFloat {
        step > 0 ? max(0, min(step, limit - offset)) : min(0, max(step, -offset))
    }

    /// Where a list at `offset` stops after `step` on a display of `scale` pixels per point, with `carried`, the part of earlier steps toward the same end not yet scrolled: on a whole pixel short of the step's end, or on the list's end, so that steps under a pixel add up instead of leaving the rows between pixels. Returns the new offset, the same while the steps add up to less than a pixel, and the part carried to the next frame, or nil when the list cannot scroll toward the step (`distance`).
    static func scroll(from offset: CGFloat, by step: CGFloat, carrying carried: CGFloat, limit: CGFloat, scale: CGFloat) -> (offset: CGFloat, carried: CGFloat)? {
        let distance = Self.distance(step, from: offset, limit: limit)
        guard distance != 0 else { return nil }
        let carried = (carried < 0) == (distance < 0) ? carried : 0
        let target = offset + Self.distance(distance + carried, from: offset, limit: limit)
        guard target != 0, target != limit else { return (target, 0) }
        let pixels = target * scale
        let aligned = (distance > 0 ? pixels.rounded(.down) : pixels.rounded(.up)) / scale
        let next = distance > 0 ? max(aligned, offset) : min(aligned, offset)
        return (next, target - next)
    }

    private static func eased(_ depth: CGFloat) -> CGFloat { depth * depth }
}

/// Placed in a SwiftUI `ScrollView`'s content, follows the `NSScrollView` that AppKit hosts it in while a drag holds `point`: it reports each scroll of the list to `onScroll`, positive toward the bottom, where the content moves up under the pointer, whether it scrolls the list itself or a mouse's wheel does. While `scrolls` is set and `point` is in a band of `visible` (`DragAutoScroll`), it scrolls the list once per display frame of the view's screen (`NSView.displayLink(target:selector:)`), on the screen's pixel grid, up to `limit`, the offset that shows the content's end. It stops when `point` leaves the bands or turns nil, `scrolls` turns off, the list reaches that end, or the scroll view refuses a scroll. Without an enclosing scroll view it does nothing.
struct DragAutoScroller: NSViewRepresentable {
    /// The pointer of the drag that the list's scrolls move the rows under, or nil while none does.
    let point: CGPoint?
    /// Whether the band under `point` scrolls the list (`DragAutoScroll.arms(from:at:in:)`).
    let scrolls: Bool
    /// The list's visible frame, in `point`'s coordinate space.
    let visible: CGRect
    let limit: CGFloat
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollerView { ScrollerView() }

    func updateNSView(_ view: ScrollerView, context: Context) {
        view.onScroll = onScroll
        view.update(point: point, scrolls: scrolls, visible: visible, limit: limit)
    }

    static func dismantleNSView(_ view: ScrollerView, coordinator: ()) {
        view.update(point: nil, scrolls: false, visible: .zero, limit: 0)
    }

    /// The view that `DragAutoScroller` places in the list: it reports the list's scrolls during a drag and scrolls the list on a display link while the pointer is in a band.
    final class ScrollerView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private(set) var point: CGPoint?
        private var scrolls = false
        private var visible = CGRect.zero
        private var limit: CGFloat = 0
        private var link: CADisplayLink?
        /// The part of the steps toward one end that the list has not scrolled yet, less than a pixel.
        private var carried: CGFloat = 0
        /// The clip view whose scrolls go to `onScroll` while a drag holds `point`, and its bounds' top at the last one.
        private var observedClip: NSClipView?
        private var reportedTop: CGFloat = 0

        // Clicks, scrolls, and drops reach the views around it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Follows the enclosing scroll view's scrolls while `point` is set, and runs the display link while the view is in a window and the list can scroll toward the band under the pointer, stopping it otherwise.
        func update(point: CGPoint?, scrolls: Bool, visible: CGRect, limit: CGFloat) {
            self.point = point
            self.scrolls = scrolls
            self.visible = visible
            self.limit = limit
            observe(point == nil ? nil : enclosingScrollView?.contentView)
            if window != nil, let scrollView = enclosingScrollView, canScroll(scrollView) { start() } else { stop() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            update(point: point, scrolls: scrolls, visible: visible, limit: limit)
        }

        /// Scrolls the enclosing scroll view by the step for `interval` seconds, on the pixel grid of the view's window, and returns how far the list moved: 0 while the steps add up to less than a pixel, and nil once it cannot scroll, with the pointer outside the bands, the list at that end, a scroll the clip view refused, or no scroll view around this view. The clip view's bounds change reports the scroll (`onScroll`).
        @discardableResult
        func advance(over interval: TimeInterval) -> CGFloat? {
            guard let scrollView = enclosingScrollView, canScroll(scrollView), let point else {
                carried = 0
                return nil
            }
            let clip = scrollView.contentView, inset = scrollView.contentInsets.top
            // A view that joined its scroll view after the last update reports its scrolls from here.
            observe(clip)
            let offset = clip.bounds.minY + inset
            let step = DragAutoScroll.step(at: point, in: visible, over: interval)
            guard let next = DragAutoScroll.scroll(from: offset, by: step, carrying: carried, limit: limit, scale: window?.backingScaleFactor ?? 1) else {
                carried = 0
                return nil
            }
            carried = next.carried
            guard next.offset != offset else { return 0 }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: next.offset - inset))
            scrollView.reflectScrolledClipView(clip)
            let moved = clip.bounds.minY + inset - offset
            guard moved != 0 else {
                carried = 0
                return nil
            }
            return moved
        }

        /// Whether `scrolls` is set and the list in `scrollView` can scroll toward the band under the pointer: not from that end, nor in a scroll view whose content, unlike SwiftUI's, is not flipped.
        private func canScroll(_ scrollView: NSScrollView) -> Bool {
            guard scrolls, let point, scrollView.contentView.isFlipped else { return false }
            let offset = scrollView.contentView.bounds.minY + scrollView.contentInsets.top
            return DragAutoScroll.distance(DragAutoScroll.step(at: point, in: visible), from: offset, limit: limit) != 0
        }

        /// Sends `clip`'s scrolls to `onScroll`, or stops sending them for nil.
        private func observe(_ clip: NSClipView?) {
            guard clip !== observedClip else { return }
            if let observedClip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip) }
            observedClip = clip
            guard let clip else { return }
            reportedTop = clip.bounds.minY
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange), name: NSView.boundsDidChangeNotification, object: clip)
        }

        @objc private func clipBoundsDidChange(_ notification: Notification) {
            guard let observedClip else { return }
            let top = observedClip.bounds.minY, distance = top - reportedTop
            reportedTop = top
            if distance != 0 { onScroll?(distance) }
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
            carried = 0
        }

        @objc private func frameDidArrive(_ link: CADisplayLink) {
            let interval = link.targetTimestamp - link.timestamp
            if advance(over: interval > 0 ? interval : 1.0 / 60) == nil { stop() }
        }
    }
}
