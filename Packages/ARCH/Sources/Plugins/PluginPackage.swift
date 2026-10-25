// Plugin packages: a folder with `plugin.json` at its top for a script plugin, or with the manifest file of a runtime's kind, such as a web extension's `manifest.json`, which the user chooses as the folder or as a `.zip` archive, or a script plugin's folder whose files AI writes. The manager copies it, or writes AI's files, into a staging folder, reads it there for the install sheet without running any of it, has the engines that run the kind check it, and moves it into the Persona's plugin folder when the user installs it.
import ARCHEngine
import Foundation

/// A plugin's package, with its manifest read and checked: staged for review, or installed.
public struct PluginPackage: Identifiable, Sendable {
    public var id: URL { rootURL }
    public let kind: PluginKind
    public let manifest: PluginManifest
    /// The folder that holds the manifest.
    public private(set) var rootURL: URL
    /// The folder or archive the user chose, or how AI wrote the package.
    public let origin: PluginOrigin
    /// The package paths of the package's files, such as `scripts/count.js`, in ascending order, as the install sheet lists them.
    public let files: [String]
    /// The package path of a script plugin's background script, if it has one.
    let background: String?
    /// What each engine that runs the kind on this Mac found when it checked the package at staging. Empty for kinds that Arch runs alike on every engine.
    public internal(set) var engineChecks: [EngineKind: PluginEngineCheck] = [:]
    /// The installed plugin that the package matches as a version of the same extension, by the rule in Engine versions ▸ Counterparts: the one with the package's identifier, or else the first installed with its name and developer, while it is not in a pair. Nil without one, and for kinds that Arch runs alike on every engine.
    public internal(set) var counterpart: PluginID?
    /// The engines, in the order of `EngineKind`, that the package can join `counterpart` for: each that runs the package while the counterpart runs on the pair's other engine, by the answers at staging.
    public internal(set) var joinableEngines: [EngineKind] = []
    /// The joinable engine that the review's choice starts on when the package and the counterpart complement each other, each running on an engine that refused the other. Nil starts it on Update or on the separate plugin.
    public internal(set) var suggestedEngine: EngineKind?
    /// The installed plugin that the package updates, by the rule in Engine versions ▸ Counterparts, or nil for a new plugin. The review sets it to the version the user chooses where the rule leaves two.
    public var updates: PluginID?
    /// The two versions with the package's identifier that the review chooses between where the rule leaves both, in the order the user installed them; empty otherwise.
    public internal(set) var updateChoices: [PluginID] = []

    /// Reads the package at `root`: a script plugin's when `plugin.json` is at its top, else, for a folder or archive the user chose, the package of the runtime whose manifest file is there. Throws as `ScriptManifest(packageAt:)` or the runtime does, and `PluginError.invalidPackage` for a package of no kind that Arch runs and for one that is or holds a symbolic link, which could lead to files outside it.
    init(at root: URL, origin: PluginOrigin, runtimes: [any PluginRuntime] = []) throws {
        let files = try Self.files(in: root)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(ScriptManifest.fileName).path) {
            let declared = try ScriptManifest(packageAt: root)
            self.init(kind: .script, manifest: declared.manifest, rootURL: root, origin: origin, files: files, background: declared.background)
        } else if case let .file(source) = origin,
                  let runtime = runtimes.first(where: { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.manifestFileName).path) }) {
            self.init(kind: runtime.kind, manifest: try runtime.manifest(forPackageAt: root, source: source.absoluteURL), rootURL: root, origin: origin, files: files, background: nil)
        } else {
            throw PluginError.invalidPackage("The package has no \(Self.manifestFiles(runtimes).joined(separator: " or ")) at its top level.")
        }
    }

    private init(kind: PluginKind, manifest: PluginManifest, rootURL: URL, origin: PluginOrigin, files: [String], background: String?) {
        self.kind = kind
        self.manifest = manifest
        self.rootURL = rootURL
        self.origin = origin
        self.files = files
        self.background = background
    }

    /// The package once its folder has moved to `root`.
    func moved(to root: URL) -> PluginPackage {
        var moved = self
        moved.rootURL = root
        return moved
    }

    /// The text of the file at a package path, as the review shows it. Nil for a path that names no file of the package, and for a file that is not UTF-8 text.
    public func text(of path: String) -> String? {
        Self.file(path, in: rootURL).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Where the package runs, as the review sheet says it: the engines whose check it passed, such as "Runs on WebKit tabs.", then why each engine that refused it did. Empty without checks.
    public var engineNotes: [String] {
        let refusals = EngineKind.allCases.compactMap { engine -> String? in
            guard case let .refused(reason)? = engineChecks[engine] else { return nil }
            return reason
        }
        return [Self.runsNote(on: Set(engineChecks.filter { $0.value == .runs }.keys))].compactMap { $0 } + refusals
    }

    /// "Runs on WebKit tabs." or "Runs on WebKit and Chromium tabs.", in the order of `EngineKind`; nil for no engine.
    public static func runsNote(on engines: Set<EngineKind>) -> String? {
        let names = EngineKind.allCases.filter(engines.contains).map(\.displayName)
        guard let last = names.last else { return nil }
        let list = names.count < 3 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + ", and " + last
        return "Runs on \(list) tabs."
    }

    /// The manifest files that tell a package's kind: `plugin.json`, then the runtimes'.
    private static func manifestFiles(_ runtimes: [any PluginRuntime]) -> [String] {
        [ScriptManifest.fileName] + runtimes.map(\.manifestFileName)
    }

    /// Copies the folder at `source`, or extracts the `.zip` archive there, to `root`, which must not exist yet, and reads the package as `init(at:origin:runtimes:)` does. An archive's package is its top level or its only top folder, as an archive of a package folder has. A failure leaves nothing at `root`.
    static func stage(_ source: URL, at root: URL, runtimes: [any PluginRuntime] = []) throws -> PluginPackage {
        try stage(at: root, origin: .file(source.absoluteURL), runtimes: runtimes) {
            if (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try FileManager.default.copyItem(at: source, to: root)
            } else {
                try extractArchive(source, to: root, runtimes: runtimes)
            }
        }
    }

    /// Writes the text of each file at its package path in `root`, which must not exist yet, and reads the package. Throws `PluginError.invalidPackage` for a path that breaks the rules of `file(_:in:)`. A failure leaves nothing at `root`.
    static func stage(_ files: [String: String], at root: URL, origin: PluginOrigin) throws -> PluginPackage {
        try stage(at: root, origin: origin) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            for (path, text) in files {
                guard isPackagePath(path) else { throw PluginError.invalidPackage("“\(path)” is not a path inside the package.") }
                let url = root.appendingPathComponent(path, isDirectory: false)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
        }
    }

    /// Has `fill` create the folder at `root`, then reads the package there as `init(at:origin:runtimes:)` does. When either fails, it removes what `fill` left.
    private static func stage(at root: URL, origin: PluginOrigin, runtimes: [any PluginRuntime] = [], filling fill: () throws -> Void) throws -> PluginPackage {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fill()
            return try PluginPackage(at: root, origin: origin, runtimes: runtimes)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// The file at a package path such as `scripts/count.js`. Nil for a path that `isPackagePath(_:)` refuses, names no regular file, or leads out of the package through a link.
    static func file(_ path: String, in root: URL) -> URL? {
        guard isPackagePath(path) else { return nil }
        let url = root.appendingPathComponent(path, isDirectory: false)
        // The attributes are those of a final link itself, and the resolved path catches a link among the folders.
        guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular,
              url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { return nil }
        return url
    }

    /// Whether `path` is names separated by `/`, none of them empty, `.`, or `..`.
    private static func isPackagePath(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Extracts the archive with `ditto`, which keeps every entry inside the destination, then moves the package folder in it to `root`.
    private static func extractArchive(_ archive: URL, to root: URL, runtimes: [any PluginRuntime]) throws {
        let extracted = root.appendingPathExtension("archive")
        defer { try? FileManager.default.removeItem(at: extracted) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, extracted.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw PluginError.invalidPackage("\(archive.lastPathComponent) is not a folder or a .zip archive.") }
        try FileManager.default.moveItem(at: packageFolder(in: extracted, runtimes: runtimes), to: root)
    }

    /// The extracted archive's top level when it holds a manifest file, else its only folder, leaving out the Finder's `.DS_Store`.
    private static func packageFolder(in extracted: URL, runtimes: [any PluginRuntime]) throws -> URL {
        let manifestFiles = manifestFiles(runtimes)
        if manifestFiles.contains(where: { FileManager.default.fileExists(atPath: extracted.appendingPathComponent($0).path) }) { return extracted }
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: extracted.path)) ?? []).filter { $0 != ".DS_Store" }
        var isDirectory: ObjCBool = false
        guard entries.count == 1, FileManager.default.fileExists(atPath: extracted.appendingPathComponent(entries[0]).path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PluginError.invalidPackage("The archive has no \(manifestFiles.joined(separator: " or ")) at its top level or in its only folder.")
        }
        return extracted.appendingPathComponent(entries[0], isDirectory: true)
    }

    /// The package paths of the regular files below `root`, in ascending order. Throws for a symbolic link, `root` itself included.
    private static func files(in root: URL) throws -> [String] {
        // The attributes are those of a link itself, such as the only entry of an archive that ditto restored as a link.
        guard (try? FileManager.default.attributesOfItem(atPath: root.path))?[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw PluginError.invalidPackage("The package is a symbolic link, which could lead to files outside Arch.")
        }
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { throw PluginError.invalidPackage("The package cannot be read.") }
        var files: [String] = []
        while let path = enumerator.nextObject() as? String {
            switch enumerator.fileAttributes?[.type] as? FileAttributeType {
            case .typeSymbolicLink?: throw PluginError.invalidPackage("The package has a symbolic link, \(path), which could lead to files outside it.")
            case .typeRegular?: files.append(path)
            default: break
            }
        }
        return files.sorted()
    }
}
