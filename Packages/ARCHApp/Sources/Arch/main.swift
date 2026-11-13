import AppKit
import CEFBridge

/// The session answers every tab's prompt before AppKit quits, so that each engine callback has its answer before the engines shut down at `NSApplicationWillTerminateNotification`. The user confirms a quit that stops downloads or a terminal program first, while the prompt cards still show, so that Cancel keeps them. AppKit itself still stops a quit while a window shows a sheet of its own with more than one button; the prompts then wait for answers again.
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
}

// CEF requires its NSApplication subclass, so create it before anything else touches NSApp.
let application = ArchApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
