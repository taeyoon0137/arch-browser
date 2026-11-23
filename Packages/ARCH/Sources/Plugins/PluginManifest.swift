// A plugin's identity and manifest: what it declares before any of its code runs, where it came from and what its signatures prove, and what the user grants it. `docs/plugins.md` describes the whole plugin system.
import AI
import Events
import Foundation

/// Identifies a Persona, which owns its installed plugins.
public typealias PersonaID = UUID

/// A reverse-DNS identifier, such as `xyz.taeyoon.arch.page-address`. It is lowercase, so identifiers that differ only in case name one plugin, as they name one folder on a volume that ignores case.
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
    /// Hosts named by the script plugin's `network` permission.
    public var network: [PluginNetworkHost]
    /// An HTML file in the package that Settings opens in the plugin sandbox.
    public var settingsPage: String?
    /// The data kinds beyond text that the plugin's AI requests carry, which its `ai` permission lists: `page` for page parts, such as of the text that its page calls read, and `selection` for selected text. They name the parts' kinds, not what can reach a model: a plugin with sites can also put the text of their pages into a text part. They come with `ai`, as a web extension's other API permissions come with its install, and the install sheet and Settings state them in one sentence (`aiDataSummary`). Empty without `ai`.
    public var aiDataKinds: Set<AIDataKind>
    /// The pages the plugin may reach. Without `tabs`, the plugin still sees the title and address of a tab whose page they cover.
    public var sites: [MatchPattern]
    /// How the plugin reaches its sites: in every page they cover, or only in a tab where the user runs one of its commands. A web extension's is `listedSites`, since its engines keep its site access.
    public var siteAccess: SiteAccess
    /// The API permissions of a web extension that no `PluginPermission` stands for, as its manifest names them, such as `storage`. They come with the install, as in other browsers, and the install sheet and Settings list them. Empty for other kinds.
    public var extensionPermissions: [String]
    public var contributions: PluginContributions
    /// The browser events that reach the plugin's `handle(_:)` and start its code: none unless the manifest lists them.
    public var events: Set<BrowserEventKind>
    /// Whether the changes the user makes to the plugin's settings reach its `handle(_:)` as `PluginEvent.settingChanged` and start its code, which `plugin.json` asks for with `settingChanged` in `events`. They come from Settings rather than the bus, so they are not among `events` and run no hooks.
    public var receivesSettingChanges: Bool
    /// A web extension's `author`, as text or as the `email` of an author object, lowercased, by which a package matches an installed plugin as a version of the same extension. Nil for other kinds and without the field.
    public var author: String?
    /// A web extension's `homepage_url` without its scheme, a leading `www.`, and a trailing `/`, lowercased, so that two projects on one hosting site differ. Nil for other kinds and without the field.
    public var homepage: String?

    public init(id: PluginID, name: String, version: String, summary: String, permissions: Set<PluginPermission> = [], aiDataKinds: Set<AIDataKind> = [], network: [PluginNetworkHost] = [], settingsPage: String? = nil,
                sites: [MatchPattern] = [], siteAccess: SiteAccess = .listedSites, extensionPermissions: [String] = [], contributions: PluginContributions,
                events: Set<BrowserEventKind> = [], receivesSettingChanges: Bool = false, author: String? = nil, homepage: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.permissions = permissions
        self.network = permissions.contains(.network) ? network : []
        self.settingsPage = settingsPage
        self.aiDataKinds = permissions.contains(.ai) ? aiDataKinds : []
        self.sites = sites
        self.siteAccess = siteAccess
        self.extensionPermissions = extensionPermissions
        self.contributions = contributions
        self.events = events
        self.receivesSettingChanges = receivesSettingChanges
        self.author = author
        self.homepage = homepage
    }

    /// The data kinds that AI requests carry as the sentence that the install sheet and Settings show after the `ai` permission's, such as "Send the text of pages and selected text to the AI models you connected", or nil without any.
    public var aiDataSummary: String? {
        let listed = AIDataKind.allCases.filter(aiDataKinds.contains).map(\.sentenceName)
        guard !listed.isEmpty else { return nil }
        return localized("Send \(ListFormatter.localizedString(byJoining: listed)) to the AI models you connected")
    }

    /// The extension permissions as the sentence that the install sheet and Settings show, or nil without any.
    public var extensionPermissionsSummary: String? {
        guard !extensionPermissions.isEmpty else { return nil }
        return localized("Use the extension APIs \(ListFormatter.localizedString(byJoining: extensionPermissions))")
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
    /// Downloaded from the Web Store for the extension identifier, 32 letters from `a` to `p` (`docs/web-store.md`).
    case webStore(String)
}

/// What a package's signatures prove about its identifier (`docs/web-store.md`, Package proof). Folders, `.zip` archives, and packages that AI writes have no proof.
public enum PluginProof: String, Hashable, Sendable {
    /// A `.crx` file with a valid proof by the key whose digest the extension's identifier is: its developer's.
    case developer
    /// A `.crx` file with a developer proof and a valid proof by the Web Store's publisher key, as the store publishes packages.
    case webStore
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
    /// Titles and addresses of tabs. Without it, a plugin sees a tab's identifier, space, kind, engine, and pinned state only.
    case tabs
    /// Suggested names for tabs, which the user's own names always outrank (`docs/hooks.md`, hook decision 13).
    case renameTabs = "tabs.rename"
    /// Opening, closing, selecting, and moving the Persona's tabs, and what `renameTabs` grants. The tabs it opens load pages from any host, the local network's among them, with the Persona's cookies, as the user's own tabs do, so an address can carry what the plugin knows to any host and act as the user on a site, as a sign-out link does; the summary says so.
    case manageTabs = "tabs.manage"
    /// Writing text to the clipboard.
    case clipboard
    /// Messages to native apps on the Mac that the plugin names. Web extensions only; granting it asks for Touch ID or the login password.
    case nativeMessaging
    /// Requests through the AI interface under the plugin's own feature, `plugin.<id>`, with text and the data kinds that the manifest lists for it (`PluginManifest.aiDataKinds`), through `PluginContext.ai()`. With `events`, the plugin's listeners run as hooks on the shared hook scheduler, which makes that feature automatic (`InstalledPlugin.runsHooks`).
    case ai
    /// Read download names, states, and sizes without file locations or contents.
    case downloads
    /// Suggest a safe name for a completed download in the plugin's Persona.
    case renameDownloads = "downloads.rename"
    /// Post local notifications under the plugin's name.
    case notifications
    /// Send requests to the listed HTTPS hosts without Persona cookies.
    case network
    /// Search the pages that the plugin's Persona visited (`PluginContext.history(matching:limit:)`).
    case history

    /// What the permission lets a plugin do, as a sentence that Settings shows.
    public var summary: String {
        switch self {
        case .tabs: return localized("Read the titles and addresses of your tabs")
        case .renameTabs: return localized("Suggest names for your tabs")
        case .manageTabs: return localized("Open any website in your tabs, signed in as you, and close, select, move, pin, and suggest names for your tabs")
        case .clipboard: return localized("Write text to the clipboard")
        case .nativeMessaging: return localized("Exchange messages with apps on this Mac")
        case .ai: return localized("Send text to the AI models you connected")
        case .downloads: return localized("Read the names, states, and sizes of your downloads")
        case .renameDownloads: return localized("Rename completed downloads in this Persona")
        case .notifications: return localized("Show notifications under the plugin's name")
        case .network: return localized("Send requests to the listed hosts")
        case .history: return localized("Search your browsing history in this Persona")
        }
    }
}

/// How a plugin reaches the pages its granted sites cover (`docs/plugins.md`, Permissions). A grant without sites reaches none either way.
public enum SiteAccess: String, Hashable, Sendable {
    /// Every page the sites cover: its page scripts run there, its page calls and page script values reach them, and it sees their tabs' titles and addresses.
    case listedSites
    /// Only a tab where the user runs one of the plugin's commands, on the host of the page the command ran on, until the tab commits a document of another host or gets another page, as when it unloads or changes engines. The page scripts run in that page at the command and in the tab's later documents on the host.
    case whenInvoked

    /// The sentence that the install sheet and Settings show after the sites' for `whenInvoked`, or nil for `listedSites`, whose sites' sentences say it all.
    public var summary: String? {
        switch self {
        case .listedSites: return nil
        case .whenInvoked: return localized("Only in a tab where you use one of its commands, until the tab leaves the website")
        }
    }
}

/// What the user granted a plugin: a subset of what its manifest asks for. `PluginContext` checks every call against it.
public struct PluginGrant: Hashable, Sendable {
    public var permissions: Set<PluginPermission>
    public var sites: [MatchPattern]
    public var network: [PluginNetworkHost]
    /// How the plugin reaches `sites`: `whenInvoked` when its manifest asks for it or the user chose it at install.
    public var siteAccess: SiteAccess

    public init(permissions: Set<PluginPermission>, sites: [MatchPattern], siteAccess: SiteAccess = .listedSites, network: [PluginNetworkHost] = []) {
        self.permissions = permissions
        self.sites = sites
        self.siteAccess = siteAccess
        self.network = permissions.contains(.network) ? network : []
        if self.network.isEmpty { self.permissions.remove(.network) }
    }

    /// Everything the manifest asks for. Built-in plugins get this grant.
    public init(requestedBy manifest: PluginManifest) {
        self.init(permissions: manifest.permissions, sites: manifest.sites, siteAccess: manifest.siteAccess, network: manifest.network)
    }

    /// What the review of a new plugin of `kind` with `manifest` offers at first: everything it asks for, and for a script plugin that asks for every website and has commands to run, its sites only where the user runs one of them, so that such a grant reaches pages one tab at a time unless the user chooses otherwise and confirms it.
    public init(offeredBy manifest: PluginManifest, kind: PluginKind) {
        self.init(requestedBy: manifest)
        if kind == .script, manifest.sites.contains(where: \.coversEverySite), !manifest.contributions.commands.isEmpty { siteAccess = .whenInvoked }
    }

    /// What the review of an update to `manifest` offers at first: everything it asks for, except the permissions, sites, and network hosts that the installed version asked for and the user left out or revoked, with the installed grant's site access, or `whenInvoked` when the manifest asks for it.
    public init(updating installed: InstalledPlugin, to manifest: PluginManifest) {
        let leftOut = Set(installed.manifest.sites).subtracting(installed.grant.sites)
        let revoked = installed.manifest.permissions.subtracting(installed.grant.permissions)
        let leftOutHosts = Set(installed.manifest.network).subtracting(installed.grant.network)
        self.init(permissions: manifest.permissions.subtracting(revoked), sites: manifest.sites.filter { !leftOut.contains($0) },
                  siteAccess: manifest.siteAccess == .whenInvoked ? .whenInvoked : installed.grant.siteAccess,
                  network: manifest.network.filter { !leftOutHosts.contains($0) })
    }

    /// Whether the review, starting from this grant, offers the switch for `whenInvoked` to a plugin of `kind` with `manifest`: a script plugin with sites whose manifest asks for its sites as listed and has commands, without which the switch would leave it no page to reach, or whose grant starts with the switch on, as in an update of a plugin that the user limited and whose new version has no commands, so that the user can switch it off.
    public func offersSiteAccessSwitch(for manifest: PluginManifest, kind: PluginKind) -> Bool {
        kind == .script && !manifest.sites.isEmpty && manifest.siteAccess == .listedSites && (!manifest.contributions.commands.isEmpty || siteAccess == .whenInvoked)
    }

    /// The grant without what the manifest of a plugin of `kind` does not ask for, so that a grant never exceeds the request: a manifest that asks for `whenInvoked` gets no more, and a plugin of a runtime's kind, such as a web extension, whose engines keep its site access, reaches its sites as listed.
    func limited(to manifest: PluginManifest, kind: PluginKind) -> PluginGrant {
        PluginGrant(permissions: permissions.intersection(manifest.permissions), sites: sites.filter(manifest.sites.contains),
                    siteAccess: kind != .script ? .listedSites : manifest.siteAccess == .whenInvoked ? .whenInvoked : siteAccess,
                    network: network.filter(manifest.network.contains))
    }

    /// Whether the granted sites cover the page at `url`. With `whenInvoked`, the plugin reaches it only in a tab where the user ran one of its commands on its host (`PluginManager`).
    func covers(_ url: URL) -> Bool {
        sites.contains { $0.matches(url) }
    }

    /// What the grant lets the plugin do, one sentence for each permission, in a fixed order, for each site, and, with `whenInvoked` and sites, for its site access.
    public var summaries: [String] {
        PluginPermission.allCases.filter(permissions.contains).map { $0 == .network ? networkSummary : $0.summary } + sites.map(\.accessSummary) + siteAccessSummaries
    }

    public var networkSummary: String { localized("Send requests to \(network.map(\.description).joined(separator: ", "))") }

    /// The sentence of the site access after the sites' sentences, for `whenInvoked` with sites.
    public var siteAccessSummaries: [String] {
        sites.isEmpty ? [] : [siteAccess.summary].compactMap { $0 }
    }

    /// The reason that Touch ID or the login password states before Arch gives the grant to `pluginName`, at install and when a web extension asks while it runs, or nil when the grant needs no confirmation: access to every website and to native apps need it. A grant of every website with `whenInvoked` reaches a page only after the user runs one of the plugin's commands on it, so it needs none.
    public func confirmationReason(for pluginName: String) -> String? {
        let access = [siteAccess == .listedSites && sites.contains(where: \.coversEverySite) ? localized("run scripts on every website") : nil,
                      permissions.contains(.nativeMessaging) ? localized("exchange messages with apps on this Mac") : nil].compactMap { $0 }
        guard !access.isEmpty else { return nil }
        return localized("let \u{201C}\(pluginName)\u{201D} \(access.joined(separator: localized(" and ")))")
    }
}

/// A grant encodes as `plugins.json` keeps it: `{"permissions": […], "sites": […]}`, or with `whenInvoked` its sites under `sitesWhenInvoked` in place of `sites`, so that a build before site access modes, which needs `sites`, keeps such an entry as one it cannot read rather than run the plugin in every page of its sites.
extension PluginGrant: Codable {
    private enum CodingKeys: String, CodingKey {
        case permissions, sites, sitesWhenInvoked, network
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let permissions = try container.decode(Set<PluginPermission>.self, forKey: .permissions)
        let network = try container.decodeIfPresent([PluginNetworkHost].self, forKey: .network) ?? []
        if let sites = try container.decodeIfPresent([MatchPattern].self, forKey: .sites) {
            self.init(permissions: permissions, sites: sites, network: network)
        } else {
            self.init(permissions: permissions, sites: try container.decode([MatchPattern].self, forKey: .sitesWhenInvoked), siteAccess: .whenInvoked, network: network)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(sites, forKey: siteAccess == .whenInvoked ? .sitesWhenInvoked : .sites)
        if !network.isEmpty { try container.encode(network, forKey: .network) }
    }
}
