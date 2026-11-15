// `manifest.json`, the manifest of a Manifest V3 web extension, read into a `PluginManifest` without any engine, so that one install serves every engine that runs extensions. Arch reads what it shows and grants: the name, version, and description, localized from `_locales` where the manifest names a message, the permissions, the sites, whether the extension has an action, and the developer fields by which two packages name one extension. The engines read the rest.
import CryptoKit
import Foundation
import Plugins

/// What a web extension's `manifest.json` declares, as Arch reads it.
struct WebExtensionManifest {
    static let fileName = "manifest.json"
    /// The command that runs the extension's action, which the palette lists under the extension's name.
    static let actionCommand = "action"
    /// The API permissions that an Arch permission stands for, by the names manifests give them.
    static let mappedPermissions: [String: PluginPermission] = ["tabs": .tabs, "clipboardWrite": .clipboard, "nativeMessaging": .nativeMessaging]

    let manifest: PluginManifest

    /// Reads `manifest.json` in the package folder at `root`, which the user installs from `source`. Throws `PluginError.invalidPackage` with a sentence that names the field for a manifest Arch cannot install. A name of nothing but spaces gives the extension its identifier as its name, and an action title of nothing but spaces the name.
    init(packageAt root: URL, source: URL) throws {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(Self.fileName)),
              let object = try? JSONSerialization.jsonObject(with: data) else { throw PluginError.invalidPackage("manifest.json is not valid JSON.") }
        guard let fields = object as? [String: Any] else { throw invalidManifest("the manifest must be a JSON object") }
        guard fields["manifest_version"] as? Int == 3 else { throw invalidManifest("manifest_version must be 3, as Arch runs Manifest V3 extensions only") }
        let messages = try LocalizedMessages(packageAt: root, defaultLocale: fields["default_locale"] as? String)
        let givenName = try messages.text(of: "name", in: fields, required: true)
        let version = try messages.text(of: "version", in: fields, required: true)
        let summary = try messages.text(of: "description", in: fields, required: false)
        let requested = Self.unique(try Self.permissionNames(of: "permissions", in: fields))
        // Chromium refuses a manifest whose optional permissions do not read, and requests at run time read them.
        _ = try Self.permissionNames(of: "optional_permissions", in: fields)
        let extensionID = try Self.extensionID(key: fields["key"], source: source)
        // A name of nothing but spaces, as a localized name whose message is empty, would show as no name, so the extension goes by its identifier, as the address of its pages names it. Chromium runs a name of only spaces, and the user's languages, which pick the message, can change between launches, so the package is not refused.
        let name = givenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? extensionID : givenName
        var commands: [PluginCommand] = []
        if let action = fields["action"] as? [String: Any] {
            let title = try messages.text(of: "default_title", in: action, required: false)
            commands.append(PluginCommand(id: Self.actionCommand, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : title, symbol: "puzzlepiece.extension", keywords: [name]))
        }
        manifest = PluginManifest(
            id: Self.pluginID(of: extensionID), name: name, version: version, summary: summary.isEmpty ? "A web extension." : summary,
            permissions: Set(requested.compactMap { Self.mappedPermissions[$0] }), sites: Self.sites(in: fields),
            extensionPermissions: requested.filter { Self.mappedPermissions[$0] == nil }, contributions: PluginContributions(commands: commands),
            author: Self.author(in: fields), homepage: Self.homepage(in: fields)
        )
    }

    /// `author` as text or as the `email` of an author object, lowercased; nil without one.
    private static func author(in fields: [String: Any]) -> String? {
        let author = fields["author"] as? String ?? (fields["author"] as? [String: Any])?["email"] as? String
        let text = author?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return text.isEmpty ? nil : text
    }

    /// `homepage_url` without its scheme, a leading `www.`, and a trailing `/`, lowercased, so that two projects on one hosting site differ by their paths; nil without one.
    private static func homepage(in fields: [String: Any]) -> String? {
        var text = (fields["homepage_url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// The sites the extension asks for at install, from `host_permissions` and its content scripts' `matches`, in order. Patterns for pages other than web pages, such as `file:///*`, and patterns with a port are left out, since Arch's grants cover web pages on every port only.
    private static func sites(in fields: [String: Any]) -> [MatchPattern] {
        let contentScripts = fields["content_scripts"] as? [[String: Any]] ?? []
        let patterns = (fields["host_permissions"] as? [String] ?? []) + contentScripts.flatMap { $0["matches"] as? [String] ?? [] }
        var sites: [MatchPattern] = []
        for site in patterns.compactMap({ try? MatchPattern($0) }) where !sites.contains(site) {
            sites.append(site)
        }
        return sites
    }

    /// The permission names in the list at `key`, as Chromium reads them: each a name, or an object with one key, the name, whose value holds the permission's arguments. Nothing without the key. Throws for a value that is not such a list, which Chromium refuses to load, so that no entry it would grant goes unread.
    static func permissionNames(of key: String, in fields: [String: Any]) throws -> [String] {
        guard let value = fields[key] else { return [] }
        let problem = invalidManifest("\(key) must be a list of permissions, each a name or an object with one key")
        guard let list = value as? [Any] else { throw problem }
        return try list.map { item in
            if let name = item as? String { return name }
            guard let object = item as? [String: Any], object.count == 1, let name = object.keys.first else { throw problem }
            return name
        }
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    // MARK: Identifiers

    /// The plugin identifier of the extension whose engine identifier is `extensionID`.
    static func pluginID(of extensionID: String) -> PluginID {
        // Engine identifiers are 32 lowercase letters, so the identifier is valid.
        PluginID(rawValue: "extension." + extensionID)!
    }

    /// The engine identifier of a web extension's plugin, which `pluginID(of:)` made.
    static func extensionID(of id: PluginID) -> String {
        String(id.rawValue.dropFirst("extension.".count))
    }

    /// The identifier that Chromium gives the extension: from the public key in the manifest's `key`, so that each engine and Persona knows it alike, or else from the path the user installs it from, as Chromium names an unpacked extension, so that installing from the same place again updates it. Throws for a `key` that is not Base64 text.
    static func extensionID(key: Any?, source: URL) throws -> String {
        guard let key else { return extensionID(ofBytes: Data(source.standardizedFileURL.path.utf8)) }
        guard let text = key as? String, let bytes = Data(base64Encoded: text) else { throw invalidManifest("key must be a public key as Base64 text") }
        return extensionID(ofBytes: bytes)
    }

    /// The first 128 bits of the SHA-256 digest, each hexadecimal digit written as a letter from `a` to `p`.
    static func extensionID(ofBytes bytes: Data) -> String {
        let letters = Array("abcdefghijklmnop")
        return SHA256.hash(data: bytes).prefix(16).map { "\(letters[Int($0 >> 4)])\(letters[Int($0 & 0xF)])" }.joined()
    }

    /// Writes a `key` whose bytes are the path of `source` into the manifest of the package at `root`, which the user installed from `source`, when the manifest has none. Chromium names an extension by the digest of its key's bytes, and otherwise by the folder it loads from, which for an installed package is Arch's copy; with this key it knows the extension by the identifier that `extensionID(key:source:)` gives, as WebKit and Arch do. Chromium reads a key as Base64 bytes without checking that they hold a public key (`ComputeExtensionID` in `extensions/common/extension.cc`).
    static func writeKey(packageAt root: URL, source: URL) throws {
        try PluginPackage.writeManifestKey(Data(source.standardizedFileURL.path.utf8), into: root.appendingPathComponent(fileName))
    }

    /// What an extension may ask for at run time with `permissions.request()`: its manifest's `optional_permissions` and `optional_host_permissions`, the sites as far as Arch's match patterns hold them.
    struct OptionalAccess {
        var permissions: Set<String> = []
        var sites: [MatchPattern] = []

        /// The sites as a grant, whose rule says whether the user confirms them.
        var grant: PluginGrant { PluginGrant(permissions: [], sites: sites) }
    }

    /// Nil for a manifest that does not read, or whose optional lists do not, so that Arch refuses the requests of an extension whose optional access it cannot tell.
    static func optionalAccess(ofPackageAt root: URL) -> OptionalAccess? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = try? permissionNames(of: "optional_permissions", in: fields),
              let hosts = (fields["optional_host_permissions"] ?? [String]()) as? [String] else { return nil }
        return OptionalAccess(permissions: Set(names.filter { !$0.contains(":") && $0 != "<all_urls>" }), sites: (hosts + names).compactMap { try? MatchPattern($0) })
    }

    /// What the installed extension may ask for at run time: its optional access, and the sites its manifest asks for that its grant leaves out, which Chromium withholds and lets `permissions.request()` ask for again. Nil when its package's optional access does not read.
    static func runTimeAccess(of installed: InstalledPlugin) -> OptionalAccess? {
        guard let packageURL = installed.packageURL, var access = optionalAccess(ofPackageAt: packageURL) else { return nil }
        access.sites += installed.manifest.sites.filter { !installed.grant.sites.contains($0) }
        return access
    }
}

/// A manifest problem, stated as a clause, as a sentence that names the file.
private func invalidManifest(_ problem: String) -> PluginError {
    .invalidPackage("manifest.json: \(problem).")
}

/// The messages that a manifest's `__MSG_<name>__` texts name, from `_locales/<locale>/messages.json`: the user's preferred languages first, then the manifest's default locale.
private struct LocalizedMessages {
    /// Each locale's messages, by lowercase name, in the order they are tried.
    private let locales: [[String: String]]
    private let defaultLocale: String?

    init(packageAt root: URL, defaultLocale: String?) throws {
        self.defaultLocale = defaultLocale
        let folders = Locale.preferredLanguages.flatMap { language -> [String] in
            let folder = language.replacingOccurrences(of: "-", with: "_")
            return [folder, String(folder.prefix { $0 != "_" })]
        } + [defaultLocale].compactMap { $0 }
        locales = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: root.appendingPathComponent("_locales/\(folder)/messages.json")),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return Dictionary(entries.compactMap { name, entry in ((entry as? [String: Any])?["message"] as? String).map { (name.lowercased(), $0) } }) { first, _ in first }
        }
        if let defaultLocale, locales.isEmpty { throw invalidManifest("default_locale is \(defaultLocale), but _locales/\(defaultLocale)/messages.json could not be read") }
    }

    /// The text of `key` in `fields`, with a whole `__MSG_<name>__` replaced by its message. A missing text is empty unless `required`.
    func text(of key: String, in fields: [String: Any], required: Bool) throws -> String {
        guard let text = fields[key] as? String, !text.isEmpty else {
            if required { throw invalidManifest("\(key) is missing") }
            return ""
        }
        guard text.hasPrefix("__MSG_"), text.hasSuffix("__"), text.count > 8 else { return text }
        let name = String(text.dropFirst(6).dropLast(2))
        guard let message = locales.lazy.compactMap({ $0[name.lowercased()] }).first else {
            guard let defaultLocale else { throw invalidManifest("\(key) names the message “\(name)”, but default_locale is missing") }
            throw invalidManifest("\(key) names the message “\(name)”, which _locales/\(defaultLocale)/messages.json does not have")
        }
        return message
    }
}
