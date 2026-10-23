import AppKit
import Foundation

public struct EngineCookie: Hashable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public init(name: String, value: String, domain: String, path: String = "/", expires: Date? = nil, isSecure: Bool = false, isHTTPOnly: Bool = false) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }
}

public protocol EngineBrowserDelegate: AnyObject {
    func browser(_ browser: any EngineBrowser, didCreateNewWebContents webContents: any EngineWebContents, isActive: Bool)
    func browser(_ browser: any EngineBrowser, didRestoreWebContents webContents: any EngineWebContents, sessionID: String)
    func browser(_ browser: any EngineBrowser, didChangeFullscreenState isFullscreen: Bool)
}

/// Window-level container: creates and restores web contents and manages cookies.
public protocol EngineBrowser: AnyObject {
    var sessionID: String { get }
    var context: any EngineBrowserContext { get }
    var window: NSWindow? { get set }
    var delegate: (any EngineBrowserDelegate)? { get set }

    func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents
    func canRestoreWebContents(sessionID: String) -> Bool
    func restoreWebContents(sessionID: String) -> (any EngineWebContents)?
    func takeOwnership(of webContents: any EngineWebContents)
    func tryToClose(skipBeforeUnloadHandlers: Bool, completion: @escaping (Bool) -> Void)

    func allCookies(completion: @escaping ([EngineCookie]) -> Void)
    func setCookie(_ cookie: EngineCookie, for url: URL)
    func removeCookie(named name: String, for url: URL)
}
