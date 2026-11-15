// Hosts a tab's engine view in SwiftUI. Replaces the view when the pane shows another tab.
import AppKit
import SwiftUI

struct WebContentsHostView: NSViewRepresentable {
    let contentView: NSView?
    /// The page frame's radius, or 0 while the page fills the window in fullscreen.
    var cornerRadius = PageFrameShape.cornerRadius
    /// Runs when a click lands on the page, such as one in a split view pane that is not focused. `nil` when nothing needs to know.
    var onClick: (() -> Void)?
    /// Set while a prompt card covers the page, so that VoiceOver reads the card and not the page that waits under it.
    var hidesPageFromAccessibility = false

    func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        return container
    }

    func updateNSView(_ container: ContainerView, context: Context) {
        container.layer?.cornerRadius = cornerRadius
        container.onClick = onClick
        container.hidesPageFromAccessibility = hidesPageFromAccessibility
        if let current = container.subviews.first, current === contentView { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let contentView else { return }
        // A new container has no size yet. The page keeps the size it had until the container gets one, so it never lays out for an empty viewport.
        if !container.bounds.isEmpty { contentView.frame = container.bounds }
        container.addSubview(contentView)
    }

    // The page leaves the window with its pane, as it does when another tab takes its place.
    static func dismantleNSView(_ container: ContainerView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    final class ContainerView: NSView {
        var onClick: (() -> Void)? {
            didSet { updateClickMonitor() }
        }
        var hidesPageFromAccessibility = false {
            didSet {
                guard hidesPageFromAccessibility != oldValue else { return }
                NSAccessibility.post(element: self, notification: .layoutChanged)
            }
        }
        private var clickMonitor: Any?

        // The page under a card has no accessibility children, so VoiceOver cannot move into it.
        override func accessibilityChildren() -> [Any]? {
            hidesPageFromAccessibility ? [] : super.accessibilityChildren()
        }

        deinit {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        }

        // The page fills the container. Autoresizing would instead grow a page that comes from a pane of another size by this container's own change in size.
        override func resizeSubviews(withOldSize oldSize: NSSize) {
            subviews.forEach { $0.frame = bounds }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateClickMonitor()
        }

        /// The engine's view handles its clicks itself, so a local monitor watches for them while the container is in a window and `onClick` is set.
        private func updateClickMonitor() {
            let isNeeded = window != nil && onClick != nil
            if isNeeded, clickMonitor == nil {
                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                    self?.handleClick(event)
                    return event
                }
            } else if !isNeeded, let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
        }

        /// Counts a click only where it reaches the page (`takesClick(at:)`).
        private func handleClick(_ event: NSEvent) {
            guard let window, event.window === window, takesClick(at: event.locationInWindow) else { return }
            onClick?()
        }
    }
}

extension NSView {
    /// Whether a click at `locationInWindow` reaches the view or one inside it, as the window hands the click on: not where a view above takes it, such as a prompt card, its dimming, the find bar, or a pane's close control. A local monitor sees a click before the window does, so this also says no while a sheet or a modal window keeps the window from taking clicks.
    func takesClick(at locationInWindow: NSPoint) -> Bool {
        guard let window, window.attachedSheet == nil, NSApp.modalWindow == nil, let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(locationInWindow, from: nil) ?? locationInWindow) else { return false }
        return hit.isDescendant(of: self)
    }

    /// Whether `event` is a key press that activates the focused link or button of the view's page, as a click does: Return, Enter, or Space, not held down, without Command, Control, or Option, while the view or one inside it has its window's keys.
    func takesActivation(by event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat, event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              Self.activationKeyCodes.contains(event.keyCode), let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// Return, the keypad's Enter, and Space.
    private static let activationKeyCodes: Set<UInt16> = [36, 76, 49]
}
