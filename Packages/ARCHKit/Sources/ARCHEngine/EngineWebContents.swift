import AppKit
import Foundation

/// How a new web contents starts. Its engine is that of the browser that creates it.
public struct EngineWebContentsConfiguration: Sendable {
    public var initialURL: URL?
    /// Page state that an earlier web contents of the same engine reported as `restorableState`. The engine restores it in place of loading `initialURL` when it can.
    public var restorableState: Data?
    /// The scripts that run in each new document, from the first one on. A web contents a page opens starts with its opener's scripts.
    public var pageScripts: [EnginePageScript]
    public init(initialURL: URL? = nil, restorableState: Data? = nil, pageScripts: [EnginePageScript] = []) {
        self.initialURL = initialURL
        self.restorableState = restorableState
        self.pageScripts = pageScripts
    }
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
    /// The earlier pages, oldest first.
    var backList: [any EngineBackForwardListItem] { get }
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

/// One tab: state, navigation, find, page scripts, capture, and media.
public protocol EngineWebContents: AnyObject {
    var engineKind: EngineKind { get }
    var view: NSView { get }

    var url: URL? { get }
    var title: String { get }
    var favicon: NSImage? { get }
    var isLoading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    /// The page's state, such as its back-forward list, as opaque data the same engine restores through `EngineWebContentsConfiguration.restorableState`. `nil` when the engine cannot restore it.
    var restorableState: Data? { get }
    /// Whether a media element in the page plays sound that is not muted. Sound from Web Audio, or from media elements outside the document or inside shadow roots, does not count.
    var isAudible: Bool { get }
    var zoomFactor: Double { get set }

    var navigationController: any EngineNavigationController { get }
    var mediaSession: any EngineMediaSession { get }
    var uiDelegate: (any EngineWebContentsUIDelegate)? { get set }
    var navigationDelegate: (any EngineWebContentsNavigationDelegate)? { get set }

    func find(_ text: String, forward: Bool, matchCase: Bool, completion: @escaping (EngineFindResult) -> Void)
    func stopFind()
    /// Receives what the page scripts send.
    var pageScriptDelegate: (any EnginePageScriptDelegate)? { get set }
    /// Replaces the scripts that run in each new document, from the next document on. On WebKit, a web contents and those its pages open share one set, so replacing it in one replaces it in all.
    func setPageScripts(_ scripts: [EnginePageScript])
    /// Calls a JavaScript function expression, such as `(channel) => …`, with the channel of `world` in the main frame's current document, opening one there if the world has none, and passes the string the function returns, or nil for any other value. Fails when the function throws or the main frame has no document to run it in.
    func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void)
    /// Delivers a value, as JSON text, to the listeners of a world's channel in the main frame's current document. Nothing happens without them.
    func postPageScriptMessage(_ json: String, toWorld world: String)
    /// Reads the main frame's visible text, up to `limit` characters, with its address, title, language, and selection. Fields and editable areas are never read. Fails with `EngineReadableContentError.unreadable` when the page has no document a script can read.
    func readableContent(limit: Int, completion: @escaping (Result<EngineReadableContent, Error>) -> Void)
    func captureViewport(completion: @escaping (NSImage?) -> Void)
    func captureFullPage(completion: @escaping (NSImage?) -> Void)
    /// Renders the page as a paginated PDF on the system's default paper with the page's print styles, for printing and export.
    func createPDF(completion: @escaping (Result<Data, Error>) -> Void)
    /// Ends the page's fullscreen. WebKit ends the page's other media presentations with it, picture in picture included.
    func exitFullscreen()
    /// Whether closing this web contents now would stop downloads it started. Only Chromium ties downloads to the page that started them.
    var closingStopsDownloads: Bool { get }
    /// Runs the page's `beforeunload` handlers and reports whether the page agreed to close. An engine that cannot run them reports true at once.
    func tryToClose(completion: @escaping (Bool) -> Void)
    /// Tier 2 capability. nil when the engine does not support it.
    var devTools: (any EngineDevTools)? { get }
}

public protocol EngineDevTools: AnyObject {
    var isOpen: Bool { get }
    /// The view the tools fill while they are open, for the app to place beside the page or in a window of its own.
    var view: NSView? { get }
    /// Whether the app chooses where the tools go. An engine that attaches its tools inside the page's view returns false; its tools have their own docking controls.
    var isPlacedByApp: Bool { get }
    /// Called when the tools open in a view or close.
    var didChangeView: (() -> Void)? { get set }
    func open()
    func close()
}
