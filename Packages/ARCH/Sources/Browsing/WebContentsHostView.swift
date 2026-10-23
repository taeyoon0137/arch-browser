// Hosts the selected tab's engine view in SwiftUI. Replaces the view when the selected tab changes.
import AppKit
import SwiftUI

struct WebContentsHostView: NSViewRepresentable {
    let contentView: NSView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if let current = container.subviews.first, current === contentView { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let contentView else { return }
        contentView.frame = container.bounds
        contentView.autoresizingMask = [.width, .height]
        container.addSubview(contentView)
    }
}
