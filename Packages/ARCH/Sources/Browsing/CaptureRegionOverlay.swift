// The region capture overlay: it dims the page, and the rectangle the user drags out is the part of the viewport to capture. Escape cancels.
import AppKit
import SwiftUI

/// Covers the selected page while the user chooses the region to capture. It takes the clicks, scrolling, and keys meant for the page, and leaving the window, as when another tab is selected, cancels the capture.
struct CaptureRegionOverlay: NSViewRepresentable {
    let windowModel: BrowserWindowModel
    /// The engine's view, whose coordinates the region is given in.
    let pageView: NSView
    /// The page frame's radius, or 0 while the page fills the window in fullscreen.
    var cornerRadius = PageFrameShape.cornerRadius

    func makeNSView(context: Context) -> SelectionView {
        let view = SelectionView()
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: SelectionView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
        view.onSelect = { [weak view, windowModel, pageView] rect in
            guard let view else { return }
            windowModel.finishRegionCapture(view.convert(rect, to: pageView))
        }
        view.onCancel = { [windowModel] in windowModel.cancelRegionCapture() }
    }

    // SwiftUI removes the view during an update, which must not change the window's state, so the cancellation follows it.
    static func dismantleNSView(_ view: SelectionView, coordinator: ()) {
        guard let cancel = view.onCancel else { return }
        DispatchQueue.main.async(execute: cancel)
    }

    final class SelectionView: NSView {
        var onSelect: ((CGRect) -> Void)?
        var onCancel: (() -> Void)?
        /// Where the drag started.
        private var dragOrigin: NSPoint?
        /// The dragged rectangle; the page shows through it undimmed.
        private var selection: NSRect? {
            didSet { needsDisplay = true }
        }
        /// A drag shorter than this on either side chooses nothing, so a click leaves the overlay for another try.
        private static let minimumSide: CGFloat = 4
        /// Centered, so that the lines of a hint that wraps in a narrow pane stay centered in its box.
        private static let hint: NSAttributedString = {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            return NSAttributedString(string: "Drag across the page to capture a region. Press Escape to cancel.",
                                      attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        }()

        override var acceptsFirstResponder: Bool { true }
        // A drag here chooses the region instead of moving the window.
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Keys go here instead of the page. SwiftUI places the view before the window finishes its update, so focus follows on the next turn of the run loop.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        // The page under the overlay keeps its own tracking area and can set its pointer as the mouse moves, so the crosshair is set again on each move.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate, .mouseMoved], owner: self))
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
        override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }
        override func scrollWheel(with event: NSEvent) {}

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            dragOrigin = clamped(convert(event.locationInWindow, from: nil))
            selection = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragOrigin else { return }
            let point = clamped(convert(event.locationInWindow, from: nil))
            selection = NSRect(x: min(dragOrigin.x, point.x), y: min(dragOrigin.y, point.y), width: abs(point.x - dragOrigin.x), height: abs(point.y - dragOrigin.y))
            NSCursor.crosshair.set()
        }

        override func mouseUp(with event: NSEvent) {
            dragOrigin = nil
            guard let selection, selection.width >= Self.minimumSide, selection.height >= Self.minimumSide else { return self.selection = nil }
            onSelect?(selection)
        }

        override func keyDown(with event: NSEvent) {
            guard event.keyCode == 53 else { return super.keyDown(with: event) }
            onCancel?()
        }

        private func clamped(_ point: NSPoint) -> NSPoint {
            NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        }

        /// Dims the page outside the dragged rectangle and outlines it. Before a drag, a hint at the top says what to do.
        override func draw(_ dirtyRect: NSRect) {
            let dimming = NSBezierPath(rect: bounds)
            if let selection {
                dimming.append(NSBezierPath(rect: selection))
                dimming.windingRule = .evenOdd
            }
            NSColor.black.withAlphaComponent(0.3).setFill()
            dimming.fill()
            guard let selection else { return drawHint() }
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            NSColor.white.setStroke()
            border.stroke()
        }

        /// One line in a capsule, 16 points below the page's top. A page too narrow for the line wraps the text, keeping 16 points beside the box, and the box keeps the capsule's corners.
        private func drawHint() {
            let radius = (Self.hint.size().height + 12) / 2
            let text = Self.hint.boundingRect(with: NSSize(width: max(0, bounds.width - 56), height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
            let size = NSSize(width: ceil(text.width), height: ceil(text.height))
            let height = size.height + 12
            let box = NSRect(x: bounds.midX - size.width / 2 - 12, y: isFlipped ? bounds.minY + 16 : bounds.maxY - 16 - height, width: size.width + 24, height: height)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
            Self.hint.draw(in: box.insetBy(dx: 12, dy: 6))
        }
    }
}
