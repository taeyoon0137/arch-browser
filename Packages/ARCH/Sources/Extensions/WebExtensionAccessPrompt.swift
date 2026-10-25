// The question that a web extension's request for more access asks, such as an optional permission or a site it requests with `permissions.request`: a sheet that names the extension, and for a version of a pair that version, states the access in the sentences of the install sheet, and Touch ID or the login password for access to every website, as at install. Native messaging is never granted here, since only the install grants it.
import AppKit
import ARCHEngine
import LocalAuthentication
import Plugins

struct WebExtensionAccessPrompt {
    /// The access the prompt asks about: what the extension requested, except native messaging, which the runtime relays for the install's grant only, and sites and pages other than web pages, which Arch never grants.
    let access: Set<EngineExtensionAccess>
    /// The plugin's name, for a version of a pair the pair's.
    let extensionName: String
    /// The engine of the version that asks, for a version of a pair, whose grant alone the answer extends.
    let version: EngineKind?

    init(requested: Set<EngineExtensionAccess>, extensionName: String, version: EngineKind? = nil) {
        access = requested.filter { item in
            switch item {
            case let .permission(name): return WebExtensionManifest.mappedPermissions[name] != .nativeMessaging
            case let .site(pattern): return (try? MatchPattern(pattern)) != nil
            case let .page(url): return ["http", "https"].contains(url.scheme?.lowercased()) && url.host()?.isEmpty == false
            }
        }
        self.extensionName = extensionName
        self.version = version
    }

    /// The permissions, by the names manifests give them, in a fixed order.
    private var permissions: [String] {
        access.compactMap { if case let .permission(name) = $0 { return name } else { return nil } }.sorted()
    }

    /// The sites, in a fixed order.
    private var sites: [MatchPattern] {
        access.compactMap { if case let .site(pattern) = $0 { return try? MatchPattern(pattern) } else { return nil } }.sorted { $0.description < $1.description }
    }

    /// The access as a plugin grant, whose rule says what the user confirms. Single pages never need confirming.
    var grant: PluginGrant {
        PluginGrant(permissions: Set(permissions.compactMap { WebExtensionManifest.mappedPermissions[$0] }), sites: sites)
    }

    /// One sentence for each permission, then each site and page, in a fixed order.
    var sentences: [String] {
        let pages = Set(access.compactMap { if case let .page(url) = $0 { return url.host() } else { return nil } }).sorted()
        return permissions.map { name in WebExtensionManifest.mappedPermissions[name]?.summary ?? "Use the extension API \(name)" }
            + sites.map(\.accessSummary) + pages.map { "Run scripts on pages from \($0)" }
    }

    /// Allow, then Don't Allow, under a title that names the version of a pair that asks, such as "Allow the Chromium version of “Reader” more access?". What the user allows lasts while the extension stays loaded.
    func alert() -> NSAlert {
        let alert = NSAlert()
        let name = "\u{201C}\(extensionName)\u{201D}"
        alert.messageText = "Allow \(version.map { "the \($0.displayName) version of \(name)" } ?? name) more access?"
        let keeper = version.map { "Only the \($0.displayName) version gets this access. It keeps it" } ?? "The extension keeps this access"
        alert.informativeText = sentences.joined(separator: "\n") + "\n\n\(keeper) until you quit Arch or switch the extension off."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don\u{2019}t Allow")
        return alert
    }

    /// True at once for access that needs no confirmation.
    func confirm() async -> Bool {
        guard let reason = grant.confirmationReason(for: extensionName) else { return true }
        return (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
