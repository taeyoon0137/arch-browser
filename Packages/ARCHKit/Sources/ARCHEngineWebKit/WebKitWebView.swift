// The views of a WebKit tab: the web view every web contents makes, which knows its web contents, and the page view that holds it.
import AppKit
import ARCHEngine
import WebKit

/// The web view of every WebKit web contents. It hands its context menu to the adapter before the menu opens.
final class WebKitWebView: WKWebView {
    /// The web contents that made the web view, set as soon as they exist. Every script message handler of the adapter finds its web contents through it.
    weak var contents: WebKitWebContents?
    /// What the script reported for the click that opens the next menu.
    var pendingElement: EngineContextMenuElement?
    var pendingMediaFrame: WKFrameInfo?

    /// Sends a key event that `WebKitInput` made to WebKit. When WebKit hands the key down back to the application, the application drops it (`WebKitEngine.isTrustedInputKey(_:)`), so it reaches neither the app's monitors and menus nor any view.
    func sendKeyEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { return super.keyUp(with: event) }
        WebKitSentKeys.add(event)
        super.keyDown(with: event)
    }

    /// A sent key down that comes back to the web view through its window, not through the application, goes no further either.
    override func keyDown(with event: NSEvent) {
        guard !WebKitSentKeys.contains(event) else { return }
        super.keyDown(with: event)
    }

    // A new click clears the last report, so a menu never shows what an earlier click was on.
    override func rightMouseDown(with event: NSEvent) {
        pendingElement = nil
        pendingMediaFrame = nil
        super.rightMouseDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { pendingElement = nil; pendingMediaFrame = nil }
        super.mouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // A modifier click may bypass our DOM event. Keep WebKit's own menu when it did,
        // rather than replacing native media controls with a background menu.
        guard let element = pendingElement else { return }
        let mediaFrame = pendingMediaFrame
        pendingElement = nil
        pendingMediaFrame = nil
        guard let contents else { return }
        contents.prepareContextMenu(menu, for: element, at: contents.view.convert(event.locationInWindow, from: nil), mediaFrame: mediaFrame)
    }

    /// Select All gets its own action, because WebKit's editable menu has none on macOS.
    @objc func selectAllFromContextMenu(_ sender: Any?) {
        selectAll(sender)
    }
}

/// A tab's view: its web view, and the Web Inspector once WebKit attaches it beside the web view, so the inspector moves with the tab.
final class WebKitPageView: NSView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    // Focusing the page focuses its web view, which takes the keys.
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            self.window?.makeFirstResponder(self.webView)
        }
        return true
    }
}
