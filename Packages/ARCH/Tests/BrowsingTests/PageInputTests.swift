// Which clicks and keys are the user's acts in a page (`NSView.takesClick(at:)` and `takesActivation(by:)`, `PageDownloadGate`): a click that reaches the page, not one that a view above it takes, as a prompt card or its dimming does, and Return, Enter, or Space while the page has the window's keys. The window is never ordered in.
import AppKit
import Testing
@testable import Browsing

@MainActor @Suite struct PageInputTests {
    /// A window that is never ordered in, whose content holds a page and, over the page's top half, a card.
    private func makeWindow() -> (window: NSWindow, page: NSView, card: NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = window.contentView ?? NSView()
        let page = FocusableView(frame: content.bounds)
        let card = FocusableView(frame: NSRect(x: 0, y: 150, width: 400, height: 150))
        content.addSubview(page)
        content.addSubview(card)
        return (window, page, card)
    }

    /// A key press of `keyCode` in the window.
    private func key(_ keyCode: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = [], isARepeat: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: " ", charactersIgnoringModifiers: " ", isARepeat: isARepeat, keyCode: keyCode))
    }

    /// A click on the card over the page, such as its Don't Allow, reaches the card and not the page, while a click beside the card reaches the page.
    @Test func aClickReachesThePageOnlyWhereNoViewAboveItTakesIt() {
        let (window, page, card) = makeWindow()
        defer { window.close() }
        #expect(page.takesClick(at: NSPoint(x: 200, y: 50)))
        #expect(!page.takesClick(at: NSPoint(x: 200, y: 250)))
        #expect(card.takesClick(at: NSPoint(x: 200, y: 250)))
    }

    /// Return, Enter, and Space activate the page that has the keys, unless held down or pressed with Command, Control, or Option; another key does not, and neither does a key while the card has the keys.
    @Test func activationKeysActInThePageThatHasTheKeys() throws {
        let (window, page, card) = makeWindow()
        defer { window.close() }
        #expect(window.makeFirstResponder(page))
        for keyCode: UInt16 in [36, 76, 49] {
            #expect(page.takesActivation(by: try key(keyCode, in: window)))
        }
        #expect(!page.takesActivation(by: try key(0, in: window)))
        #expect(!page.takesActivation(by: try key(36, in: window, isARepeat: true)))
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            #expect(!page.takesActivation(by: try key(36, in: window, modifiers: modifier)))
        }
        #expect(page.takesActivation(by: try key(36, in: window, modifiers: .shift)))
        #expect(window.makeFirstResponder(card))
        #expect(!page.takesActivation(by: try key(36, in: window)))
    }

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
