// `arch-cli links install` and `links remove`, and Install Command-Line Tools… in Settings ▸ AI ▸ Agents (docs/agents.md, arch-cli): symbolic links to the bundle's `arch-cli` and `arch-mcp` in a writable folder on PATH, `~/.local/bin` first when PATH has it. A link follows the bundle, so a rebuilt app brings its own tools. The installer writes only inside the user's home folder, replaces only links into an Arch bundle, and removes only those.
import Darwin
import Foundation

public struct AgentLinkInstaller {
    /// A link and the bundled executable it points to.
    public struct Link: Equatable, Sendable {
        public var location: URL
        public var destination: URL

        public init(location: URL, destination: URL) {
            self.location = location
            self.destination = destination
        }
    }

    public enum Failure: Error, Equatable {
        /// A folder the caller named lies outside the home folder.
        case outsideHome(String)
        case notAFolder(String)
        case notWritable(String)
        /// No folder of PATH inside the home folder exists and is writable.
        case noFolder
        /// A file that is not a link into an Arch bundle is in the way; it was left alone.
        case foreignFile(String)
        case system(String)

        /// One sentence for the user.
        public var message: String {
            switch self {
            case .outsideHome(let path): return "\(path) is outside your home folder, and arch-cli writes links only inside it."
            case .notAFolder(let path): return "\(path) is not a folder."
            case .notWritable(let path): return "\(path) is not writable."
            case .noFolder: return "No folder on your PATH inside your home folder is writable. Make one and add it to PATH, for example with mkdir -p ~/.local/bin and the line export PATH=\"$HOME/.local/bin:$PATH\" in ~/.zprofile, or name a folder with --dir."
            case .foreignFile(let path): return "\(path) is not a link into an Arch bundle, so it was left alone."
            case .system(let detail): return detail
            }
        }

        public var exitCode: AgentExitCode {
            switch self {
            case .outsideHome, .notAFolder: return .usage
            case .notWritable, .noFolder, .system: return .toolError
            case .foreignFile: return .refused
            }
        }
    }

    public static let names = [AgentBundleLayout.cliName, AgentBundleLayout.mcpName]

    public var homeFolder: URL
    /// PATH's folders, in order.
    public var searchFolders: [URL]

    /// `searchPath` is PATH: the login shell's for the app, the environment's for `arch-cli`.
    public init(homeFolder: URL, searchPath: String) {
        self.homeFolder = homeFolder
        var seen = Set<String>()
        searchFolders = searchPath.split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The home folder of the user this process runs as, from the account database rather than `$HOME`, as for the control socket.
    public static var userHomeFolder: URL? {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }

    // MARK: - Folders

    /// The folder `install` links into: the one named, which must be a writable folder inside the home folder, or else the first such folder of PATH, with `~/.local/bin` before the others.
    public func installFolder(named name: String?) throws -> URL {
        if let name {
            let folder = URL(fileURLWithPath: name, isDirectory: true).standardizedFileURL
            try checkInHome(folder)
            guard FileManager.default.isWritableFile(atPath: folder.path) else { throw Failure.notWritable(folder.path) }
            return folder
        }
        let usable = homeSearchFolders.filter { FileManager.default.isWritableFile(atPath: $0.path) }
        if let local = resolved(homeFolder.appendingPathComponent(".local/bin")), let folder = usable.first(where: { resolved($0) == local }) {
            return folder
        }
        guard let folder = usable.first else { throw Failure.noFolder }
        return folder
    }

    /// The folders `remove` looks in: the one named, or every folder of PATH inside the home folder.
    public func removalFolders(named name: String?) throws -> [URL] {
        if let name {
            let folder = URL(fileURLWithPath: name, isDirectory: true).standardizedFileURL
            try checkInHome(folder)
            return [folder]
        }
        return homeSearchFolders
    }

    /// Whether a folder is one of PATH's, so that the links can be run by name.
    public func isOnSearchPath(_ folder: URL) -> Bool {
        guard let target = resolved(folder) else { return false }
        return searchFolders.contains { resolved($0) == target }
    }

    /// PATH's existing folders inside the home folder.
    private var homeSearchFolders: [URL] {
        searchFolders.filter { (try? checkInHome($0)) != nil }
    }

    private func checkInHome(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue, let path = resolved(folder) else {
            throw Failure.notAFolder(folder.path)
        }
        guard let home = resolved(homeFolder), path == home || path.hasPrefix(home + "/") else { throw Failure.outsideHome(folder.path) }
    }

    /// The path with every symbolic link resolved (`realpath`), or nil when nothing is there.
    private func resolved(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }

    // MARK: - Links

    /// The links `install` writes into a folder for a bundle: `arch-cli` and `arch-mcp`, each to the bundle's file of that name.
    public static func links(in folder: URL, for bundle: AgentBundleLayout) -> [Link] {
        names.map { Link(location: folder.appendingPathComponent($0), destination: bundle.helpersURL.appendingPathComponent($0)) }
    }

    /// Whether a link's destination is an executable in an Arch bundle's `Contents/Helpers`. A relative destination is read from the link's folder.
    public static func isArchLink(destination: String, in folder: URL) -> Bool {
        let target = URL(fileURLWithPath: destination, relativeTo: folder).standardizedFileURL
        return names.contains(target.lastPathComponent) && AgentBundleLayout.containing(helper: target) != nil
    }

    /// Writes the links, replacing earlier links into an Arch bundle. Each location is checked before any is written, so a file in the way leaves both alone.
    public func install(_ links: [Link]) throws {
        for link in links where kind(at: link.location) != .none {
            guard let destination = linkDestination(at: link.location), Self.isArchLink(destination: destination, in: link.location.deletingLastPathComponent()) else {
                throw Failure.foreignFile(link.location.path)
            }
        }
        do {
            for link in links {
                if kind(at: link.location) != .none { try FileManager.default.removeItem(at: link.location) }
                try FileManager.default.createSymbolicLink(atPath: link.location.path, withDestinationPath: link.destination.path)
            }
        } catch {
            throw Failure.system("The links could not be written: \(error.localizedDescription)")
        }
    }

    /// Removes `arch-cli` and `arch-mcp` from the folders where they are links into an Arch bundle, and returns what it removed. Anything else of those names stays.
    public func remove(from folders: [URL]) throws -> [URL] {
        var removed: [URL] = []
        for folder in folders {
            for name in Self.names {
                let location = folder.appendingPathComponent(name)
                guard let destination = linkDestination(at: location), Self.isArchLink(destination: destination, in: folder) else { continue }
                do {
                    try FileManager.default.removeItem(at: location)
                } catch {
                    throw Failure.system("\(location.path) could not be removed: \(error.localizedDescription)")
                }
                removed.append(location)
            }
        }
        return removed
    }

    private enum Kind {
        case none, link, other
    }

    /// What is at a path, without following a link there.
    private func kind(at location: URL) -> Kind {
        var status = stat()
        guard lstat(location.path, &status) == 0 else { return .none }
        return status.st_mode & S_IFMT == S_IFLNK ? .link : .other
    }

    private func linkDestination(at location: URL) -> String? {
        guard kind(at: location) == .link else { return nil }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: location.path)
    }
}
