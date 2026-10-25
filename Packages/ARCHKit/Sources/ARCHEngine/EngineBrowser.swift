import AppKit
import Foundation

/// The cookie's `SameSite` attribute: whether requests from other sites carry it.
public enum EngineCookieSameSite: String, Hashable, Sendable {
    /// The cookie names no policy. Chromium then treats it as `lax`.
    case unspecified
    /// `SameSite=None`: requests from other sites carry it too.
    case noRestriction
    case lax
    case strict
}

public struct EngineCookie: Hashable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var sameSite: EngineCookieSameSite
    public init(name: String, value: String, domain: String, path: String = "/", expires: Date? = nil, isSecure: Bool = false, isHTTPOnly: Bool = false,
                sameSite: EngineCookieSameSite = .unspecified) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
    }

    /// An address the cookie belongs to, for stores that set cookies by URL.
    public var originURL: URL? {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        var components = URLComponents()
        components.scheme = isSecure ? "https" : "http"
        components.host = host
        components.path = path.isEmpty ? "/" : path
        return components.url
    }
}

public protocol EngineBrowserDelegate: AnyObject {
    func browser(_ browser: any EngineBrowser, didCreateNewWebContents webContents: any EngineWebContents, isActive: Bool)
    func browser(_ browser: any EngineBrowser, didChangeFullscreenState isFullscreen: Bool)
}

/// The web contents of one browser context in one engine. Creates web contents, which restore a page's state from their configuration. Manages cookies.
public protocol EngineBrowser: AnyObject {
    var sessionID: String { get }
    var context: any EngineBrowserContext { get }
    var window: NSWindow? { get set }
    var delegate: (any EngineBrowserDelegate)? { get set }

    func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents
    func takeOwnership(of webContents: any EngineWebContents)
    /// Releases a tab after the user interface closes it so the engine can tear it down.
    func closeWebContents(_ webContents: any EngineWebContents)
    func tryToClose(skipBeforeUnloadHandlers: Bool, completion: @escaping (Bool) -> Void)

    func allCookies(completion: @escaping ([EngineCookie]) -> Void)
    func setCookie(_ cookie: EngineCookie, for url: URL)
    /// Stores the cookies, each for its own domain, and calls `completion` on the main thread once all are stored.
    func setCookies(_ cookies: [EngineCookie], completion: @escaping () -> Void)
    func removeCookie(named name: String, for url: URL)
    /// Deletes every cookie `shouldRemove` accepts and calls `completion` on the main thread once the store has applied the deletions.
    func removeCookies(where shouldRemove: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void)
    /// Removes what the engine stores for each origin besides cookies, such as local storage, IndexedDB, caches, and service workers, and calls `completion` on the main thread once it is gone. An engine that keeps this data by site removes it for each origin's whole site.
    func removeSiteData(for origins: [URL], completion: @escaping () -> Void)
    /// Called after the cookie store changes, when the engine can tell. The Chromium engine cannot.
    var cookiesDidChange: (() -> Void)? { get set }
}

public extension EngineBrowserDelegate {
    func browser(_ browser: any EngineBrowser, didCreateNewWebContents webContents: any EngineWebContents, isActive: Bool) {}
    func browser(_ browser: any EngineBrowser, didChangeFullscreenState isFullscreen: Bool) {}
}
