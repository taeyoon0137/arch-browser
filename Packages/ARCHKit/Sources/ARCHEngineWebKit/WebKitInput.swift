// Trusted input on WebKit: events made with AppKit's and Core Graphics' public constructors and sent to the web view's responder methods, which WebKit hands to the page as it does the user's events. Pointer events and keys need the web view in a window, whose coordinates they carry; text needs none.
import AppKit
import ARCHEngine
import WebKit

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

    /// A click with Control opens the page's context menu, whose menu tracks modally, so the input sends none. The pointer move before the presses fires `mousemove` only in the key window; the press updates the page's hover state in any window.
    func click(at point: CGPoint, count: Int, modifiers: EngineInputModifiers) throws {
        guard (1...3).contains(count), !modifiers.contains(.control) else { throw EngineInputError.unsupported }
        let (webView, window, location) = try place(point)
        var events = [try Self.mouseEvent(.mouseMoved, at: location, in: window, modifiers: modifiers, clickCount: 0)]
        for click in 1...count {
            events.append(try Self.mouseEvent(.leftMouseDown, at: location, in: window, modifiers: modifiers, clickCount: click))
            events.append(try Self.mouseEvent(.leftMouseUp, at: location, in: window, modifiers: modifiers, clickCount: click))
        }
        for event in events {
            switch event.type {
            case .leftMouseDown: webView.mouseDown(with: event)
            case .leftMouseUp: webView.mouseUp(with: event)
            default: webView.mouseMoved(with: event)
            }
        }
    }

    /// AppKit has no public constructor for wheel events, so the event starts as a Core Graphics event. WebKit reads its location as one in the web view's window. AppKit gives that location for an event at the point's place on screen when it finds the window there, and otherwise the screen location, so such an event is made with the window point as its screen location instead.
    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double, modifiers: EngineInputModifiers) throws {
        let (webView, window, location) = try place(point)
        var event = Self.wheelEvent(at: window.convertPoint(toScreen: location), deltaX: deltaX, deltaY: deltaY, modifiers: modifiers)
        if event?.window !== window {
            event = Self.wheelEvent(at: location, deltaX: deltaX, deltaY: deltaY, modifiers: modifiers)
        }
        guard let event, event.window === window || event.window == nil,
              abs(event.locationInWindow.x - location.x) < 0.5, abs(event.locationInWindow.y - location.y) < 0.5
        else { throw EngineInputError.unsupported }
        webView.scrollWheel(with: event)
    }

    /// WebKit hands a key down that the page leaves unhandled back to the application, which sends it to the key window's first responder and first offers keys with Command, Control, or the function key flag to the menus and the key window's key equivalents. So a key goes only while its window is key or no window is, only to a web view that is its window's first responder, which drops the key when it comes back (`WebKitWebView.sendKeyEvent(_:)`), never with Command or Control, and with no function key flag. A character key would pass through the user's input source, which may type another character, so only named keys go; `insertText(_:)` types text.
    func press(_ key: EngineKey, modifiers: EngineInputModifiers) throws {
        guard let webView = webView as? WebKitWebView, let window = webView.window else { throw EngineInputError.notInWindow }
        guard modifiers.isDisjoint(with: [.command, .control]), let stroke = key.stroke(with: modifiers) else { throw EngineInputError.unsupported }
        if case .character = key { throw EngineInputError.unsupported }
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

    /// WebKit inserts the text as it does an input method's text outside a key press, also in a page that no window shows. Text that is a line break alone submits a single-line field's form, as Enter does, so no text with a line break goes.
    func insertText(_ text: String) throws {
        guard let webView else { throw EngineInputError.noPage }
        guard !text.contains(where: \.isNewline) else { throw EngineInputError.unsupported }
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
    private static func wheelEvent(at screenPoint: NSPoint, deltaX: Double, deltaY: Double, modifiers: EngineInputModifiers) -> NSEvent? {
        guard let screenHeight = NSScreen.screens.first?.frame.height,
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-deltaY.rounded()), wheel2: Int32(-deltaX.rounded()), wheel3: 0)
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
