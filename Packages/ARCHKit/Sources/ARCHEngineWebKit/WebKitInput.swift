// Trusted input on WebKit: events made with AppKit's and Core Graphics' public constructors and sent to the web view's responder methods, which WebKit hands to the page as it does the user's events. Pointer events and keys need the web view in a window, whose coordinates they carry; text needs none.
import AppKit
import ARCHEngine
import WebKit

/// Sends a WebKit tab trusted mouse and key events as AppKit events, for the agents' action tools.
final class WebKitInput: EngineInput {
    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// WebKit fires `mousemove` only in the key window; in another window a move updates only the page's scroll bars, so the input sends none there.
    func movePointer(to point: CGPoint, modifiers: EngineInputModifiers) throws {
        let (webView, window, location) = try place(point)
        guard window.isKeyWindow else { throw EngineInputError.notFocused }
        webView.mouseMoved(with: try Self.mouseEvent(.mouseMoved, at: location, in: window, modifiers: modifiers, clickCount: 0))
    }

    /// A click with Control opens the page's context menu, whose menu tracks modally, so the input sends none. The press updates the page's hover state in any window, so no pointer move goes first.
    func click(at point: CGPoint, count: Int, modifiers: EngineInputModifiers) throws {
        guard (1...3).contains(count), !modifiers.contains(.control) else { throw EngineInputError.unsupported }
        let (webView, window, location) = try place(point)
        let events = try (1...count).flatMap { click in
            try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { try Self.mouseEvent($0, at: location, in: window, modifiers: modifiers, clickCount: click) }
        }
        for event in events {
            if event.type == .leftMouseDown {
                webView.mouseDown(with: event)
            } else {
                webView.mouseUp(with: event)
            }
        }
    }

    /// AppKit has no public constructor for wheel events, so the event starts as a Core Graphics event. WebKit reads its location as one in the web view's window. AppKit gives that location for an event at the point's place on screen when it finds the window there, and otherwise the screen location, so such an event is made with the window point as its screen location instead.
    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double, modifiers: EngineInputModifiers) throws {
        let turn = try EngineWheelTurn(deltaX: deltaX, deltaY: deltaY)
        let (webView, window, location) = try place(point)
        var event = Self.wheelEvent(at: window.convertPoint(toScreen: location), turn: turn, modifiers: modifiers)
        if event?.window !== window {
            event = Self.wheelEvent(at: location, turn: turn, modifiers: modifiers)
        }
        guard let event, event.window === window || event.window == nil,
              abs(event.locationInWindow.x - location.x) < 0.5, abs(event.locationInWindow.y - location.y) < 0.5
        else { throw EngineInputError.unsupported }
        webView.scrollWheel(with: event)
    }

    /// WebKit hands a key down that the page leaves unhandled back to the application, which would send it to the key window's first responder and first offer keys with Command, Control, or the function key flag to the menus and the key window's key equivalents; the application's `sendEvent(_:)` drops it first (`WebKitEngine.isTrustedInputKey(_:)`). So a key goes only while its window is key or no window is, only to a web view that is its window's first responder, never with Command or Control, and with no function key flag. A character key or Space would pass through the user's input source, which may type another character, such as a full-width space, or convert text the input source is composing, so only the other named keys go; `insertText(_:)` types text, a space included.
    func press(_ key: EngineKey, modifiers: EngineInputModifiers) throws {
        guard let webView = webView as? WebKitWebView, let window = webView.window else { throw EngineInputError.notInWindow }
        guard modifiers.isDisjoint(with: [.command, .control]), let stroke = key.stroke(with: modifiers) else { throw EngineInputError.unsupported }
        switch key {
        case .character, .space: throw EngineInputError.unsupported
        default: break
        }
        guard (NSApplication.shared.keyWindow ?? window) === window, window.firstResponder === webView else { throw EngineInputError.notFocused }
        let events = try [NSEvent.EventType.keyDown, .keyUp].map { type in
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: Self.modifierFlags(modifiers), timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: stroke.characters,
                                               charactersIgnoringModifiers: stroke.charactersIgnoringModifiers, isARepeat: false, keyCode: stroke.keyCode)
            else { throw EngineInputError.unsupported }
            return event
        }
        events.forEach(webView.sendKeyEvent)
    }

    /// WebKit inserts the text as it does an input method's text outside a key press, also in a page that no window shows. Text that is a line break alone submits a single-line field's form, as Enter does, so no text with a line break or a control character goes.
    func insertText(_ text: String) throws {
        guard let webView else { throw EngineInputError.noPage }
        guard !text.contains(where: \.isNewline), !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw EngineInputError.unsupported }
        webView.insertText(text)
    }

    /// The web view, its window, and the point in the window's coordinates.
    private func place(_ point: CGPoint) throws -> (WKWebView, NSWindow, NSPoint) {
        guard let webView, let window = webView.window else { throw EngineInputError.notInWindow }
        let bounds = webView.bounds
        guard point.x >= 0, point.y >= 0, point.x < bounds.width, point.y < bounds.height else { throw EngineInputError.outsideView }
        let inView = NSPoint(x: bounds.minX + point.x, y: webView.isFlipped ? bounds.minY + point.y : bounds.maxY - point.y)
        return (webView, window, webView.convert(inView, to: nil))
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow, modifiers: EngineInputModifiers, clickCount: Int) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifierFlags(modifiers), timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)
        else { throw EngineInputError.unsupported }
        return event
    }

    /// A pixel wheel event at a point in screen coordinates, Cocoa's, with the origin at the bottom left of the main screen.
    private static func wheelEvent(at screenPoint: NSPoint, turn: EngineWheelTurn, modifiers: EngineInputModifiers) -> NSEvent? {
        guard let screenHeight = NSScreen.screens.first?.frame.height,
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-turn.deltaY), wheel2: Int32(-turn.deltaX), wheel3: 0)
        else { return nil }
        wheel.location = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
        wheel.flags = CGEventFlags(rawValue: UInt64(modifierFlags(modifiers).rawValue))
        return NSEvent(cgEvent: wheel)
    }

    private static func modifierFlags(_ modifiers: EngineInputModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }
}

/// The key downs that `WebKitInput` sent (`WebKitEngine.isTrustedInputKey(_:)`). The table holds each key weakly, so it leaves once WebKit lets it go, after its hand back or once the page handled it, however many keys went since, and no other event at its address is taken for it.
@MainActor enum WebKitSentKeys {
    private static let keyDowns = NSHashTable<NSEvent>(options: [.weakMemory, .objectPointerPersonality])

    static func add(_ event: NSEvent) {
        keyDowns.add(event)
    }

    static func contains(_ event: NSEvent) -> Bool {
        keyDowns.contains(event)
    }

    /// The sent key downs that WebKit or a caller still holds.
    static var sent: [NSEvent] { keyDowns.allObjects }
}
