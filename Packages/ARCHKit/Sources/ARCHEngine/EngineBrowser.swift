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

/// One cookie as both engines read and write it, apart from each engine's own cookie type.
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

    /// Whether `other` is this cookie with the same contents, whatever the `SameSite` policy of each: the same name, domain, path, value, and flags, and an expiry within a second of this one's, since the stores keep dates with different precision.
    public func hasSameContents(as other: EngineCookie) -> Bool {
        guard name == other.name, value == other.value, domain.lowercased() == other.domain.lowercased(), path == other.path,
              isSecure == other.isSecure, isHTTPOnly == other.isHTTPOnly else { return false }
        switch (expires, other.expires) {
        case (nil, nil): return true
        case let (date?, otherDate?): return abs(date.timeIntervalSince(otherDate)) < 1
        default: return false
        }
    }
}

/// The web contents of one browser context in one engine. Creates web contents, which restore a page's state from their configuration. Manages cookies.
public protocol EngineBrowser: AnyObject {
    func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents
    func takeOwnership(of webContents: any EngineWebContents)
    /// Releases a tab after the user interface closes it so the engine can tear it down.
    func closeWebContents(_ webContents: any EngineWebContents)
    /// Closes every web contents this browser owns as `closeWebContents` does, without asking their pages, as when the browser's profile goes.
    func closeAllWebContents()

    func allCookies(completion: @escaping ([EngineCookie]) -> Void)
    /// Stores the cookies, each for its own domain, and calls `completion` on the main thread once all are stored.
    func setCookies(_ cookies: [EngineCookie], completion: @escaping () -> Void)
    /// Deletes every cookie `shouldRemove` accepts and calls `completion` on the main thread once the store has applied the deletions.
    func removeCookies(where shouldRemove: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void)
    /// Removes what the engine stores for each origin besides cookies, such as local storage, IndexedDB, caches, and service workers, and calls `completion` on the main thread once it is gone. An engine that keeps this data by site removes it for each origin's whole site.
    func removeSiteData(for origins: [URL], completion: @escaping () -> Void)
    /// Called after the cookie store changes, when the engine can tell. The Chromium engine cannot.
    var cookiesDidChange: (() -> Void)? { get set }
}
