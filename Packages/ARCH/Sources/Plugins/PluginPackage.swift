// Script plugin packages: a folder with `plugin.json` at its top, which the user chooses as the folder or as a `.zip` archive, or whose files AI writes. The manager copies it, or writes AI's files, into a staging folder, reads it there for the install sheet without running any of it, and moves it into the Persona's plugin folder when the user installs it.
import Foundation

/// A script plugin's package, with its manifest read and checked: staged for review, or installed.
public struct PluginPackage: Identifiable, Sendable {
    public var id: URL { rootURL }
    public let manifest: PluginManifest
    /// The folder that holds `plugin.json`.
    public let rootURL: URL
    /// The folder or archive the user chose, or how AI wrote the package.
    public let origin: PluginOrigin
    /// The package paths of the package's files, such as `scripts/count.js`, in ascending order, as the install sheet lists them.
    public let files: [String]
    /// The package path of the background script, if the plugin has one.
    let background: String?

    /// Reads the package at `root`. Throws as `ScriptManifest(packageAt:)` does, and `PluginError.invalidPackage` for a package that is or holds a symbolic link, which could lead to files outside it.
    init(at root: URL, origin: PluginOrigin) throws {
        let files = try Self.files(in: root)
        let declared = try ScriptManifest(packageAt: root)
        self.init(manifest: declared.manifest, rootURL: root, origin: origin, files: files, background: declared.background)
    }

    private init(manifest: PluginManifest, rootURL: URL, origin: PluginOrigin, files: [String], background: String?) {
        self.manifest = manifest
        self.rootURL = rootURL
        self.origin = origin
        self.files = files
        self.background = background
    }

    /// The package once its folder has moved to `root`.
    func moved(to root: URL) -> PluginPackage {
        PluginPackage(manifest: manifest, rootURL: root, origin: origin, files: files, background: background)
    }

    /// The text of the file at a package path, as the review shows it. Nil for a path that names no file of the package, and for a file that is not UTF-8 text.
    public func text(of path: String) -> String? {
        Self.file(path, in: rootURL).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Copies the folder at `source`, or extracts the `.zip` archive there, to `root`, which must not exist yet, and reads the package. An archive's package is its top level or its only top folder, as an archive of a package folder has. A failure leaves nothing at `root`.
    static func stage(_ source: URL, at root: URL) throws -> PluginPackage {
        try stage(at: root, origin: .file(source.absoluteURL)) {
            if (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try FileManager.default.copyItem(at: source, to: root)
            } else {
                try extractArchive(source, to: root)
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

    /// Has `fill` create the folder at `root`, then reads the package there. When either fails, it removes what `fill` left.
    private static func stage(at root: URL, origin: PluginOrigin, filling fill: () throws -> Void) throws -> PluginPackage {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fill()
            return try PluginPackage(at: root, origin: origin)
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
    private static func extractArchive(_ archive: URL, to root: URL) throws {
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
        try FileManager.default.moveItem(at: packageFolder(in: extracted), to: root)
    }

    /// The extracted archive's top level when it holds `plugin.json`, else its only folder, leaving out the Finder's `.DS_Store`.
    private static func packageFolder(in extracted: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: extracted.appendingPathComponent("plugin.json").path) { return extracted }
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: extracted.path)) ?? []).filter { $0 != ".DS_Store" }
        var isDirectory: ObjCBool = false
        guard entries.count == 1, FileManager.default.fileExists(atPath: extracted.appendingPathComponent(entries[0]).path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PluginError.invalidPackage("The archive has no plugin.json at its top level or in its only folder.")
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
