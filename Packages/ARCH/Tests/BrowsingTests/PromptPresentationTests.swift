// When a pane shows its tab's prompt, that a card arrives with its motion only the first time, and when the card takes the keyboard focus as it shows: in the focused pane, from nothing, the window, the pane's page, or a field over the page that reports its focus, never from the sidebar, another pane, or a view that only lies over the pane, as the palette, the preview panel, and the floating sidebar do. The window is never shown.
import AppKit
import Testing
@testable import Browsing

@MainActor @Suite struct PromptPresentationTests {
    private static let content = PromptContent(kind: .pageAlert, identity: PromptIdentity(icon: .symbol("globe"), name: "example.com", isSecure: true),
                                               buttons: [PromptButton(id: "ok", title: "OK")], defaultButtonID: "ok", cancelButtonID: "ok")

    @Test func aPromptShowsOnlyWhileItsTabIsOnScreenAndUncovered() throws {
        let queue = TabPromptQueue()
        let tab = UUID()
        queue.enqueue(Self.content, for: tab) { _ in }
        #expect(PromptPresentation.shownPrompt(in: queue, tabID: tab, isOnScreen: false, isCovered: false) == nil)
        #expect(PromptPresentation.shownPrompt(in: queue, tabID: tab, isOnScreen: true, isCovered: true) == nil)
        let shown = try #require(PromptPresentation.shownPrompt(in: queue, tabID: tab, isOnScreen: true, isCovered: false))
        #expect(shown === queue.current(for: tab))
        #expect(PromptPresentation.shownPrompt(in: queue, tabID: UUID(), isOnScreen: true, isCovered: false) == nil)
    }

    @Test func aCardArrivesWithItsMotionOnlyTheFirstTime() {
        let state = PromptState(tabID: UUID(), content: Self.content)
        #expect(!state.hasAppeared)
        #expect(PromptPresentation.markAppeared(state))
        #expect(!PromptPresentation.markAppeared(state))
        #expect(state.hasAppeared)
    }

    /// A window, never shown, with a sidebar field, two panes side by side, and over the first pane's frame its engine's view with a view inside, and views that lie over the pane without being its page: the palette's field, the preview panel's engine view, and the floating sidebar's field.
    @MainActor private struct Layout {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let sidebarField = NSTextField(frame: NSRect(x: 10, y: 500, width: 200, height: 24))
        /// The engine's view of the first pane's tab.
        let pageView = NSView(frame: NSRect(x: 260, y: 8, width: 600, height: 584))
        let viewInPage = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 24))
        let otherPane = NSView(frame: NSRect(x: 868, y: 8, width: 24, height: 584))
        let paletteField = NSTextField(frame: NSRect(x: 410, y: 440, width: 300, height: 24))
        let previewPage = NSView(frame: NSRect(x: 292, y: 40, width: 536, height: 520))
        let floatingSidebarField = NSTextField(frame: NSRect(x: 270, y: 400, width: 180, height: 24))

        init() {
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            window.contentView = content
            for view in [sidebarField, pageView, otherPane, paletteField, previewPage, floatingSidebarField] { content.addSubview(view) }
            pageView.addSubview(viewInPage)
        }

        /// The window's first responder while `field` has the focus: the field editor that edits it.
        func editor(of field: NSTextField) -> NSResponder? {
            window.makeFirstResponder(field)
            return window.firstResponder
        }
    }

    @Test func theCardTakesTheFocusFromNothingTheWindowOrThePage() {
        let layout = Layout()
        func takes(_ responder: NSResponder?, focused: Bool = true) -> Bool {
            PromptPresentation.takesFocus(firstResponder: responder, pageView: layout.pageView, window: layout.window, isFocusedPane: focused, isPageFieldFocused: false)
        }
        #expect(takes(nil))
        #expect(takes(layout.window))
        #expect(takes(layout.pageView))
        #expect(takes(layout.viewInPage))
        #expect(!takes(layout.sidebarField))
        let editor = layout.editor(of: layout.sidebarField)
        #expect(editor is NSText && editor.flatMap(PromptPresentation.view) === layout.sidebarField)
        #expect(!takes(editor))
        #expect(!takes(layout.otherPane))
        // The window's content view holds the page, as SwiftUI's hosting view does while one of its own controls has the focus.
        #expect(!takes(layout.window.contentView))
        // A pane that is not focused takes nothing.
        #expect(!takes(nil, focused: false))
        #expect(!takes(layout.pageView, focused: false))
    }

    @Test func viewsThatOnlyLieOverThePaneKeepTheFocus() {
        let layout = Layout()
        func takes(_ responder: NSResponder?) -> Bool {
            PromptPresentation.takesFocus(firstResponder: responder, pageView: layout.pageView, window: layout.window, isFocusedPane: true, isPageFieldFocused: false)
        }
        // Each lies within the page's frame, in front of it.
        for view in [layout.paletteField, layout.previewPage, layout.floatingSidebarField] as [NSView] {
            #expect(layout.pageView.frame.contains(view.frame))
        }
        #expect(!takes(layout.editor(of: layout.paletteField)))
        #expect(!takes(layout.previewPage))
        #expect(!takes(layout.editor(of: layout.floatingSidebarField)))
    }

    @Test func aFieldOverThePageCountsAsThePagesOnlyWhileItReportsTheFocus() {
        let layout = Layout()
        // The find bar's field, as one of the fields that report their focus.
        let findField = NSTextField(frame: NSRect(x: 460, y: 540, width: 300, height: 24))
        layout.window.contentView?.addSubview(findField)
        func takes(_ responder: NSResponder?, isPageFieldFocused: Bool) -> Bool {
            PromptPresentation.takesFocus(firstResponder: responder, pageView: layout.pageView, window: layout.window, isFocusedPane: true, isPageFieldFocused: isPageFieldFocused)
        }
        #expect(takes(layout.editor(of: findField), isPageFieldFocused: true))
        #expect(!takes(layout.editor(of: findField), isPageFieldFocused: false))
        // A report counts only for a field, so another pane's page keeps the focus.
        #expect(!takes(layout.otherPane, isPageFieldFocused: true))
    }
}
