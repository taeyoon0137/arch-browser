// How an engine's page context menu is shown so that AppKit adds its own items: which view AppKit is asked about, how the page's text input view is found under the click, the click event the menu opens at, and what a clicked link hands Services. AppKit's items themselves appear only in a menu on the screen, which the running app shows (regression check 60).
import AppKit
@testable import ARCHEngine
import Foundation
import Testing

@MainActor @Suite struct EngineContextMenuPresenterTests {
    private let link = URL(string: "https://example.com/a?b=c")!

    /// Stands in for an engine's page view, which adopts `NSTextInputClient`.
    private final class TextInputView: NSView, NSTextInputClient {
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

    @Test func aLinkWithoutASelectionOutsideAFieldGoesToServicesAsTheLink() {
        let page = TextInputView()
        #expect(EngineContextMenuPresenter.subject(for: EngineContextMenuElement(linkURL: link), textInputView: page) == .link(link))
        #expect(EngineContextMenuPresenter.subject(for: EngineContextMenuElement(linkURL: link, imageURL: link), textInputView: page) == .link(link))
        #expect(EngineContextMenuPresenter.subject(for: EngineContextMenuElement(linkURL: link, selectedText: ""), textInputView: nil) == .link(link))
    }

    @Test func everythingElseGoesToThePagesTextInputView() {
        let page = TextInputView()
        for element in [
            EngineContextMenuElement(),
            EngineContextMenuElement(selectedText: "text"),
            EngineContextMenuElement(isEditable: true),
            EngineContextMenuElement(linkURL: link, selectedText: "text"),
            EngineContextMenuElement(linkURL: link, isEditable: true),
            EngineContextMenuElement(imageURL: link),
            EngineContextMenuElement(mediaURL: link),
        ] {
            #expect(EngineContextMenuPresenter.subject(for: element, textInputView: page) == .textInput(page))
        }
        #expect(EngineContextMenuPresenter.subject(for: EngineContextMenuElement(selectedText: "text"), textInputView: nil) == .container)
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

    @Test func theMenuOpensAtARightMouseDownAtTheClick() throws {
        let event = try #require(EngineContextMenuPresenter.clickEvent(locationInWindow: NSPoint(x: 120, y: 80), windowNumber: 42, timestamp: 7))
        #expect(event.type == .rightMouseDown)
        #expect(event.locationInWindow == NSPoint(x: 120, y: 80))
        #expect(event.windowNumber == 42)
        #expect(event.clickCount == 1)
        #expect(event.timestamp == 7)
        #expect(event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty)
    }

    @Test func aLinkOffersItsAddressAsAURLAndAsText() throws {
        let requestor = EngineLinkServicesRequestor()
        #expect(requestor.validRequestor(forSendType: .URL, returnType: nil) == nil)
        requestor.url = link
        #expect(requestor.validRequestor(forSendType: .URL, returnType: nil) as? NSView === requestor)
        #expect(requestor.validRequestor(forSendType: .string, returnType: nil) as? NSView === requestor)
        // It takes nothing back, and offers no other kind of data.
        #expect(requestor.validRequestor(forSendType: .string, returnType: .string) == nil)
        #expect(requestor.validRequestor(forSendType: nil, returnType: .string) == nil)
        #expect(requestor.validRequestor(forSendType: .rtf, returnType: nil) == nil)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ARCHEngineTests.linkServices.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(requestor.writeSelection(to: pasteboard, types: [.rtf, .URL, .string]))
        #expect(pasteboard.string(forType: .URL) == link.absoluteString)
        #expect(pasteboard.string(forType: .string) == link.absoluteString)
        #expect(pasteboard.types?.contains(.rtf) == false)
        #expect(!requestor.writeSelection(to: pasteboard, types: [.rtf]))
    }
}
