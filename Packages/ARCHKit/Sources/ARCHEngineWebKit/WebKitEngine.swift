// WKWebView adapter for the ARCHEngine protocols. Secondary engine; prefers Apple APIs.
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
    public func createBrowser(_ params: EngineBrowserCreateParams, context: any EngineBrowserContext, delegate: any EngineBrowserDelegate, window: NSWindow?) -> any EngineBrowser { fatalError("skeleton") }
    public func restoreBrowser(context: any EngineBrowserContext, sessionID: String, delegate: any EngineBrowserDelegate, completion: @escaping (any EngineBrowser) -> Void) { fatalError("skeleton") }
    /// Converting EasyList-format lists to WKContentRuleList is not implemented yet.
    public func setBlockLists(_ lists: [URL]) { fatalError("skeleton") }
    public func setExcludedDomains(_ domains: [String]) { fatalError("skeleton") }
}

/// One profile. WKWebsiteDataStore owns cookies and cache; history needs its own store (not implemented).
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

/// One WKWebView per tab.
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
    public var favicon: NSImage? { nil }
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
    /// Site customization CSS injection: inserts a <style> element through WKUserScript.
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
