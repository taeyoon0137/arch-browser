// Keeps the keys of a pane with a prompt card for the card: while the card shows, the keyboard focus that moves anywhere else in the pane, such as the page, the find bar's field, or the question popover's, goes back to the card. Focus outside the pane, as in the sidebar or another pane, stays where it went. The guard covers the pane, takes no clicks, and is the view the card measures the focus against.
import AppKit
import SwiftUI

struct PromptFocusGuard: NSViewRepresentable {
    /// Whether a card shows over the pane.
    let isEngaged: Bool
    /// The card's frame in the pane, where the focus may stay.
    let cardFrame: CGRect
    let requestCardFocus: () -> Void
    /// Receives the guard's view, which covers the pane, so the layer can ask whether the card takes the focus as it shows.
    let paneView: (NSView) -> Void

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        DispatchQueue.main.async { paneView(view) }
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.isEngaged = isEngaged
        view.cardFrame = cardFrame
        view.requestCardFocus = requestCardFocus
        if isEngaged { view.check() }
    }

    final class GuardView: NSView {
        var isEngaged = false
        var cardFrame = CGRect.zero
        var requestCardFocus: (() -> Void)?
        private var observation: NSKeyValueObservation?
        /// Set while a request waits for the next turn of the run loop, so a burst of changes asks once.
        private var isRequestPending = false

        // The frame matches SwiftUI's, whose origin is at the top.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.check() }
            }
        }

        /// Sends the focus back to the card when it is in the pane outside the card.
        func check() {
            guard isEngaged, !isRequestPending, let window, let responder = window.firstResponder, responder !== window,
                  let view = PromptPresentation.view(of: responder), PromptPresentation.isInside(view, pane: self) else { return }
            let rect = convert(view.bounds, from: view)
            guard !cardFrame.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return }
            isRequestPending = true
            DispatchQueue.main.async { [weak self] in
                self?.isRequestPending = false
                guard let self, self.isEngaged else { return }
                self.requestCardFocus?()
            }
        }
    }
}
