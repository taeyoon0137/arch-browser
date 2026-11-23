// The dimming over a page while its tab's prompt shows. It takes every click, scroll, and gesture meant for the page, so the page waits for the answer while the sidebar, other panes, and other windows go on working. VoiceOver skips it.
import AppKit
import SwiftUI

/// The dimming over a page while its tab's prompt shows, as the file header describes; `PanePromptLayer` puts it under the card.
struct PromptScrim: View {
    /// The page frame's radius, or 0 while the page fills the window.
    let cornerRadius: CGFloat
    /// A click on the dimming, which selects the pane's tab and gives its card the focus.
    let onMouseDown: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// Black at 10% in the light appearance and 22% in the dark one, 8 points more with Increase Contrast.
    static func opacity(colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Double {
        (colorScheme == .dark ? 0.22 : 0.10) + (contrast == .increased ? 0.08 : 0)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(Self.opacity(colorScheme: colorScheme, contrast: contrast)))
            .overlay(ScrimEvents(onMouseDown: onMouseDown))
            .accessibilityHidden(true)
    }
}

/// The view that takes the page's events under the dimming. The page keeps its own tracking areas and can set its pointer as the mouse moves, so the arrow is set again on each move.
private struct ScrimEvents: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> EventView { EventView() }

    func updateNSView(_ view: EventView, context: Context) {
        view.onMouseDown = onMouseDown
    }

    /// Takes the clicks, scrolls, and gestures over the dimmed page, and reports a click to `onMouseDown`.
    final class EventView: NSView {
        var onMouseDown: (() -> Void)?

        // A click here selects the pane instead of moving the window, also as the click that brings the window forward.
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func isAccessibilityElement() -> Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate, .mouseMoved], owner: self))
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
        override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
        override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }

        override func mouseDown(with event: NSEvent) { onMouseDown?() }
        override func rightMouseDown(with event: NSEvent) { onMouseDown?() }
        override func otherMouseDown(with event: NSEvent) { onMouseDown?() }
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
        override func rightMouseUp(with event: NSEvent) {}
        override func otherMouseUp(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
        override func magnify(with event: NSEvent) {}
        override func smartMagnify(with event: NSEvent) {}
        override func rotate(with event: NSEvent) {}
        override func swipe(with event: NSEvent) {}
        override func pressureChange(with event: NSEvent) {}
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}
