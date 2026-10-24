// Hosts the selected tab's engine view in SwiftUI. Replaces the view when the selected tab changes.
import AppKit
import SwiftUI

struct WebContentsHostView: NSViewRepresentable {
    let contentView: NSView?
    /// The page frame's radius, or 0 while the page fills the window in fullscreen.
    var cornerRadius = PageFrameShape.cornerRadius

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        container.layer?.cornerRadius = cornerRadius
        if let current = container.subviews.first, current === contentView { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let contentView else { return }
        contentView.frame = container.bounds
        contentView.autoresizingMask = [.width, .height]
        container.addSubview(contentView)
    }
}
