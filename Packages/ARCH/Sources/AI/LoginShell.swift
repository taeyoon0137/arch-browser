// The user's login shell and the PATH it sets up. GUI apps get a short PATH, while command-line tools usually live in folders that a shell profile adds, such as a package manager's. The built-in terminal runs the same login shell, so a tool installed there is found here.
import Darwin
import Foundation

actor LoginShell {
    static let shared = LoginShell(executable: userShell)

    /// `$SHELL`, else the account's shell, else zsh.
    static var userShell: URL {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return URL(fileURLWithPath: shell) }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return URL(fileURLWithPath: String(cString: shell)) }
        return URL(fileURLWithPath: "/bin/zsh")
    }

    /// The minimal environment command-line tools run in: HOME, USER, LOGNAME, SHELL, PATH, LANG, TMPDIR, and TERM=dumb. PATH is this app's own until the login shell's replaces it.
    static var baseEnvironment: [String: String] {
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

    let executable: URL
    private var lookup: Task<String?, Never>?

    init(executable: URL) {
        self.executable = executable
    }

    /// The login shell's PATH, read once per launch. Callers during a read share it; a read that fails is tried again by the next call.
    func path() async -> String? {
        let task = lookup ?? Task { [executable] in await Self.readPath(shell: executable) }
        lookup = task
        let path = await task.value
        if path == nil, lookup == task { lookup = nil }
        return path
    }

    /// Runs `shell -l -i -c` with a command that prints a marker followed by `$PATH`, and takes the line after the marker, since a profile may print text of its own first. Reading stops as soon as that line is complete, because a process the profile starts in the background can keep the output open; the shell and that process then end. Gives up after 10 seconds.
    static func readPath(shell: URL) async -> String? {
        let process: CommandLineProcess
        do {
            process = try CommandLineProcess(executable: shell, arguments: ["-l", "-i", "-c", "printf '%s\\n%s\\n' \(marker) \"$PATH\""],
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
            if let path = path(inOutput: String(decoding: output, as: UTF8.self)) { return path }
        }
        return nil
    }

    /// The line after the last line that ends with the marker, once a newline has ended it.
    static func path(inOutput output: String) -> String? {
        let lines = output.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.hasSuffix(marker) }), index + 2 < lines.count else { return nil }
        let path = lines[index + 1].trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }
}

/// The login shell's PATH for modules outside `AI`, such as Settings ▸ AI ▸ Agents, which links `arch-cli` and `arch-mcp` into one of its folders.
public enum AILoginShell {
    /// The PATH that `LoginShell` reads once per launch; nil when the shell could not tell, and the next call tries again.
    public static func path() async -> String? {
        await LoginShell.shared.path()
    }
}

extension AICommandLineConfiguration {
    /// The absolute path of a tool: `name` itself when it is a path, with `~` expanded, or else the first match in the login shell's PATH. nil when no executable file is there.
    public static func locateExecutable(named name: String) async -> URL? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            return isExecutable(at: url) ? url : nil
        }
        let searchPath = await LoginShell.shared.path() ?? LoginShell.baseEnvironment["PATH"] ?? ""
        return locate(name, searchPath: searchPath)
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
