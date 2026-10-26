import AppKit
import CEFBridge

/// AppKit does not quit while a window shows a sheet, so the session answers its sheets before AppKit checks. The user confirms a quit that stops downloads or a terminal program first, while the sheets still show, so that Cancel keeps them.
final class ArchApplication: ARCHCEFApplication {
    override func terminate(_ sender: Any?) {
        let appDelegate = delegate as? AppDelegate
        guard appDelegate?.confirmsQuit() != false else { return }
        appDelegate?.setQuitting(true)
        super.terminate(sender)
        // AppKit returns only when the app does not quit.
        appDelegate?.setQuitting(false)
    }
}

// CEF requires its NSApplication subclass, so create it before anything else touches NSApp.
let application = ArchApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
