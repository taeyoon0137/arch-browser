// The user's login shell and the variables it sets up. GUI apps get a short PATH, while command-line tools usually live in folders that a shell profile adds, such as a package manager's. The built-in terminal runs the same login shell, so a tool installed there is found here, and `gh` finds the sign-in that `gh auth login` wrote there.
import Darwin
import Foundation

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

    static let marker = "__ARCH_LOGIN_SHELL_PATH__"

    public let executable: URL
    private var lookup: Task<Variables?, Never>?

    public init(executable: URL) {
        self.executable = executable
    }

    /// The login shell's variables, read once per launch. Callers during a read share it; a read that fails is tried again by the next call.
    public func variables() async -> Variables? {
        let task = lookup ?? Task { [executable] in await Self.readVariables(shell: executable) }
        lookup = task
        let variables = await task.value
        if variables == nil, lookup == task { lookup = nil }
        return variables
    }

    /// The login shell's PATH.
    public func path() async -> String? {
        await variables()?.path
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

    /// Runs `shell -l -i -c` with a command that prints a marker followed by `$PATH`, `$GH_CONFIG_DIR`, and `$XDG_CONFIG_HOME`, one to a line, and takes the lines after the marker, since a profile may print text of its own first. Reading stops as soon as those lines are complete, because a process the profile starts in the background can keep the output open; the shell and that process then end. Gives up after 10 seconds.
    static func readVariables(shell: URL) async -> Variables? {
        let process: CommandLineProcess
        do {
            let command = "printf '%s\\n%s\\n%s\\n%s\\n' \(marker) \"$PATH\" \"$GH_CONFIG_DIR\" \"$XDG_CONFIG_HOME\""
            process = try CommandLineProcess(executable: shell, arguments: ["-l", "-i", "-c", command],
                                             environment: baseEnvironment, directory: URL(fileURLWithPath: NSHomeDirectory()), input: Data())
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
            if let variables = variables(inOutput: String(decoding: output, as: UTF8.self)) { return variables }
        }
        return nil
    }

    /// The three lines after the last line that ends with the marker, once a newline has ended the third. nil without a PATH. A configuration folder that is empty or not an absolute path counts as unset.
    static func variables(inOutput output: String) -> Variables? {
        let lines = output.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.hasSuffix(marker) }), index + 4 < lines.count else { return nil }
        let path = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        func folder(_ line: String) -> String? {
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("/") ? value : nil
        }
        return Variables(path: path, gitHubConfigDirectory: folder(lines[index + 2]), configHome: folder(lines[index + 3]))
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
