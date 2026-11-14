import Foundation

/// No autofill settings here: passwords, cards, and addresses are handled by Apple Passwords or 1Password.
public struct EnginePreferences: Hashable, Codable, Sendable {
    public var downloadFilePath: URL?
    public var promptForDownloadPath: Bool
    public init(downloadFilePath: URL? = nil, promptForDownloadPath: Bool = false) {
        self.downloadFilePath = downloadFilePath
        self.promptForDownloadPath = promptForDownloadPath
    }
}

/// What the app does for a profile's pages that no tab holds, such as its service workers.
public protocol EngineBrowserContextDelegate: AnyObject {
    /// A service worker of the profile asks for a page in a new window, as `clients.openWindow()` does after a click on its notification. The app opens `url` in a new tab of the profile in the foreground and completes at once with the tab's web contents, before its page loads, or with nil when it opened none.
    func browserContext(_ context: any EngineBrowserContext, openTabWith url: URL, completion: @escaping ((any EngineWebContents)?) -> Void)
}

/// A browser context (profile): downloads, preferences, web extensions, and the permission answers the engine keeps. Browsing history belongs to the `History` module, not to the engines.
public protocol EngineBrowserContext: AnyObject {
    var downloads: any EngineDownloads { get }
    var preferences: EnginePreferences { get set }
    /// Tier 2 capability. nil when the engine does not support it.
    var extensions: (any EngineExtensions)? { get }
    /// Receives the profile's requests that come from no tab. An adapter that sends none, as the WebKit adapter, keeps no delegate.
    var delegate: (any EngineBrowserContextDelegate)? { get set }
    /// Makes the answer the engine itself keeps for `origin` and `type` match the app's: `true` allows, `false` blocks, and `nil` lets the site ask again. An engine that keeps no answers of its own ignores it.
    func setRememberedPermission(_ allowed: Bool?, for type: EnginePermissionType, origin: URL)
}

public extension EngineBrowserContext {
    var delegate: (any EngineBrowserContextDelegate)? {
        get { nil }
        set {}
    }
    func setRememberedPermission(_ allowed: Bool?, for type: EnginePermissionType, origin: URL) {}
}
