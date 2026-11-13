// Supports `arch-cli skills list`, `install`, and `remove`, and Install, Update, and Remove in Settings ▸ AI ▸ Agents (docs/agents.md, Harness and skills ▸ Skills for outside agents). Copies the entry skill into Claude Code's or Codex's skill folder, or a folder the user names, and writes topic skills into an in-app session's own folder. Copies rather than links let agents read the skills without access to the app bundle. The installer replaces or removes only Arch's folders: folders, not links, containing only a `SKILL.md` with Arch's version line and text that matches its digest.
import Darwin
import Foundation

public struct AgentSkillInstaller {
    /// A tool's skill folder, named by `--target`. Written only when named.
    public enum Target: String, CaseIterable, Sendable {
        /// Claude Code's user skills, `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills`.
        case claude
        /// Codex's user skills in `$HOME/.agents/skills`, also read by other agents.
        case codex
        /// Codex's skills under its own folder, `${CODEX_HOME:-$HOME/.codex}/skills`.
        case codexHome = "codex-home"

        public var title: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .codexHome: return "Codex, under CODEX_HOME"
            }
        }
    }

    /// Where a skill goes: a target, or a folder of skill folders named by `--path`.
    public enum Place: Equatable, Sendable {
        case target(Target)
        case path(String)

        public var title: String {
            switch self {
            case .target(let target): return target.title
            case .path: return "Folder"
            }
        }
    }

    /// A skill's own folder inside a folder of skill folders.
    public struct Destination: Equatable, Sendable {
        public var place: Place
        /// The folder containing skill folders, such as `~/.claude/skills`.
        public var skillsFolder: URL
        public var folder: URL

        public var file: URL { folder.appendingPathComponent(AgentSkill.fileName) }
    }

    public enum State: Equatable, Sendable {
        case absent
        /// Arch's copy with this app's text.
        case current
        /// Arch's copy with different text, written by an older Arch or a copy at another location.
        case outdated
        /// Arch's copy changed after Arch wrote it, as by the user, which Arch leaves unchanged.
        case modified
        /// Something Arch did not write and leaves unchanged.
        case foreign
    }

    public enum Failure: Error, Equatable {
        /// `HOME`, `CLAUDE_CONFIG_DIR`, or `CODEX_HOME` is set to a path that is not absolute, which the tools do not expand, `~` included.
        case notAbsolute(variable: String, value: String)
        /// The folder lies inside an app bundle, whose signature covers its files.
        case insideAppBundle(String)
        /// The path named by `--path` is not a folder.
        case notAFolder(String)
        /// The skill's folder was left unchanged because it contains something Arch did not write.
        case foreignFolder(String)
        /// The skill's folder was left unchanged because its `SKILL.md` changed after Arch wrote it.
        case modifiedSkill(String)
        case system(String)

        /// A one-sentence message for the user.
        public var message: String {
            switch self {
            case .notAbsolute(let variable, let value): return "\(variable) is set to \(value), which is not an absolute path, so the folder the tool reads is unclear."
            case .insideAppBundle(let path): return "\(path) is inside an app bundle, whose signature covers its files, so arch-cli leaves it alone."
            case .notAFolder(let path): return "\(path) is not a folder."
            case .foreignFolder(let path): return "\(path) holds files that Arch did not write, so arch-cli leaves it alone."
            case .modifiedSkill(let path): return "\(path) holds Arch's skill with changes made after Arch wrote it, so arch-cli leaves it alone."
            case .system(let detail): return detail
            }
        }

        public var exitCode: AgentExitCode {
            switch self {
            case .notAbsolute, .insideAppBundle, .notAFolder: return .usage
            case .foreignFolder, .modifiedSkill: return .refused
            case .system: return .toolError
            }
        }
    }

    /// The maximum `SKILL.md` size read to check whether Arch wrote it; Arch's files are a few kilobytes.
    static let largestSkillFile = 1024 * 1024

    /// The home folder from the account database, used when the environment has no `HOME`.
    public var accountHomeFolder: URL
    /// The environment supplying `HOME`, `CLAUDE_CONFIG_DIR`, and `CODEX_HOME`: the login shell's for the app, the process's for `arch-cli`.
    public var environment: [String: String]

    public init(accountHomeFolder: URL, environment: [String: String]) {
        self.accountHomeFolder = accountHomeFolder
        self.environment = environment
    }

    // MARK: - Folders

    /// The destination folder for a skill. A target's folder of skill folders may not exist yet; `--path` must name an existing folder. Neither may lie inside an app bundle.
    public func destination(for place: Place, skillName: String) throws -> Destination {
        let skillsFolder: URL
        switch place {
        case .target(.claude):
            skillsFolder = try folder(variable: "CLAUDE_CONFIG_DIR", default: ".claude").appendingPathComponent("skills", isDirectory: true)
        case .target(.codex):
            skillsFolder = try homeFolder().appendingPathComponent(".agents/skills", isDirectory: true)
        case .target(.codexHome):
            skillsFolder = try folder(variable: "CODEX_HOME", default: ".codex").appendingPathComponent("skills", isDirectory: true)
        case .path(let path):
            // `standardized` removes only dot segments; `standardizedFileURL` would also drop an existing folder's `/private` prefix, changing the printed path once the folder exists.
            skillsFolder = URL(fileURLWithPath: path, isDirectory: true).standardized
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: skillsFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw Failure.notAFolder(skillsFolder.path) }
        }
        let resolved = Self.resolved(skillsFolder)
        guard !resolved.pathComponents.contains(where: { ($0 as NSString).pathExtension == "app" }) else { throw Failure.insideAppBundle(skillsFolder.path) }
        return Destination(place: place, skillsFolder: skillsFolder, folder: skillsFolder.appendingPathComponent(skillName, isDirectory: true))
    }

    /// The home folder that Claude Code and Codex read their skill folders under: `HOME`, as both tools take it, or the account database's when `HOME` is unset or empty.
    private func homeFolder() throws -> URL {
        try absoluteFolder(variable: "HOME") ?? accountHomeFolder
    }

    /// The folder named by a variable, or the home folder's `default`.
    private func folder(variable: String, default name: String) throws -> URL {
        try absoluteFolder(variable: variable) ?? homeFolder().appendingPathComponent(name, isDirectory: true)
    }

    /// The absolute path a variable holds as the tools use it, without expanding `~`, or nil when it is unset or empty.
    private func absoluteFolder(variable: String) throws -> URL? {
        guard let value = environment[variable], !value.isEmpty else { return nil }
        guard value.hasPrefix("/") else { throw Failure.notAbsolute(variable: variable, value: value) }
        return URL(fileURLWithPath: value, isDirectory: true).standardized
    }

    /// Resolves links in the deepest existing folder with `realpath` and keeps the rest of the path as written, so a link into an app bundle counts as inside it.
    private static func resolved(_ url: URL) -> URL {
        var existing = url
        var rest: [String] = []
        while existing.path != "/" {
            if let path = realpath(existing.path, nil) {
                defer { free(path) }
                return rest.reversed().reduce(URL(fileURLWithPath: String(cString: path), isDirectory: true)) { $0.appendingPathComponent($1) }
            }
            rest.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return url
    }

    // MARK: - State

    /// The state of a skill's folder compared with the skill Arch would write there.
    public func state(of destination: Destination, skill: AgentSkill) -> State {
        switch Self.contents(of: destination) {
        case .absent: return .absent
        case .foreign: return .foreign
        case .modified: return .modified
        case .archs(let text): return text == skill.markdown ? .current : .outdated
        }
    }

    private enum Contents {
        case absent
        case foreign
        /// Arch's folder with a `SKILL.md` changed after Arch wrote it.
        case modified
        /// Arch's folder and its `SKILL.md` text.
        case archs(String)
    }

    /// Whether a skill's folder is absent, Arch's, or someone else's. Finder's `.DS_Store` may sit beside `SKILL.md`. An empty folder counts as absent because writing into it loses nothing.
    private static func contents(of destination: Destination) -> Contents {
        switch kind(at: destination.folder) {
        case .none: return .absent
        case .folder: break
        case .link, .file, .other: return .foreign
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: destination.folder.path) else { return .foreign }
        if entries.allSatisfy({ $0 == ".DS_Store" }) { return .absent }
        guard entries.contains(AgentSkill.fileName),
              entries.allSatisfy({ $0 == AgentSkill.fileName || $0 == ".DS_Store" }),
              kind(at: destination.file) == .file,
              let size = (try? FileManager.default.attributesOfItem(atPath: destination.file.path))?[.size] as? Int, size <= largestSkillFile,
              let data = try? Data(contentsOf: destination.file),
              let text = String(data: data, encoding: .utf8)
        else { return .foreign }
        switch AgentSkill.origin(of: text) {
        case .other: return .foreign
        case .modified: return .modified
        case .archs: return .archs(text)
        }
    }

    // MARK: - Writing and removing

    /// Throws for the first destination that Arch leaves unchanged: a folder Arch did not write, or Arch's copy changed after Arch wrote it.
    public func checkReplaceable(_ destinations: [Destination]) throws {
        for destination in destinations {
            switch Self.contents(of: destination) {
            case .absent, .archs: break
            case .foreign: throw Failure.foreignFolder(destination.folder.path)
            case .modified: throw Failure.modifiedSkill(destination.folder.path)
            }
        }
    }

    /// Writes the skill to each destination, replacing Arch's earlier copies. Checks all destinations before writing; if any folder is not Arch's or was changed, writes nothing.
    public func install(_ skill: AgentSkill, at destinations: [Destination]) throws {
        try checkReplaceable(destinations)
        for destination in destinations {
            try Self.write(skill, to: destination.folder)
        }
    }

    /// Removes the skill's folder if Arch wrote it unchanged and returns whether one was removed. Leaves other folders unchanged and throws.
    @discardableResult
    public func remove(at destination: Destination) throws -> Bool {
        switch Self.contents(of: destination) {
        case .absent: return false
        case .foreign: throw Failure.foreignFolder(destination.folder.path)
        case .modified: throw Failure.modifiedSkill(destination.folder.path)
        case .archs: break
        }
        do {
            try FileManager.default.removeItem(at: destination.folder)
        } catch {
            throw Failure.system("\(destination.folder.path) could not be removed: \(error.localizedDescription)")
        }
        return true
    }

    /// Creates a folder of skill folders and writes an in-app session's topic skills into it (agent decision 16). Arch makes one for each session.
    public static func write(_ skills: [AgentSkill], into skillsFolder: URL) throws {
        for skill in skills {
            try write(skill, to: skillsFolder.appendingPathComponent(skill.name, isDirectory: true))
        }
    }

    private static func write(_ skill: AgentSkill, to folder: URL) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(skill.markdown.utf8).write(to: folder.appendingPathComponent(AgentSkill.fileName), options: .atomic)
        } catch {
            throw Failure.system("\(folder.path) could not be written: \(error.localizedDescription)")
        }
    }

    private enum Kind {
        case none, link, file, folder, other
    }

    /// What a path contains, without following a link at that path.
    private static func kind(at url: URL) -> Kind {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return .none }
        switch status.st_mode & S_IFMT {
        case S_IFLNK: return .link
        case S_IFDIR: return .folder
        case S_IFREG: return .file
        default: return .other
        }
    }
}
