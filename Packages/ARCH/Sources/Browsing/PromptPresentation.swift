// When a pane shows its tab's prompt, and when the card may take the keyboard focus from where it is.
import AppKit

/// The rules for when a pane shows its tab's prompt card and when the card takes the keyboard focus, which `PanePromptLayer` and `PromptFocusGuard` follow.
enum PromptPresentation {
    /// The prompt a pane shows over its tab's page: the tab's oldest, while the tab is on its window's screen and nothing covers the page, as an internal page or the preview panel does. Otherwise the prompt waits, and only the sidebar marks it.
    @MainActor static func shownPrompt(in queue: TabPromptQueue, tabID: UUID, isOnScreen: Bool, isCovered: Bool) -> PromptState? {
        guard isOnScreen, !isCovered else { return nil }
        return queue.current(for: tabID)
    }

    /// Records that a card shows the prompt. True only the first time, when the card arrives with its motion; later it shows at once with its page.
    @discardableResult
    static func markAppeared(_ state: PromptState) -> Bool {
        guard !state.hasAppeared else { return false }
        state.hasAppeared = true
        return true
    }

    /// Whether the card takes the focus as it shows: in the focused pane, while nothing has the focus, the window has it, or the pane's page has it (`isInPage`). A field in the sidebar, the palette, the preview panel, another pane, or another window keeps it, also where it lies over the pane.
    static func takesFocus(firstResponder: NSResponder?, pageView: NSView, window: NSWindow, isFocusedPane: Bool, isPageFieldFocused: Bool) -> Bool {
        guard isFocusedPane else { return false }
        guard let responder = firstResponder, responder !== window else { return true }
        return isInPage(responder, pageView: pageView, isPageFieldFocused: isPageFieldFocused)
    }

    /// Whether the focus belongs to the pane's page: to the tab's engine view or a view inside it, or to a text field over the page while `isPageFieldFocused` says that one of those fields has it, the find bar's or the question popover's (`PageField`). Views that only lie over the pane, as the palette, the preview panel, and the floating sidebar do, are not the page's.
    static func isInPage(_ responder: NSResponder, pageView: NSView, isPageFieldFocused: Bool) -> Bool {
        guard let view = view(of: responder) else { return false }
        if view === pageView || view.isDescendant(of: pageView) { return true }
        return isPageFieldFocused && responder is NSText
    }

    /// The view that holds a responder: the view itself, or the field that the field editor edits.
    static func view(of responder: NSResponder) -> NSView? {
        if let text = responder as? NSText, text.isFieldEditor, let field = text.delegate as? NSView { return field }
        return responder as? NSView
    }
}
