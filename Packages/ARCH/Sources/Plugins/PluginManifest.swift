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
    public var contributions: PluginContributions

    public init(id: PluginID, name: String, version: String, summary: String, permissions: Set<PluginPermission> = [], sites: [MatchPattern] = [], contributions: PluginContributions) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.permissions = permissions
        self.sites = sites
        self.contributions = contributions
    }
}

/// Where a plugin came from.
public enum PluginOrigin: Hashable, Sendable {
    /// Compiled into the app.
    case bundled
    /// Installed from the folder or archive at the address.
    case file(URL)
}

/// A capability a plugin asks for. Each permission guards members of `PluginContext` or fields the plugin receives, and joins with them. A script plugin's manifest names it by its raw value.
public enum PluginPermission: String, Hashable, Codable, Sendable, CaseIterable {
    /// Titles and addresses of tabs. Without it, a plugin sees a tab's identifier, space, engine, and pinned state only.
    case tabs
    /// Writing text to the clipboard.
    case clipboard

    /// What the permission lets a plugin do, as a sentence that Settings shows.
    public var summary: String {
        switch self {
        case .tabs: return "Read the titles and addresses of your tabs"
        case .clipboard: return "Write text to the clipboard"
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
}
