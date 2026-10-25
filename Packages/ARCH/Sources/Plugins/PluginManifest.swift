// A plugin's identity and manifest: what it declares before any of its code runs, and what the user grants it. `docs/plugins.md` describes the whole plugin system.
import Foundation

/// Identifies a Persona, which owns its installed plugins.
public typealias PersonaID = UUID

/// A reverse-DNS identifier, such as `local.arch.browser.page-address`. It is lowercase, so identifiers that differ only in case name one plugin, as they name one folder on a volume that ignores case.
public struct PluginID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    /// Fails for anything but dot-separated labels of letters, digits, and `-`, fewer than two labels, or more than 128 characters. Empty labels fail, so an identifier is never `.` or `..` when it names a folder. Lowercases the letters.
    public init?(rawValue: String) {
        guard rawValue.count <= 128, rawValue.isDomainName, rawValue.contains(".") else { return nil }
        self.rawValue = rawValue.lowercased()
    }
}

extension StringProtocol {
    /// Whether the text is dot-separated labels of ASCII letters, digits, and `-`, none of them empty.
    var isDomainName: Bool {
        split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

/// Who a plugin is, what it asks for, and what it adds to the interface. The app shows the contributions before any of the plugin's code runs.
public struct PluginManifest: Hashable, Sendable {
    /// The newest plugin API this app runs, which a script plugin's `apiVersion` may not exceed.
    public static let apiVersion = 1

    public var id: PluginID
    public var name: String
    public var version: String
    /// What the plugin does, in one sentence.
    public var summary: String
    public var permissions: Set<PluginPermission>
    /// The pages the plugin may reach. Without `tabs`, the plugin still sees the title and address of a tab whose page they cover.
    public var sites: [MatchPattern]
    /// The API permissions of a web extension that no `PluginPermission` stands for, as its manifest names them, such as `storage`. They come with the install, as in other browsers, and the install sheet and Settings list them. Empty for other kinds.
    public var extensionPermissions: [String]
    public var contributions: PluginContributions

    public init(id: PluginID, name: String, version: String, summary: String, permissions: Set<PluginPermission> = [], sites: [MatchPattern] = [],
                extensionPermissions: [String] = [], contributions: PluginContributions) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.permissions = permissions
        self.sites = sites
        self.extensionPermissions = extensionPermissions
        self.contributions = contributions
    }

    /// The extension permissions as the sentence that the install sheet and Settings show, or nil without any.
    public var extensionPermissionsSummary: String? {
        guard !extensionPermissions.isEmpty else { return nil }
        return "Use the extension APIs " + ListFormatter.localizedString(byJoining: extensionPermissions)
    }
}

/// How a plugin's code comes and runs.
public enum PluginKind: String, Hashable, Sendable {
    /// A Swift type compiled into the app, which runs in the app.
    case builtIn
    /// A package with `plugin.json`, whose background script runs in the plugin sandbox.
    case script
    /// A Manifest V3 web extension, which runs in an engine's own extension runtime (`PluginRuntime`).
    case webExtension
}

/// Where a plugin came from.
public enum PluginOrigin: Hashable, Sendable {
    /// Compiled into the app.
    case bundled
    /// Installed from the folder or archive at the address.
    case file(URL)
    /// Written by AI through the AI interface, from what the user asked for.
    case generated(PluginComposition)
}

/// How AI wrote a plugin, which the review and Settings show.
public struct PluginComposition: Hashable, Codable, Sendable {
    /// What the user typed: the request, then each change the user asked for in the review, in order.
    public var requests: [String]
    /// The model that wrote the plugin's last version, as Settings ▸ AI names it.
    public var model: String

    public init(requests: [String], model: String) {
        self.requests = requests
        self.model = model
    }
}

/// A capability a plugin asks for. Each permission guards members of `PluginContext` or fields the plugin receives, and joins with them. A script plugin's manifest names it by its raw value.
public enum PluginPermission: String, Hashable, Codable, Sendable, CaseIterable {
    /// Titles and addresses of tabs. Without it, a plugin sees a tab's identifier, space, engine, and pinned state only.
    case tabs
    /// Writing text to the clipboard.
    case clipboard
    /// Messages to native apps on the Mac that the plugin names. Web extensions only; granting it asks for Touch ID or the login password.
    case nativeMessaging

    /// What the permission lets a plugin do, as a sentence that Settings shows.
    public var summary: String {
        switch self {
        case .tabs: return "Read the titles and addresses of your tabs"
        case .clipboard: return "Write text to the clipboard"
        case .nativeMessaging: return "Exchange messages with apps on this Mac"
        }
    }
}

/// What the user granted a plugin: a subset of what its manifest asks for. `PluginContext` checks every call against it.
public struct PluginGrant: Hashable, Codable, Sendable {
    public var permissions: Set<PluginPermission>
    public var sites: [MatchPattern]

    public init(permissions: Set<PluginPermission>, sites: [MatchPattern]) {
        self.permissions = permissions
        self.sites = sites
    }

    /// Everything the manifest asks for. Built-in plugins get this grant.
    public init(requestedBy manifest: PluginManifest) {
        self.init(permissions: manifest.permissions, sites: manifest.sites)
    }

    /// What the review of an update to `manifest` offers at first: everything it asks for, except the sites that the installed version asked for and the user left out.
    public init(updating installed: InstalledPlugin, to manifest: PluginManifest) {
        let leftOut = Set(installed.manifest.sites).subtracting(installed.grant.sites)
        self.init(permissions: manifest.permissions, sites: manifest.sites.filter { !leftOut.contains($0) })
    }

    /// The grant without what the manifest does not ask for, so that a grant never exceeds the request.
    func limited(to manifest: PluginManifest) -> PluginGrant {
        PluginGrant(permissions: permissions.intersection(manifest.permissions), sites: sites.filter(manifest.sites.contains))
    }

    /// Whether the granted sites cover the page at `url`.
    func covers(_ url: URL) -> Bool {
        sites.contains { $0.matches(url) }
    }

    /// What the grant lets the plugin do, one sentence for each permission, in a fixed order, and for each site.
    public var summaries: [String] {
        PluginPermission.allCases.filter(permissions.contains).map(\.summary) + sites.map(\.accessSummary)
    }

    /// The reason that Touch ID or the login password states before Arch gives the grant to `pluginName`, at install and when a web extension asks while it runs, or nil when the grant needs no confirmation: access to every website and to native apps need it.
    public func confirmationReason(for pluginName: String) -> String? {
        let access = [sites.contains(where: \.coversEverySite) ? "run scripts on every website" : nil,
                      permissions.contains(.nativeMessaging) ? "exchange messages with apps on this Mac" : nil].compactMap { $0 }
        guard !access.isEmpty else { return nil }
        return "let \u{201C}\(pluginName)\u{201D} \(access.joined(separator: " and "))"
    }
}
