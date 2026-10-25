// `WKWebView` adapter for the `ARCHEngine` protocols. This secondary engine prefers Apple APIs.
import AppKit
import ARCHEngine
import Foundation
import WebKit

public final class WebKitEngine: Engine {
    public let kind: EngineKind = .webKit
    /// Web extensions need macOS 15.4.
    public var capabilities: Set<EngineCapability> {
        let capabilities: Set<EngineCapability> = [.pdfController, .translation, .pictureInPicture, .sessionRestore, .contentBlocking, .cookies]
        guard #available(macOS 15.4, *) else { return capabilities }
        return capabilities.union([.extensions])
    }

    public init() {}

    public func makeApplication(configuration: EngineApplicationConfiguration) throws -> any EngineApplication {
        // The engine starts on the main thread, where the flags live.
        MainActor.assumeIsolated { WebKitInspectorAPI.register() }
        return WebKitApplication(configuration: configuration)
    }

    /// WebKit keeps a store of its own in `~/Library/WebKit/<bundle identifier>/WebsiteDataStore/<UUID>`, and removing one that does not exist also succeeds. The data of the profile's web extensions goes too. The WebKit application need not run.
    public func removeStoredData(forStorage identifier: UUID, configuration: EngineApplicationConfiguration, completion: @escaping (Bool) -> Void) {
        // WebKit sets up its run loop when it creates its first object, and the store's class methods crash before that.
        _ = WKWebViewConfiguration()
        WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
            guard #available(macOS 15.4, *) else { return completion(error == nil) }
            WebKitExtensions.removeData(forStorage: identifier) { completion(error == nil) }
        }
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

/// One profile, whose `WKWebsiteDataStore` keeps its cookies, site storage, and caches for the app's lifetime: a store that keeps nothing for incognito, otherwise the default store or, with a storage identifier, the store of that identifier. History needs a separate store, which is not implemented.
public final class WebKitBrowserContext: EngineBrowserContext {
    public let attributes: EngineBrowserContextAttributes
    public weak var delegate: (any EngineBrowserContextDelegate)?
    public var preferences = EnginePreferences()
    public let dataStore: WKWebsiteDataStore
    weak var application: WebKitApplication?
    lazy var webKitDownloads = WebKitDownloads(context: self)

    init(attributes: EngineBrowserContextAttributes) {
        self.attributes = attributes
        self.dataStore = switch (attributes.type, attributes.storageIdentifier) {
        case (.incognito, _): .nonPersistent()
        case (.regular, nil): .default()
        case let (.regular, identifier?): WKWebsiteDataStore(forIdentifier: identifier)
        }
    }

    public var id: EngineBrowserContextID { attributes.id }
    public var type: EngineBrowserContextType { attributes.type }
    public var userVisibleName: String { attributes.userVisibleName }
    public var history: any EngineHistory { fatalError("skeleton") }
    public var downloads: any EngineDownloads { webKitDownloads }
    /// From macOS 15.4, the profile's web extensions, whose controller every web view of the profile uses.
    public var extensions: (any EngineExtensions)? {
        guard #available(macOS 15.4, *) else { return nil }
        return webExtensions
    }
    @available(macOS 15.4, *)
    var webExtensions: WebKitExtensions? { webExtensionsObject as? WebKitExtensions }
    /// The profile's `WebKitExtensions` on macOS 15.4 and later, made at first use. It is stored untyped, as a stored property cannot have a type of a newer system.
    private lazy var webExtensionsObject: AnyObject? = {
        guard #available(macOS 15.4, *) else { return nil }
        return WebKitExtensions(context: self)
    }()
}

/// The tabs of one context. Cookies use the context's `WKHTTPCookieStore`.
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
    public func takeOwnership(of webContents: any EngineWebContents) {
        guard let webContents = webContents as? WebKitWebContents, !ownedWebContents.contains(where: { $0 === webContents }) else { return }
        ownedWebContents.append(webContents)
    }
    public func closeWebContents(_ webContents: any EngineWebContents) {
        guard let index = ownedWebContents.firstIndex(where: { $0 === (webContents as AnyObject) }) else { return }
        let closing = ownedWebContents.remove(at: index)
        closing.discard()
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
    public func removeCookies(where shouldRemove: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void) {
        let store = webKitContext.dataStore.httpCookieStore
        store.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies where shouldRemove(EngineCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, expires: cookie.expiresDate,
                                                                  isSecure: cookie.isSecure, isHTTPOnly: cookie.isHTTPOnly)) {
                group.enter()
                store.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main, execute: completion)
        }
    }
    /// WebKit keeps this data in one record per site, its registrable domain, so each origin's whole site loses it. Cookies stay for `removeCookies(where:completion:)`.
    public func removeSiteData(for origins: [URL], completion: @escaping () -> Void) {
        let hosts = origins.compactMap { $0.host?.lowercased() }
        let store = webKitContext.dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes().subtracting([WKWebsiteDataTypeCookies])
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { record in hosts.contains { $0 == record.displayName || $0.hasSuffix("." + record.displayName) } }
            guard !matching.isEmpty else { return completion() }
            store.removeData(ofTypes: types, for: matching, completionHandler: completion)
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

/// A PDF that a print operation saves to a temporary file. It reads the file, removes it, and reports once.
final class PDFPrintJob: NSObject {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("arch-\(UUID().uuidString).pdf")
    private let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    /// `contextInfo` holds the retain that keeps the job alive while the operation runs; it is released last. A web view's print operation finishes on a thread of its own, so the job reports on the main thread, where the completion can open the print panel or a sheet.
    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let data = success ? try? Data(contentsOf: file) : nil
        try? FileManager.default.removeItem(at: file)
        let result: Result<Data, Error> = data.map { .success($0) } ?? .failure(WebKitWebContents.PDFError.exportFailed)
        let completion = completion
        DispatchQueue.main.async { completion(result) }
        if let contextInfo { Unmanaged<PDFPrintJob>.fromOpaque(contextInfo).release() }
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
    public weak var pageScriptDelegate: (any EnginePageScriptDelegate)?
    public var visibility: EngineWebContentsVisibility = .visible
    public lazy var navigationController: any EngineNavigationController = WebKitNavigationController(webView: webView, contents: self)
    /// The web view's content controller, which holds its page scripts.
    let userContent: WebKitUserContentController
    let allowsDownloads: Bool
    var bridge: WebKitDelegateBridge?
    var observers: [any EngineWebContentsNavigationObserver] = []
    /// Gives the dialog the page waits on its safe answer. Set while an `alert`, `confirm`, or `prompt` dialog is open.
    private var dismissPendingDialog: (() -> Void)?
    /// The documents, in any frame, whose media elements play sound.
    var audibleDocuments: Set<String> = []
    /// The frame of each document that reports media, where its media actions run.
    var mediaFrames: [String: WKFrameInfo] = [:]
    lazy var webKitMediaSession = ScriptMediaSession { [weak self] document, action in self?.performMediaAction(action, inDocument: document) }
    /// The last search and the position of its active match, kept for when the page's selection cannot place the match.
    private var findQuery: String?
    private var findOrdinal = 0
    /// Set from a dismissed dialog until the navigation the user started finishes loading, so the page cannot hold that navigation with another dialog.
    private(set) var suppressesDialogs = false
    /// What the profile's web extensions see of the web contents.
    lazy var extensionTab = WebKitExtensionTab(contents: self)

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
        // The Fullscreen API then works as in the system's browser: WebKit moves the element into its own full-screen window.
        webConfiguration.preferences.isElementFullscreenEnabled = true
        if WebKitInspectorAPI.isAllowed { WebKitInspectorAPI.enableDeveloperExtras(in: webConfiguration.preferences) }
        if #available(macOS 15.4, *) { webConfiguration.webExtensionController = context.webExtensions?.controller }
        self.userContent = WebKitUserContentController()
        webConfiguration.userContentController = userContent
        self.webView = WebKitWebView(frame: .zero, configuration: webConfiguration)
        self.view = WebKitPageView(webView: webView)
        super.init()
        installBridge()
        installContextMenu()
        installAudibleScript()
        allowInspection()
        userContent.setPageScripts(configuration.pageScripts)
        // Restoring loads the current entry; a state WebKit cannot read leaves the list empty, and the page loads its address instead.
        if let state = configuration.restorableState {
            webView.interactionState = state
        }
        if webView.backForwardList.currentItem == nil, let url = configuration.initialURL {
            webView.load(URLRequest(url: url))
        }
    }

    /// For popups (window.open). The configuration WebKit hands over must be used as-is, so the popup shares its opener's content controller, page scripts, and web extensions.
    init(sessionID: String, parentConfiguration: WKWebViewConfiguration, context: WebKitBrowserContext) {
        guard let userContent = parentConfiguration.userContentController as? WebKitUserContentController else {
            preconditionFailure("WebKit popups come from web views of WebKit web contents")
        }
        self.sessionID = sessionID
        self.context = context
        self.userContent = userContent
        self.allowsDownloads = true
        self.webView = WebKitWebView(frame: .zero, configuration: parentConfiguration)
        self.view = WebKitPageView(webView: webView)
        super.init()
        installBridge()
        installContextMenu()
        installAudibleScript()
        allowInspection()
    }

    /// The web view inside a view that also holds the Web Inspector once it attaches.
    public let view: NSView
    public var url: URL? { webView.url }
    public var title: String { webView.title ?? "" }
    public private(set) var favicon: NSImage?
    public var isLoading: Bool { webView.isLoading }
    public var loadProgress: Double { webView.estimatedProgress }
    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }
    public var themeColor: NSColor? { webView.themeColor }
    /// WebKit's interaction state holds the back-forward list and each page's position.
    public var restorableState: Data? { webView.interactionState as? Data }
    public var isAudible: Bool { !audibleDocuments.isEmpty }
    public var selectedText: String? { nil }
    public var zoomFactor: Double {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }
    public var isFullscreen: Bool { webView.fullscreenState == .inFullscreen }
    public var mediaSession: any EngineMediaSession { webKitMediaSession }
    public func addNavigationObserver(_ observer: any EngineWebContentsNavigationObserver) {
        observers.append(observer)
    }
    public func removeNavigationObserver(_ observer: any EngineWebContentsNavigationObserver) {
        observers.removeAll { $0 === observer }
    }

    /// WebKit's find reports only whether a match exists. Once it selects the match, a script counts the matches in the page's visible text and places the selected one among them.
    public func find(_ text: String, forward: Bool, matchCase: Bool, completion: @escaping (EngineFindResult) -> Void) {
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = matchCase
        webView.find(text, configuration: configuration) { [weak self] result in
            guard let self, result.matchFound else {
                self?.findQuery = nil
                return completion(EngineFindResult(activeMatchOrdinal: 0, numberOfMatches: 0))
            }
            self.countMatches(of: text, matchCase: matchCase) { count, position in
                // WebKit found a match the script may not see, such as one in a frame, so the count is at least one.
                let count = max(count, 1)
                let isSameSearch = self.findQuery == text
                let ordinal = position ?? (isSameSearch ? (forward ? self.findOrdinal % count + 1 : (self.findOrdinal + count - 2) % count + 1) : (forward ? 1 : count))
                self.findQuery = text
                self.findOrdinal = min(ordinal, count)
                completion(EngineFindResult(activeMatchOrdinal: self.findOrdinal, numberOfMatches: count))
            }
        }
    }

    public func stopFind() {
        findQuery = nil
    }

    /// Counts the matches in the text of visible elements, as find sees the page, and returns the position of the match that starts at the selection, or `nil` when the selection lies outside that text. It runs in its own script world, out of the page's reach.
    private func countMatches(of text: String, matchCase: Bool, completion: @escaping (Int, Int?) -> Void) {
        guard let query = try? JSONSerialization.data(withJSONObject: [text]), let queryJSON = String(data: query, encoding: .utf8) else { return completion(0, nil) }
        let script = """
        (() => {
          const [query] = \(queryJSON);
          const fold = (s) => \(matchCase ? "s" : "s.toLocaleLowerCase()");
          const needle = fold(query);
          const root = document.body || document.documentElement;
          if (!needle || !root) return [0, -1];
          const selection = getSelection();
          const range = selection && selection.rangeCount ? selection.getRangeAt(0) : null;
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode(node) {
            const parent = node.parentElement;
            if (!parent || parent.closest("script, style, noscript, template")) return NodeFilter.FILTER_REJECT;
            return parent.checkVisibility && !parent.checkVisibility() ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
          } });
          let text = "", mark = -1;
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (range && node === range.startContainer) mark = text.length + range.startOffset;
            text += node.data;
          }
          const haystack = fold(text);
          let count = 0, position = -1;
          for (let i = haystack.indexOf(needle); i !== -1; i = haystack.indexOf(needle, i + needle.length)) {
            count += 1;
            if (mark >= 0 && position < 0 && i >= mark) position = count;
          }
          return [count, position];
        })()
        """
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            guard case .success(let value) = result, let numbers = value as? [NSNumber], numbers.count == 2 else { return completion(0, nil) }
            let position = numbers[1].intValue
            completion(numbers[0].intValue, position > 0 ? position : nil)
        }
    }
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
    /// `takeSnapshot` draws only what is on screen and leaves the rest of a larger rectangle blank, so the whole page comes from `createPDF`, which draws the document from its top-left corner at the current zoom as one page. The page is drawn off the main thread at the window's backing scale, or lower when a side would otherwise pass `maximumCaptureSide` pixels.
    public func captureFullPage(completion: @escaping (NSImage?) -> Void) {
        let scale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        webView.createPDF { result in
            guard case .success(let data) = result else { return completion(nil) }
            DispatchQueue.global(qos: .userInitiated).async {
                let image = Self.image(fromPDF: data, scale: scale)
                DispatchQueue.main.async { completion(image) }
            }
        }
    }
    /// The longest side, in pixels, of a full-page capture.
    private static let maximumCaptureSide: CGFloat = 16_384
    /// Draws the first page of a PDF over white at `scale` pixels per point. The image's size is the page's size in points.
    private static func image(fromPDF data: Data, scale: CGFloat) -> NSImage? {
        guard let provider = CGDataProvider(data: data as CFData), let page = CGPDFDocument(provider)?.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width >= 1, box.height >= 1 else { return nil }
        let scale = min(scale, maximumCaptureSide / box.width, maximumCaptureSide / box.height)
        let width = Int((box.width * scale).rounded(.up))
        let height = Int((box.height * scale).rounded(.up))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage().map { NSImage(cgImage: $0, size: box.size) }
    }
    public enum PDFError: Error {
        case exportFailed
    }
    /// Renders a paginated PDF on the system's default paper with the page's print styles, as Chromium does. WebKit's print operation saves it without a panel and runs modal for the window, because `run()` never finishes for a web view. `createPDF` draws the whole page as one tall page, so it serves only a page outside a window.
    public func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {
        guard let window = webView.window else {
            webView.createPDF { completion($0) }
            return
        }
        let job = PDFPrintJob(completion: completion)
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = job.file
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: job, didRun: #selector(PDFPrintJob.printOperationDidRun(_:success:contextInfo:)), contextInfo: Unmanaged.passRetained(job).toOpaque())
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
    public func exitFullscreen() { webView.closeAllMediaPresentations(completionHandler: nil) }
    /// Ends the page. A web view keeps its page, with the page's media and scripts, for as long as anything holds it, so the page leaves its media presentations, pauses its media, and moves to a blank page without its delegates.
    public func discard() {
        webView.stopLoading()
        webView.closeAllMediaPresentations(completionHandler: nil)
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }
    /// A `WKDownload` continues after its web view closes.
    public var closingStopsDownloads: Bool { false }
    /// WebKit has no public way to run `beforeunload` handlers.
    public func tryToClose(completion: @escaping (Bool) -> Void) { completion(true) }
    /// The Web Inspector inside the app while its private API flags allow it; otherwise none.
    public var devTools: (any EngineDevTools)? { WebKitInspectorAPI.isAllowed ? inspector : nil }
    private lazy var inspector = WebKitDevTools(webView: webView)

    /// Lets the system's browser inspect the page, which keeps working when the Web Inspector inside the app is off.
    private func allowInspection() {
        webView.isInspectable = true
    }
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
