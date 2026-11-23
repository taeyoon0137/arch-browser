// The Claude Code and Codex presets: what each tool is called, how Arch reads its version and sign-in from the tool's own status command, and the probes Arch runs before it trusts a version (`docs/agents.md`, Connecting a subscription). Status commands and probes run no model, so they use none of the subscription. Arch never reads a tool's credentials.
import Darwin
import Foundation

extension AIAgentKind {
    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The name Arch looks up in the login shell's PATH.
    public var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// The arguments of the tool's own sign-in, which Sign In types in the built-in terminal without running it.
    public var signInArguments: [String] {
        switch self {
        case .claudeCode: return ["auth", "login"]
        case .codex: return ["login"]
        }
    }

    /// A provider for the preset: the tool at `executable` with its own default model and two concurrent requests. Arch builds every argument, so the configuration has none.
    public func preset(executable: URL) -> AIProviderConfiguration {
        AIProviderConfiguration(name: title, kind: .commandLine(AICommandLineConfiguration(executable: executable, agent: self)),
                                models: [AIModelConfiguration(name: "")], limits: .agentPreset)
    }

    /// The tool in the login shell's PATH, or in `searchPath` when given.
    public func locateExecutable(searchPath: String? = nil) async -> URL? {
        guard let searchPath else { return await AICommandLineConfiguration.locateExecutable(named: executableName) }
        return AICommandLineConfiguration.locate(executableName, searchPath: searchPath)
    }
}

// MARK: - Status

/// What the tool's own commands say about it: `--version`, and the sign-in from `claude auth status --json` (only `loggedIn` is read) or the exit status of `codex login status`.
public struct AIAgentToolStatus: Sendable, Equatable {
    /// The version number the tool printed, such as `2.1.323`; nil when it printed none.
    public var version: String?
    /// nil when the status command could not tell.
    public var isSignedIn: Bool?

    public init(version: String?, isSignedIn: Bool?) {
        self.version = version
        self.isSignedIn = isSignedIn
    }

    /// Runs the version and status commands of the tool at `executable`. `environment` holds the provider's variables, such as a moved `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. Throws an error that says why when the tool cannot start.
    public static func read(kind: AIAgentKind, executable: URL, environment: [String: String] = [:]) async throws -> AIAgentToolStatus {
        let tool = AICommandLineConfiguration(executable: executable, environment: environment, agent: kind)
        let base = await tool.runEnvironment()
        let version = try await AIAgentCommand.run(executable, kind.versionArguments, environment: base)
        let status = try await AIAgentCommand.run(executable, kind.statusArguments, environment: base)
        return AIAgentToolStatus(version: Self.versionNumber(in: version.output), isSignedIn: kind.isSignedIn(status))
    }

    /// The first version number in the tool's `--version` line, such as `2.1.323` in "2.1.323 (Claude Code)" or `0.164.0` in "codex-cli 0.164.0".
    static func versionNumber(in output: String) -> String? {
        guard let match = output.firstMatch(of: try! Regex("[0-9]+(\\.[0-9]+)+")) else { return nil }
        return String(output[match.range])
    }
}

extension AIAgentKind {
    var versionArguments: [String] {
        ["--version"]
    }

    var statusArguments: [String] {
        switch self {
        case .claudeCode: return ["auth", "status", "--json"]
        case .codex: return ["--no-daemon", "login", "status"]
        }
    }

    /// Only `loggedIn` of Claude Code's JSON, and only the exit status of Codex's command; anything else they print stays unread.
    func isSignedIn(_ result: AIAgentCommandResult) -> Bool? {
        switch self {
        case .claudeCode:
            guard let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else { return nil }
            return object["loggedIn"] as? Bool
        case .codex:
            guard case .exited(let code) = result.status else { return nil }
            return code == 0
        }
    }
}

// MARK: - Commands

/// Why a tool cannot serve a session or Check, in a sentence: it does not start, or a probe found a missing flag, feature, or key. Requests and sessions report it as `providerUnavailable`.
struct AIAgentToolError: LocalizedError, Sendable {
    var detail: String

    var errorDescription: String? { detail }

    func aiError(provider: AIProviderID) -> AIError {
        .providerUnavailable(provider, detail: detail)
    }
}

/// How a short command that Arch runs itself ended: a status command or a probe.
struct AIAgentCommandResult: Sendable {
    var status: CommandLineTermination
    var output: String
    var errorLine: String?

    var succeeded: Bool { status == .exited(0) }
}

/// Runs a preset's tool once for its version, status, help, or probe output, which the Claude Code and Codex presets read before Arch trusts the tool.
enum AIAgentCommand {
    /// Runs the tool with no input in a new empty folder under TMPDIR, as requests do, and ends it after `timeout`. Throws `AIAgentToolError` when it cannot start or does not finish in time.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration = .seconds(30)) async throws -> AIAgentCommandResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Arch-\(UUID().uuidString)", isDirectory: true)
        let name = executable.lastPathComponent
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AIAgentToolError(detail: localized("\(name) could not start: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let process: CommandLineProcess
        do {
            process = try CommandLineProcess(executable: executable, arguments: arguments, environment: environment, directory: directory, input: Data())
        } catch let error as POSIXError {
            throw AIAgentToolError(detail: localized("\(name) could not start: \(String(cString: strerror(error.code.rawValue)))."))
        }
        let deadline = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return false }
            process.terminate()
            return true
        }
        var output = Data()
        for await chunk in process.output { output.append(chunk) }
        let status = await process.termination()
        deadline.cancel()
        if await deadline.value {
            throw AIAgentToolError(detail: localized("\(name) \(arguments.joined(separator: " ")) did not finish."))
        }
        return AIAgentCommandResult(status: status, output: String(decoding: output, as: UTF8.self), errorLine: await process.lastErrorLine())
    }
}

// MARK: - Probes

/// A tool's executable as it is now: its resolved path, size, and modification time. A tool that updated itself by switching a link, as both tools' installers do, gets a new identity, and its probes run again.
struct AIAgentToolIdentity: Hashable, Sendable {
    var path: String
    var size: Int64
    var modified: TimeInterval

    init?(executable: URL) {
        guard let resolved = realpath(executable.path, nil) else { return nil }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0 else { return nil }
        path = String(cString: resolved)
        size = Int64(info.st_size)
        modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }
}

/// What the probes found for one version of a tool.
struct AIAgentProbeResult: Sendable, Equatable {
    var version: String?
    /// The installed CLI accepts the run-only option Arch checked (Claude Code's turn limit or Codex's ephemeral thread).
    var supportsRunOption: Bool
    /// Codex: the features Arch turns off (`CodexAgent.disabledFeatures(fromList:)`).
    var disabledFeatures: [String] = []
    /// Codex: each bundled model's effort levels, by slug.
    var effortLevels: [String: [String]] = [:]
}

/// The probe results of each tool version, kept until quit. A probe that fails is not kept, so the next session or Check runs it again.
@MainActor
final class AIAgentProbeStore {
    static let shared = AIAgentProbeStore()

    private var results: [AIAgentToolIdentity: AIAgentProbeResult] = [:]
    private var running: [AIAgentToolIdentity: Task<AIAgentProbeResult, any Error>] = [:]

    /// The probe result for the executable as it is now, probing it first when it is new or changed. `environment` is the tool's run environment. Throws `AIAgentToolError` naming what the tool lacks.
    func result(kind: AIAgentKind, executable: URL, environment: [String: String]) async throws -> AIAgentProbeResult {
        guard let identity = AIAgentToolIdentity(executable: executable) else {
            throw AIAgentToolError(detail: localized("\(executable.lastPathComponent) could not start: no executable at \(executable.path)."))
        }
        if let result = results[identity] { return result }
        let task = running[identity] ?? Task {
            switch kind {
            case .claudeCode: return try await ClaudeCodeAgent.probe(executable: executable, environment: environment)
            case .codex: return try await CodexAgent.probe(executable: executable, environment: environment)
            }
        }
        running[identity] = task
        defer { running[identity] = nil }
        let result = try await task.value
        results[identity] = result
        return result
    }

    /// Forgets every result, so the next use probes again.
    func removeAll() {
        results.removeAll()
    }
}

// MARK: - Environment and output lines

extension AICommandLineConfiguration {
    /// The minimal environment and the configured variables, which take precedence. PATH is the login shell's, or this app's when the shell cannot tell, after the executable's own folder, so a script finds an interpreter installed beside it; a configured PATH replaces it. A preset also takes the tool's folder variable (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`) from the login shell, as the built-in terminal's sign-in does, and its environment never carries an API key or token, so the tool uses its own sign-in. Tests give `loginShell`.
    func runEnvironment(loginShell: @Sendable () async -> [String: String]? = { await LoginShell.shared.environment() }) async -> [String: String] {
        var environment = LoginShell.baseEnvironment
        let shell = self.environment["PATH"] == nil || agent != nil ? await loginShell() : nil
        if self.environment["PATH"] == nil {
            let searchPath = shell?["PATH"] ?? environment["PATH"] ?? ""
            var folders = [executable.deletingLastPathComponent().path]
            for folder in searchPath.split(separator: ":").map(String.init) where !folders.contains(folder) { folders.append(folder) }
            environment["PATH"] = folders.joined(separator: ":")
        }
        if let agent {
            let folder = agent == .claudeCode ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
            environment[folder] = shell?[folder]
        }
        environment.merge(self.environment) { _, configured in configured }
        if agent != nil {
            for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"] { environment[key] = nil }
        }
        return environment
    }
}

/// Splits standard output into lines before decoding them as UTF-8, so a character split between reads stays whole.
struct AIAgentLineBuffer {
    private var partial = Data()

    mutating func lines(in chunk: Data) -> [Data] {
        partial.append(chunk)
        var lines: [Data] = []
        var start = partial.startIndex
        while let newline = partial[start...].firstIndex(of: 0x0A) {
            lines.append(Data(partial[start..<newline]))
            start = partial.index(after: newline)
        }
        partial = Data(partial[start...])
        return lines
    }

    /// The last line, when it had no newline.
    mutating func finish() -> Data? {
        defer { partial = Data() }
        return partial.isEmpty ? nil : partial
    }
}

/// A JSON line as an object, or nil for a line that is not one.
func agentJSONObject(_ line: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: line) as? [String: Any]
}
