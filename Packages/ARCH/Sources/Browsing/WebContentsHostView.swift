// Hosts a tab's engine view in SwiftUI. Replaces the view when the pane shows another tab.
import AppKit
import SwiftUI

struct WebContentsHostView: NSViewRepresentable {
    let contentView: NSView?
    /// The page frame's radius, or 0 while the page fills the window in fullscreen.
    var cornerRadius = PageFrameShape.cornerRadius
    /// Runs when a click lands on the page, such as one in a split view pane that is not focused. `nil` when nothing needs to know.
    var onClick: (() -> Void)?

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
        private var clickMonitor: Any?

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

        /// Counts a click only where it reaches the page, not where a view above the page takes it, such as the find bar or a pane's close control.
        private func handleClick(_ event: NSEvent) {
            guard let window, event.window === window, let content = window.contentView,
                  let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
                  hit.isDescendant(of: self) else { return }
            onClick?()
        }
    }
}
