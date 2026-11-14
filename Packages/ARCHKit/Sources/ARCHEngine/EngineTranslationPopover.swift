// Shows the system's translation of a page's selection in a popover at the click, the same on both engines, through SwiftUI's `translationPresentation`, which macOS offers from 14.4.
import AppKit
import SwiftUI
import Translation

/// Shows the system's translation popover for text at a point of a view.
@available(macOS 14.4, *)
enum EngineTranslationPopover {
    /// Puts a one-point view at `location`, in `view`'s coordinates, that presents the popover once it is in the window, and removes it when the popover closes. Without a window it shows nothing.
    static func show(_ text: String, at location: NSPoint, in view: NSView) {
        guard view.window != nil else { return }
        view.addSubview(anchor(for: text, at: location))
    }

    /// The one-point view that presents the popover for `text` at `location`. The popover offers no replacement, so it never changes a field's text.
    static func anchor(for text: String, at location: NSPoint) -> NSView {
        let host = NSHostingView(rootView: TranslationAnchor(text: text, closed: {}))
        // The view leaves its superview on the next turn of the run loop, outside SwiftUI's update.
        host.rootView = TranslationAnchor(text: text) { [weak host] in
            DispatchQueue.main.async { host?.removeFromSuperview() }
        }
        host.frame = NSRect(origin: location, size: NSSize(width: 1, height: 1))
        return host
    }
}

/// An empty view that presents the translation popover as soon as it appears and reports when the popover closes.
@available(macOS 14.4, *)
private struct TranslationAnchor: View {
    let text: String
    let closed: () -> Void
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .translationPresentation(isPresented: $isPresented, text: text)
            .onAppear { isPresented = true }
            .onChange(of: isPresented) { _, presented in
                if !presented { closed() }
            }
    }
}
