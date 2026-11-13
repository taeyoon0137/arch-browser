// Shows the app's page context menu as a context menu for the page's text input view, so that AppKit adds its own items to it, as it does to WebKit's menu and to a text view's in any app: Siri, AutoFill, Services, and Writing Tools where macOS offers them. AppKit adds them only to a menu shown with `NSMenu.popUpContextMenu(_:with:for:)`, from the view that call names; `popUp(positioning:at:in:)` adds none. The WebKit engine needs none of this, because WebKit shows its menu that way itself.
import AppKit

/// Shows an engine's context menu with AppKit's own items. An engine whose menu opens after the click event has gone, as Chromium's does once its renderer reports the click, calls it.
public final class EngineContextMenuPresenter {
    /// The view the menu is shown for, which AppKit asks about its items.
    public enum Subject: Equatable {
        /// The page's text input view. AppKit adds AutoFill while the view has a text input context, which an engine gives it in a field, and Services for its selection.
        case textInput(NSView)
        /// A clicked link with no selection outside a field, offered to Services the way WebKit offers a clicked link.
        case link(URL)
        /// The container, when no text input view was found.
        case container
    }

    private lazy var linkRequestor = EngineLinkServicesRequestor()

    public init() {}

    /// Shows `menu` at `location`, in `container`'s coordinates, and returns once it closes. Without a window or an event the menu still shows, without AppKit's items.
    public func show(_ menu: NSMenu, at location: NSPoint, in container: NSView, for element: EngineContextMenuElement) {
        guard let window = container.window,
              let event = Self.clickEvent(locationInWindow: container.convert(location, to: nil), windowNumber: window.windowNumber,
                                          timestamp: ProcessInfo.processInfo.systemUptime) else {
            menu.popUp(positioning: nil, at: location, in: container)
            return
        }
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

    /// A link without a selection outside a field goes to Services as the link; anything else as the page's text input view, which offers its own selection and field.
    public static func subject(for element: EngineContextMenuElement, textInputView: NSView?) -> Subject {
        if let link = element.linkURL, !element.isEditable, element.selectedText?.isEmpty ?? true {
            return .link(link)
        }
        return textInputView.map(Subject.textInput) ?? .container
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

    /// A right mouse down at the click, which `popUpContextMenu` places the menu by, as the engine's own menu code does.
    public static func clickEvent(locationInWindow: NSPoint, windowNumber: Int, timestamp: TimeInterval) -> NSEvent? {
        NSEvent.mouseEvent(with: .rightMouseDown, location: locationInWindow, modifierFlags: [], timestamp: timestamp, windowNumber: windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
}

/// Offers a link's address, as a URL and as text, to the Services in a context menu, through the Services requestor protocol that AppKit asks the menu's view.
final class EngineLinkServicesRequestor: NSView, NSServicesMenuRequestor {
    var url: URL?
    static let types: [NSPasteboard.PasteboardType] = [.URL, .string]

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if url != nil, returnType == nil, let sendType, Self.types.contains(sendType) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let wanted = types.filter(Self.types.contains)
        guard let url, !wanted.isEmpty else { return false }
        pboard.declareTypes(wanted, owner: nil)
        return wanted.allSatisfy { pboard.setString(url.absoluteString, forType: $0) }
    }
}
