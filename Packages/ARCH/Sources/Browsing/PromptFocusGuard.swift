// Keeps the keys of a pane with a prompt card for the card: while the card shows, the keyboard focus that moves into the tab's page or a field over it, the find bar's or the question popover's, goes back to the card (`PromptPresentation.isInPage`). Focus anywhere else, as in the sidebar, the palette, the preview panel, or another pane, stays where it went. The guard takes no clicks and watches the window's first responder.
import AppKit
import SwiftUI

struct PromptFocusGuard: NSViewRepresentable {
    /// Whether a card shows over the pane.
    let isEngaged: Bool
    /// The engine's view of the pane's tab.
    let pageView: NSView
    /// Whether a field over the page has the focus while the card does not.
    let isPageFieldFocused: Bool
    let requestCardFocus: () -> Void

    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.isEngaged = isEngaged
        view.pageView = pageView
        view.isPageFieldFocused = isPageFieldFocused
        view.requestCardFocus = requestCardFocus
        if isEngaged { view.check() }
    }

    final class GuardView: NSView {
        var isEngaged = false
        weak var pageView: NSView?
        var isPageFieldFocused = false
        var requestCardFocus: (() -> Void)?
        private var observation: NSKeyValueObservation?
        /// Set while a request waits for the next turn of the run loop, so a burst of changes asks once.
        private var isRequestPending = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.check() }
            }
        }

        /// Sends the focus back to the card when the page has it.
        func check() {
            guard isEngaged, !isRequestPending, let window, let pageView, let responder = window.firstResponder, responder !== window,
                  PromptPresentation.isInPage(responder, pageView: pageView, isPageFieldFocused: isPageFieldFocused) else { return }
            isRequestPending = true
            DispatchQueue.main.async { [weak self] in
                self?.isRequestPending = false
                guard let self, self.isEngaged else { return }
                self.requestCardFocus?()
            }
        }
    }
}
