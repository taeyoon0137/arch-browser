import AppKit
import Foundation

public struct EngineWebContentsConfiguration: Sendable {
    public var initialURL: URL?
    public var initiallyHidden: Bool
    public var initiallyMuted: Bool
    public var disallowAutoplay: Bool
    public var disallowContextMenus: Bool
    public var disallowDownloads: Bool
    public var transparentBackground: Bool
    public var forcedViewSize: CGSize?
    /// Per-tab engine selection. nil uses the profile default.
    public var engineOverride: EngineKind?
    public init(initialURL: URL? = nil, initiallyHidden: Bool = false, initiallyMuted: Bool = false, disallowAutoplay: Bool = false,
                disallowContextMenus: Bool = false, disallowDownloads: Bool = false, transparentBackground: Bool = false,
                forcedViewSize: CGSize? = nil, engineOverride: EngineKind? = nil) {
        self.initialURL = initialURL
        self.initiallyHidden = initiallyHidden
        self.initiallyMuted = initiallyMuted
        self.disallowAutoplay = disallowAutoplay
        self.disallowContextMenus = disallowContextMenus
        self.disallowDownloads = disallowDownloads
        self.transparentBackground = transparentBackground
        self.forcedViewSize = forcedViewSize
        self.engineOverride = engineOverride
    }
}

public enum EngineWebContentsVisibility: String, Codable, Sendable {
    case visible
    case hidden
    case occluded
}

public struct EngineFindResult: Hashable, Sendable {
    public var activeMatchOrdinal: Int
    public var numberOfMatches: Int
    public init(activeMatchOrdinal: Int, numberOfMatches: Int) {
        self.activeMatchOrdinal = activeMatchOrdinal
        self.numberOfMatches = numberOfMatches
    }
}

public protocol EngineBackForwardListItem: AnyObject {
    var url: URL { get }
    var title: String { get }
}

public protocol EngineBackForwardList: AnyObject {
    var backList: [any EngineBackForwardListItem] { get }
    var forwardList: [any EngineBackForwardListItem] { get }
    var currentItem: (any EngineBackForwardListItem)? { get }
}

public protocol EngineNavigationController: AnyObject {
    var backForwardList: any EngineBackForwardList { get }
    func load(_ request: URLRequest)
    func reload()
    func reloadWithoutCache()
    func stop()
    func goBack()
    func goForward()
    /// Loads an earlier or later page from this controller's own list. Nothing happens for the current page or an item from another list.
    func go(to item: any EngineBackForwardListItem)
}

/// One tab: state, navigation, find, script and style injection, capture, and media.
public protocol EngineWebContents: AnyObject {
    var engineKind: EngineKind { get }
    var sessionID: String { get }
    var view: NSView { get }

    var url: URL? { get }
    var title: String { get }
    var favicon: NSImage? { get }
    var isLoading: Bool { get }
    var loadProgress: Double { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var themeColor: NSColor? { get }
    var selectedText: String? { get }
    var zoomFactor: Double { get set }
    var visibility: EngineWebContentsVisibility { get set }
    var isFullscreen: Bool { get }

    var navigationController: any EngineNavigationController { get }
    var mediaSession: any EngineMediaSession { get }
    var uiDelegate: (any EngineWebContentsUIDelegate)? { get set }
    var navigationDelegate: (any EngineWebContentsNavigationDelegate)? { get set }
    func addNavigationObserver(_ observer: any EngineWebContentsNavigationObserver)
    func removeNavigationObserver(_ observer: any EngineWebContentsNavigationObserver)

    func find(_ text: String, forward: Bool, matchCase: Bool, completion: @escaping (EngineFindResult) -> Void)
    func stopFind()
    func executeJavaScript(_ script: String, completion: @escaping (Result<Any?, Error>) -> Void)
    /// CSS injection for site customizations. WebKit implements it with WKUserContentController.
    func insertStylesheet(_ css: String, identifier: String)
    func removeStylesheet(identifier: String)
    func captureViewport(completion: @escaping (NSImage?) -> Void)
    func captureFullPage(completion: @escaping (NSImage?) -> Void)
    func createPDF(completion: @escaping (Result<Data, Error>) -> Void)
    func print()
    func exitFullscreen()
    func discard()
    /// Whether closing this web contents now would stop downloads it started. Only Chromium ties downloads to the page that started them.
    var closingStopsDownloads: Bool { get }
    /// Runs the page's `beforeunload` handlers and reports whether the page agreed to close. An engine that cannot run them reports true at once.
    func tryToClose(completion: @escaping (Bool) -> Void)
    func clearSiteDataAndReload()
    /// Tier 2 capability. nil when the engine does not support it.
    var devTools: (any EngineDevTools)? { get }
    var thumbnails: (any EngineThumbnails)? { get }
}

public protocol EngineThumbnails: AnyObject {
    func requestThumbnail(size: CGSize, completion: @escaping (NSImage?) -> Void)
}

public protocol EngineDevTools: AnyObject {
    var isOpen: Bool { get }
    func open()
    func close()
    func openConsoleView()
    func openInspectView()
    func openNetworkView()
}
