// Runs one command-line tool with `posix_spawn` in its own process group and working directory. The process receives only the given environment. Pipes replace a terminal for standard input, output, and error. Standard input closes after the first message unless the caller keeps it open for later messages, as a Claude Code session does. A shell hook's interpreter reads its script from descriptor 3. Ending the run sends SIGTERM to the group, then SIGKILL two seconds later.
import Darwin
import Foundation

/// How a process ended.
public enum CommandLineTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    /// Decodes a `waitpid` status; Swift cannot import the macros that do this.
    init(waitStatus: Int32) {
        let signal = waitStatus & 0x7F
        self = signal == 0 ? .exited((waitStatus >> 8) & 0xFF) : .signaled(signal)
    }
}

/// Runs one process in its own group and streams its standard output.
public final class CommandLineProcess: @unchecked Sendable {
    /// Seconds between SIGTERM and SIGKILL.
    private static let terminationGrace: TimeInterval = 2
    /// Seconds standard output stays open after the process exits, for what it wrote to be read.
    private static let outputGrace: TimeInterval = 1
    private static let errorTailLimit = 8_192

    /// The process ID, which is also the ID of its process group.
    public let id: pid_t
    /// Standard output as it arrives. It finishes at the end of the output, a second after the process exits if a process it started keeps the output open, or when the task reading it is cancelled.
    public let output: AsyncStream<Data>
    /// The end of standard error, kept for an error's detail.
    private let errorTail: Task<Data, Never>
    private let exit = ExitRecord()
    private let input: InputPipe
    private let scriptInput: ScriptPipe?
    private let lock = NSLock()
    private var isTerminating = false

    /// Starts the process. Throws a `POSIXError` when it cannot start, for example because the executable does not exist. `input` goes to standard input, which then closes, or with `keepsInputOpen` stays open for `write(_:)` until `closeInput()` or the process ends. `script`, when given, goes to a pipe at descriptor 3, which closes once it is written or the process ends, so that an interpreter started with `/dev/fd/3` runs exactly these bytes. `argumentZero` is the name the process gets as its first argument, the executable's path when nil.
    public init(executable: URL, arguments: [String], environment: [String: String], directory: URL, input: Data, keepsInputOpen: Bool = false, script: Data? = nil,
                argumentZero: String? = nil) throws {
        let pipes = try Self.makePipes()
        var scriptPipe: [Int32] = [-1, -1]
        if script != nil {
            guard pipe(&scriptPipe) == 0 else {
                let code = errno
                pipes.all.forEach { close($0) }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            scriptPipe.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
            // A `dup2` onto itself would keep the descriptor's close-on-exec flag, so the read end moves off descriptor 3.
            if scriptPipe[0] == 3 {
                let moved = fcntl(3, F_DUPFD_CLOEXEC, 4)
                close(3)
                guard moved >= 0 else {
                    pipes.all.forEach { close($0) }
                    close(scriptPipe[1])
                    throw POSIXError(.EMFILE)
                }
                scriptPipe[0] = moved
            }
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipes.inputRead, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipes.outputWrite, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipes.errorWrite, STDERR_FILENO)
        if script != nil { posix_spawn_file_actions_adddup2(&actions, scriptPipe[0], 3) }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A process group of its own, so ending it reaches the processes it starts; default signal handling; and no other descriptor of this app.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var signals = sigset_t()
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)

        var processID: pid_t = 0
        let status = Self.withCStrings([argumentZero ?? executable.path] + arguments) { argv in
            Self.withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&processID, executable.path, &actions, &attributes, argv, envp)
            }
        }
        [pipes.inputRead, pipes.outputWrite, pipes.errorWrite].forEach { close($0) }
        if script != nil { close(scriptPipe[0]) }
        guard status == 0 else {
            [pipes.inputWrite, pipes.outputRead, pipes.errorRead].forEach { close($0) }
            if script != nil { close(scriptPipe[1]) }
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        id = processID

        // A tool that exits without reading its input ends the write with EPIPE instead of a signal.
        _ = fcntl(pipes.inputWrite, F_SETNOSIGPIPE, 1)
        let inputPipe = InputPipe(descriptor: pipes.inputWrite)
        self.input = inputPipe
        inputPipe.write(input)
        if !keepsInputOpen { inputPipe.close() }
        let scriptInput = script.map { ScriptPipe(descriptor: scriptPipe[1], script: $0) }
        self.scriptInput = scriptInput
        let standardOutput = Self.stream(reading: pipes.outputRead)
        output = standardOutput.stream
        let outputSource = standardOutput.source
        let errors = Self.stream(reading: pipes.errorRead).stream
        errorTail = Task.detached {
            var tail = Data()
            for await chunk in errors {
                tail.append(chunk)
                if tail.count > Self.errorTailLimit { tail = Data(tail.suffix(Self.errorTailLimit)) }
            }
            return tail
        }
        // `waitpid` blocks until the process ends, so it gets a thread of its own, which reaps the process as soon as it ends.
        Thread.detachNewThread { [exit, inputPipe] in
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1, errno == EINTR {}
            exit.record(CommandLineTermination(waitStatus: status))
            inputPipe.close()
            scriptInput?.close()
            // A background process the tool started, such as an update check, can hold standard output open after the tool exits; reading stops once the tool's own output has been read.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.outputGrace) { outputSource.cancel() }
        }
    }

    /// Waits until the process has ended.
    public func termination() async -> CommandLineTermination {
        await exit.wait()
    }

    /// Writes more to standard input, after what was written before. Does nothing once standard input has closed.
    func write(_ data: Data) {
        input.write(data)
    }

    /// Closes standard input, after what was written before.
    func closeInput() {
        input.close()
    }

    /// Whether the script's pipe at descriptor 3 has closed, or there is none.
    var isScriptClosed: Bool {
        scriptInput?.isClosed ?? true
    }

    /// Sends SIGTERM to the process group, then SIGKILL two seconds later to whatever of the group still runs. Calls after the first do nothing.
    public func terminate() {
        lock.lock()
        let isFirst = !isTerminating
        isTerminating = true
        lock.unlock()
        guard isFirst else { return }
        let group = -id
        kill(group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminationGrace) { kill(group, SIGKILL) }
    }

    /// The last line the tool wrote to standard error. It is read once standard error ends, or a second after this call if a process the tool started keeps standard error open.
    public func lastErrorLine() async -> String? {
        let text = String(decoding: await errorOutput(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    /// The last 8 KB the tool wrote to standard error, kept in memory only. It is read once standard error ends, or a second after this call if a process the tool started keeps standard error open.
    public func errorOutput() async -> Data {
        let deadline = Task { [errorTail] in
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            errorTail.cancel()
        }
        defer { deadline.cancel() }
        return await errorTail.value
    }

    // MARK: Descriptors

    private struct Pipes {
        var inputRead, inputWrite, outputRead, outputWrite, errorRead, errorWrite: Int32

        var all: [Int32] { [inputRead, inputWrite, outputRead, outputWrite, errorRead, errorWrite] }
    }

    /// Pipes for the three standard descriptors, closed on exec in any other process this app starts.
    private static func makePipes() throws -> Pipes {
        var descriptors: [Int32] = []
        for _ in 0..<3 {
            var pair: [Int32] = [0, 0]
            guard pipe(&pair) == 0 else {
                let code = errno
                descriptors.forEach { close($0) }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            descriptors += pair
        }
        descriptors.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        return Pipes(inputRead: descriptors[0], inputWrite: descriptors[1], outputRead: descriptors[2], outputWrite: descriptors[3], errorRead: descriptors[4], errorWrite: descriptors[5])
    }

    /// The data read from `descriptor` until its end, after which the descriptor closes, and the source that reads it. Reading stops early once the stream is dropped, the task reading it is cancelled, or the source is cancelled.
    private static func stream(reading descriptor: Int32) -> (stream: AsyncStream<Data>, source: DispatchSourceRead) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        let stream = AsyncStream<Data> { continuation in
            source.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    continuation.yield(Data(buffer[..<count]))
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    source.cancel()
                }
            }
            source.setCancelHandler {
                close(descriptor)
                continuation.finish()
            }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
        return (stream, source)
    }

    /// Writes all of `data` unless the reader goes away.
    fileprivate static func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count, let base = buffer.baseAddress {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// A NULL-terminated array of C strings for `posix_spawn`, valid during `body`.
    private static func withCStrings<Result>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Result) -> Result {
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        return body(pointers + [nil])
    }
}

/// The writing end of standard input. Writes and the close run in order on a queue of their own, so a tool that reads slowly holds no other thread; a write after the close does nothing.
private final class InputPipe: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "xyz.taeyoon.arch.command-line-input", qos: .userInitiated)
    /// Read and written only on `queue`.
    private var isOpen = true

    /// Keeps the descriptor open for ordered writes and a later close.
    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Queues nonempty input behind earlier writes unless the pipe has closed.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard isOpen else { return }
            CommandLineProcess.write(data, to: descriptor)
        }
    }

    /// Queues a close after all writes already submitted.
    func close() {
        queue.async { [self] in
            guard isOpen else { return }
            isOpen = false
            Darwin.close(descriptor)
        }
    }
}

/// The writing end of a shell hook's script pipe at descriptor 3. Every process the interpreter starts inherits that descriptor, and one that keeps it open without reading would block a plain write for good once the interpreter has exited, so the bytes go out without blocking, as the pipe takes them, and the pipe closes once they are all written, the reader is gone, or the process ends.
private final class ScriptPipe: @unchecked Sendable {
    private let source: DispatchSourceWrite
    private let lock = NSLock()
    /// Set by the source's cancel handler; read under `lock`.
    private var hasClosed = false

    /// Streams script bytes through descriptor 3 without blocking a thread.
    init(descriptor: Int32, script: Data) {
        // An interpreter that exits before it reads its whole script ends the write with EPIPE instead of a signal.
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        self.source = source
        var offset = 0
        // A source's event handler never runs twice at once, so `offset` needs no lock.
        source.setEventHandler {
            let written = script.withUnsafeBytes { buffer in buffer.baseAddress.map { Darwin.write(descriptor, $0 + offset, buffer.count - offset) } ?? 0 }
            if written > 0 { offset += written }
            if offset >= script.count || (written < 0 && errno != EAGAIN && errno != EINTR) { source.cancel() }
        }
        source.setCancelHandler { [self] in
            Darwin.close(descriptor)
            lock.lock()
            hasClosed = true
            lock.unlock()
        }
        source.resume()
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasClosed
    }

    func close() {
        source.cancel()
    }
}

/// How the process ended, recorded once by the thread that waits for it and awaited by any number of callers.
private final class ExitRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var termination: CommandLineTermination?
    private var waiters: [CheckedContinuation<CommandLineTermination, Never>] = []

    /// Saves the process result and resumes callers already waiting for it.
    func record(_ termination: CommandLineTermination) {
        lock.lock()
        self.termination = termination
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0.resume(returning: termination) }
    }

    /// Returns the recorded result or waits until the process ends.
    func wait() async -> CommandLineTermination {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let termination {
                lock.unlock()
                continuation.resume(returning: termination)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
