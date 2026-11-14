// Shows the app's page context menu as a context menu, so that AppKit adds its own items to it, as it does to WebKit's menu and to a text view's in any app: AutoFill, Services, and Writing Tools where macOS offers them. AppKit adds them only to a menu shown with `NSMenu.popUpContextMenu(_:with:for:)`, from the view that call names; `popUp(positioning:at:in:)` adds none. The view is the one that gets the menu the items WebKit's view gets: the page's text input view in a field, the clicked link on a link, and a view that offers nothing elsewhere. The WebKit engine needs none of this, because WebKit shows its menu that way itself.
import AppKit

/// Shows an engine's context menu with AppKit's own items. An engine whose menu opens after the click event has gone, as Chromium's does once its renderer reports the click, calls it.
public final class EngineContextMenuPresenter {
    /// The view the menu is shown for, which AppKit asks about its items.
    public enum Subject: Equatable {
        /// The page's text input view, in a field while the view has a text input context. AppKit adds AutoFill for the context and Services for the field's selection.
        case textInput(NSView)
        /// A clicked link outside a field, offered to Services the way WebKit offers a clicked link.
        case link(URL)
        /// The container, which offers AppKit nothing: WebKit's view gets none of AppKit's items on the page background, a selection outside a field, an image, or a video. A field whose text input view has no text input context gets it too, as a password field of an engine without the password AutoFill call does, so that no service reads or replaces a password.
        case container
    }

    private lazy var linkRequestor = EngineLinkServicesRequestor()

    public init() {}

    /// Shows `menu` at `location`, in `container`'s coordinates, and returns once it closes. Without a window the menu still shows, without AppKit's items.
    ///
    /// `passwordAutoFill` is the engine's call for a page view that gives a password field a text input context only while the engine's context menu shows, as Chromium's does through Arch's engine (VI.9): it gets true right before a field's menu shows and false once the menu closes, around the choice of the view as well, so that a password field goes to AppKit as the page's text input view and gets AutoFill. The engine's view then offers the password to no service itself, so the presenter needs no other sign of a password field and ignores the call's answer, whether the field is one.
    public func show(_ menu: NSMenu, at location: NSPoint, in container: NSView, for element: EngineContextMenuElement, passwordAutoFill: ((Bool) -> Bool)? = nil) {
        guard let window = container.window,
              let event = Self.menuEvent(current: NSApp.currentEvent, locationInWindow: container.convert(location, to: nil), windowNumber: window.windowNumber,
                                         timestamp: ProcessInfo.processInfo.systemUptime) else {
            menu.popUp(positioning: nil, at: location, in: container)
            return
        }
        Self.withPasswordAutoFill(passwordAutoFill, for: element) {
            popUp(menu, with: event, at: location, in: container, for: element)
        }
    }

    /// Runs `body` with the engine's password AutoFill call on, for a field only: the call gets true before `body` and false after it.
    static func withPasswordAutoFill(_ passwordAutoFill: ((Bool) -> Bool)?, for element: EngineContextMenuElement, _ body: () -> Void) {
        guard element.isEditable, let passwordAutoFill else { return body() }
        _ = passwordAutoFill(true)
        defer { _ = passwordAutoFill(false) }
        body()
    }

    private func popUp(_ menu: NSMenu, with event: NSEvent, at location: NSPoint, in container: NSView, for element: EngineContextMenuElement) {
        let view: NSView
        switch Self.subject(for: element, textInputView: Self.textInputView(at: location, in: container)) {
        case .textInput(let textInputView):
            view = textInputView
        case .link(let url):
            // The requestor stands at the click only while the menu is open.
            linkRequestor.url = url
            linkRequestor.frame = NSRect(origin: location, size: NSSize(width: 1, height: 1))
            container.addSubview(linkRequestor)
            view = linkRequestor
        case .container:
            view = container
        }
        defer {
            if linkRequestor.superview != nil { linkRequestor.removeFromSuperview() }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// A field goes to AppKit as the page's text input view while that view has a text input context, which Chromium's withholds in a password field and in one that has been one except while the password AutoFill call is on; a link outside a field as the link, also when the click selected the link's text, as a right click on a text link does on both engines; anything else as the container.
    public static func subject(for element: EngineContextMenuElement, textInputView: NSView?) -> Subject {
        if element.isEditable {
            guard let textInputView, textInputView.inputContext != nil else { return .container }
            return .textInput(textInputView)
        }
        return element.linkURL.map(Subject.link) ?? .container
    }

    /// The text input view under `location`, in `container`'s coordinates: the frontmost view there or the closest view above it that adopts `NSTextInputClient`, inside `container`. Without one, the window's first responder when it is such a view inside `container`.
    public static func textInputView(at location: NSPoint, in container: NSView) -> NSView? {
        var view = container.subviews.reversed().lazy.compactMap { $0.hitTest(location) }.first
        while let current = view, current !== container {
            if current is NSTextInputClient { return current }
            view = current.superview
        }
        if let responder = container.window?.firstResponder as? NSView, responder is NSTextInputClient, responder.isDescendant(of: container) {
            return responder
        }
        return nil
    }

    /// The event the menu opens at, which `popUpContextMenu` places the menu by. While the app's current event is the click's own mouse down or up, it is that event, as in Chromium's own context menu code (`ui::EventForPositioningContextMenuRelativeToWindow`), provided it is in the window and within two points of the click, which the engine reports in whole points: the menu opens after the renderer reports the click, when a later event may be current. Otherwise it is a right mouse down made at the click with `timestamp`, the current time, and full pressure, as a click that has just happened; Chromium makes its own with time 0 and no pressure, for a menu that opens without a click, as from the keyboard.
    public static func menuEvent(current: NSEvent?, locationInWindow: NSPoint, windowNumber: Int, timestamp: TimeInterval) -> NSEvent? {
        let clickTypes: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        if let current, clickTypes.contains(current.type), current.windowNumber == windowNumber,
           abs(current.locationInWindow.x - locationInWindow.x) <= 2, abs(current.locationInWindow.y - locationInWindow.y) <= 2 {
            return current
        }
        return NSEvent.mouseEvent(with: .rightMouseDown, location: locationInWindow, modifierFlags: [], timestamp: timestamp, windowNumber: windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
}

/// Offers a link's address, as a URL and as text, to the Services in a context menu, through the Services requestor protocol that AppKit asks the menu's view.
final class EngineLinkServicesRequestor: NSView, NSServicesMenuRequestor {
    var url: URL?
    /// The types it writes, each with the older name that AppKit also asks for, as Chromium's source notes (`ui/base/cocoa/appkit_utils_unittest.mm`): the values of the deprecated `NSURLPboardType` and `NSStringPboardType`, which Swift does not offer.
    static let types: [(current: NSPasteboard.PasteboardType, older: NSPasteboard.PasteboardType)] = [
        (.URL, NSPasteboard.PasteboardType("Apple URL pasteboard type")), (.string, NSPasteboard.PasteboardType("NSStringPboardType")),
    ]

    /// The current name of each type that `requested` names by either name, in the order of `types`.
    static func writtenTypes(for requested: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        types.filter { requested.contains($0.current) || requested.contains($0.older) }.map(\.current)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if url != nil, returnType == nil, let sendType, !Self.writtenTypes(for: [sendType]).isEmpty {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Writes the address under the current names only. The pasteboard then offers it under the older names too, the URL in the older type's own format, which a string written under the older name would not have.
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let written = Self.writtenTypes(for: types)
        guard let url, !written.isEmpty else { return false }
        pboard.declareTypes(written, owner: nil)
        return written.allSatisfy { pboard.setString(url.absoluteString, forType: $0) }
    }
}
