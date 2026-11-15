// The shell hook runner (`docs/hooks.md`, Shell scripts): runs Arch's copy of a script the user trusted, which the registry checked against its digest, only while its interpreter is still the one recorded at trust time, by path and SHA-256. It starts that interpreter directly with `posix_spawn` in a process group of its own, never through `env`, with the checked bytes on descriptor 3 and `/dev/fd/3` as the script's path, the event as JSON on standard input, only the listed environment, and a working folder of its own. Standard output is read and dropped, and the end of standard error stays in memory. At the hook's timeout the process group gets SIGTERM, then SIGKILL. While the script runs, `arch-cli` binds to the run with `ARCH_HOOK_TICKET` from the script's process tree and reaches the run's tabs under the hook's grant.
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
    public static let inputSentence = "The script gets the event as JSON on standard input, and only PATH, HOME, LANG, TMPDIR, ARCH_HOOK_ID, ARCH_HOOK_EVENT, and ARCH_HOOK_TICKET in its environment. Arch runs its own copy of the file, so later changes to the file take effect only after Update from File\u{2026}."
    /// What Let Agent Runs Read Pages says on the trust sheet.
    public static let readsPagesSentence = "The script and every command it runs can then read the event's page through agent runs."
    static let firstLineSentence = "Its first line must be #! and the absolute path of a program, with at most one option, or /usr/bin/env and one program's name."
    static let changedSentence = "Its interpreter changed."

    /// What the first line names.
    public enum InterpreterLine: Equatable, Sendable {
        /// An absolute path, and at most one word that the interpreter gets before the script's path, as in `#!/bin/sh -e`.
        case path(String, argument: String?)
        /// `/usr/bin/env` and one program's name, which PATH resolves.
        case env(String)

        /// What the interpreter gets before `/dev/fd/3`.
        var arguments: [String] {
            if case .path(_, let argument?) = self { return [argument] }
            return []
        }
    }

    /// Why Arch would not trust or run the bytes, or nil: at most 1 MB of UTF-8 text whose first line names its interpreter.
    public static func problem(in script: Data) -> String? {
        guard script.count <= maximumSize else { return "The script is larger than 1 MB." }
        guard String(data: script, encoding: .utf8) != nil else { return "The script is not UTF-8 text." }
        return interpreterLine(of: script) == nil ? firstLineSentence : nil
    }

    /// The first line's interpreter: `#!` with an absolute path and at most one word after it, or `/usr/bin/env` and one program's name without options or a path. One word keeps the line's meaning the same however a system splits it.
    public static func interpreterLine(of script: Data) -> InterpreterLine? {
        guard script.starts(with: Array("#!".utf8)) else { return nil }
        let end = script.firstIndex(of: UInt8(ascii: "\n")) ?? script.endIndex
        guard let line = String(data: script[script.startIndex.advanced(by: 2) ..< end], encoding: .utf8) else { return nil }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
        guard let program = words.first, program.hasPrefix("/"), words.count <= 2 else { return nil }
        if program == "/usr/bin/env" {
            guard words.count == 2, !words[1].hasPrefix("-"), !words[1].contains("/"), !words[1].contains("=") else { return nil }
            return .env(words[1])
        }
        return .path(program, argument: words.count == 2 ? words[1] : nil)
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

    /// The PATH the script gets: the bundle's `Contents/Helpers`, where `arch-cli` is, then the login shell's PATH, or this app's when the shell could not tell.
    public static func searchPath(helpers: URL?, loginPath: String?) -> String {
        let login = loginPath ?? LoginShell.baseEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return ([helpers?.path].compactMap { $0 } + [login]).joined(separator: ":")
    }

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

    /// Before a run: why the script's first line no longer resolves to the recorded interpreter, by path and digest, or nil when it still does.
    static func interpreterProblem(_ recorded: HookInterpreter, script: Data, searchPath: String) -> String? {
        guard let line = interpreterLine(of: script) else { return firstLineSentence }
        switch resolve(line, searchPath: searchPath) {
        case .failure: return changedSentence
        case .success(let resolution): return resolution.interpreter == recorded ? nil : changedSentence
        }
    }

    /// The lines of `new` that `old` does not hold in the same order, by index, and how many lines of `old` are gone, for Update from File….
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

    public static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
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

    private static func isProgram(_ path: String) -> Bool {
        var status = stat()
        return stat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
    }

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
public final class ShellHookRunner: HookScriptRunning {
    /// The end of standard error that a run's last runs keep in memory.
    public static let errorOutputLimit = 4 * 1024

    private let host: any PluginBrowserHost
    private let allowsAI: (URL) -> Bool
    private let channel: (any AgentHookRunChannel)?
    private let helpers: URL?
    private let temporaryFolder: URL
    private let loginPath: @Sendable () async -> String?
    private var running: [UUID: Running] = [:]
    private var errorOutputs: [UUID: String] = [:]

    /// `host` reaches the tabs, `allowsAI` is the AI interface's site check for a hook with `agent`, and `channel` binds `arch-cli`'s tickets; `helpers` is the bundle's `Contents/Helpers`, which leads the script's PATH. Tests give their own folder and PATH.
    public init(host: any PluginBrowserHost, allowsAI: @escaping (URL) -> Bool, channel: (any AgentHookRunChannel)?, helpers: URL?,
                temporaryFolder: URL = FileManager.default.temporaryDirectory, loginPath: @escaping @Sendable () async -> String? = { await AILoginShell.path() }) {
        self.host = host
        self.allowsAI = allowsAI
        self.channel = channel
        self.helpers = helpers
        self.temporaryFolder = temporaryFolder
        self.loginPath = loginPath
    }

    public func run(_ invocation: HookInvocation) async -> HookRunOutcome {
        guard case .shell(_, _, let recorded) = invocation.hook.script else { return .failed(code: "invalidScript", message: "This hook's script is not a shell script.") }
        if let problem = HookShellScript.problem(in: invocation.script) { return .failed(code: "invalidScript", message: problem) }
        let state = Running()
        running[invocation.run] = state
        defer { running[invocation.run] = nil }
        let searchPath = HookShellScript.searchPath(helpers: helpers, loginPath: await loginPath())
        let script = invocation.script
        guard let line = HookShellScript.interpreterLine(of: script) else { return .failed(code: "invalidScript", message: HookShellScript.firstLineSentence) }
        let problem = await Task.detached { HookShellScript.interpreterProblem(recorded, script: script, searchPath: searchPath) }.value
        if state.isCancelled { return .cancelled }
        if ContinuousClock.now >= invocation.deadline { return .timedOut }
        if let problem { return .failed(code: "scriptChanged", message: problem) }

        let folder = temporaryFolder.appendingPathComponent("Arch-Hook-\(invocation.run.uuidString)", isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else { return .failed(code: "notStarted", message: "Arch could not make the run's folder: \(String(cString: strerror(errno))).") }
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = ShellHookRunTools(invocation: invocation, host: host, allowsAI: allowsAI)
        let ticket = channel?.openHookRun(invocation.run, tools: tools.names) { call in tools.call(call) } ?? ""
        defer {
            tools.end()
            channel?.closeHookRun(invocation.run)
        }
        let environment = Self.environment(of: invocation, searchPath: searchPath, folder: folder, ticket: ticket)
        let process: CommandLineProcess
        do {
            process = try CommandLineProcess(executable: URL(fileURLWithPath: recorded.path), arguments: line.arguments + ["/dev/fd/3"], environment: environment, directory: folder,
                                             input: Self.input(of: invocation, handles: tools.handles), script: script)
        } catch {
            return .failed(code: "notStarted", message: "Arch could not start \(recorded.path): \(error.localizedDescription)")
        }
        // Before any message of the script's `arch-cli` can arrive, which the main actor delivers after this.
        channel?.hookRun(invocation.run, didStart: process.id)
        state.process = process
        if state.isCancelled { process.terminate() }
        Task.detached { for await _ in process.output {} }
        let watchdog = Task { [weak state] in
            try await Task.sleep(until: invocation.deadline, clock: .continuous)
            state?.didTimeOut = true
            process.terminate()
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
            return .completed(actions: tools.actions, agent: nil)
        case .exited(let status):
            let line = errorText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            return .failed(code: "exitStatus", message: "Exited with status \(status)" + (line.map { ": \($0)" } ?? "."))
        case .signaled(let signal):
            return .failed(code: "signal", message: "Ended by signal \(signal).")
        }
    }

    /// Ends the run's process group: SIGTERM, then SIGKILL two seconds later.
    public func cancel(run: UUID) {
        running[run]?.cancel()
    }

    public func takeErrorOutput(of run: UUID) -> String? {
        errorOutputs.removeValue(forKey: run)
    }

    /// Ends every running script, as at quit.
    public func endAll() {
        for state in running.values { state.cancel() }
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

    /// The event as one line of JSON in the hook's script view, dates in ISO 8601, with `tab.handle` for the event's tab when the run reaches it and `hook: {id, name, agent}` as a JavaScript hook's listener gets it.
    static func input(of invocation: HookInvocation, handles: [UUID: String]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(invocation.event), case .object(var members)? = try? AgentJSON.decode(encoded) else { return Data() }
        if let id = invocation.event.tab?.id, let handle = handles[id], case .object(var tab)? = members["tab"] {
            tab["handle"] = .string(handle)
            members["tab"] = .object(tab)
        }
        let hook = invocation.hook
        members["hook"] = .object(["id": .string(hook.id.uuidString), "name": .string(hook.name), "agent": hook.agent.flatMap { try? AgentJSON(encoding: $0) } ?? .null])
        return ((try? AgentJSON.object(members).encoded()) ?? Data()) + Data("\n".utf8)
    }

    /// One running script, from its check to its end.
    @MainActor
    private final class Running {
        var process: CommandLineProcess?
        var isCancelled = false
        var didTimeOut = false

        func cancel() {
            isCancelled = true
            process?.terminate()
        }
    }
}

// MARK: - The run's tools

/// What `arch-cli` reaches through a shell hook run's ticket (`docs/hooks.md`, Shell scripts ▸ Acting): the run's tabs under the hook's grant, with the event's tab as `t1` and the other run tabs as `t2`, `t3`, and on in sidebar order. `list_tabs` lists them, with titles and addresses only under `tabs`, and for a hook with `agent` none for a tab on a site excluded from AI; `rename_tab` needs `tabs.rename`, sets the suggested name for the run's document of the tab under the suggested name rules with the run's cause, and in a test reports what it would do. Calls after the run ends are refused.
@MainActor
final class ShellHookRunTools {
    let invocation: HookInvocation
    /// Each run tab's handle.
    let handles: [UUID: String]
    private(set) var actions: [AgentRunAction] = []
    private let host: any PluginBrowserHost
    private let allowsAI: (URL) -> Bool
    private var hasEnded = false

    init(invocation: HookInvocation, host: any PluginBrowserHost, allowsAI: @escaping (URL) -> Bool) {
        self.invocation = invocation
        self.host = host
        self.allowsAI = allowsAI
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
