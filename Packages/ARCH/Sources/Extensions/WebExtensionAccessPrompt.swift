// The question that a web extension's request for more access asks, such as an optional permission or a site it requests with `permissions.request`: a sheet that names the extension, and for a version of a pair that version, states the access in the sentences of the install sheet, and Touch ID or the login password for access to every website, as at install. Native messaging is never granted here, since only the install grants it. The engines' own questions, in their own sentences, ask with sheets of the same kind.
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
        await WebExtensionEnginePrompt.confirm(grant, extensionName: extensionName)
    }
}

/// The questions that an engine's extension runtime asks in its own words: more access that Chromium describes in its sentences, which do not say which permissions or sites they stand for, and a reload of a tab so that the extensions it kept from running there run.
enum WebExtensionEnginePrompt {
    /// Allow, then Don't Allow, under a title that names the version of a pair that asks. The engine keeps what the user allows until the extension's storage goes, as Chromium keeps the permissions it grants at run time.
    static func permissionsAlert(messages: [String], extensionName: String, version: EngineKind?, engine: EngineKind) -> NSAlert {
        let alert = NSAlert()
        let name = "\u{201C}\(extensionName)\u{201D}"
        alert.messageText = "Allow \(version.map { "the \($0.displayName) version of \(name)" } ?? name) more access?"
        let keeper = version.map { "Only the \($0.displayName) version gets this access." } ?? "The extension gets this access on \(engine.displayName) tabs."
        alert.informativeText = (messages.isEmpty ? "" : messages.joined(separator: "\n") + "\n\n")
            + "\(keeper) \(engine.displayName) keeps it until you remove the extension."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don\u{2019}t Allow")
        return alert
    }

    /// Reload, then Cancel, naming the extensions that run on the page once it loads again.
    static func reloadAlert(names: [String]) -> NSAlert {
        let alert = NSAlert()
        let list = names.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        alert.messageText = "Reload This Page?"
        alert.informativeText = "\(list.isEmpty ? "The extension" : list) can run on this page once it loads again."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// Touch ID or the login password for a grant whose rule needs it, true at once otherwise.
    static func confirm(_ grant: PluginGrant, extensionName: String) async -> Bool {
        guard let reason = grant.confirmationReason(for: extensionName) else { return true }
        return (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
