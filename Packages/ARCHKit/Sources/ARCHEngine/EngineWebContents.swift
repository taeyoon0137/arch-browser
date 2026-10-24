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
    /// Page state that an earlier web contents of the same engine reported as `restorableState`. The engine restores it in place of loading `initialURL` when it can.
    public var restorableState: Data?
    public init(initialURL: URL? = nil, initiallyHidden: Bool = false, initiallyMuted: Bool = false, disallowAutoplay: Bool = false,
                disallowContextMenus: Bool = false, disallowDownloads: Bool = false, transparentBackground: Bool = false,
                forcedViewSize: CGSize? = nil, engineOverride: EngineKind? = nil, restorableState: Data? = nil) {
        self.initialURL = initialURL
        self.restorableState = restorableState
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
    /// Loads an earlier or later page from this controller's list. Ignores the current page and items from other lists.
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
    /// The page's state, such as its back-forward list, as opaque data the same engine restores through `EngineWebContentsConfiguration.restorableState`. `nil` when the engine cannot restore it.
    var restorableState: Data? { get }
    /// Whether a media element in the page plays sound that is not muted. Sound from Web Audio, or from media elements outside the document or inside shadow roots, does not count.
    var isAudible: Bool { get }
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
    /// Reads the main frame's visible text, up to `limit` characters, with its address, title, language, and selection. Fields and editable areas are never read. Fails with `EngineReadableContentError.unreadable` when the page has no document a script can read.
    func readableContent(limit: Int, completion: @escaping (Result<EngineReadableContent, Error>) -> Void)
    /// CSS injection for site customizations. WebKit implements it with WKUserContentController.
    func insertStylesheet(_ css: String, identifier: String)
    func removeStylesheet(identifier: String)
    func captureViewport(completion: @escaping (NSImage?) -> Void)
    func captureFullPage(completion: @escaping (NSImage?) -> Void)
    /// Renders the page as a paginated PDF on the system's default paper with the page's print styles, for printing and export.
    func createPDF(completion: @escaping (Result<Data, Error>) -> Void)
    func print()
    func exitFullscreen()
    func discard()
    /// Whether closing this web contents now would stop downloads it started. Only Chromium ties downloads to the page that started them.
    var closingStopsDownloads: Bool { get }
    /// Runs the page's `beforeunload` handlers and reports whether the page agreed to close. An engine that cannot run them reports true at once.
    func tryToClose(completion: @escaping (Bool) -> Void)
    /// Tier 2 capability. nil when the engine does not support it.
    var devTools: (any EngineDevTools)? { get }
    var thumbnails: (any EngineThumbnails)? { get }
}

public protocol EngineThumbnails: AnyObject {
    func requestThumbnail(size: CGSize, completion: @escaping (NSImage?) -> Void)
}

public protocol EngineDevTools: AnyObject {
    var isOpen: Bool { get }
    /// The window the tools show in while they are open, for the app to place beside the page.
    var window: NSWindow? { get }
    /// Whether the app chooses where the tools go. An engine that attaches its tools inside the page's view returns false; its tools have their own docking controls.
    var isPlacedByApp: Bool { get }
    /// Called when the tools open in a window or close.
    var didChangeWindow: (() -> Void)? { get set }
    func open()
    func close()
    func openConsoleView()
    func openInspectView()
    func openNetworkView()
}
