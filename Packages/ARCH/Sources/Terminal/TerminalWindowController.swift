// The built-in terminal opens the user's login shell in one window.
// The user can install command-line AI tools and sign in to them there.
// Closing the window or quitting Arch ends the shell. Showing the terminal again after its shell ends starts a new shell.
import AppKit

/// Owns the built-in terminal window and its current login shell.
public final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    /// The controller, created when the terminal first shows.
    public static var shared: TerminalWindowController {
        if let instance { return instance }
        let controller = TerminalWindowController()
        instance = controller
        return controller
    }

    private static var instance: TerminalWindowController?

    private let scrollView = NSScrollView()
    private var terminal: PseudoTerminal?
    private var shellHasExited = false
    /// Whether the user confirmed closing the window while a program runs.
    private var closesWithRunningProgram = false
    /// A command that `show(typing:)` types once the new shell's output has paused, which is when its prompt shows.
    private var pendingTyping: Data?
    private var typingWork: DispatchWorkItem?

    private init() {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .textBackgroundColor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = localized("Terminal")
        window.contentView = scrollView
        window.contentMinSize = NSSize(width: 320, height: 160)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    /// Brings the terminal to the front, starting a login shell when none runs.
    public func show() {
        if terminal == nil || shellHasExited { start() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Brings the terminal to the front and types `command` at the shell's prompt without running it, so that the user reads it and presses Return, as Sign In in Settings ▸ AI does with a tool's sign-in. Nothing is typed while a program other than the shell runs in front, since the text would go to that program.
    public func show(typing command: String) {
        let startsShell = terminal == nil || shellHasExited
        show()
        guard let terminal else { return }
        if startsShell {
            pendingTyping = Data(command.utf8)
        } else if !terminal.hasRunningProgram {
            terminal.write(Data(command.utf8))
        }
    }

    /// Types the pending command a moment after the latest output, so that a profile that prints first does not take it.
    private func scheduleTyping() {
        guard pendingTyping != nil else { return }
        typingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let text = self.pendingTyping, let terminal = self.terminal else { return }
            self.pendingTyping = nil
            if !terminal.hasRunningProgram { terminal.write(text) }
        }
        typingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    /// A new screen and view for each shell, sized to the window before the shell starts so its first prompt fits.
    private func start() {
        terminal?.close()
        terminal = nil
        shellHasExited = false
        typingWork?.cancel()
        pendingTyping = nil
        let screen = TerminalScreen(size: TerminalSize(columns: 80, rows: 24))
        let view = TerminalView(screen: screen)
        scrollView.documentView = view
        view.updateLayout()
        window?.makeFirstResponder(view)
        window?.title = localized("Terminal")
        let terminal: PseudoTerminal
        do {
            terminal = try PseudoTerminal(size: screen.size)
        } catch {
            screen.feed(Data("The shell could not start: \(error.localizedDescription)\r\n".utf8))
            view.screenDidChange()
            return
        }
        terminal.onOutput = { [weak self, weak view] data in
            screen.feed(data)
            view?.screenDidChange()
            self?.window?.title = screen.title.isEmpty ? localized("Terminal") : screen.title
            self?.scheduleTyping()
        }
        // The window keeps the last output readable, such as a sign-in code.
        terminal.onExit = { [weak self, weak view, weak terminal] in
            guard let self, self.terminal === terminal else { return }
            self.shellHasExited = true
            screen.feed(Data("\r\n[Process completed]\r\n".utf8))
            view?.screenDidChange()
        }
        screen.onReply = { [weak terminal] reply in terminal?.write(reply) }
        view.onInput = { [weak terminal] input in terminal?.write(input) }
        view.onResize = { [weak terminal] size in terminal?.resize(to: size) }
        self.terminal = terminal
    }

    // MARK: Closing

    /// A program that runs in front, such as a tool in the middle of a sign-in, ends with the window, so the user confirms first.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard terminal?.hasRunningProgram == true, !closesWithRunningProgram else { return true }
        let alert = Self.runningProgramAlert(message: localized("Close the terminal?"), action: localized("Close"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.closesWithRunningProgram = true
            sender.performClose(nil)
        }
        return false
    }

    /// Cancels pending typing and closes the shell when the window closes.
    public func windowWillClose(_ notification: Notification) {
        closesWithRunningProgram = false
        typingWork?.cancel()
        pendingTyping = nil
        terminal?.close()
        terminal = nil
    }

    /// Whether a program other than the shell runs in front, which quitting the app ends as closing the window does. False when the terminal never showed. The app reads it when a quit starts, before it answers the tabs' prompts, and asks in one alert with whatever else the quit stops.
    public static var hasRunningProgram: Bool {
        instance?.terminal?.hasRunningProgram == true
    }

    /// Brings the terminal forward, so that the program the quit alert names shows behind it.
    public static func bringForward() {
        instance?.window?.makeKeyAndOrderFront(nil)
    }

    /// Builds the confirmation alert shown before ending a foreground terminal program.
    private static func runningProgramAlert(message: String, action: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = localized("The program running in the terminal will stop.")
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: localized("Cancel"))
        return alert
    }
}
