// Trusted input on Chromium: the bridge's calls over `CefBrowserHost`'s input methods, which CEF hands to Chromium's input pipeline as AppKit's events go, so the page receives them as the user's own. They need the browser's view in a window, as the WebKit adapter's pointer events do; whether Chromium also routes them to a view that no window shows is unverified.
import AppKit
import ARCHEngine
import CEFBridge

final class ChromiumInput: EngineInput {
    private weak var webContents: ChromiumWebContents?

    init(webContents: ChromiumWebContents) {
        self.webContents = webContents
    }

    /// One key event that the bridge sends: its part of a press, the macOS virtual key code, and AppKit's characters, one UTF-16 unit each.
    struct KeyEvent: Equatable {
        var kind: ARCHCEFKeyEventKind
        var keyCode: Int32
        var character: unichar
        var unmodifiedCharacter: unichar
    }

    func movePointer(to point: CGPoint, modifiers: EngineInputModifiers) throws {
        try browser(at: point).sendMouseMove(to: point, modifiers: Self.modifiers(modifiers))
    }

    /// A click with Control opens the page's context menu, whose menu tracks modally, so the input sends none.
    func click(at point: CGPoint, count: Int, modifiers: EngineInputModifiers) throws {
        guard (1...3).contains(count), !modifiers.contains(.control) else { throw EngineInputError.unsupported }
        let browser = try browser(at: point)
        let modifiers = Self.modifiers(modifiers)
        browser.sendMouseMove(to: point, modifiers: modifiers)
        for click in 1...count {
            browser.sendMouseClick(at: point, mouseUp: false, clickCount: click, modifiers: modifiers)
            browser.sendMouseClick(at: point, mouseUp: true, clickCount: click, modifiers: modifiers)
        }
    }

    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double, modifiers: EngineInputModifiers) throws {
        try browser(at: point).sendMouseWheel(at: point, deltaX: Int(deltaX.rounded()), deltaY: Int(deltaY.rounded()), modifiers: Self.modifiers(modifiers))
    }

    /// CEF sends the key straight to the page, past the user's input source and the window's first responder, and the bridge stops a key the page leaves unhandled, so every key and modifier goes.
    func press(_ key: EngineKey, modifiers: EngineInputModifiers) throws {
        let events = try Self.keyEvents(for: key, modifiers: modifiers)
        send(events, to: try browser(at: nil), modifiers: Self.modifiers(modifiers))
    }

    func insertText(_ text: String) throws {
        let events = try Self.textEvents(for: text)
        send(events, to: try browser(at: nil), modifiers: [])
    }

    /// A press sends the key's down and up, with the character it types between them, as AppKit's typing does.
    static func keyEvents(for key: EngineKey, modifiers: EngineInputModifiers) throws -> [KeyEvent] {
        guard let stroke = key.stroke(with: modifiers), stroke.characters.utf16.count == 1, stroke.charactersIgnoringModifiers.utf16.count == 1,
              let character = stroke.characters.utf16.first, let unmodified = stroke.charactersIgnoringModifiers.utf16.first
        else { throw EngineInputError.unsupported }
        let keyCode = Int32(stroke.keyCode)
        let kinds: [ARCHCEFKeyEventKind] = stroke.typesCharacter ? [.down, .character, .up] : [.down, .up]
        return kinds.map { KeyEvent(kind: $0, keyCode: keyCode, character: character, unmodifiedCharacter: unmodified) }
    }

    /// Text goes as a character event per character, as CEF's input method calls work only for pages it draws offscreen; the page receives a keypress and input events for each. A character event carries one UTF-16 unit, so text outside the Basic Multilingual Plane, such as most emoji, cannot go. A line break as a character of its own submits a single-line field's form, as Enter does, so no text with a line break goes.
    static func textEvents(for text: String) throws -> [KeyEvent] {
        guard !text.contains(where: \.isNewline), text.unicodeScalars.allSatisfy({ $0.value <= 0xFFFF }) else { throw EngineInputError.unsupported }
        return text.flatMap { character in
            let keyCode = EngineKey.keyCode(typing: character).map(Int32.init) ?? noKeyCode
            return String(character).utf16.map { KeyEvent(kind: .character, keyCode: keyCode, character: $0, unmodifiedCharacter: $0) }
        }
    }

    /// A virtual key code that no key of a Mac keyboard has, for a character that no key of the US layout types.
    static let noKeyCode: Int32 = 0xFF

    private func send(_ events: [KeyEvent], to browser: ARCHCEFBrowser, modifiers: ARCHCEFInputModifiers) {
        for event in events {
            browser.sendKeyEvent(event.kind, keyCode: event.keyCode, character: event.character, unmodifiedCharacter: event.unmodifiedCharacter, modifiers: modifiers)
        }
    }

    /// The browser, once CEF has created it and its view is in a window, with `point` inside the view.
    private func browser(at point: CGPoint?) throws -> ARCHCEFBrowser {
        guard let browser = webContents?.browser, let view = browser.browserView else { throw EngineInputError.noPage }
        guard view.window != nil else { throw EngineInputError.notInWindow }
        if let point {
            guard point.x >= 0, point.y >= 0, point.x < view.bounds.width, point.y < view.bounds.height else { throw EngineInputError.outsideView }
        }
        return browser
    }

    private static func modifiers(_ modifiers: EngineInputModifiers) -> ARCHCEFInputModifiers {
        var bridged: ARCHCEFInputModifiers = []
        if modifiers.contains(.shift) { bridged.insert(.shift) }
        if modifiers.contains(.control) { bridged.insert(.control) }
        if modifiers.contains(.option) { bridged.insert(.option) }
        if modifiers.contains(.command) { bridged.insert(.command) }
        return bridged
    }
}
