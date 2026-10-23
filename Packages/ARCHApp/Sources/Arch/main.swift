import AppKit
import CEFBridge

// CEF requires its NSApplication subclass, so create it before anything else touches NSApp.
let application = ARCHCEFApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
