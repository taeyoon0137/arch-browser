// Chromium is the primary engine. This adapter implements the `ARCHEngine` protocols using the Chromium Embedded Framework (CEF) through the Objective-C bridge.
import AppKit
import ARCHEngine
import AVFoundation
import CEFBridge
import Foundation

public final class ChromiumEngine: Engine {
    public let kind: EngineKind = .chromium
    public let capabilities: Set<EngineCapability> = [.devTools, .pdfController, .sessionRestore, .cookies]
    let frameworkPath: String
    let helperPath: String?

    /// Returns `nil` if the framework directory is missing, allowing the app to fall back to WebKit.
    public init?(frameworkPath: String, helperPath: String?) {
        guard FileManager.default.fileExists(atPath: frameworkPath) else { return nil }
        self.frameworkPath = frameworkPath
        self.helperPath = helperPath
    }

    public enum StartError: Error {
        case initializationFailed
    }

    public func makeApplication(configuration: EngineApplicationConfiguration) throws -> any EngineApplication {
        let cachePath = configuration.cacheDirectory.appendingPathComponent("Chromium").path
        guard ARCHCEFRuntime.initialize(withFrameworkPath: frameworkPath, helperPath: helperPath, cachePath: cachePath) else {
            throw StartError.initializationFailed
        }
        return ChromiumApplication()
    }
}

public final class ChromiumApplication: EngineApplication {
    public let engineKind: EngineKind = .chromium
    public weak var delegate: (any EngineApplicationDelegate)?
    var contexts: [EngineBrowserContextID: ChromiumBrowserContext] = [:]

    public var version: String { "Chromium (CEF)" }
    public func run() { delegate?.applicationDidInitialize(self) }
    public func tryToTerminate(completion: @escaping (Bool) -> Void) { completion(true) }
    public var availableBrowserContextAttributes: [EngineBrowserContextAttributes] { contexts.values.map(\.attributes) }
    public func createBrowserContext(_ attributes: EngineBrowserContextAttributes, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void) {
        let context = ChromiumBrowserContext(attributes: attributes)
        context.application = self
        contexts[attributes.id] = context
        completion(.success(context))
    }
    private var rendererCrashCount = 0
    /// Counts renderer process exits across all tabs and reports the running total.
    func rendererDidCrash() {
        rendererCrashCount += 1
        delegate?.application(self, didReceiveRendererProcessCrash: rendererCrashCount)
    }
    public func loadBrowserContext(_ id: EngineBrowserContextID, type: EngineBrowserContextType, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void) { fatalError("not implemented") }
    public func browserContext(_ id: EngineBrowserContextID, type: EngineBrowserContextType) -> (any EngineBrowserContext)? { contexts[id] }
    public func deleteBrowserContext(_ id: EngineBrowserContextID) throws { contexts[id] = nil }
    public func createBrowser(_ params: EngineBrowserCreateParams, context: any EngineBrowserContext, delegate: any EngineBrowserDelegate, window: NSWindow?) -> any EngineBrowser {
        let browser = ChromiumBrowser(sessionID: UUID().uuidString, context: context, delegate: delegate, window: window)
        self.delegate?.application(self, didCreateBrowser: browser)
        return browser
    }
    public func restoreBrowser(context: any EngineBrowserContext, sessionID: String, delegate: any EngineBrowserDelegate, completion: @escaping (any EngineBrowser) -> Void) {
        completion(ChromiumBrowser(sessionID: sessionID, context: context, delegate: delegate, window: nil))
    }
    public func setBlockLists(_ lists: [URL]) { fatalError("not implemented") }
    public func setExcludedDomains(_ domains: [String]) { fatalError("not implemented") }
}

/// All regular contexts share a single CEF cache directory until per-profile request contexts are added.
public final class ChromiumBrowserContext: EngineBrowserContext {
    public let attributes: EngineBrowserContextAttributes
    public weak var delegate: (any EngineBrowserContextDelegate)?
    public var preferences = EnginePreferences()
    weak var application: ChromiumApplication?
    let chromiumDownloads = ChromiumDownloads()

    init(attributes: EngineBrowserContextAttributes) {
        self.attributes = attributes
    }

    public var id: EngineBrowserContextID { attributes.id }
    public var type: EngineBrowserContextType { attributes.type }
    public var userVisibleName: String { attributes.userVisibleName }
    public var history: any EngineHistory { fatalError("not implemented") }
    public var downloads: any EngineDownloads { chromiumDownloads }
    public var extensions: (any EngineExtensions)? { nil }
}

public final class ChromiumBrowser: EngineBrowser {
    public let sessionID: String
    public let context: any EngineBrowserContext
    public weak var window: NSWindow?
    public weak var delegate: (any EngineBrowserDelegate)?
    private var ownedWebContents: [ChromiumWebContents] = []

    init(sessionID: String, context: any EngineBrowserContext, delegate: any EngineBrowserDelegate, window: NSWindow?) {
        self.sessionID = sessionID
        self.context = context
        self.delegate = delegate
        self.window = window
    }

    public func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents {
        let webContents = ChromiumWebContents(sessionID: UUID().uuidString, context: context as? ChromiumBrowserContext, configuration: configuration)
        ownedWebContents.append(webContents)
        return webContents
    }
    public func canRestoreWebContents(sessionID: String) -> Bool { false }
    public func restoreWebContents(sessionID: String) -> (any EngineWebContents)? { nil }
    public func takeOwnership(of webContents: any EngineWebContents) {
        guard let webContents = webContents as? ChromiumWebContents, !ownedWebContents.contains(where: { $0 === webContents }) else { return }
        ownedWebContents.append(webContents)
    }
    public func closeWebContents(_ webContents: any EngineWebContents) {
        guard let index = ownedWebContents.firstIndex(where: { $0 === (webContents as AnyObject) }) else { return }
        ownedWebContents.remove(at: index).discard()
    }
    public func tryToClose(skipBeforeUnloadHandlers: Bool, completion: @escaping (Bool) -> Void) {
        ownedWebContents.forEach { $0.discard() }
        ownedWebContents.removeAll()
        completion(true)
    }
    public func allCookies(completion: @escaping ([EngineCookie]) -> Void) { completion([]) }
    public func setCookie(_ cookie: EngineCookie, for url: URL) {}
    public func removeCookie(named name: String, for url: URL) {}
}

/// A single CEF browser embedded in a container view hosted by the user interface.
public final class ChromiumWebContents: NSObject, EngineWebContents {
    public let engineKind: EngineKind = .chromium
    public let sessionID: String
    public let view: NSView
    public weak var uiDelegate: (any EngineWebContentsUIDelegate)?
    public weak var navigationDelegate: (any EngineWebContentsNavigationDelegate)?
    public var visibility: EngineWebContentsVisibility = .visible
    /// Chromium scales the page by 1.2 per zoom level, and level 0 is the default size.
    public var zoomFactor: Double {
        get { browser.map { pow(1.2, $0.zoomLevel) } ?? 1 }
        set { browser?.zoomLevel = log(newValue) / log(1.2) }
    }
    public private(set) var url: URL?
    public private(set) var title = ""
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    private var browser: ARCHCEFBrowser?
    private weak var context: ChromiumBrowserContext?
    private var observers: [any EngineWebContentsNavigationObserver] = []
    private var pendingURL: URL?
    private var findCompletion: ((EngineFindResult) -> Void)?
    private var lastFind: (text: String, matchCase: Bool, forward: Bool)?
    private var lastActiveMatchOrdinal = 0
    private var didSelectFirstMatch = false
    /// The page that last crashed. Skipping a reload after two consecutive crashes on the same page prevents a reload loop.
    private var lastCrashedURL: URL?
    public lazy var navigationController: any EngineNavigationController = ChromiumNavigationController(webContents: self)

    init(sessionID: String, context: ChromiumBrowserContext?, configuration: EngineWebContentsConfiguration) {
        self.sessionID = sessionID
        self.context = context
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.view.wantsLayer = true
        self.url = configuration.initialURL
        super.init()
        browser = ARCHCEFBrowser(parentView: view, url: configuration.initialURL?.absoluteString ?? "about:blank", delegate: self)
        browser?.allowsDownloads = !configuration.disallowDownloads
    }

    public enum PDFError: Error {
        case exportFailed
    }

    public private(set) var favicon: NSImage?
    public var loadProgress: Double { isLoading ? 0.5 : 1 }
    public var themeColor: NSColor? { nil }
    public var selectedText: String? { nil }
    public var isFullscreen: Bool { false }
    public var mediaSession: any EngineMediaSession { fatalError("not implemented") }
    public func addNavigationObserver(_ observer: any EngineWebContentsNavigationObserver) { observers.append(observer) }
    public func removeNavigationObserver(_ observer: any EngineWebContentsNavigationObserver) { observers.removeAll { $0 === observer } }
    public func find(_ text: String, forward: Bool, matchCase: Bool, completion: @escaping (EngineFindResult) -> Void) {
        guard !text.isEmpty else {
            stopFind()
            completion(EngineFindResult(activeMatchOrdinal: 0, numberOfMatches: 0))
            return
        }
        // CEF restarts the search when the text or case sensitivity changes; a repeated request only advances the active match.
        let findNext = lastFind?.text == text && lastFind?.matchCase == matchCase
        lastFind = (text, matchCase, forward)
        if !findNext {
            lastActiveMatchOrdinal = 0
            didSelectFirstMatch = false
        }
        // A request that arrives before the previous final result replaces it, because Chromium cancels the superseded search.
        findCompletion = completion
        browser?.findText(text, forward: forward, matchCase: matchCase, findNext: findNext)
    }
    public func stopFind() {
        findCompletion = nil
        lastFind = nil
        lastActiveMatchOrdinal = 0
        didSelectFirstMatch = false
        browser?.stopFinding()
    }
    public func executeJavaScript(_ script: String, completion: @escaping (Result<Any?, Error>) -> Void) {
        browser?.executeJavaScript(script)
        completion(.success(nil))
    }
    public func insertStylesheet(_ css: String, identifier: String) {
        let escaped = css.replacingOccurrences(of: "`", with: "\\`")
        browser?.executeJavaScript("(function(){var s=document.getElementById('arch-style-\(identifier)');if(!s){s=document.createElement('style');s.id='arch-style-\(identifier)';document.documentElement.appendChild(s);}s.textContent=`\(escaped)`;})();")
    }
    public func removeStylesheet(identifier: String) {
        browser?.executeJavaScript("document.getElementById('arch-style-\(identifier)')?.remove();")
    }
    public func captureViewport(completion: @escaping (NSImage?) -> Void) {
        browser?.captureScreenshot(beyondViewport: false) { completion($0.flatMap(NSImage.init(data:))) }
    }
    public func captureFullPage(completion: @escaping (NSImage?) -> Void) {
        browser?.captureScreenshot(beyondViewport: true) { completion($0.flatMap(NSImage.init(data:))) }
    }
    public func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {
        browser?.printToPDF { completion($0.map { .success($0) } ?? .failure(PDFError.exportFailed)) }
    }
    public func print() { browser?.print() }
    public func exitFullscreen() {}
    public func discard() { browser?.close() }
    public func clearSiteDataAndReload() { browser?.reloadIgnoringCache() }
    public var devTools: (any EngineDevTools)? { nil }
    public var thumbnails: (any EngineThumbnails)? { nil }

    fileprivate func load(_ request: URLRequest) {
        guard let target = request.url else { return }
        browser?.loadURL(target.absoluteString)
    }
    fileprivate func reload() { browser?.reload() }
    fileprivate func reloadWithoutCache() { browser?.reloadIgnoringCache() }
    fileprivate func stop() { browser?.stopLoading() }
    fileprivate func goBack() { browser?.goBack() }
    fileprivate func goForward() { browser?.goForward() }
}

extension ChromiumWebContents: ARCHCEFBrowserDelegate {
    public func cefBrowserDidCreateView() {}
    public func cefBrowserDidChangeTitle(_ title: String) {
        self.title = title
        uiDelegate?.webContentsDidChangeTitle(self)
    }
    public func cefBrowserDidChangeURL(_ url: String) {
        self.url = URL(string: url)
        uiDelegate?.webContentsDidChangeURL(self)
        if favicon != nil {
            favicon = nil
            uiDelegate?.webContentsDidChangeFavicon(self)
        }
    }
    public func cefBrowserDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        uiDelegate?.webContentsDidChangeLoadingState(self)
    }
    public func cefBrowserDidChangeFaviconURLs(_ urls: [String]) {
        guard let iconURL = urls.lazy.compactMap(URL.init(string:)).first ?? url.flatMap(FaviconLoader.defaultIconURL(for:)) else { return }
        let pageURL = url
        FaviconLoader.load(iconURL) { [weak self] image in
            // Ignore icons that finish loading after the tab navigates to another page.
            guard let self, let image, self.url == pageURL else { return }
            self.favicon = image
            self.uiDelegate?.webContentsDidChangeFavicon(self)
        }
    }
    /// Chromium reports the active match and the match count in separate updates, so the last reported ordinal accompanies each final count. A new search can finish with matches but no active match; one follow-up request in the same direction then selects the first match. Every final update reaches the completion until the next search replaces it.
    public func cefBrowserDidFindMatches(_ count: Int, activeMatchOrdinal: Int, finalUpdate: Bool) {
        if activeMatchOrdinal > 0 { lastActiveMatchOrdinal = activeMatchOrdinal }
        guard finalUpdate, let completion = findCompletion else { return }
        if count > 0, lastActiveMatchOrdinal == 0, let lastFind, !didSelectFirstMatch {
            didSelectFirstMatch = true
            browser?.findText(lastFind.text, forward: lastFind.forward, matchCase: lastFind.matchCase, findNext: true)
            return
        }
        completion(EngineFindResult(activeMatchOrdinal: count == 0 ? 0 : lastActiveMatchOrdinal, numberOfMatches: count))
    }
    public func cefBrowserDidRequestPopup(withURL url: String) {
        let popup = ChromiumWebContents(sessionID: UUID().uuidString, context: context, configuration: EngineWebContentsConfiguration(initialURL: URL(string: url)))
        uiDelegate?.webContents(self, didCreateNewWebContents: popup, targetURL: URL(string: url), disposition: .newForegroundTab)
    }
    public func cefBrowserDidClose() {
        uiDelegate?.webContentsDidClose(self)
    }
    public func cefBrowserDidStart(_ download: ARCHCEFDownload, suggestedName: String, decision: @escaping (String?, Bool) -> Void) {
        guard let downloads = context?.chromiumDownloads else { return decision(nil, true) }
        downloads.begin(download, suggestedName: suggestedName, decision: decision)
    }
    public func cefBrowserDidUpdate(_ download: ARCHCEFDownload) {
        context?.chromiumDownloads.update(download)
    }
    /// The UI delegate decides whether to grant the site's request. Camera and microphone access also require the system's permission for this app, requested before the page gets access.
    public func cefBrowserDidRequestPermissions(_ permissions: ARCHCEFPermission, fromOrigin origin: String, decision: @escaping (Bool) -> Void) {
        let mapping: [(ARCHCEFPermission, EnginePermissionType)] = [(.camera, .camera), (.microphone, .microphone), (.screenCapture, .screenCapture), (.geolocation, .geolocation),
                                                                   (.notifications, .notifications), (.clipboard, .clipboard), (.midi, .midi)]
        let types = mapping.filter { permissions.contains($0.0) }.map(\.1)
        guard let uiDelegate, !types.isEmpty else { return decision(false) }
        let request = EnginePermissionRequest(origin: URL(string: origin) ?? URL(string: "about:blank")!, types: types)
        uiDelegate.webContents(self, requestPermission: request) { granted in
            guard granted else { return decision(false) }
            let mediaTypes: [AVMediaType] = types.compactMap { $0 == .camera ? .video : $0 == .microphone ? .audio : nil }
            Self.requestCaptureAccess(for: mediaTypes) { decision($0) }
        }
    }
    /// Requests system permission for each media type in turn. Completes on the main thread with `false` as soon as one is denied.
    private static func requestCaptureAccess(for mediaTypes: [AVMediaType], completion: @escaping (Bool) -> Void) {
        guard let mediaType = mediaTypes.first else { return completion(true) }
        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            DispatchQueue.main.async {
                if granted {
                    Self.requestCaptureAccess(for: Array(mediaTypes.dropFirst()), completion: completion)
                } else {
                    completion(false)
                }
            }
        }
    }
    /// Reports the crash, then reloads the page once. The page stays blank after two consecutive crashes on the same URL.
    public func cefBrowserRenderProcessDidTerminate() {
        isLoading = false
        uiDelegate?.webContentsDidChangeLoadingState(self)
        uiDelegate?.webContentsProcessDidTerminate(self)
        context?.application?.rendererDidCrash()
        guard let url, url != lastCrashedURL else { return }
        lastCrashedURL = url
        browser?.loadURL(url.absoluteString)
    }
}

public final class ChromiumNavigationController: EngineNavigationController {
    unowned let webContents: ChromiumWebContents

    init(webContents: ChromiumWebContents) {
        self.webContents = webContents
    }

    public var backForwardList: any EngineBackForwardList { fatalError("not implemented") }
    public func load(_ request: URLRequest) { webContents.load(request) }
    public func reload() { webContents.reload() }
    public func reloadWithoutCache() { webContents.reloadWithoutCache() }
    public func stop() { webContents.stop() }
    public func goBack() { webContents.goBack() }
    public func goForward() { webContents.goForward() }
    public func go(to item: any EngineBackForwardListItem) { fatalError("not implemented") }
}
