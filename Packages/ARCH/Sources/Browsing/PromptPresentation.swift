// When a pane shows its tab's prompt, and when the card may take the keyboard focus from where it is.
import AppKit

enum PromptPresentation {
    /// The prompt a pane shows over its tab's page: the tab's oldest, while the tab is on its window's screen and no internal page covers the page. Otherwise the prompt waits, and only the sidebar marks it.
    static func shownPrompt(in queue: TabPromptQueue, tabID: UUID, isOnScreen: Bool, isCoveredByInternalPage: Bool) -> PromptState? {
        guard isOnScreen, !isCoveredByInternalPage else { return nil }
        return queue.current(for: tabID)
    }

    /// Records that a card shows the prompt. True only the first time, when the card arrives with its motion; later it shows at once with its page.
    @discardableResult
    static func markAppeared(_ state: PromptState) -> Bool {
        guard !state.hasAppeared else { return false }
        state.hasAppeared = true
        return true
    }

    /// Whether the card takes the focus as it shows: in the focused pane, while nothing has the focus, the window has it, or something in the pane has it, such as the page. A field in the sidebar, the palette, the preview panel, another pane, or another window keeps it.
    static func takesFocus(firstResponder: NSResponder?, pane: NSView, window: NSWindow, isFocusedPane: Bool) -> Bool {
        guard isFocusedPane else { return false }
        guard let responder = firstResponder, responder !== window else { return true }
        guard let view = view(of: responder) else { return false }
        return isInside(view, pane: pane)
    }

    /// The view that holds a responder: the view itself, or the field that the field editor edits.
    static func view(of responder: NSResponder) -> NSView? {
        if let text = responder as? NSText, text.isFieldEditor, let field = text.delegate as? NSView { return field }
        return responder as? NSView
    }

    /// Whether `view` lies in the pane: in its view hierarchy, or within its frame in the same window, as the engine's view and the find bar's field do, which other views hold. A view that holds the pane, such as the window's content view, does not.
    static func isInside(_ view: NSView, pane: NSView) -> Bool {
        if view === pane || view.isDescendant(of: pane) { return true }
        guard !pane.isDescendant(of: view), let window = pane.window, view.window === window else { return false }
        let rect = pane.convert(view.bounds, from: view)
        return pane.bounds.insetBy(dx: -1, dy: -1).contains(rect)
    }
}
