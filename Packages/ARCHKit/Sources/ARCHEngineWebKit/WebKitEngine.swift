// `WKWebView` adapter for the `ARCHEngine` protocols. This secondary engine prefers Apple APIs.
import AppKit
import ARCHEngine
import Foundation
import WebKit

public final class WebKitEngine: Engine {
    public let kind: EngineKind = .webKit
    public let capabilities: Set<EngineCapability> = [.pdfController, .translation, .pictureInPicture, .sessionRestore, .contentBlocking, .cookies]

    public init() {}

    public func makeApplication(configuration: EngineApplicationConfiguration) throws -> any EngineApplication {
        WebKitApplication(configuration: configuration)
    }
}

public final class WebKitApplication: EngineApplication {
    public let engineKind: EngineKind = .webKit
    public weak var delegate: (any EngineApplicationDelegate)?
    let configuration: EngineApplicationConfiguration
    var contexts: [EngineBrowserContextID: WebKitBrowserContext] = [:]

    init(configuration: EngineApplicationConfiguration) {
        self.configuration = configuration
    }

    private var rendererCrashCount = 0

    public var version: String { "WebKit \(ProcessInfo.processInfo.operatingSystemVersionString)" }
    public func run() { delegate?.applicationDidInitialize(self) }
    public func tryToTerminate(completion: @escaping (Bool) -> Void) { completion(true) }
    public var availableBrowserContextAttributes: [EngineBrowserContextAttributes] { contexts.values.map(\.attributes) }
    public func createBrowserContext(_ attributes: EngineBrowserContextAttributes, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void) {
        let context = WebKitBrowserContext(attributes: attributes)
        context.application = self
        contexts[attributes.id] = context
        completion(.success(context))
    }
    public func loadBrowserContext(_ id: EngineBrowserContextID, type: EngineBrowserContextType, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void) { fatalError("skeleton") }
    public func browserContext(_ id: EngineBrowserContextID, type: EngineBrowserContextType) -> (any EngineBrowserContext)? { contexts[id] }
    public func deleteBrowserContext(_ id: EngineBrowserContextID) throws { contexts[id] = nil }
    public func createBrowser(_ params: EngineBrowserCreateParams, context: any EngineBrowserContext, delegate: any EngineBrowserDelegate, window: NSWindow?) -> any EngineBrowser {
        makeBrowser(sessionID: UUID().uuidString, context: context, delegate: delegate, window: window)
    }
    /// Nothing is persisted yet, so restoring yields an empty browser with the same session identifier.
    public func restoreBrowser(context: any EngineBrowserContext, sessionID: String, delegate: any EngineBrowserDelegate, completion: @escaping (any EngineBrowser) -> Void) {
        completion(makeBrowser(sessionID: sessionID, context: context, delegate: delegate, window: nil))
    }
    private func makeBrowser(sessionID: String, context: any EngineBrowserContext, delegate: any EngineBrowserDelegate, window: NSWindow?) -> WebKitBrowser {
        guard let context = context as? WebKitBrowserContext else {
            preconditionFailure("WebKit browsers require a WebKit browser context")
        }
        let browser = WebKitBrowser(sessionID: sessionID, context: context, delegate: delegate, window: window)
        self.delegate?.application(self, didCreateBrowser: browser)
        return browser
    }
    /// Counts web content process terminations across all tabs and reports the total.
    func rendererDidCrash() {
        rendererCrashCount += 1
        delegate?.application(self, didReceiveRendererProcessCrash: rendererCrashCount)
    }
    /// Conversion from EasyList-format lists to `WKContentRuleList` is not implemented.
    public func setBlockLists(_ lists: [URL]) { fatalError("skeleton") }
    public func setExcludedDomains(_ domains: [String]) { fatalError("skeleton") }
}

/// One profile. `WKWebsiteDataStore` owns cookies and cache. History needs a separate store, which is not implemented.
public final class WebKitBrowserContext: EngineBrowserContext {
    public let attributes: EngineBrowserContextAttributes
    public weak var delegate: (any EngineBrowserContextDelegate)?
    public var preferences = EnginePreferences()
    public let dataStore: WKWebsiteDataStore
    weak var application: WebKitApplication?
    lazy var webKitDownloads = WebKitDownloads(context: self)

    init(attributes: EngineBrowserContextAttributes) {
        self.attributes = attributes
        self.dataStore = attributes.type == .incognito ? .nonPersistent() : .default()
    }

    public var id: EngineBrowserContextID { attributes.id }
    public var type: EngineBrowserContextType { attributes.type }
    public var userVisibleName: String { attributes.userVisibleName }
    public var history: any EngineHistory { fatalError("skeleton") }
    public var downloads: any EngineDownloads { webKitDownloads }
    public var extensions: (any EngineExtensions)? { nil }
}

/// Tabs for one window. Cookies use the context's `WKHTTPCookieStore`.
public final class WebKitBrowser: EngineBrowser {
    public let sessionID: String
    public let webKitContext: WebKitBrowserContext
    public weak var window: NSWindow?
    public weak var delegate: (any EngineBrowserDelegate)?
    private var ownedWebContents: [WebKitWebContents] = []
    private let cookieObserver = CookieObserver()
    public var cookiesDidChange: (() -> Void)? {
        get { cookieObserver.handler }
        set { cookieObserver.handler = newValue }
    }

    init(sessionID: String, context: WebKitBrowserContext, delegate: any EngineBrowserDelegate, window: NSWindow?) {
        self.sessionID = sessionID
        self.webKitContext = context
        self.delegate = delegate
        self.window = window
        context.dataStore.httpCookieStore.add(cookieObserver)
    }

    deinit {
        webKitContext.dataStore.httpCookieStore.remove(cookieObserver)
    }

    public var context: any EngineBrowserContext { webKitContext }

    public func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents {
        let webContents = WebKitWebContents(sessionID: UUID().uuidString, context: webKitContext, configuration: configuration)
        ownedWebContents.append(webContents)
        return webContents
    }
    public func canRestoreWebContents(sessionID: String) -> Bool { false }
    public func restoreWebContents(sessionID: String) -> (any EngineWebContents)? { nil }
    public func takeOwnership(of webContents: any EngineWebContents) {
        guard let webContents = webContents as? WebKitWebContents, !ownedWebContents.contains(where: { $0 === webContents }) else { return }
        ownedWebContents.append(webContents)
    }
    public func closeWebContents(_ webContents: any EngineWebContents) {
        guard let index = ownedWebContents.firstIndex(where: { $0 === (webContents as AnyObject) }) else { return }
        let closing = ownedWebContents.remove(at: index)
        closing.webView.stopLoading()
        closing.webView.removeFromSuperview()
    }
    public func tryToClose(skipBeforeUnloadHandlers: Bool, completion: @escaping (Bool) -> Void) {
        ownedWebContents.removeAll()
        completion(true)
    }

    public func allCookies(completion: @escaping ([EngineCookie]) -> Void) {
        webKitContext.dataStore.httpCookieStore.getAllCookies { cookies in
            completion(cookies.map { EngineCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate, isSecure: $0.isSecure, isHTTPOnly: $0.isHTTPOnly) })
        }
    }
    public func setCookie(_ cookie: EngineCookie, for url: URL) {
        guard let httpCookie = Self.httpCookie(cookie, for: url) else { return }
        webKitContext.dataStore.httpCookieStore.setCookie(httpCookie)
    }
    public func setCookies(_ cookies: [EngineCookie], completion: @escaping () -> Void) {
        let store = webKitContext.dataStore.httpCookieStore
        let group = DispatchGroup()
        for cookie in cookies {
            guard let url = cookie.originURL, let httpCookie = Self.httpCookie(cookie, for: url) else { continue }
            group.enter()
            store.setCookie(httpCookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }
    private static func httpCookie(_ cookie: EngineCookie, for url: URL) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path, .originURL: url]
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.isSecure { properties[.secure] = "TRUE" }
        if cookie.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
    public func removeCookie(named name: String, for url: URL) {
        let store = webKitContext.dataStore.httpCookieStore
        store.getAllCookies { cookies in
            let host = url.host ?? ""
            for cookie in cookies where cookie.name == name {
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                if (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path) {
                    store.delete(cookie)
                }
            }
        }
    }
}

/// Forwards the cookie store's change reports. The store keeps its observers weakly, so the browser holds this one.
final class CookieObserver: NSObject, WKHTTPCookieStoreObserver {
    var handler: (() -> Void)?

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        DispatchQueue.main.async { [weak self] in self?.handler?() }
    }
}

/// One `WKWebView` per tab.
public final class WebKitWebContents: NSObject, EngineWebContents {
    public let engineKind: EngineKind = .webKit
    public let sessionID: String
    public let webView: WKWebView
    public let context: WebKitBrowserContext
    public weak var uiDelegate: (any EngineWebContentsUIDelegate)?
    public weak var navigationDelegate: (any EngineWebContentsNavigationDelegate)?
    public var visibility: EngineWebContentsVisibility = .visible
    public lazy var navigationController: any EngineNavigationController = WebKitNavigationController(webView: webView, contents: self)
    let allowsDownloads: Bool
    var bridge: WebKitDelegateBridge?
    var observers: [any EngineWebContentsNavigationObserver] = []
    /// Gives the dialog the page waits on its safe answer. Set while an `alert`, `confirm`, or `prompt` dialog is open.
    private var dismissPendingDialog: (() -> Void)?
    /// Set from a dismissed dialog until the navigation the user started finishes loading, so the page cannot hold that navigation with another dialog.
    private(set) var suppressesDialogs = false

    /// Version and engine tokens a full browser on this system adds to its user agent. `WKWebView` omits them, so some sites send pages for old browsers. The system's WebKit uses the system's version number.
    static let applicationNameForUserAgent: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(version.majorVersion).\(version.minorVersion) Safari/605.1.15"
    }()

    public init(sessionID: String, context: WebKitBrowserContext, configuration: EngineWebContentsConfiguration) {
        self.sessionID = sessionID
        self.context = context
        self.allowsDownloads = !configuration.disallowDownloads
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = context.dataStore
        webConfiguration.applicationNameForUserAgent = Self.applicationNameForUserAgent
        self.webView = WebKitWebView(frame: .zero, configuration: webConfiguration)
        super.init()
        installBridge()
        installContextMenu()
        if let url = configuration.initialURL {
            webView.load(URLRequest(url: url))
        }
    }

    /// For popups (window.open). The configuration WebKit hands over must be used as-is.
    init(sessionID: String, parentConfiguration: WKWebViewConfiguration, context: WebKitBrowserContext) {
        self.sessionID = sessionID
        self.context = context
        self.allowsDownloads = true
        self.webView = WebKitWebView(frame: .zero, configuration: parentConfiguration)
        super.init()
        installBridge()
        installContextMenu()
    }

    public var view: NSView { webView }
    public var url: URL? { webView.url }
    public var title: String { webView.title ?? "" }
    public private(set) var favicon: NSImage?
    public var isLoading: Bool { webView.isLoading }
    public var loadProgress: Double { webView.estimatedProgress }
    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }
    public var themeColor: NSColor? { webView.themeColor }
    public var selectedText: String? { nil }
    public var zoomFactor: Double {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }
    public var isFullscreen: Bool { webView.fullscreenState == .inFullscreen }
    public var mediaSession: any EngineMediaSession { fatalError("skeleton") }
    public func addNavigationObserver(_ observer: any EngineWebContentsNavigationObserver) {
        observers.append(observer)
    }
    public func removeNavigationObserver(_ observer: any EngineWebContentsNavigationObserver) {
        observers.removeAll { $0 === observer }
    }

    public func find(_ text: String, forward: Bool, matchCase: Bool, completion: @escaping (EngineFindResult) -> Void) {
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = matchCase
        webView.find(text, configuration: configuration) { result in
            completion(EngineFindResult(activeMatchOrdinal: result.matchFound ? 1 : 0, numberOfMatches: result.matchFound ? 1 : 0))
        }
    }
    public func stopFind() {}
    public func executeJavaScript(_ script: String, completion: @escaping (Result<Any?, Error>) -> Void) {
        webView.evaluateJavaScript(script) { value, error in
            completion(error.map { .failure($0) } ?? .success(value))
        }
    }
    /// Injects CSS for site customization by inserting a `<style>` element through `WKUserScript`.
    public func insertStylesheet(_ css: String, identifier: String) {
        let escaped = css.replacingOccurrences(of: "`", with: "\\`")
        let source = "(function(){var s=document.getElementById('arch-style-\(identifier)');if(!s){s=document.createElement('style');s.id='arch-style-\(identifier)';document.documentElement.appendChild(s);}s.textContent=`\(escaped)`;})();"
        webView.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        webView.evaluateJavaScript(source)
    }
    public func removeStylesheet(identifier: String) {
        webView.evaluateJavaScript("document.getElementById('arch-style-\(identifier)')?.remove();")
    }
    public func captureViewport(completion: @escaping (NSImage?) -> Void) {
        webView.takeSnapshot(with: nil) { image, _ in completion(image) }
    }
    /// Measures the document, then snapshots it in full from its top-left corner instead of the current scroll position.
    public func captureFullPage(completion: @escaping (NSImage?) -> Void) {
        let script = "[document.documentElement.scrollWidth, document.documentElement.scrollHeight, window.scrollX, window.scrollY]"
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let metrics = value as? [Double], metrics.count == 4 else { return completion(nil) }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: -metrics[2], y: -metrics[3], width: metrics[0], height: metrics[1])
            self.webView.takeSnapshot(with: configuration) { image, _ in completion(image) }
        }
    }
    public func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {
        webView.createPDF { completion($0) }
    }
    /// Runs the system print panel. The operation's view has no initial size, so it takes the page's bounds first.
    public func print() {
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
    public func exitFullscreen() { webView.closeAllMediaPresentations() }
    public func discard() { webView.stopLoading() }
    /// A `WKDownload` continues after its web view closes.
    public var closingStopsDownloads: Bool { false }
    /// WebKit has no public way to run `beforeunload` handlers.
    public func tryToClose(completion: @escaping (Bool) -> Void) { completion(true) }
    public func clearSiteDataAndReload() { fatalError("skeleton") }
    public var devTools: (any EngineDevTools)? { nil }
    public var thumbnails: (any EngineThumbnails)? { nil }

    /// Clears the previous icon, then reads the page's declared icon or `/favicon.ico` as a fallback and sends the result to the UI delegate.
    func refreshFavicon() {
        guard let pageURL = webView.url else { return }
        if favicon != nil {
            favicon = nil
            uiDelegate?.webContentsDidChangeFavicon(self)
        }
        let script = "(function(){var l=document.querySelector('link[rel~=\"icon\"],link[rel=\"shortcut icon\"],link[rel=\"apple-touch-icon\"]');return l?l.href:null;})()"
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self else { return }
            let declared = (value as? String).flatMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL }
            guard let iconURL = declared ?? FaviconLoader.defaultIconURL(for: pageURL) else { return }
            FaviconLoader.load(iconURL) { [weak self] image in
                // Ignore icons received after the tab navigates to another page.
                guard let self, let image, self.webView.url == pageURL else { return }
                self.favicon = image
                self.uiDelegate?.webContentsDidChangeFavicon(self)
            }
        }
    }
}

extension WebKitWebContents {
    /// Wraps a dialog's completion so that it runs once, from the sheet or from a navigation the user starts, whichever comes first.
    func trackDialog<Answer>(safeAnswer: Answer, completion: @escaping (Answer) -> Void) -> (Answer) -> Void {
        var answered = false
        let answer: (Answer) -> Void = { [weak self] value in
            guard !answered else { return }
            answered = true
            self?.dismissPendingDialog = nil
            completion(value)
        }
        dismissPendingDialog = { answer(safeAnswer) }
        return answer
    }

    /// The page stops while its dialog waits, so a navigation the user starts would not begin. Dismiss the dialog first, as on the Chromium engine.
    func dismissDialogBeforeNavigation() {
        guard let dismiss = dismissPendingDialog else { return }
        suppressesDialogs = true
        dismiss()
        uiDelegate?.webContentsDidCancelDialogs(self)
    }

    func loadingStateDidChange() {
        if !webView.isLoading {
            suppressesDialogs = false
        }
        uiDelegate?.webContentsDidChangeLoadingState(self)
    }
}

public final class WebKitNavigationController: EngineNavigationController {
    let webView: WKWebView
    private weak var contents: WebKitWebContents?

    init(webView: WKWebView, contents: WebKitWebContents) {
        self.webView = webView
        self.contents = contents
    }

    public lazy var backForwardList: any EngineBackForwardList = WebKitBackForwardList(webView: webView)
    public func load(_ request: URLRequest) {
        contents?.dismissDialogBeforeNavigation()
        webView.load(request)
    }
    public func reload() {
        contents?.dismissDialogBeforeNavigation()
        webView.reload()
    }
    public func reloadWithoutCache() {
        contents?.dismissDialogBeforeNavigation()
        webView.reloadFromOrigin()
    }
    public func stop() { webView.stopLoading() }
    // Without an entry nothing loads, and the dialog would stay suppressed until another load ends.
    public func goBack() {
        guard webView.canGoBack else { return }
        contents?.dismissDialogBeforeNavigation()
        webView.goBack()
    }
    public func goForward() {
        guard webView.canGoForward else { return }
        contents?.dismissDialogBeforeNavigation()
        webView.goForward()
    }
    // WebKit loads any item, even one from another web view's list.
    public func go(to item: any EngineBackForwardListItem) {
        guard let item = (item as? WebKitBackForwardListItem)?.item,
              webView.backForwardList.backList.contains(item) || webView.backForwardList.forwardList.contains(item) else { return }
        contents?.dismissDialogBeforeNavigation()
        webView.go(to: item)
    }
}

/// Reads the live `WKBackForwardList` on every access.
final class WebKitBackForwardList: EngineBackForwardList {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
    }

    var backList: [any EngineBackForwardListItem] { webView.backForwardList.backList.map(WebKitBackForwardListItem.init) }
    var forwardList: [any EngineBackForwardListItem] { webView.backForwardList.forwardList.map(WebKitBackForwardListItem.init) }
    var currentItem: (any EngineBackForwardListItem)? { webView.backForwardList.currentItem.map(WebKitBackForwardListItem.init) }
}

/// Wraps a `WKBackForwardListItem` in the engine item protocol. `go(to:)` unwraps it.
final class WebKitBackForwardListItem: EngineBackForwardListItem {
    let item: WKBackForwardListItem

    init(_ item: WKBackForwardListItem) {
        self.item = item
    }

    var url: URL { item.url }
    var title: String { item.title ?? "" }
}
