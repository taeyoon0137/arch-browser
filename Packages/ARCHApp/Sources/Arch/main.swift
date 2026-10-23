import AppKit
import CEFBridge

/// AppKit does not quit while a window shows a sheet, so the session answers its sheets before AppKit checks.
final class ArchApplication: ARCHCEFApplication {
    override func terminate(_ sender: Any?) {
        let appDelegate = delegate as? AppDelegate
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
