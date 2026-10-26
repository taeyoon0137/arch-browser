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

/// A browser context (profile): downloads, preferences, web extensions, and the permission answers the engine keeps. Browsing history belongs to the `History` module, not to the engines.
public protocol EngineBrowserContext: AnyObject {
    var downloads: any EngineDownloads { get }
    var preferences: EnginePreferences { get set }
    /// Tier 2 capability. nil when the engine does not support it.
    var extensions: (any EngineExtensions)? { get }
    /// Makes the answer the engine itself keeps for `origin` and `type` match the app's: `true` allows, `false` blocks, and `nil` lets the site ask again. An engine that keeps no answers of its own ignores it.
    func setRememberedPermission(_ allowed: Bool?, for type: EnginePermissionType, origin: URL)
}

public extension EngineBrowserContext {
    func setRememberedPermission(_ allowed: Bool?, for type: EnginePermissionType, origin: URL) {}
}
