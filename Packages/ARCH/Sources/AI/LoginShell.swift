// The user's login shell and the environment it sets up. GUI apps get a short PATH, while command-line tools usually live in folders that a shell profile adds, such as a package manager's, and a profile may also export where Claude Code and Codex keep their settings. The built-in terminal runs the same login shell with this app's environment, so the read starts the shell with the tools' folder variables this app has, and a tool installed there is found here.
import Darwin
import Foundation

/// Reads the user's exported login-shell environment for tool discovery.
public actor LoginShell {
    /// What the login shell sets. Only `PATH` reaches every command-line tool; the GitHub CLI also gets the two configuration folders (`docs/bookmarks.md`, GitHub).
    public struct Variables: Equatable, Sendable {
        public var path: String
        /// `GH_CONFIG_DIR`, when the shell sets it to an absolute path.
        public var gitHubConfigDirectory: String?
        /// `XDG_CONFIG_HOME`, when the shell sets it to an absolute path.
        public var configHome: String?

        public init(path: String, gitHubConfigDirectory: String? = nil, configHome: String? = nil) {
            self.path = path
            self.gitHubConfigDirectory = gitHubConfigDirectory
            self.configHome = configHome
        }
    }
    public static let shared = LoginShell(executable: userShell)

    /// `$SHELL`, else the account's shell, else zsh.
    public static var userShell: URL {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return URL(fileURLWithPath: shell) }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return URL(fileURLWithPath: String(cString: shell)) }
        return URL(fileURLWithPath: "/bin/zsh")
    }

    /// The minimal environment command-line tools run in: HOME, USER, LOGNAME, SHELL, PATH, LANG, TMPDIR, and TERM=dumb. PATH is this app's own until the login shell's replaces it.
    public static var baseEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "SHELL": userShell.path,
            "PATH": inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
            "TERM": "dumb",
        ]
    }

    /// The login shell’s search path and the folders used by the agent tools and GitHub CLI.
    static let variableNames = ["PATH", "HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "GH_CONFIG_DIR", "XDG_CONFIG_HOME"]
    /// The variables of `variableNames` that name the tools' folders and that the read takes from this app's environment, as `launchctl setenv` gives them to every app and the built-in terminal passes them on to its shell; a profile can still change or unset them. HOME stays the account's, as in `baseEnvironment`.
    static let inheritedVariableNames = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"]
    static let marker = "__ARCH_LOGIN_SHELL__"
    static let endMarker = "__ARCH_LOGIN_SHELL_END__"

    public let executable: URL
    private var lookup: Task<[String: String]?, Never>?

    public init(executable: URL) {
        self.executable = executable
    }

    /// The login shell's PATH, read once per launch with the rest of `environment()`.
    public func path() async -> String? {
        await environment()?["PATH"]
    }

    /// The login shell's exported values of `variableNames` that are set and not empty, read once per launch. Callers during a read share it; a read that fails is tried again by the next call.
    func environment() async -> [String: String]? {
        let task = lookup ?? Task { [executable] in await Self.readEnvironment(shell: executable) }
        lookup = task
        let environment = await task.value
        if environment == nil, lookup == task { lookup = nil }
        return environment
    }

    /// Forgets the variables read, so the next call reads the login shell again, as after the user changed a profile in the built-in terminal (Check Again).
    public func reload() {
        lookup = nil
    }

    /// The absolute path of a tool: `name` itself when it is a path, with `~` expanded, or else the first match in this shell's PATH, or in this app's when the shell cannot tell. nil when no executable file is there.
    public func locateExecutable(named name: String) async -> URL? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            return AICommandLineConfiguration.isExecutable(at: url) ? url : nil
        }
        let searchPath = await path() ?? Self.baseEnvironment["PATH"] ?? ""
        return AICommandLineConfiguration.locate(name, searchPath: searchPath)
    }

    /// The paths used by live folders. Only absolute configuration directories reach the GitHub CLI.
    public func variables() async -> Variables? {
        guard let values = await environment(), let path = values["PATH"] else { return nil }
        func absoluteFolder(_ key: String) -> String? {
            guard let folder = values[key], folder.hasPrefix("/") else { return nil }
            return folder
        }
        return Variables(path: path, gitHubConfigDirectory: absoluteFolder("GH_CONFIG_DIR"), configHome: absoluteFolder("XDG_CONFIG_HOME"))
    }

    /// The environment the read starts the shell with: `baseEnvironment`, and those of `inheritedVariableNames` that `inherited`, this app's environment, holds. Command-line tools still run in `baseEnvironment` with the login shell's PATH.
    static func readingEnvironment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        inheritedVariableNames.reduce(into: baseEnvironment) { environment, name in
            if let value = inherited[name] { environment[name] = value }
        }
    }

    /// Runs `shell -l -i -c` in `start`, `readingEnvironment()` unless a test names another, with a command that prints a marker line, the exported environment with each entry ended by NUL (`env -0`), and an end marker line, since a profile may print text of its own first. `env` reads only exported variables, as the tools see them, and prints them the same way in every shell, a value that holds a line break included. Reading stops as soon as the end marker's line is complete, because a process the profile starts in the background, or a shell that lingers, can keep the output open; the shell and that process then end. Gives up after 10 seconds.
    static func readEnvironment(shell: URL, environment start: [String: String] = LoginShell.readingEnvironment()) async -> [String: String]? {
        let process: CommandLineProcess
        do {
            process = try CommandLineProcess(executable: shell, arguments: ["-l", "-i", "-c", "echo \(marker); /usr/bin/env -0; echo \(endMarker)"],
                                             environment: start, directory: URL(fileURLWithPath: NSHomeDirectory()), input: Data())
        } catch {
            return nil
        }
        let deadline = Task {
            guard (try? await Task.sleep(for: .seconds(10))) != nil else { return }
            process.terminate()
        }
        defer {
            deadline.cancel()
            process.terminate()
        }
        var output = Data()
        for await chunk in process.output {
            output.append(chunk)
            if let environment = environment(inOutput: String(decoding: output, as: UTF8.self)) { return environment }
        }
        return nil
    }

    /// The values of `variableNames` among the NUL-ended entries between the last line that ends with the marker and the end marker's line, once that line is complete. nil before then, and when PATH is missing or empty, since every login shell sets it.
    static func environment(inOutput output: String) -> [String: String]? {
        guard let start = output.range(of: marker + "\n", options: .backwards),
              let end = output.range(of: "\0" + endMarker + "\n", range: start.upperBound..<output.endIndex)
        else { return nil }
        var environment: [String: String] = [:]
        for entry in output[start.upperBound..<end.lowerBound].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<equals])
            let value = String(entry[entry.index(after: equals)...])
            if variableNames.contains(name), !value.isEmpty { environment[name] = value }
        }
        return environment["PATH"] == nil ? nil : environment
    }
}

/// The login shell's PATH and environment for modules outside `AI`, such as Settings ▸ AI ▸ Agents, which links `arch-cli` and `arch-mcp` into one of PATH's folders and writes the entry skill where Claude Code and Codex read it.
public enum AILoginShell {
    /// The PATH that `LoginShell` reads once per launch; nil when the shell could not tell, and the next call tries again.
    public static func path() async -> String? {
        await LoginShell.shared.path()
    }

    /// PATH, HOME, CLAUDE_CONFIG_DIR, and CODEX_HOME as the login shell exports them, each only when set and not empty, from the same read as `path()`; nil when the shell could not tell, and the next call tries again. The app's own environment lacks the variables a shell profile sets.
    public static func environment() async -> [String: String]? {
        await LoginShell.shared.environment()?.filter { ["PATH", "HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME"].contains($0.key) }
    }
}

extension AICommandLineConfiguration {
    /// The absolute path of a tool, found through the user's login shell (`LoginShell.locateExecutable(named:)`).
    public static func locateExecutable(named name: String) async -> URL? {
        await LoginShell.shared.locateExecutable(named: name)
    }

    /// Whether `url` is a file, or a link to one, that this user may run.
    public static func isExecutable(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// The first executable named `name` in the folders of `searchPath`, in order.
    static func locate(_ name: String, searchPath: String) -> URL? {
        searchPath.split(separator: ":").lazy
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name) }
            .first(where: isExecutable(at:))
    }
}
