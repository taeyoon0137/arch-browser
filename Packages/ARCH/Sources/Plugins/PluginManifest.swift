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

/// A capability a plugin asks for. Each permission guards members of `PluginContext` or fields the plugin receives, and joins with them.
public enum PluginPermission: String, Hashable, Sendable {
    /// Titles and addresses of tabs. Without it, a plugin sees a tab's identifier, space, engine, and pinned state only.
    case tabs
    /// Writing text to the clipboard.
    case clipboard
}

/// What the user granted a plugin: a subset of what its manifest asks for. `PluginContext` checks every call against it.
public struct PluginGrant: Hashable, Sendable {
    public var permissions: Set<PluginPermission>
    public var sites: [MatchPattern]

    /// Everything the manifest asks for. Built-in plugins get this grant.
    public init(requestedBy manifest: PluginManifest) {
        permissions = manifest.permissions
        sites = manifest.sites
    }

    /// Whether the granted sites cover the page at `url`.
    func covers(_ url: URL) -> Bool {
        sites.contains { $0.matches(url) }
    }
}
