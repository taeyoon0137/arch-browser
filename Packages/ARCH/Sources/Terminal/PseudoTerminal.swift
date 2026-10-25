// The user's login shell on a pseudo-terminal from `posix_openpt`. The shell starts in a session of its own with the terminal as its controlling terminal, so job control, passwords read from /dev/tty, and window size changes work as in any terminal app.
import Darwin
import Foundation

final class PseudoTerminal {
    /// Output from the shell and the programs it runs, on the main queue.
    var onOutput: ((Data) -> Void)?
    /// Called on the main queue once the shell has exited.
    var onExit: (() -> Void)?

    /// The shell's process ID, which is also its session's and process group's.
    private let shellID: pid_t
    private let master: Descriptor
    private let readSource: DispatchSourceRead
    /// Keeps typed and pasted input in order.
    private let writeQueue = DispatchQueue(label: "xyz.taeyoon.arch.terminal.write")
    private var hasExited = false

    /// Starts the login shell in the user's home folder on a terminal of `size`. Throws a `POSIXError` when the terminal or the shell cannot start.
    init(size: TerminalSize) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw Self.lastError() }
        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard grantpt(master) == 0, unlockpt(master) == 0, ptsname_r(master, &nameBuffer, nameBuffer.count) == 0 else {
            let error = Self.lastError()
            Darwin.close(master)
            throw error
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // Writes wait on the write queue rather than block while a program does not read its input.
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let terminalPath = String(cString: nameBuffer)
        // The size can be set only while the terminal's other side is open, so it is opened here too, without becoming this app's terminal, until the shell has opened it.
        let terminal = open(terminalPath, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard terminal >= 0 else {
            let error = Self.lastError()
            Darwin.close(master)
            throw error
        }
        defer { Darwin.close(terminal) }
        Self.setSize(size, of: master)
        var processID: pid_t = 0
        let status = Self.spawn(shell: Self.loginShell, terminalPath: terminalPath, processID: &processID)
        guard status == 0 else {
            Darwin.close(master)
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        shellID = processID
        self.master = Descriptor(master)
        readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue(label: "xyz.taeyoon.arch.terminal.read"))
        startReading()
        waitForExit()
    }

    /// Writes input for the program in front, such as typed keys or pasted text.
    func write(_ data: Data) {
        writeQueue.async { [master] in
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count, let base = buffer.baseAddress {
                    guard let written = master.use({ Darwin.write($0, base + offset, buffer.count - offset) }) else { return }
                    if written > 0 {
                        offset += written
                    } else if errno == EAGAIN {
                        // The program has not read its earlier input yet.
                        usleep(10_000)
                    } else if errno != EINTR {
                        return
                    }
                }
            }
        }
    }

    /// Tells the programs the new size; the kernel sends them SIGWINCH.
    func resize(to size: TerminalSize) {
        master.use { Self.setSize(size, of: $0) }
    }

    /// Whether a program other than the shell runs in front, such as a tool waiting for a sign-in.
    var hasRunningProgram: Bool {
        guard let foreground = master.use(tcgetpgrp) else { return false }
        return foreground > 0 && foreground != shellID
    }

    /// Hangs up the terminal, which ends the shell and the programs it runs.
    func close() {
        if !hasExited { kill(shellID, SIGHUP) }
        readSource.cancel()
    }

    // MARK: Reading

    /// Reads until every program has closed the terminal or it is hung up, then closes it.
    private func startReading() {
        let source = readSource
        let master = master
        let capacity = 65_536
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        source.setEventHandler { [weak self] in
            guard let count = master.use({ read($0, buffer, capacity) }) else { return }
            guard count > 0 else {
                // The terminal reports EIO once the last program using it has exited.
                if count == 0 || (errno != EAGAIN && errno != EINTR) { source.cancel() }
                return
            }
            let data = Data(bytes: buffer, count: count)
            DispatchQueue.main.async { self?.onOutput?(data) }
        }
        source.setCancelHandler {
            master.close()
            buffer.deallocate()
        }
        source.resume()
    }

    private func waitForExit() {
        let shellID = shellID
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(shellID, &status, 0) == -1, errno == EINTR {}
            DispatchQueue.main.async {
                self?.hasExited = true
                self?.onExit?()
            }
        }
    }

    // MARK: Starting

    /// `$SHELL`, else the account's shell, else zsh.
    private static var loginShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    /// Opens the terminal in the new session, which makes it the session's controlling terminal, then replaces itself with the login shell. A terminal that `posix_spawn` opens for the standard descriptors does not become the controlling terminal, and zsh opens its terminal in a way that does not either, so `/bin/sh` opens it once more first.
    private static let controllingTerminalCommand = #": <>"$1"; exec "$0" -l"#

    /// Starts the shell as a login shell in a new session, through `controllingTerminalCommand`. Only the three standard descriptors pass to the shell.
    private static func spawn(shell: String, terminalPath: String, processID: inout pid_t) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, terminalPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, NSHomeDirectory())
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var signals = sigset_t()
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        let arguments = ["/bin/sh", "-c", controllingTerminalCommand, shell, terminalPath]
        let variables = environment.map { "\($0.key)=\($0.value)" }
        return withCStrings(arguments) { argv in
            withCStrings(variables) { envp in
                posix_spawn(&processID, "/bin/sh", &actions, &attributes, argv, envp)
            }
        }
    }

    /// This app's environment, with the terminal type this terminal emulates and a UTF-8 locale when none is set, so the shell handles text other than ASCII.
    private static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = preferredLocale }
        return environment
    }

    /// The user's language and region as a UTF-8 locale the system has, else US English.
    private static var preferredLocale: String {
        let locale = Locale.current
        if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier {
            let name = "\(language)_\(region).UTF-8"
            if FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)") { return name }
        }
        return "en_US.UTF-8"
    }

    /// `TIOCSWINSZ`, which Swift cannot import because the `_IOW` macro builds it: `_IOW('t', 103, struct winsize)`.
    private static let setWindowSize = UInt(0x8000_0000) | UInt(MemoryLayout<winsize>.size & 0x1FFF) << 16 | UInt(UInt8(ascii: "t")) << 8 | 103

    private static func setSize(_ size: TerminalSize, of master: Int32) {
        var value = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, setWindowSize, &value)
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// A NULL-terminated array of C strings for `posix_spawn`, valid during `body`.
    private static func withCStrings<Result>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Result) -> Result {
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        return body(pointers + [nil])
    }
}

/// The terminal's controlling side. Every use holds the lock, so the descriptor never closes during a use and is never used after it closes, when its number may already belong to another file. Uses do not block because the descriptor does not.
private final class Descriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?

    init(_ value: Int32) {
        self.value = value
    }

    /// nil once the descriptor has closed.
    @discardableResult
    func use<Result>(_ body: (Int32) -> Result) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        return value.map(body)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let value { Darwin.close(value) }
        value = nil
    }
}
