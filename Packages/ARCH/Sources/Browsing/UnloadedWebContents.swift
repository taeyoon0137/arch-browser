// The stand-in for the page of a tab without one: a tab restored from `session.json` until a window first shows it, and a tab whose page unloaded (`docs/bookmarks.md`, Unloading). It keeps the address, title, engine, and page state of the tab's record or of the page that unloaded, so saving writes the record back unchanged, and it loads nothing, so no engine starts a page, or a renderer, for a tab that no window shows. The session puts the engine's web contents in its place as a window next shows the tab (`BrowserSession.loadPage(of:)`).
import AppKit
import ARCHEngine
import Foundation

/// A tab's web contents while the tab has no page. Every reader of `Tab.webContents` gets an answer without a page: the saved address, title, engine, and state; no loading, history, sound, media, developer tools, or downloads; a close that needs no agreement; a find with no matches; and failures for reading, scripts, captures, and PDF. Navigation waits for the page: reload, stop, Back, and Forward do nothing, and a load replaces the saved page with its address, which the tab loads from the start once a window shows it. Engines pass it by: neither owns it, so closing it closes nothing, and neither lists it to web extensions.
final class UnloadedWebContents: EngineWebContents {
    /// The engine whose page the tab gets.
    let engineKind: EngineKind
    private(set) var url: URL?
    private(set) var title: String
    /// The icon of the page that unloaded, the site's usual icon once `loadSiteIcon()` finds one, or a live folder's icon (`showIcon(_:)`).
    private(set) var favicon: NSImage?
    /// False for a live folder item's tab, whose row shows its folder's icon, so that a folder of links to many sites contacts none of them until the user opens an item (`docs/bookmarks.md`, Items as tabs): `loadSiteIcon()` requests nothing, and a load keeps the icon.
    let requestsSiteIcon: Bool
    /// The engine's saved state, which the page restores when it loads, or nil after a load replaced the saved page.
    private(set) var restorableState: Data?
    /// Kept for the page, which takes its host's remembered zoom once it loads.
    var zoomFactor = 1.0
    weak var uiDelegate: (any EngineWebContentsUIDelegate)?
    weak var navigationDelegate: (any EngineWebContentsNavigationDelegate)?
    weak var pageScriptDelegate: (any EnginePageScriptDelegate)?
    /// An empty view, which no window shows, since a window loads the tab before it shows it.
    lazy var view = NSView()
    lazy var navigationController: any EngineNavigationController = Navigation(page: self)
    let mediaSession: any EngineMediaSession = NoMedia()

    var isLoading: Bool { false }
    var canGoBack: Bool { false }
    var canGoForward: Bool { false }
    var isAudible: Bool { false }
    var isCapturingMedia: Bool { false }
    var isInPictureInPicture: Bool { false }
    var closingStopsDownloads: Bool { false }
    func download(_ url: URL) {}
    var devTools: (any EngineDevTools)? { nil }

    /// `icon` is the icon of the page that unloaded, which the tab's row keeps showing, or a live folder's icon.
    init(url: URL?, title: String, engine: EngineKind, state: Data?, icon: NSImage? = nil, requestsSiteIcon: Bool = true) {
        self.url = url
        self.title = title
        engineKind = engine
        restorableState = state
        favicon = icon
        self.requestsSiteIcon = requestsSiteIcon
    }

    /// The stand-in for the page of a saved tab, as relaunching reopens it: the record's address, title, engine, or `defaultEngine` for a record without one, and page state. A live folder item's stand-in requests no site icon.
    convenience init(record: SessionSnapshot.TabRecord, defaultEngine: EngineKind) {
        self.init(url: record.url, title: record.title, engine: record.engine ?? defaultEngine, state: record.state, requestsSiteIcon: record.liveItemID == nil)
    }

    /// Shows the site's usual icon, its `/favicon.ico`, until the page loads and reports its own, so that the tab's row keeps an icon meanwhile. The icon loads as the engines load theirs, without cookies (`FaviconLoader`). A live folder item's stand-in requests none.
    func loadSiteIcon() {
        guard requestsSiteIcon, let pageURL = url, let iconURL = FaviconLoader.defaultIconURL(for: pageURL) else { return }
        FaviconLoader.load(iconURL) { [weak self] image in
            guard let self, let image, self.url == pageURL else { return }
            self.favicon = image
            self.uiDelegate?.webContentsDidChangeFavicon(self)
        }
    }

    /// Shows a live folder's icon in an item's row until the item's page loads and reports its own.
    func showIcon(_ icon: NSImage) {
        favicon = icon
        uiDelegate?.webContentsDidChangeFavicon(self)
    }

    /// Replaces the saved page with `url`, which the tab then loads from the start, without the saved state, title, or icon. A live folder item's stand-in keeps its folder's icon.
    fileprivate func replacePage(with url: URL?) {
        self.url = url
        title = ""
        if requestsSiteIcon { favicon = nil }
        restorableState = nil
        uiDelegate?.webContentsDidChangeURL(self)
        uiDelegate?.webContentsDidChangeTitle(self)
        uiDelegate?.webContentsDidChangeFavicon(self)
        loadSiteIcon()
    }

    func find(_ text: String, forward: Bool, matchCase: Bool, completion: @escaping (EngineFindResult) -> Void) {
        completion(EngineFindResult(activeMatchOrdinal: 0, numberOfMatches: 0))
    }

    func stopFind() {}

    /// The page starts with the scripts of the moment it is created.
    func setPageScripts(_ scripts: [EnginePageScript]) {}

    func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {
        completion(.failure(UnloadedPageError()))
    }

    func executeJavaScriptWithoutUserGesture(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {
        completion(.failure(UnloadedPageError()))
    }

    func postPageScriptMessage(_ json: String, toWorld world: String) {}

    func readableContent(limit: Int, completion: @escaping (Result<EngineReadableContent, Error>) -> Void) {
        completion(.failure(EngineReadableContentError.unreadable))
    }

    func captureViewport(completion: @escaping (NSImage?) -> Void) { completion(nil) }

    func captureFullPage(completion: @escaping (NSImage?) -> Void) { completion(nil) }

    func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {
        completion(.failure(UnloadedPageError()))
    }

    func exitFullscreen() {}

    /// No page runs `beforeunload` handlers, so the tab closes at once.
    func tryToClose(completion: @escaping (Bool) -> Void) { completion(true) }
}

/// Why a call that needs the page fails while the tab has none.
struct UnloadedPageError: Error {}

/// The navigation of a tab without its page: an empty back list, and only a load, which replaces the saved page.
private final class Navigation: EngineNavigationController, EngineBackForwardList {
    private weak var page: UnloadedWebContents?

    init(page: UnloadedWebContents) {
        self.page = page
    }

    var backForwardList: any EngineBackForwardList { self }
    var backList: [any EngineBackForwardListItem] { [] }

    func load(_ request: URLRequest) { page?.replacePage(with: request.url) }
    func reload() {}
    func reloadWithoutCache() {}
    func stop() {}
    func goBack() {}
    func goForward() {}
    func go(to item: any EngineBackForwardListItem) {}
}

/// No media plays without a page, so Now Playing passes the tab by.
private final class NoMedia: EngineMediaSession {
    weak var delegate: (any EngineMediaSessionDelegate)?
    var playbackState: EngineMediaPlaybackState { .none }
    var position: EngineMediaPosition? { nil }
    var metadata: EngineMediaMetadata? { nil }
    var canGoToNextTrack: Bool { false }
    var canGoToPreviousTrack: Bool { false }
    func play() {}
    func pause() {}
    func nextTrack() {}
    func previousTrack() {}
}
