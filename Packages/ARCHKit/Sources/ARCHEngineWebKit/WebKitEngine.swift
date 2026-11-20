// `WKWebView` adapter for the `ARCHEngine` protocols. This secondary engine prefers Apple APIs.
import AppKit
import ARCHEngine
import ARCHPrivateAPI
import Foundation
import WebKit

public final class WebKitEngine: Engine {
    public let kind: EngineKind = .webKit
    /// Web extensions need macOS 15.4.
    public var capabilities: Set<EngineCapability> {
        guard #available(macOS 15.4, *) else { return [] }
        return [.extensions]
    }

    /// The WebKit framework's bundle version, such as `22625.2.5.11.1`, which a macOS update changes; the system's version if the framework names none.
    public var extensionRuntimeVersion: String? {
        guard #available(macOS 15.4, *) else { return nil }
        return Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// Registers the private APIs of the Web Inspector inside pages and of file choosers' types, so that the flags page lists them before the engine starts. Call on the main thread, where the flags live.
    public init() {
        MainActor.assumeIsolated {
            WebKitInspectorAPI.register()
            WebKitFileChooserAPI.register()
            WebKitPictureInPictureAPI.register()
        }
    }

    /// Marks a key down sent by trusted input (`EngineWebContents.input`). WebKit can return an unhandled key to `NSApplication.sendEvent(_:)` after the page answers, even seconds later.
    /// The application would pass it to local monitors in unspecified order, menus, and the window and view then in focus, perhaps the address field. Its `sendEvent(_:)` drops this key first.
    @MainActor public static func isTrustedInputKey(_ event: NSEvent) -> Bool {
        event.type == .keyDown && WebKitSentKeys.contains(event)
    }

    public func makeApplication(configuration: EngineApplicationConfiguration) throws -> any EngineApplication {
        WebKitApplication(configuration: configuration)
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

    /// Registers the private member that page scripts run through without a user gesture, so that the flags page lists it before the first web contents.
    init(configuration: EngineApplicationConfiguration) {
        self.configuration = configuration
        MainActor.assumeIsolated { WebKitUserGestureAPI.register() }
    }

    private var rendererCrashCount = 0

    /// The default store without a storage identifier, otherwise the store of that identifier.
    public func createBrowserContext(storageIdentifier: UUID?, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void) {
        let dataStore = storageIdentifier.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
        completion(.success(makeBrowserContext(storageIdentifier: storageIdentifier, dataStore: dataStore)))
    }
    /// A profile over `dataStore`. Besides `createBrowserContext`, the adapter's tests use it for a profile whose store, `.nonPersistent()`, keeps nothing on disk; the app's profiles all keep their data.
    func makeBrowserContext(storageIdentifier: UUID?, dataStore: WKWebsiteDataStore) -> WebKitBrowserContext {
        let context = WebKitBrowserContext(storageIdentifier: storageIdentifier, dataStore: dataStore)
        context.application = self
        return context
    }
    public func createBrowser(context: any EngineBrowserContext) -> any EngineBrowser {
        guard let context = context as? WebKitBrowserContext else {
            preconditionFailure("WebKit browsers require a WebKit browser context")
        }
        return WebKitBrowser(context: context)
    }
    /// Counts web content process terminations across all tabs and reports the total.
    func rendererDidCrash() {
        rendererCrashCount += 1
        delegate?.application(self, didReceiveRendererProcessCrash: rendererCrashCount)
    }
}

/// One profile, whose `WKWebsiteDataStore` keeps its cookies, site storage, and caches for the app's lifetime: the default store or, with a storage identifier, the store of that identifier.
public final class WebKitBrowserContext: EngineBrowserContext {
    /// The identifier of the profile's store, or nil for the default store or one that keeps nothing on disk.
    let storageIdentifier: UUID?
    public var preferences = EnginePreferences()
    public let dataStore: WKWebsiteDataStore
    weak var application: WebKitApplication?
    lazy var webKitDownloads = WebKitDownloads(context: self)

    init(storageIdentifier: UUID?, dataStore: WKWebsiteDataStore) {
        self.storageIdentifier = storageIdentifier
        self.dataStore = dataStore
    }

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
    public let webKitContext: WebKitBrowserContext
    private var ownedWebContents: [WebKitWebContents] = []
    private let cookieObserver = CookieObserver()
    public var cookiesDidChange: (() -> Void)? {
        get { cookieObserver.handler }
        set { cookieObserver.handler = newValue }
    }

    init(context: WebKitBrowserContext) {
        self.webKitContext = context
        context.dataStore.httpCookieStore.add(cookieObserver)
    }

    deinit {
        webKitContext.dataStore.httpCookieStore.remove(cookieObserver)
    }

    public func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents {
        let webContents = WebKitWebContents(context: webKitContext, configuration: configuration)
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
    public func closeAllWebContents() {
        for webContents in ownedWebContents { closeWebContents(webContents) }
    }

    public func allCookies(completion: @escaping ([EngineCookie]) -> Void) {
        webKitContext.dataStore.httpCookieStore.getAllCookies { cookies in completion(cookies.map(Self.engineCookie)) }
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
    /// WebKit keeps no policy both for a cookie that names `SameSite=None` and for one that names none, and sends either with requests from other sites, so such a cookie reads as `noRestriction`.
    private static func engineCookie(_ cookie: HTTPCookie) -> EngineCookie {
        let sameSite: EngineCookieSameSite = switch cookie.sameSitePolicy {
        case .sameSiteLax?: .lax
        case .sameSiteStrict?: .strict
        default: .noRestriction
        }
        return EngineCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, expires: cookie.expiresDate, isSecure: cookie.isSecure,
                            isHTTPOnly: cookie.isHTTPOnly, sameSite: sameSite)
    }
    private static func httpCookie(_ cookie: EngineCookie, for url: URL) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path, .originURL: url]
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.isSecure { properties[.secure] = "TRUE" }
        if cookie.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch cookie.sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        case .noRestriction, .unspecified: break
        }
        return HTTPCookie(properties: properties)
    }
    public func removeCookies(where shouldRemove: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void) {
        let store = webKitContext.dataStore.httpCookieStore
        store.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies where shouldRemove(Self.engineCookie(cookie)) {
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
    public let webView: WKWebView
    public let context: WebKitBrowserContext
    public weak var uiDelegate: (any EngineWebContentsUIDelegate)?
    public weak var navigationDelegate: (any EngineWebContentsNavigationDelegate)?
    public weak var pageScriptDelegate: (any EnginePageScriptDelegate)?
    public lazy var navigationController: any EngineNavigationController = WebKitNavigationController(webView: webView, contents: self)
    /// The web view's content controller, which holds its page scripts.
    let userContent: WebKitUserContentController
    /// The base URL of the web extension whose pages alone the web view loads, since WebKit loads an extension's pages only in a web view made for that extension; nil for a web view that loads other pages.
    let extensionBaseURL: URL?
    var bridge: WebKitDelegateBridge?
    /// Gives the dialog the page waits on its safe answer. Set while an `alert`, `confirm`, or `prompt` dialog is open.
    private var dismissPendingDialog: (() -> Void)?
    /// The documents, in any frame, whose media elements play sound.
    var audibleDocuments: Set<String> = []
    /// The documents, in any frame, with a video in picture in picture.
    var pictureInPictureDocuments: Set<String> = []
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
    /// The page of an extension that the profile had not loaded when the web contents opened at it, as a restored tab does, with its saved state. The web view loads nothing meanwhile, and the web contents reports the page's address and state, until the extension loads and a replacement loads the page, or until another navigation goes ahead.
    var waitingPage: (url: URL, state: Data?)?
    /// The page that a replacement loads on the next turn of the run loop, with its saved state.
    var pendingReplacement: (url: URL, state: Data?)?
    /// The address of the app's last load through the navigation controller, as the address field's or `tabs.update`'s, until the navigation policy sees a main frame navigation to it. WebKit asks about the app's loads as about a page's own navigations, so this tells the policy which navigations the app started.
    var appLoadURL: URL?

    /// Version and engine tokens a full browser on this system adds to its user agent. `WKWebView` omits them, so some sites send pages for old browsers. The system's WebKit uses the system's version number.
    static let applicationNameForUserAgent: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(version.majorVersion).\(version.minorVersion) Safari/605.1.15"
    }()

    public init(context: WebKitBrowserContext, configuration: EngineWebContentsConfiguration) {
        self.context = context
        let (webConfiguration, extensionBaseURL) = Self.baseConfiguration(loading: configuration.initialURL, in: context)
        self.extensionBaseURL = extensionBaseURL
        webConfiguration.websiteDataStore = context.dataStore
        webConfiguration.applicationNameForUserAgent = Self.applicationNameForUserAgent
        // The Fullscreen API then works as in the system's browser: WebKit moves the element into its own full-screen window.
        webConfiguration.preferences.isElementFullscreenEnabled = true
        WebKitPictureInPictureAPI.enable(in: webConfiguration.preferences)
        // A page opens a window only from the user's click or key, as Blink holds Chromium's pages to. WebKit on macOS lets a script open windows without one by default, so a page, or an extension's script in it, could open tab after tab, each with a first download of its own. Popups take this configuration, so the rule holds for them too.
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if WebKitInspectorAPI.isAllowed { WebKitInspectorAPI.enableDeveloperExtras(in: webConfiguration.preferences) }
        if #available(macOS 15.4, *) { webConfiguration.webExtensionController = context.webExtensions?.controller }
        self.userContent = WebKitUserContentController()
        webConfiguration.userContentController = userContent
        let webView = WebKitWebView(frame: .zero, configuration: webConfiguration)
        self.webView = webView
        self.view = WebKitPageView(webView: webView)
        super.init()
        webView.contents = self
        installBridge()
        installContextMenu()
        installAudibleScript()
        allowInspection()
        userContent.setPageScripts(configuration.pageScripts)
        if let url = configuration.initialURL, waitsForExtension(ofPageAt: url) {
            waitingPage = (url, configuration.restorableState)
            return
        }
        // Restoring loads the current entry; a state WebKit cannot read leaves the list empty, and the page loads its address instead.
        if let state = configuration.restorableState {
            webView.interactionState = state
        }
        if webView.backForwardList.currentItem == nil, let url = configuration.initialURL {
            webView.load(URLRequest(url: url))
        }
    }

    /// WebKit loads a web extension's page only in a web view made from the configuration that the extension's context gives, and such a web view loads only that extension's pages. A web contents that starts at a loaded extension's page, as an options page or a tab that `tabs.create` opens at `runtime.getURL(…)`, starts from that configuration; any other starts from a new one.
    private static func baseConfiguration(loading url: URL?, in context: WebKitBrowserContext) -> (WKWebViewConfiguration, extensionBaseURL: URL?) {
        if #available(macOS 15.4, *), let url, let extensionContext = context.webExtensions?.extensionContext(ofPageAt: url),
           let configuration = extensionContext.webViewConfiguration {
            return (configuration, extensionContext.baseURL)
        }
        return (WKWebViewConfiguration(), nil)
    }

    /// For popups (window.open), a valid configuration keeps the opener's content controller, page scripts, and web extensions. `extensionBaseURL` is the opener's.
    /// `makePopup` rejects an unexpected controller. Direct callers receive a fresh controller instead of trapping.
    static func makePopup(parentConfiguration: WKWebViewConfiguration, extensionBaseURL: URL?, context: WebKitBrowserContext) -> WebKitWebContents? {
        guard parentConfiguration.userContentController is WebKitUserContentController else { return nil }
        return WebKitWebContents(parentConfiguration: parentConfiguration, extensionBaseURL: extensionBaseURL, context: context)
    }

    init(parentConfiguration: WKWebViewConfiguration, extensionBaseURL: URL?, context: WebKitBrowserContext) {
        let userContent: WebKitUserContentController
        if let existing = parentConfiguration.userContentController as? WebKitUserContentController {
            userContent = existing
        } else {
            userContent = WebKitUserContentController()
            parentConfiguration.userContentController = userContent
        }
        self.context = context
        self.userContent = userContent
        self.extensionBaseURL = extensionBaseURL
        let webView = WebKitWebView(frame: .zero, configuration: parentConfiguration)
        self.webView = webView
        self.view = WebKitPageView(webView: webView)
        super.init()
        webView.contents = self
        installBridge()
        installContextMenu()
        installAudibleScript()
        allowInspection()
    }

    /// The web view inside a view that also holds the Web Inspector once it attaches.
    public let view: NSView
    public var url: URL? { webView.url ?? waitingPage?.url ?? localHistoryItemWithoutPage?.url }

    /// A restored file can be missing on disk. Its history entry survives even though WebKit has no page to reload.
    fileprivate var localHistoryItemWithoutPage: WKBackForwardListItem? {
        guard webView.url == nil, let item = webView.backForwardList.currentItem, item.url.isFileURL else { return nil }
        return item
    }
    public var title: String { webView.title ?? "" }
    public private(set) var favicon: NSImage?
    public var isLoading: Bool { webView.isLoading }
    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }
    /// WebKit's interaction state holds the back-forward list and each page's position. A page that waits for its extension keeps the state it opened with.
    public var restorableState: Data? {
        if let waitingPage { return waitingPage.state }
        return webView.interactionState as? Data
    }
    public var isAudible: Bool { !audibleDocuments.isEmpty }
    /// WebKit reports the camera and the microphone as active or muted while the page holds them; it has no public state for screen sharing.
    public var isCapturingMedia: Bool { webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none }
    /// WebKit has no public state for picture in picture, so the media script reports each document's (`WebKitAudibleScript`).
    public var isInPictureInPicture: Bool { !pictureInPictureDocuments.isEmpty }

    public func download(_ url: URL) {
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { download.cancel(); return }
            self.context.webKitDownloads.add(download, from: self)
        }
    }

    public func startPictureInPicture(completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            let result = try? await webView.callAsyncJavaScript("return await " + EnginePictureInPictureScript.start,
                                                                arguments: [:], in: nil, contentWorld: .page)
            completion(result as? Bool == true)
        }
    }
    public var zoomFactor: Double {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }
    public var mediaSession: any EngineMediaSession { webKitMediaSession }

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
                let result = Self.findResult(countedMatches: count, selectedMatch: position, previousOrdinal: self.findQuery == text ? self.findOrdinal : nil, forward: forward)
                self.findQuery = text
                self.findOrdinal = result.activeMatchOrdinal
                completion(result)
            }
        }
    }

    /// The result of a search WebKit found a match for, from the script's count and its position of the selected match. WebKit found a match the script may not see, such as one in a frame, so the count is at least one. Without the script's position, the active match moves one step from `previousOrdinal`, the position of the same search's last match, wrapping around at either end; a new search starts at the first match forward and the last backward.
    static func findResult(countedMatches: Int, selectedMatch: Int?, previousOrdinal: Int?, forward: Bool) -> EngineFindResult {
        let count = max(countedMatches, 1)
        let ordinal = selectedMatch ?? previousOrdinal.map { forward ? $0 % count + 1 : ($0 + count - 2) % count + 1 } ?? (forward ? 1 : count)
        return EngineFindResult(activeMatchOrdinal: min(ordinal, count), numberOfMatches: count)
    }

    public func stopFind() {
        findQuery = nil
    }

    /// Counts the matches in the text of visible elements, as find sees the page, and returns the position of the match that starts at the selection, or `nil` when the selection lies outside that text. A line break separates the text of different blocks, as in the text WebKit's find searches, so that no match spans two paragraphs or table cells, while text in inline elements runs on. It runs in its own script world, out of the page's reach.
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
          const inline = new Map();
          const isInline = (element) => {
            if (!inline.has(element)) {
              const display = getComputedStyle(element).display;
              inline.set(element, display.startsWith("inline") || display === "contents");
            }
            return inline.get(element);
          };
          const blockOf = (node) => {
            let element = node.parentElement;
            while (element && element !== root && isInline(element)) element = element.parentElement;
            return element;
          };
          let text = "", mark = -1, block;
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            const nodeBlock = blockOf(node);
            if (text && nodeBlock !== block) text += "\\n";
            block = nodeBlock;
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
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            completion(.failure(CocoaError(.fileWriteUnknown)))
            return
        }
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = job.file
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: job, didRun: #selector(PDFPrintJob.printOperationDidRun(_:success:contextInfo:)), contextInfo: Unmanaged.passRetained(job).toOpaque())
    }
    public func exitFullscreen() { webView.closeAllMediaPresentations(completionHandler: nil) }
    /// Ends the page, with any replacement that waits to load and any wait for an extension. A web view keeps its page, with the page's media and scripts, for as long as anything holds it, so the page leaves its media presentations, pauses its media, and moves to a blank page without its delegates. The bridge goes first: its observations would report the blank page's address, which the load sets before it returns, to the tab and the profile's extensions.
    func discard() {
        pendingReplacement = nil
        stopWaitingForExtension()
        webView.stopLoading()
        webView.closeAllMediaPresentations(completionHandler: nil)
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        bridge = nil
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }
    /// A `WKDownload` continues after its web view closes.
    public var closingStopsDownloads: Bool { false }
    /// WebKit has no public way to run `beforeunload` handlers.
    public func tryToClose(completion: @escaping (Bool) -> Void) { completion(true) }
    /// The Web Inspector inside the app while its private API flags allow it; otherwise none.
    public var devTools: (any EngineDevTools)? { WebKitInspectorAPI.isAllowed ? inspector : nil }
    private lazy var inspector = WebKitDevTools(webView: webView)
    public var input: (any EngineInput)? { webKitInput }
    private lazy var webKitInput = WebKitInput(webView: webView)

    /// Lets the system's browser inspect the page, which keeps working when the Web Inspector inside the app is off.
    private func allowInspection() {
        webView.isInspectable = true
    }

    /// Clears the previous icon, then reads the page's declared icon or `/favicon.ico` as a fallback and sends the result to the UI delegate. The lookup runs in a world of the app's own: `evaluateJavaScript` runs with a user gesture, which in the page's world would reach a DOM method the page replaced, and with it a file chooser or a popup after every load.
    func refreshFavicon() {
        guard let pageURL = webView.url else { return }
        if favicon != nil {
            favicon = nil
            uiDelegate?.webContentsDidChangeFavicon(self)
        }
        let script = "(function(){var l=document.querySelector('link[rel~=\"icon\"],link[rel=\"shortcut icon\"],link[rel=\"apple-touch-icon\"]');return l?l.href:null;})()"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            let declared = (try? result.get() as? String).flatMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL }
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
        contents?.appLoadURL = request.url?.absoluteURL
        webView.load(request)
    }
    public func reload() { reload(ignoringCache: false) }
    public func reloadWithoutCache() { reload(ignoringCache: true) }

    private func reload(ignoringCache: Bool) {
        contents?.dismissDialogBeforeNavigation()
        if let item = contents?.localHistoryItemWithoutPage {
            // Revisit the existing entry. Loading its address would insert another copy into Back.
            webView.go(to: item)
        } else if ignoringCache {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
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

private enum WebKitPictureInPictureAPI {
    static let apiID = "webkit.pictureInPicturePlayback"
    static let featureID = "webkit.pictureInPicture"

    @MainActor static func register() {
        let flags = PrivateAPIFlags.shared
        flags.register(PrivateAPI(id: apiID, name: "WKPreferences.allowsPictureInPictureMediaPlayback", framework: "WebKit") {
            WKPreferences.instancesRespond(to: NSSelectorFromString("setAllowsPictureInPictureMediaPlayback:"))
        })
        flags.register(PrivateAPIFeature(id: featureID, name: "Picture in picture on WebKit", apiIDs: [apiID]))
    }

    static func enable(in preferences: WKPreferences) {
        guard MainActor.assumeIsolated({ PrivateAPIFlags.shared.allows(featureID) }),
              preferences.responds(to: NSSelectorFromString("setAllowsPictureInPictureMediaPlayback:")) else { return }
        preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
    }
}
