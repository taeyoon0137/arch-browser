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

    public var version: String { "WebKit \(ProcessInfo.processInfo.operatingSystemVersionString)" }
    public func run() { delegate?.applicationDidInitialize(self) }
    public func tryToTerminate(completion: @escaping (Bool) -> Void) { completion(true) }
    public var availableBrowserContextAttributes: [EngineBrowserContextAttributes] { contexts.values.map(\.attributes) }
    public func createBrowserContext(_ attributes: EngineBrowserContextAttributes, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void) {
        let context = WebKitBrowserContext(attributes: attributes)
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

    init(attributes: EngineBrowserContextAttributes) {
        self.attributes = attributes
        self.dataStore = attributes.type == .incognito ? .nonPersistent() : .default()
    }

    public var id: EngineBrowserContextID { attributes.id }
    public var type: EngineBrowserContextType { attributes.type }
    public var userVisibleName: String { attributes.userVisibleName }
    public var history: any EngineHistory { fatalError("skeleton") }
    public var downloads: any EngineDownloads { fatalError("skeleton") }
    public var extensions: (any EngineExtensions)? { nil }
}

/// Tabs for one window. Cookies use the context's `WKHTTPCookieStore`.
public final class WebKitBrowser: EngineBrowser {
    public let sessionID: String
    public let webKitContext: WebKitBrowserContext
    public weak var window: NSWindow?
    public weak var delegate: (any EngineBrowserDelegate)?
    private var ownedWebContents: [WebKitWebContents] = []

    init(sessionID: String, context: WebKitBrowserContext, delegate: any EngineBrowserDelegate, window: NSWindow?) {
        self.sessionID = sessionID
        self.webKitContext = context
        self.delegate = delegate
        self.window = window
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
        var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path, .originURL: url]
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.isSecure { properties[.secure] = "TRUE" }
        if cookie.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        guard let httpCookie = HTTPCookie(properties: properties) else { return }
        webKitContext.dataStore.httpCookieStore.setCookie(httpCookie)
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

/// One `WKWebView` per tab.
public final class WebKitWebContents: NSObject, EngineWebContents {
    public let engineKind: EngineKind = .webKit
    public let sessionID: String
    public let webView: WKWebView
    public let context: WebKitBrowserContext
    public weak var uiDelegate: (any EngineWebContentsUIDelegate)?
    public weak var navigationDelegate: (any EngineWebContentsNavigationDelegate)?
    public var visibility: EngineWebContentsVisibility = .visible
    public lazy var navigationController: any EngineNavigationController = WebKitNavigationController(webView: webView)
    var bridge: WebKitDelegateBridge?
    var observers: [any EngineWebContentsNavigationObserver] = []

    public init(sessionID: String, context: WebKitBrowserContext, configuration: EngineWebContentsConfiguration) {
        self.sessionID = sessionID
        self.context = context
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = context.dataStore
        self.webView = WKWebView(frame: .zero, configuration: webConfiguration)
        super.init()
        installBridge()
        if let url = configuration.initialURL {
            webView.load(URLRequest(url: url))
        }
    }

    /// For popups (window.open). The configuration WebKit hands over must be used as-is.
    init(sessionID: String, parentConfiguration: WKWebViewConfiguration, context: WebKitBrowserContext) {
        self.sessionID = sessionID
        self.context = context
        self.webView = WKWebView(frame: .zero, configuration: parentConfiguration)
        super.init()
        installBridge()
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
    public func captureFullPage(completion: @escaping (NSImage?) -> Void) { fatalError("skeleton") }
    public func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {
        webView.createPDF { completion($0) }
    }
    public func print() { fatalError("skeleton") }
    public func exitFullscreen() { webView.closeAllMediaPresentations() }
    public func discard() { webView.stopLoading() }
    public func clearSiteDataAndReload() { fatalError("skeleton") }
    public var devTools: (any EngineDevTools)? { nil }
    public var thumbnails: (any EngineThumbnails)? { nil }

    /// Reads the page's declared icon, falls back to `/favicon.ico`, and publishes the result through the UI delegate.
    func refreshFavicon() {
        guard let pageURL = webView.url else { return }
        let script = "(function(){var l=document.querySelector('link[rel~=\"icon\"],link[rel=\"shortcut icon\"],link[rel=\"apple-touch-icon\"]');return l?l.href:null;})()"
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self else { return }
            let declared = (value as? String).flatMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL }
            guard let iconURL = declared ?? FaviconLoader.defaultIconURL(for: pageURL) else { return }
            FaviconLoader.load(iconURL) { [weak self] image in
                guard let self, let image else { return }
                self.favicon = image
                self.uiDelegate?.webContentsDidChangeFavicon(self)
            }
        }
    }
}

public final class WebKitNavigationController: EngineNavigationController {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
    }

    public var backForwardList: any EngineBackForwardList { fatalError("skeleton") }
    public func load(_ request: URLRequest) { webView.load(request) }
    public func reload() { webView.reload() }
    public func reloadWithoutCache() { webView.reloadFromOrigin() }
    public func stop() { webView.stopLoading() }
    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }
    public func go(to item: any EngineBackForwardListItem) { fatalError("skeleton") }
}
