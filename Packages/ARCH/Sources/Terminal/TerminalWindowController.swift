// The built-in terminal: one window with the user's login shell, where the user installs command-line AI tools and signs in to them. Closing the window or quitting the app ends the shell. Showing the terminal again after its shell ended starts a new one.
import AppKit

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

    private init() {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .textBackgroundColor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Terminal"
        window.contentView = scrollView
        window.contentMinSize = NSSize(width: 320, height: 160)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalWindowController is created through shared")
    }

    /// Brings the terminal to the front, starting a login shell when none runs.
    public func show() {
        if terminal == nil || shellHasExited { start() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A new screen and view for each shell, sized to the window before the shell starts so its first prompt fits.
    private func start() {
        terminal?.close()
        terminal = nil
        shellHasExited = false
        let screen = TerminalScreen(size: TerminalSize(columns: 80, rows: 24))
        let view = TerminalView(screen: screen)
        scrollView.documentView = view
        view.updateLayout()
        window?.makeFirstResponder(view)
        window?.title = "Terminal"
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
            self?.window?.title = screen.title.isEmpty ? "Terminal" : screen.title
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
        let alert = Self.runningProgramAlert(message: "Close the terminal?", action: "Close")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.closesWithRunningProgram = true
            sender.performClose(nil)
        }
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        closesWithRunningProgram = false
        terminal?.close()
        terminal = nil
    }

    /// Quitting the app ends the shell as closing the window does, so while a program runs in front the terminal comes forward and the user confirms first. Returns whether the app may quit; it may when the terminal never showed. The app asks it when a quit starts, before it ends its windows' sheets.
    public static func allowsQuit() -> Bool {
        guard let controller = instance, controller.terminal?.hasRunningProgram == true else { return true }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return runningProgramAlert(message: "Quit Arch?", action: "Quit").runModal() == .alertFirstButtonReturn
    }

    private static func runningProgramAlert(message: String, action: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "The program running in the terminal will stop."
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
