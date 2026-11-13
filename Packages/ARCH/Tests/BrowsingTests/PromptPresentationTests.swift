// When a pane shows its tab's prompt, that a card arrives with its motion only the first time, and when the card takes the keyboard focus as it shows: in the focused pane, from nothing, the window, or a view in the pane, never from the sidebar or another pane. The window is never shown.
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
        #expect(PromptPresentation.shownPrompt(in: queue, tabID: tab, isOnScreen: false, isCoveredByInternalPage: false) == nil)
        #expect(PromptPresentation.shownPrompt(in: queue, tabID: tab, isOnScreen: true, isCoveredByInternalPage: true) == nil)
        let shown = try #require(PromptPresentation.shownPrompt(in: queue, tabID: tab, isOnScreen: true, isCoveredByInternalPage: false))
        #expect(shown === queue.current(for: tab))
        #expect(PromptPresentation.shownPrompt(in: queue, tabID: UUID(), isOnScreen: true, isCoveredByInternalPage: false) == nil)
    }

    @Test func aCardArrivesWithItsMotionOnlyTheFirstTime() {
        let state = PromptState(tabID: UUID(), content: Self.content)
        #expect(!state.hasAppeared)
        #expect(PromptPresentation.markAppeared(state))
        #expect(!PromptPresentation.markAppeared(state))
        #expect(state.hasAppeared)
    }

    /// A window, never shown, with a sidebar field, two panes side by side, and a view inside the first pane.
    @MainActor private struct Layout {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let sidebarField = NSTextField(frame: NSRect(x: 10, y: 500, width: 200, height: 24))
        let pane = NSView(frame: NSRect(x: 260, y: 8, width: 300, height: 584))
        /// The engine's view of the first pane, which another view holds over the same frame.
        let pageView = NSView(frame: NSRect(x: 260, y: 8, width: 300, height: 584))
        let fieldInPane = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 24))
        let otherPane = NSView(frame: NSRect(x: 568, y: 8, width: 324, height: 584))

        init() {
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            window.contentView = content
            for view in [sidebarField, pageView, pane, otherPane] { content.addSubview(view) }
            pane.addSubview(fieldInPane)
        }
    }

    @Test func theCardTakesTheFocusFromNothingTheWindowOrThePane() {
        let layout = Layout()
        func takes(_ responder: NSResponder?, focused: Bool = true) -> Bool {
            PromptPresentation.takesFocus(firstResponder: responder, pane: layout.pane, window: layout.window, isFocusedPane: focused)
        }
        #expect(takes(nil))
        #expect(takes(layout.window))
        #expect(takes(layout.fieldInPane))
        #expect(takes(layout.pageView))
        #expect(!takes(layout.sidebarField))
        #expect(!takes(layout.otherPane))
        // The window's content view holds the pane, as SwiftUI's hosting view does while one of its own controls has the focus.
        #expect(!takes(layout.window.contentView))
        // A pane that is not focused takes nothing.
        #expect(!takes(nil, focused: false))
        #expect(!takes(layout.pageView, focused: false))
    }
}
