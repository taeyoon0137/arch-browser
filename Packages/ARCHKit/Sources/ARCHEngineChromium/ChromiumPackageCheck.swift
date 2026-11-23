// What Chromium's extension runtime needs of a Manifest V3 package, read from its files without loading it. CEF's extension runtime has no call that reads a package without installing and starting it, so the adapter checks a package for the problems that keep Chromium from running it, as Chromium's own loader reports them; anything else Chromium refuses shows when the package loads.
import Foundation

/// The parts of a package's `manifest.json` that the Chromium adapter reads.
struct ChromiumManifest {
    let fields: [String: Any]

    /// Nil for a manifest that does not read as a JSON object.
    init?(packageAt root: URL) {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.fields = fields
    }

    var version: String? { fields["version"] as? String }

    /// The host patterns the extension asks for at install, as the manifest writes them: `host_permissions` and the content scripts' `matches`.
    var hostPatterns: Set<String> {
        let contentScripts = fields["content_scripts"] as? [[String: Any]] ?? []
        return Set((fields["host_permissions"] as? [String] ?? []) + contentScripts.flatMap { $0["matches"] as? [String] ?? [] })
    }
}

/// Checks a package for the problems that keep Chromium from running it, before `ChromiumExtensions` loads it.
enum ChromiumPackageCheck {
    /// Throws with why Chromium cannot run the package in the folder at `root`.
    static func check(_ root: URL) throws {
        guard let manifest = ChromiumManifest(packageAt: root) else { throw ChromiumPackageError(localized("Its manifest.json is missing or is not a JSON object.")) }
        let fields = manifest.fields
        guard fields["manifest_version"] as? Int == 3 else { throw ChromiumPackageError(localized("Arch runs Manifest V3 extensions only.")) }
        if let background = fields["background"] as? [String: Any] {
            // Chromium leaves out a Manifest V3 package's `background.scripts` and `background.page`, so the extension would run without its background.
            guard let worker = background["service_worker"] as? String else {
                throw ChromiumPackageError(localized("Its background runs as background.scripts or background.page, which Chromium runs for Manifest V2 only; Chromium needs background.service_worker."))
            }
            try requireFile(worker, in: root, for: localized("the background service worker"))
        }
        for script in fields["content_scripts"] as? [[String: Any]] ?? [] {
            for file in (script["js"] as? [String] ?? []) + (script["css"] as? [String] ?? []) {
                try requireFile(file, in: root, for: localized("a content script"))
            }
        }
        for icon in icons(in: fields["icons"]) {
            try requireFile(icon, in: root, for: localized("an icon"))
        }
        if let action = fields["action"] as? [String: Any] {
            for icon in icons(in: action["default_icon"]) {
                try requireFile(icon, in: root, for: localized("the action\u{2019}s icon"))
            }
        }
        if let locale = fields["default_locale"] as? String {
            try requireFile("_locales/\(locale)/messages.json", in: root, for: localized("the default locale"))
        }
    }

    /// An icon set's files: a dictionary from size to path, or, for an action, one path.
    private static func icons(in value: Any?) -> [String] {
        if let path = value as? String { return [path] }
        return (value as? [String: Any])?.values.compactMap { $0 as? String } ?? []
    }

    /// Throws unless the package path names a file inside the package. Chromium reads a leading `/` as the package's root.
    private static func requireFile(_ path: String, in root: URL, for use: String) throws {
        let relative = path.hasPrefix("/") ? String(path.drop { $0 == "/" }) : path
        let file = root.appendingPathComponent(relative).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ChromiumPackageError(localized("It names \(path) as \(use), which is not in the package."))
        }
    }
}

/// A problem that `ChromiumPackageCheck` found, in a sentence for the user.
struct ChromiumPackageError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
