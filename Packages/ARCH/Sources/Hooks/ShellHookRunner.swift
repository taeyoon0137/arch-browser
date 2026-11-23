// A shell hook runs Arch's checked copy of a trusted script (`docs/hooks.md`, Shell scripts).
// The registry checks its digest, and the runner checks the interpreter's path and SHA-256 against the trusted version.
// `posix_spawn` starts that interpreter directly in its own process group, never through `env`. The script's bytes arrive on descriptor 3 at `/dev/fd/3`; the event arrives as JSON on standard input.
// The process gets only the listed environment and its own working folder. Standard output is dropped; the end of standard error stays in memory.
// At timeout the group receives SIGTERM, then SIGKILL. While it runs, `arch-cli` uses `ARCH_HOOK_TICKET` within the script's process tree to reach the run tabs under the hook grant.
import Agent
import AgentControl
import AI
import CryptoKit
import Darwin
import Events
import Foundation
import Plugins

// MARK: - The file and its interpreter

/// A sentence about a shell script or its interpreter, for the trust sheet and a run's failure.
public struct HookShellScriptProblem: LocalizedError, Equatable, Sendable {
    public var sentence: String

    public init(_ sentence: String) {
        self.sentence = sentence
    }

    public var errorDescription: String? { sentence }
}

/// The interpreter a script's first line resolved to, as the trust sheet shows it.
public struct HookInterpreterResolution: Equatable, Sendable {
    public var interpreter: HookInterpreter
    /// The path the first line or PATH named, before links resolved.
    public var named: String
    /// The folders of `named` and of the resolved path that the user can write to, which the trust sheet names, since a program can replace an interpreter there.
    public var writableFolders: [String]
}

/// The rules for a shell hook's file and interpreter, which the trust sheet and the runner share.
public enum HookShellScript {
    public static let maximumSize = 1024 * 1024
    /// The script's whole environment.
    public static let environmentNames = ["PATH", "HOME", "LANG", "TMPDIR", "ARCH_HOOK_ID", "ARCH_HOOK_EVENT", "ARCH_HOOK_TICKET"]
    /// What the trust sheet says about the commands the script runs.
    public static let pathSentence = "Commands this script runs by name come from your PATH, and each of them gets this hook's access to Arch."
    /// What the trust sheet says the script receives.
    public static let inputSentence = "The script gets the event as JSON on standard input, and only PATH, HOME, LANG, TMPDIR, ARCH_HOOK_ID, ARCH_HOOK_EVENT, and ARCH_HOOK_TICKET in its environment. Arch runs its own copy of the file, so later changes to the file take effect only after Update from File."
    /// The failure of a run whose ticket the channel could not make.
    static let noTicketSentence = "Arch could not make the run's ticket, so the script did not start."
    /// What Let Agent Runs Read Pages says on the trust sheet.
    public static let readsPagesSentence = "The script and every command it runs can then read the event's page through agent runs."
    static let firstLineSentence = "Its first line must be #! and the absolute path of a program, with at most one option made of the letters e, f, u, v, w, and x, as in -eu, or /usr/bin/env and one program's name."
    static let hiddenCharacterSentence = "The script holds a control or formatting character other than tab and line feed, such as a carriage return or a text direction mark, which Arch cannot show as the interpreter reads it."
    static let changedSentence = "Its interpreter changed."
    /// The letters a first line's option may hold. Across shells, awk, Python, Perl, and Ruby they stop at errors, trace, warn, or name the program's file, and none makes the interpreter read its program from standard input, which carries the event, as `-s`, `-i`, or `-` would.
    static let optionLetters: Set<Character> = ["e", "f", "u", "v", "w", "x"]

    /// What the first line names.
    public enum InterpreterLine: Equatable, Sendable {
        /// An absolute path, and at most one option that the interpreter gets before the script's path, as in `#!/bin/sh -e`.
        case path(String, argument: String?)
        /// `/usr/bin/env` and one program's name, which PATH resolves.
        case env(String)

        /// What the interpreter gets before `/dev/fd/3`.
        var arguments: [String] {
            if case .path(_, let argument?) = self { return [argument] }
            return []
        }
    }

    /// Why Arch would not trust or run the bytes, or nil: at most 1 MB of UTF-8 text without hidden characters whose first line names its interpreter.
    public static func problem(in script: Data) -> String? {
        guard script.count <= maximumSize else { return "The script is larger than 1 MB." }
        guard let text = String(data: script, encoding: .utf8) else { return "The script is not UTF-8 text." }
        if text.unicodeScalars.contains(where: isHidden) { return hiddenCharacterSentence }
        return interpreterLine(of: script) == nil ? firstLineSentence : nil
    }

    /// A character that the trust sheet cannot show as the interpreter reads it: a control character other than tab and line feed, a formatting character such as a text direction mark or a zero-width space, which hides or reorders the text around it, or a line or paragraph separator, where the sheet would break a line that the interpreter reads as one.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control: return scalar != "\t" && scalar != "\n"
        case .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// The first line's interpreter: `#!` with an absolute path and at most one option of `optionLetters` after it, or `/usr/bin/env` and one program's name without options or a path. One word keeps the line's meaning the same however a system splits it.
    public static func interpreterLine(of script: Data) -> InterpreterLine? {
        guard script.starts(with: Array("#!".utf8)) else { return nil }
        let end = script.firstIndex(of: UInt8(ascii: "\n")) ?? script.endIndex
        guard let line = String(data: script[script.startIndex.advanced(by: 2) ..< end], encoding: .utf8) else { return nil }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let program = words.first, program.hasPrefix("/"), words.count <= 2 else { return nil }
        if program == "/usr/bin/env" {
            guard words.count == 2, !words[1].hasPrefix("-"), !words[1].contains("/"), !words[1].contains("=") else { return nil }
            return .env(words[1])
        }
        guard words.count == 2 else { return .path(program, argument: nil) }
        let option = words[1]
        guard option.count > 1, option.first == "-", option.dropFirst().allSatisfy(optionLetters.contains) else { return nil }
        return .path(program, argument: option)
    }

    /// Reads a file for the trust sheet: a regular file, or a link to one, of at most 1 MB that `problem(in:)` accepts.
    public static func read(fileAt url: URL) throws -> Data {
        var status = stat()
        guard stat(url.path, &status) == 0 else { throw HookShellScriptProblem("Arch cannot read \(url.path).") }
        guard status.st_mode & S_IFMT == S_IFREG else { throw HookShellScriptProblem("\(url.path) is not a regular file.") }
        guard status.st_size <= maximumSize else { throw HookShellScriptProblem("The script is larger than 1 MB.") }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw HookShellScriptProblem("Arch cannot read \(url.path).") }
        if let problem = problem(in: data) { throw HookShellScriptProblem(problem) }
        return data
    }

    /// The running app's `Contents/Helpers`, which holds `arch-cli` and leads the script's PATH.
    public static var appHelpers: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    /// The PATH the script gets: the bundle's `Contents/Helpers`, where `arch-cli` is, then the login shell's PATH. Without the login shell's, neither the trust sheet nor a run goes on, since the script's commands and a `/usr/bin/env` interpreter would then come from other folders.
    public static func searchPath(helpers: URL?, loginPath: String) -> String {
        ([helpers?.path].compactMap { $0 } + [loginPath]).joined(separator: ":")
    }

    /// What a run that could not read the login shell's PATH fails with, and what the trust sheet says then.
    public static let loginPathSentence = "Arch could not read the PATH of your login shell, which this script runs with."

    /// The first line's interpreter as an absolute path with links resolved, with its SHA-256: a `/usr/bin/env` program is looked up in `searchPath`, the PATH the script gets.
    public static func resolve(_ line: InterpreterLine, searchPath: String) -> Result<HookInterpreterResolution, HookShellScriptProblem> {
        let named: String
        switch line {
        case .path(let path, _):
            named = path
        case .env(let program):
            let folders = searchPath.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            guard let found = folders.lazy.map({ ($0 as NSString).appendingPathComponent(program) }).first(where: isProgram) else {
                return .failure(HookShellScriptProblem("Arch cannot find \(program) in the PATH this script gets."))
            }
            named = found
        }
        guard isProgram(named), let resolved = realPath(of: named), isProgram(resolved) else { return .failure(HookShellScriptProblem("\(named) is not a program Arch can run.")) }
        guard let digest = digest(ofFileAt: resolved) else { return .failure(HookShellScriptProblem("Arch cannot read \(resolved).")) }
        let folders = [(named as NSString).deletingLastPathComponent, (resolved as NSString).deletingLastPathComponent]
        var writable: [String] = []
        for folder in folders where access(folder, W_OK) == 0 && !writable.contains(folder) { writable.append(folder) }
        return .success(HookInterpreterResolution(interpreter: HookInterpreter(path: resolved, digest: digest), named: named, writableFolders: writable))
    }

    /// The interpreter of the script's first line, resolved in `searchPath`, for the trust sheet.
    public static func inspect(_ script: Data, searchPath: String) -> Result<HookInterpreterResolution, HookShellScriptProblem> {
        if let problem = problem(in: script) { return .failure(HookShellScriptProblem(problem)) }
        guard let line = interpreterLine(of: script) else { return .failure(HookShellScriptProblem(firstLineSentence)) }
        return resolve(line, searchPath: searchPath)
    }

    /// Before a run: the path the first line names the recorded interpreter by, before links resolve, which the run passes as the interpreter's first argument as the system's `#!` handling would, or why the line no longer resolves to it, by path and digest.
    static func checkInterpreter(_ recorded: HookInterpreter, script: Data, searchPath: String) -> Result<String, HookShellScriptProblem> {
        guard let line = interpreterLine(of: script) else { return .failure(HookShellScriptProblem(firstLineSentence)) }
        guard case .success(let resolution) = resolve(line, searchPath: searchPath), resolution.interpreter == recorded else { return .failure(HookShellScriptProblem(changedSentence)) }
        return .success(resolution.named)
    }

    /// Why the script's first line no longer resolves to the recorded interpreter, or nil when it still does.
    static func interpreterProblem(_ recorded: HookInterpreter, script: Data, searchPath: String) -> String? {
        if case .failure(let problem) = checkInterpreter(recorded, script: script, searchPath: searchPath) { return problem.sentence }
        return nil
    }

    /// The lines of `new` that `old` does not hold in the same order, by index, and how many lines of `old` are gone, for Update from File.
    public static func changes(from old: String, to new: String) -> (changed: Set<Int>, removed: Int) {
        let before = lines(of: old), after = lines(of: new)
        var changed = Set<Int>()
        var removed = 0
        for change in after.difference(from: before) {
            switch change {
            case .insert(let offset, _, _): changed.insert(offset)
            case .remove: removed += 1
            }
        }
        return (changed, removed)
    }

    /// The text's lines as an interpreter reads them, split at line feeds only.
    public static func lines(of text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    /// A shell hook's agent grant as the trust sheet leaves it: without Let Agent Runs Read Pages, no page reads and tab access `title`, so that its runs get titles and addresses only.
    public static func agentGrant(_ grant: AgentRunGrant, readsPages: Bool) -> AgentRunGrant {
        guard !readsPages else { return grant }
        var limited = grant
        limited.tools.subtract(["read_text", "snapshot"])
        limited.tabAccess = .title
        return limited
    }

    // MARK: Files

    /// Whether the path names a regular executable file.
    private static func isProgram(_ path: String) -> Bool {
        var status = stat()
        return stat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
    }

    /// Resolves symbolic links in an interpreter path.
    private static func realPath(of path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The file's SHA-256 as `sha256:<hex>`, from the cache while its device, inode, size, and modification and change times are those it was read with, since a run checks its interpreter each time and some interpreters are large.
    static func digest(ofFileAt path: String) -> String? {
        guard let before = FileIdentity(path: path) else { return nil }
        if let cached = digestCache.withLock({ $0[path] }), cached.identity == before { return cached.digest }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        let digest = "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
        // A file that changed while it was read is read again next time.
        if FileIdentity(path: path) == before { digestCache.withLock { $0[path] = (before, digest) } }
        return digest
    }

    private struct FileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modified: timespec
        var changed: timespec

        init?(path: String) {
            var status = stat()
            guard stat(path, &status) == 0 else { return nil }
            device = status.st_dev
            inode = status.st_ino
            size = status.st_size
            modified = status.st_mtimespec
            changed = status.st_ctimespec
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    private static let digestCache = Locked<[String: (identity: FileIdentity, digest: String)]>([:])
}

/// A value behind a lock, for the digest cache that runs read off the main thread.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - The runner

@MainActor
/// Runs a trusted shell hook with its checked interpreter, bounded process, and grant channel.
public final class ShellHookRunner: HookScriptRunning {
    /// The end of standard error that a run's last runs keep in memory.
    public static let errorOutputLimit = 4 * 1024

    private let host: any PluginBrowserHost
    private let allowsAI: (URL) -> Bool
    private let channel: (any AgentHookRunChannel)?
    private let helpers: URL?
    private let temporaryFolder: URL
    private let loginPath: @Sendable () async -> String?
    /// Runs the agent runs a script starts with `arch-cli agent run`, as the JavaScript runner's `arch.agent.run` does.
    private let runAgent: HookScriptRunner.AgentCall?
    private var running: [UUID: Running] = [:]
    private var errorOutputs: [UUID: String] = [:]

    /// `host` reaches the tabs, `allowsAI` is the AI interface's site check for a hook with `agent`, and `channel` binds `arch-cli`'s tickets; `helpers` is the bundle's `Contents/Helpers`, which leads the script's PATH. Tests give their own folder and PATH.
    public init(host: any PluginBrowserHost, allowsAI: @escaping (URL) -> Bool, channel: (any AgentHookRunChannel)?, helpers: URL?,
                temporaryFolder: URL = FileManager.default.temporaryDirectory, loginPath: @escaping @Sendable () async -> String? = { await AILoginShell.path() },
                runAgent: HookScriptRunner.AgentCall? = nil) {
        self.runAgent = runAgent
        self.host = host
        self.allowsAI = allowsAI
        self.channel = channel
        self.helpers = helpers
        self.temporaryFolder = temporaryFolder
        self.loginPath = loginPath
    }

    /// Checks the interpreter, starts the script with a bounded environment and ticket, and returns its outcome.
    public func run(_ invocation: HookInvocation) async -> HookRunOutcome {
        guard case .shell(_, _, let recorded) = invocation.hook.script else { return .failed(code: "invalidScript", message: "This hook's script is not a shell script.") }
        if let problem = HookShellScript.problem(in: invocation.script) { return .failed(code: "invalidScript", message: problem) }
        let state = Running()
        running[invocation.run] = state
        defer { running[invocation.run] = nil }
        let login = await loginPath()
        if state.isCancelled { return .cancelled }
        if ContinuousClock.now >= invocation.deadline { return .timedOut }
        // A failure that pauses nothing; the next run reads the login shell again.
        guard let login else { return .failed(code: "loginShell", message: HookShellScript.loginPathSentence) }
        let searchPath = HookShellScript.searchPath(helpers: helpers, loginPath: login)
        let script = invocation.script
        guard let line = HookShellScript.interpreterLine(of: script) else { return .failed(code: "invalidScript", message: HookShellScript.firstLineSentence) }
        let checked = await Task.detached { HookShellScript.checkInterpreter(recorded, script: script, searchPath: searchPath) }.value
        if state.isCancelled { return .cancelled }
        if ContinuousClock.now >= invocation.deadline { return .timedOut }
        let named: String
        switch checked {
        case .success(let name): named = name
        case .failure(let problem): return .failed(code: "scriptChanged", message: problem.sentence)
        }

        let folder = temporaryFolder.appendingPathComponent("Arch-Hook-\(invocation.run.uuidString)", isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else { return .failed(code: "notStarted", message: "Arch could not make the run's folder: \(String(cString: strerror(errno))).") }
        defer { try? FileManager.default.removeItem(at: folder) }
        state.folder = folder
        let tools = ShellHookRunTools(invocation: invocation, host: host, allowsAI: allowsAI, runAgent: runAgent)
        var agentRun: (@MainActor ([String: AgentJSON]) async -> AgentRunResult)?
        if tools.permitsAgentRuns {
            agentRun = { @MainActor fields in await tools.runAgent(fields) }
        }
        let opened = channel?.openHookRun(invocation.run, tools: tools.names, handles: tools.handles, call: { call in tools.call(call) }, agentRun: agentRun)
        // A channel gives an empty ticket only when it could not make one, so the script would start without access; the run fails and its record says why.
        if opened?.isEmpty == true {
            tools.end()
            channel?.closeHookRun(invocation.run)
            return .failed(code: "notStarted", message: HookShellScript.noTicketSentence)
        }
        let ticket = opened ?? ""
        state.accessEnd = { [channel] in
            tools.end()
            channel?.closeHookRun(invocation.run)
        }
        defer { state.endAccess() }
        let environment = Self.environment(of: invocation, searchPath: searchPath, folder: folder, ticket: ticket)
        let process: CommandLineProcess
        do {
            // The executable is the recorded path; the first argument is the name the first line gave it, which a program that serves several tools under several names reads.
            process = try CommandLineProcess(executable: URL(fileURLWithPath: recorded.path), arguments: line.arguments + ["/dev/fd/3"], environment: environment, directory: folder,
                                             input: Self.input(of: invocation, handles: tools.handles), script: script, argumentZero: named)
        } catch {
            return .failed(code: "notStarted", message: "Arch could not start \(recorded.path): \(error.localizedDescription)")
        }
        // Before any message of the script's `arch-cli` can arrive, which the main actor delivers after this.
        channel?.hookRun(invocation.run, didStart: process.id)
        state.process = process
        if state.isCancelled { state.end() }
        Task.detached { for await _ in process.output {} }
        let watchdog = Task { [weak state] in
            try await Task.sleep(until: invocation.deadline, clock: .continuous)
            state?.didTimeOut = true
            state?.end()
        }
        let termination = await process.termination()
        watchdog.cancel()
        tools.end()
        let errorText = String(decoding: await process.errorOutput().suffix(Self.errorOutputLimit), as: UTF8.self)
        if !errorText.isEmpty { errorOutputs[invocation.run] = errorText }
        if state.didTimeOut { return .timedOut }
        if state.isCancelled { return .cancelled }
        switch termination {
        case .exited(0):
            return .completed(actions: tools.actions, agent: tools.agentUse)
        case .exited(let status):
            let line = errorText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            return .failed(code: "exitStatus", message: "Exited with status \(status)" + (line.map { ": \($0)" } ?? "."))
        case .signaled(let signal):
            return .failed(code: "signal", message: "Ended by signal \(signal).")
        }
    }

    /// Ends the run's tools and its `arch-cli` connections at once, then its process group: SIGTERM, then SIGKILL two seconds later.
    public func cancel(run: UUID) {
        running[run]?.cancel()
    }

    /// Returns and removes the captured standard error for a run.
    public func takeErrorOutput(of run: UUID) -> String? {
        errorOutputs.removeValue(forKey: run)
    }

    /// Seconds that quit gives the scripts' process groups after SIGTERM before SIGKILL.
    public nonisolated static let quitGrace: TimeInterval = 0.5

    /// Ends every running script at quit: their access to Arch, then SIGTERM to each process group and, after at most `grace` seconds, SIGKILL to whatever of them still runs, and removes the runs' folders. It waits here, on the main thread, since the timer that would send SIGKILL and the runs' own cleanup end with Arch.
    public func endAll(grace: TimeInterval = ShellHookRunner.quitGrace) {
        let states = Array(running.values)
        states.forEach { $0.cancel() }
        let groups = states.compactMap { $0.process?.id }
        let deadline = Date().addingTimeInterval(grace)
        while groups.contains(where: { kill(-$0, 0) == 0 }), Date() < deadline { usleep(20_000) }
        for group in groups { kill(-group, SIGKILL) }
        for folder in states.compactMap(\.folder) { try? FileManager.default.removeItem(at: folder) }
    }

    /// The script's whole environment (`HookShellScript.environmentNames`): PATH, the account's home folder, the app's language, the run's folder as TMPDIR, and the hook, the event's kind, and the run's ticket.
    static func environment(of invocation: HookInvocation, searchPath: String, folder: URL, ticket: String) -> [String: String] {
        [
            "PATH": searchPath,
            "HOME": NSHomeDirectory(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": folder.path + "/",
            "ARCH_HOOK_ID": invocation.hook.id.uuidString,
            "ARCH_HOOK_EVENT": invocation.event.kind.rawValue,
            AgentControlProtocol.hookTicketVariable: ticket,
        ]
    }

    /// The event as one line of JSON in the hook's script view, dates in ISO 8601, with the event's tab's handle as `tab.handle`, or `download.handle` for the tab a download came from, when the run reaches it, and `hook: {id, name, agent}` as a JavaScript hook's listener gets it.
    static func input(of invocation: HookInvocation, handles: [UUID: String]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(invocation.event), case .object(var members)? = try? AgentJSON.decode(encoded) else { return Data() }
        if let id = invocation.eventTab, let handle = handles[id] {
            for key in ["tab", "download"] {
                guard case .object(var member)? = members[key] else { continue }
                member["handle"] = .string(handle)
                members[key] = .object(member)
            }
        }
        let hook = invocation.hook
        members["hook"] = .object(["id": .string(hook.id.uuidString), "name": .string(hook.name), "agent": hook.agent.flatMap { try? AgentJSON(encoding: $0) } ?? .null])
        return ((try? AgentJSON.object(members).encoded()) ?? Data()) + Data("\n".utf8)
    }

    /// One running script, from its check to its end.
    @MainActor
    private final class Running {
        var process: CommandLineProcess?
        /// The run's working folder, which quit removes, since the run's own cleanup does not get to.
        var folder: URL?
        /// Ends the run's tools and closes its `arch-cli` connections.
        var accessEnd: (() -> Void)?
        var isCancelled = false
        var didTimeOut = false

        func cancel() {
            isCancelled = true
            end()
        }

        /// Ends the run's access to Arch before its processes, so that no `arch-cli` call of a script that ignores SIGTERM, or of a run the scheduler has already left, lands after a cancel, a pause, or the time limit; then sends the group SIGTERM, and SIGKILL two seconds later.
        func end() {
            endAccess()
            process?.terminate()
        }

        /// Ends the run's access to Arch, once.
        func endAccess() {
            let end = accessEnd
            accessEnd = nil
            end?()
        }
    }
}

// MARK: - The run's tools

/// What `arch-cli` reaches through a shell hook run's ticket (`docs/hooks.md`, Shell scripts ▸ Acting): the run's tabs under the hook's grant, with the event's tab as `t1` and the other run tabs as `t2`, `t3`, and on in sidebar order. `list_tabs` lists them, with titles and addresses only under `tabs`, and for a hook with `agent` none for a tab on a site excluded from AI; `rename_tab` needs `tabs.rename`, sets the suggested name for the run's document of the tab under the suggested name rules with the run's cause, and in a test reports what it would do. Calls after the run ends are refused.
@MainActor
final class ShellHookRunTools {
    let invocation: HookInvocation
    /// Each run tab's handle, by which `arch-cli`'s calls and the answer of its `agent run` name the tab.
    let handles: [UUID: String]
    private(set) var actions: [AgentRunAction] = []
    /// The model and usage of the agent runs the script started.
    private(set) var agentUse: HookAgentUse?
    private let host: any PluginBrowserHost
    private let allowsAI: (URL) -> Bool
    private let callAgent: HookScriptRunner.AgentCall?
    private var hasEnded = false
    private var pendingRuns: [UUID: Task<AgentRunResult, Never>] = [:]

    init(invocation: HookInvocation, host: any PluginBrowserHost, allowsAI: @escaping (URL) -> Bool, runAgent: HookScriptRunner.AgentCall? = nil) {
        self.invocation = invocation
        self.host = host
        self.allowsAI = allowsAI
        callAgent = runAgent
        var handles: [UUID: String] = [:]
        if let tab = invocation.eventTab, invocation.tabs.contains(tab) { handles[tab] = "t1" }
        var next = 2
        for tab in host.tabs(in: invocation.personaID) where invocation.tabs.contains(tab.id) && handles[tab.id] == nil {
            handles[tab.id] = "t\(next)"
            next += 1
        }
        self.handles = handles
    }

    /// The tools the run's connections list.
    var names: [String] {
        invocation.hook.grant.permissions.contains(.tabsRename) ? ["list_tabs", "rename_tab"] : ["list_tabs"]
    }

    func end() {
        hasEnded = true
        for task in pendingRuns.values { task.cancel() }
        pendingRuns.removeAll()
    }

    /// Whether the script may start agent runs: a hook with `agent` and its agent grant, which a program's hook, never a shell hook, could lack.
    var permitsAgentRuns: Bool {
        callAgent != nil && invocation.hook.usesAgent && invocation.hook.grant.agent != nil
    }

    /// `arch-cli agent run` inside the run (`docs/hooks.md`, arch-cli agent run and rename): the hook's grant and feature, the run's tabs by their handles with `t1` the event's tab and the event's tab when none is named, the model the hook saved when the options name none, the grant's tools and tab access when they name none, Keep Activity Only, and only reports in a test. The run's end cancels it.
    func runAgent(_ given: [String: AgentJSON]) async -> AgentRunResult {
        func refused(_ code: String, _ message: String) -> AgentRunResult { AgentRunResult(status: .refused, code: code, message: message) }
        guard !hasEnded else { return refused("runEnded", "This hook's run has ended.") }
        guard permitsAgentRuns, let callAgent, let grant = invocation.hook.grant.agent else { return refused("notGranted", "This hook may not start agent runs.") }
        var fields = given
        var tabs: [UUID] = invocation.eventTab.flatMap { handles[$0] == nil ? nil : [$0] } ?? []
        if let value = fields.removeValue(forKey: "tabs") {
            guard case .array(let items) = value else { return refused("invalidArguments", "tabs takes a list of the run's tab handles, such as [\"t1\"].") }
            tabs = []
            for item in items {
                guard let handle = item.stringValue, let id = handles.first(where: { $0.value == handle })?.key else {
                    return refused("notGranted", "\(item.stringValue ?? "") is not one of this hook's run tabs.")
                }
                if !tabs.contains(id) { tabs.append(id) }
            }
        }
        guard !tabs.isEmpty else { return refused("notGranted", "This run has no tab for an agent run.") }
        fields["tools"] = fields["tools"] ?? .array(grant.tools.sorted().map(AgentJSON.string))
        fields["tabAccess"] = fields["tabAccess"] ?? .string(grant.tabAccess.rawValue)
        fields["record"] = fields["record"] ?? .string(max(grant.minimumRecord, min(invocation.hook.record, grant.maximumRecord)).rawValue)
        if fields["model"] == nil, let model = invocation.hook.agent?.model, let encoded = try? AgentJSON(encoding: model) { fields["model"] = encoded }
        guard var options = try? AgentJSON.object(fields).decode(as: AgentRunOptions.self) else {
            return refused("invalidArguments", "agent run takes a prompt and, unless the hook saved one, a model.")
        }
        options.closedTab = nil
        options.dryRun = options.dryRun || !invocation.appliesActions
        let request = AgentRunRequest(options: options, tabs: tabs, allowedTabs: invocation.tabs, documents: invocation.documents, documentIDs: invocation.documentIDs,
                                      knownProviders: invocation.knownProviders,
                                      origin: invocation.isTest ? .test(hook: invocation.hook.id, run: invocation.run) : .hook(invocation.hook.id, run: invocation.run),
                                      promptSource: .user, feature: .agentHook(invocation.hook.id), grant: grant)
        let id = UUID()
        let task = Task { await callAgent(request, invocation) }
        pendingRuns[id] = task
        defer { pendingRuns[id] = nil }
        var result = await task.value
        if hasEnded || task.isCancelled { return AgentRunResult(status: .cancelled, message: "This hook's run has ended.") }
        if !grant.returnsReply { result.reply = nil }
        actions.append(contentsOf: result.actions)
        agentUse = HookAgentUse(model: result.model ?? agentUse?.model, usage: (agentUse?.usage ?? AIUsage(inputTokens: 0, outputTokens: 0)) + result.usage)
        return result
    }

    func call(_ call: AgentToolCall) -> AgentToolResult {
        guard !hasEnded else { return AgentToolResult(status: .refused, code: "runEnded", text: "This hook's run has ended.") }
        switch call.name {
        case "list_tabs": return listTabs()
        case "rename_tab" where names.contains("rename_tab"): return rename(call.arguments)
        default: return AgentToolResult(status: .refused, code: "notGranted", text: "This hook's run cannot call \(call.name).")
        }
    }

    /// The run tabs that still show the document they had when the run started, by handle.
    private func listTabs() -> AgentToolResult {
        let shown = host.tabs(in: invocation.personaID).filter { handles[$0.id] != nil && invocation.documentIDs[$0.id] == $0.documentID }
            .sorted { (Int(handles[$0.id]!.dropFirst()) ?? 0) < (Int(handles[$1.id]!.dropFirst()) ?? 0) }
        var rows: [AgentJSON] = []
        var lines: [String] = []
        for tab in shown {
            let handle = handles[tab.id]!
            var row: [String: AgentJSON] = ["handle": .string(handle), "kind": .string(tab.kind.rawValue), "engine": .string(tab.engine.rawValue),
                                            "pinned": .bool(tab.isPinned), "selected": .bool(tab.isSelected)]
            var line = handle
            if let (title, url) = titleAndAddress(of: tab) {
                row["title"] = .string(title)
                row["url"] = .string(url.absoluteString)
                line += "  \(title)  \(url.absoluteString)"
            }
            rows.append(.object(row))
            lines.append(line)
        }
        let summary = shown.count == 1 ? "1 tab in this hook's run." : "\(shown.count) tabs in this hook's run."
        return AgentToolResult(status: .ok, text: ([summary] + lines).joined(separator: "\n"), structured: ["tabs": .array(rows)])
    }

    /// The tab's title and the run's document for it under `tabs`; for a hook with `agent` nothing for a tab whose shown address or document is on a site excluded from AI.
    private func titleAndAddress(of tab: PluginTab) -> (String, URL)? {
        guard invocation.hook.grant.permissions.contains(.tabs), let document = invocation.documents[tab.id] else { return nil }
        if invocation.hook.usesAgent, [tab.url, document].contains(where: { $0.map { !allowsAI($0) } ?? false }) { return nil }
        return (tab.title ?? "", document)
    }

    /// Checks a run tab's document before applying or proposing its suggested name.
    private func rename(_ arguments: [String: AgentJSON]) -> AgentToolResult {
        guard let handle = arguments["tab"]?.stringValue, let name = arguments["name"]?.stringValue else {
            return AgentToolResult(status: .refused, code: "invalidArguments", text: "rename_tab needs a tab's handle and a name.")
        }
        guard let id = handles.first(where: { $0.value == handle })?.key else {
            return AgentToolResult(status: .refused, code: "notGranted", text: "\(handle) is not one of this hook's run tabs.")
        }
        guard let document = invocation.documents[id], let live = host.tabs(in: invocation.personaID).first(where: { $0.id == id }),
              invocation.documentIDs[id] == live.documentID, live.url?.hookDocument == document.hookDocument else {
            return AgentToolResult(status: .stale, code: "stale", text: "\(handle) shows another page than when the run started.", structured: ["tab": .string(handle)])
        }
        let suggested = PluginTab.name(from: name)
        guard host.renameTab(id, to: suggested, showing: document, cause: invocation.cause, applying: invocation.appliesActions) else {
            return AgentToolResult(status: .refused, code: "userNamed", text: "\(handle) keeps its name, which you gave it or chose over a suggested one.", structured: ["tab": .string(handle)])
        }
        if let suggested { actions.append(.renamedTab(tab: id, name: suggested)) }
        let verb = invocation.appliesActions ? "Renamed" : "Would rename"
        return AgentToolResult(status: .ok, text: suggested.map { "\(verb) \(handle) to \u{201C}\($0)\u{201D}." } ?? "Cleared the suggested name of \(handle).",
                               structured: ["tab": .string(handle), "name": suggested.map(AgentJSON.string) ?? .null, "applied": .bool(invocation.appliesActions)])
    }
}
