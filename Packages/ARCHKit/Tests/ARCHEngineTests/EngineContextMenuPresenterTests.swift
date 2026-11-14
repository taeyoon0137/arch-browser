// How an engine's page context menu is shown so that AppKit adds its own items: which view AppKit is asked about, the engine's password AutoFill call around the choice and the menu, how the page's text input view is found under the click, the event the menu opens at, and what a clicked link hands Services. AppKit's items themselves appear only in a menu on the screen, which the running app shows (the page context menu check in `docs/plan.md` Regression checks).
import AppKit
@testable import ARCHEngine
import Foundation
import Testing

@MainActor @Suite struct EngineContextMenuPresenterTests {
    private let link = URL(string: "https://example.com/a?b=c")!

    /// Stands in for an engine's page view, which adopts `NSTextInputClient` and so has a text input context.
    private class TextInputView: NSView, NSTextInputClient {
        func insertText(_ string: Any, replacementRange: NSRange) {}
        func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
        func unmarkText() {}
        func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
        func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        func hasMarkedText() -> Bool { false }
        func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
        func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
        func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
        func characterIndex(for point: NSPoint) -> Int { 0 }
    }

    /// Chromium's page view in a password field, or one that has been one, which has no text input context there.
    private final class PasswordFieldView: TextInputView {
        override var inputContext: NSTextInputContext? { nil }
    }

    @Test func aFieldGoesToThePagesTextInputViewWhileItHasATextInputContext() {
        let page = TextInputView()
        #expect(page.inputContext != nil)
        for element in [
            EngineContextMenuElement(isEditable: true),
            EngineContextMenuElement(selectedText: "text", isEditable: true),
            EngineContextMenuElement(linkURL: link, isEditable: true),
        ] {
            #expect(EngineContextMenuPresenter.subject(for: element, textInputView: page) == .textInput(page))
            // A password field, so that no service reads or replaces its text.
            #expect(EngineContextMenuPresenter.subject(for: element, textInputView: PasswordFieldView()) == .container)
            #expect(EngineContextMenuPresenter.subject(for: element, textInputView: nil) == .container)
        }
    }

    /// Chromium's page view in a password field with Arch's engine, which has a text input context only while the engine's call is on.
    private final class AutoFillPasswordFieldView: TextInputView {
        var allowsAutoFill = false
        override var inputContext: NSTextInputContext? { allowsAutoFill ? super.inputContext : nil }
    }

    @Test func aPasswordFieldGoesToThePagesTextInputViewWhileTheEnginesAutoFillCallIsOn() {
        let page = AutoFillPasswordFieldView()
        let field = EngineContextMenuElement(isEditable: true)
        var calls: [Bool] = []
        var subject: EngineContextMenuPresenter.Subject?
        EngineContextMenuPresenter.withPasswordAutoFill({ enabled in
            calls.append(enabled)
            page.allowsAutoFill = enabled
            return true
        }, for: field) {
            subject = EngineContextMenuPresenter.subject(for: field, textInputView: page)
            #expect(calls == [true])
        }
        #expect(subject == .textInput(page))
        #expect(calls == [true, false])
        #expect(EngineContextMenuPresenter.subject(for: field, textInputView: page) == .container)

        // Outside a field the call stays off, and without the call the body still runs.
        var ran = 0
        EngineContextMenuPresenter.withPasswordAutoFill({ calls.append($0); return false }, for: EngineContextMenuElement(linkURL: link)) { ran += 1 }
        EngineContextMenuPresenter.withPasswordAutoFill(nil, for: field) { ran += 1 }
        #expect(ran == 2)
        #expect(calls == [true, false])
    }

    @Test func aLinkOutsideAFieldGoesToServicesAsTheLink() {
        let page = TextInputView()
        #expect(EngineContextMenuPresenter.subject(for: EngineContextMenuElement(linkURL: link), textInputView: page) == .link(link))
        #expect(EngineContextMenuPresenter.subject(for: EngineContextMenuElement(linkURL: link, imageURL: link), textInputView: page) == .link(link))
        // A right click on a text link selects the link's text on both engines.
        #expect(EngineContextMenuPresenter.subject(for: EngineContextMenuElement(linkURL: link, selectedText: "Next page"), textInputView: page) == .link(link))
        #expect(EngineContextMenuPresenter.subject(for: EngineContextMenuElement(linkURL: link), textInputView: nil) == .link(link))
    }

    /// WebKit's view gets none of AppKit's items there.
    @Test func everythingElseGoesToTheContainer() {
        let page = TextInputView()
        for element in [
            EngineContextMenuElement(),
            EngineContextMenuElement(selectedText: "text"),
            EngineContextMenuElement(imageURL: link),
            EngineContextMenuElement(mediaURL: link),
        ] {
            #expect(EngineContextMenuPresenter.subject(for: element, textInputView: page) == .container)
        }
    }

    @Test func findsTheTextInputViewUnderTheClickFromTheFrontmostView() {
        // The container holds the engine's view, which holds the page's text input view, with a view of the page's own on top of part of it, and a view below them all.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let below = TextInputView(frame: container.bounds)
        let engine = NSView(frame: container.bounds)
        let page = TextInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let overlay = NSView(frame: NSRect(x: 10, y: 10, width: 50, height: 50))
        container.addSubview(below)
        container.addSubview(engine)
        engine.addSubview(page)
        page.addSubview(overlay)
        #expect(EngineContextMenuPresenter.textInputView(at: NSPoint(x: 100, y: 100), in: container) === page)
        #expect(EngineContextMenuPresenter.textInputView(at: NSPoint(x: 20, y: 20), in: container) === page)
        // Above the page, only the engine's own view is hit, and the view below stays out.
        #expect(EngineContextMenuPresenter.textInputView(at: NSPoint(x: 100, y: 250), in: container) == nil)
        #expect(EngineContextMenuPresenter.textInputView(at: NSPoint(x: 500, y: 100), in: container) == nil)
    }

    @Test func theMenuOpensAtTheClicksOwnEventWhileItIsCurrent() throws {
        let click = NSPoint(x: 120, y: 80)
        func mouse(_ type: NSEvent.EventType, at location: NSPoint = NSPoint(x: 120.6, y: 79.4), window: Int = 42) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: .control, timestamp: 3, windowNumber: window, context: nil,
                                            eventNumber: 9, clickCount: 1, pressure: 1))
        }
        for type: NSEvent.EventType in [.rightMouseDown, .rightMouseUp, .leftMouseDown, .leftMouseUp, .otherMouseDown] {
            let event = try mouse(type)
            #expect(EngineContextMenuPresenter.menuEvent(current: event, locationInWindow: click, windowNumber: 42, timestamp: 7) === event)
        }
        // Another event, or one in another window or away from the click, gives way to a right mouse down made at the click.
        let others: [NSEvent?] = try [nil, mouse(.mouseMoved), mouse(.rightMouseDragged), mouse(.rightMouseDown, window: 43),
                                      mouse(.rightMouseDown, at: NSPoint(x: 300, y: 80))]
        for current in others {
            let event = try #require(EngineContextMenuPresenter.menuEvent(current: current, locationInWindow: click, windowNumber: 42, timestamp: 7))
            #expect(event.type == .rightMouseDown)
            #expect(event.locationInWindow == click)
            #expect(event.windowNumber == 42)
            #expect(event.clickCount == 1)
            #expect(event.timestamp == 7)
            #expect(event.pressure == 1)
            #expect(event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty)
        }
    }

    @Test func aLinkOffersItsAddressAsAURLAndAsText() throws {
        let requestor = EngineLinkServicesRequestor()
        #expect(requestor.validRequestor(forSendType: .URL, returnType: nil) == nil)
        requestor.url = link
        // AppKit asks by the current names and by the older ones.
        let older = (url: NSPasteboard.PasteboardType("Apple URL pasteboard type"), string: NSPasteboard.PasteboardType("NSStringPboardType"))
        for type in [NSPasteboard.PasteboardType.URL, .string, older.url, older.string] {
            #expect(requestor.validRequestor(forSendType: type, returnType: nil) as? NSView === requestor)
        }
        // It takes nothing back, and offers no other kind of data.
        #expect(requestor.validRequestor(forSendType: .string, returnType: .string) == nil)
        #expect(requestor.validRequestor(forSendType: older.string, returnType: older.string) == nil)
        #expect(requestor.validRequestor(forSendType: nil, returnType: .string) == nil)
        #expect(requestor.validRequestor(forSendType: .rtf, returnType: nil) == nil)
        #expect(requestor.validRequestor(forSendType: NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type"), returnType: nil) == nil)

        func pasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("ARCHEngineTests.linkServices.\(UUID().uuidString)")) }
        for types in [[NSPasteboard.PasteboardType.rtf, .URL, .string], [older.url, older.string]] {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            #expect(requestor.writeSelection(to: board, types: types))
            #expect(board.string(forType: .URL) == link.absoluteString)
            #expect(board.string(forType: .string) == link.absoluteString)
            #expect(board.string(forType: older.string) == link.absoluteString)
            // The older URL type holds the address in its own format, which readers of a URL understand.
            #expect(NSURL(from: board)?.absoluteString == link.absoluteString)
            #expect(board.types?.contains(.rtf) == false)
        }
        let board = pasteboard()
        defer { board.releaseGlobally() }
        #expect(!requestor.writeSelection(to: board, types: [.rtf]))
    }
}
