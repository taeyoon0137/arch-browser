import AppKit
import ARCHEngineWebKit
import CEFBridge

/// AppKit does not quit while a window shows a sheet, so the session answers its sheets before AppKit checks. The user confirms a quit that stops downloads or a terminal program first, while the sheets still show, so that Cancel keeps them.
final class ArchApplication: ARCHCEFApplication {
    override func terminate(_ sender: Any?) {
        // Inside CEF's work, as for ⌘Q in a Chromium page, the bridge runs the quit again once that work has returned, and the questions wait for that.
        guard !ARCHCEFRuntime.isRunningWork else { return super.terminate(sender) }
        let appDelegate = delegate as? AppDelegate
        guard appDelegate?.confirmsQuit() != false else { return }
        appDelegate?.setQuitting(true)
        super.terminate(sender)
        // AppKit returns only when the app does not quit.
        appDelegate?.setQuitting(false)
    }

    /// A key down of a WebKit page's trusted input that WebKit hands back unhandled goes no further: AppKit would offer it to the event monitors and the menus and send it to the key window, whichever window and view are key by then.
    override func sendEvent(_ event: NSEvent) {
        guard !WebKitEngine.isTrustedInputKey(event) else { return }
        super.sendEvent(event)
    }
}

// CEF requires its NSApplication subclass, so create it before anything else touches NSApp.
let application = ArchApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
