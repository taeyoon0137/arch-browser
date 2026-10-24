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
    /// CEF does not report cookie changes, so this is never called.
    public var cookiesDidChange: (() -> Void)?

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
    /// Every browser shares CEF's global cookie manager.
    public func allCookies(completion: @escaping ([EngineCookie]) -> Void) {
        ARCHCEFCookieStore.visitAllCookies { cookies in
            completion(cookies.map { EngineCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expires, isSecure: $0.secure, isHTTPOnly: $0.httpOnly) })
        }
    }
    public func setCookie(_ cookie: EngineCookie, for url: URL) {
        ARCHCEFCookieStore.setCookie(Self.bridgeCookie(cookie), forURL: url.absoluteString)
    }
    public func setCookies(_ cookies: [EngineCookie], completion: @escaping () -> Void) {
        let addressed = cookies.compactMap { cookie in cookie.originURL.map { (Self.bridgeCookie(cookie), $0.absoluteString) } }
        ARCHCEFCookieStore.setCookies(addressed.map(\.0), forURLs: addressed.map(\.1), completion: completion)
    }
    public func removeCookie(named name: String, for url: URL) {
        ARCHCEFCookieStore.deleteCookies(forURL: url.absoluteString, name: name)
    }
    private static func bridgeCookie(_ cookie: EngineCookie) -> ARCHCEFCookie {
        let value = ARCHCEFCookie()
        value.name = cookie.name
        value.value = cookie.value
        // CEF makes a host-only cookie from an empty domain; a domain without a leading dot is host-only in the other stores.
        value.domain = cookie.domain.hasPrefix(".") ? cookie.domain : ""
        value.path = cookie.path
        value.expires = cookie.expires
        value.secure = cookie.isSecure
        value.httpOnly = cookie.isHTTPOnly
        return value
    }
}

/// A single CEF browser embedded in a container view hosted by the user interface.
public final class ChromiumWebContents: NSObject, EngineWebContents {
    public let engineKind: EngineKind = .chromium
    public let sessionID: String
    public let view: NSView
    public weak var uiDelegate: (any EngineWebContentsUIDelegate)?
    public weak var navigationDelegate: (any EngineWebContentsNavigationDelegate)?
    public var visibility: EngineWebContentsVisibility = .visible
    /// Chromium scales the page by 1.2 per zoom level; level 0 is the default size.
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
    /// Credentials sent per protection space since the last page finished loading; a further request for that space means they failed.
    private var authenticationAttempts: [String: Int] = [:]
    /// The context menu while it tracks, so that a closing browser can end it.
    private var contextMenu: NSMenu?
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
        // CEF restarts the search if the text or case sensitivity changes; otherwise, it advances the active match.
        let findNext = lastFind?.text == text && lastFind?.matchCase == matchCase
        lastFind = (text, matchCase, forward)
        if !findNext {
            lastActiveMatchOrdinal = 0
            didSelectFirstMatch = false
        }
        // A request arriving before the previous final result replaces it because Chromium cancels the previous search.
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
    public var closingStopsDownloads: Bool { browser?.hasDownloadsInProgress == true }
    public func tryToClose(completion: @escaping (Bool) -> Void) {
        guard let browser else { return completion(true) }
        browser.tryClose(completion: completion)
    }
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
    /// The back-forward list, oldest first, and the current page's index, or -1 if empty.
    fileprivate var navigationEntries: (entries: [ARCHCEFNavigationEntry], current: Int) {
        guard let browser else { return ([], -1) }
        return (browser.navigationEntries, browser.currentNavigationEntryIndex)
    }
    fileprivate func goToNavigationEntry(at index: Int, url: String) { browser?.goToNavigationEntry(at: index, url: url) }
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
        if !isLoading { authenticationAttempts.removeAll() }
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        uiDelegate?.webContentsDidChangeLoadingState(self)
    }
    public func cefBrowserDidChangeFaviconURLs(_ urls: [String]) {
        guard let iconURL = urls.lazy.compactMap(URL.init(string:)).first ?? url.flatMap(FaviconLoader.defaultIconURL(for:)) else { return }
        let pageURL = url
        FaviconLoader.load(iconURL) { [weak self] image in
            // Ignore icons loaded after the tab navigates to another page.
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
    /// Chromium's own pages, which it loads besides the web schemes.
    private static let internalSchemes: Set<String> = ["chrome", "chrome-error", "chrome-extension", "chrome-untrusted", "devtools", "view-source"]

    public func cefBrowserShouldOpenExternallyURL(_ url: String, userGesture: Bool) -> Bool {
        guard let url = URL(string: url), let scheme = url.scheme?.lowercased(),
              !EngineURLSchemes.web.contains(scheme), !Self.internalSchemes.contains(scheme) else { return false }
        // CEF asks while it decides on the navigation, so the question waits until that decision returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.uiDelegate?.webContents(self, openExternally: url, isUserInitiated: userGesture)
        }
        return true
    }
    public func cefBrowserDidRequestPopup(withURL url: String) {
        let popup = ChromiumWebContents(sessionID: UUID().uuidString, context: context, configuration: EngineWebContentsConfiguration(initialURL: URL(string: url)))
        uiDelegate?.webContents(self, didCreateNewWebContents: popup, targetURL: URL(string: url), disposition: .newForegroundTab)
    }
    public func cefBrowserDidClose() {
        contextMenu?.cancelTracking()
        uiDelegate?.webContentsDidClose(self)
    }

    /// Puts the spelling and editing items CEF can run into the menu, lets the UI delegate add the rest, and shows the menu at the click.
    public func cefBrowserRunContextMenu(_ params: ARCHCEFContextMenuParams, completion: @escaping () -> Void) {
        guard let uiDelegate, view.window != nil else { return completion() }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !params.misspelledWord.isEmpty {
            for word in params.spellingSuggestions {
                let item = engineMenuItem(word, EngineContextMenuItem.spellingSuggestion, #selector(replaceMisspellingFromMenu(_:)), isEnabled: true)
                item.representedObject = word
                menu.addItem(item)
            }
            if params.spellingSuggestions.isEmpty {
                menu.addItem(engineMenuItem("No Guesses Found", EngineContextMenuItem.noSpellingSuggestions, nil, isEnabled: false))
            }
        }
        let commands: [(String, NSUserInterfaceItemIdentifier, ARCHCEFEditCommand)] = [
            ("Cut", EngineContextMenuItem.cut, .cut), ("Copy", EngineContextMenuItem.copy, .copy),
            ("Paste", EngineContextMenuItem.paste, .paste), ("Select All", EngineContextMenuItem.selectAll, .selectAll),
        ]
        for (title, identifier, command) in commands where params.isEditable || (command == .copy && !params.selectionText.isEmpty) {
            let item = engineMenuItem(title, identifier, #selector(runEditCommandFromMenu(_:)), isEnabled: params.editCommands.contains(command))
            item.tag = Int(command.rawValue)
            menu.addItem(item)
        }
        let element = EngineContextMenuElement(linkURL: params.linkURL.flatMap(URL.init(engineString:)), imageURL: params.imageURL.flatMap(URL.init(engineString:)),
                                               mediaURL: params.mediaURL.flatMap(URL.init(engineString:)),
                                               selectedText: params.selectionText.isEmpty ? nil : params.selectionText, isEditable: params.isEditable)
        uiDelegate.webContents(self, willShowContextMenuFor: element, menu: menu)
        guard !menu.items.isEmpty else { return completion() }
        contextMenu = menu
        // Not popUpContextMenu: by now the current event is no longer the click.
        menu.popUp(positioning: nil, at: params.location, in: view)
        contextMenu = nil
        completion()
    }

    private func engineMenuItem(_ title: String, _ identifier: NSUserInterfaceItemIdentifier, _ action: Selector?, isEnabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.identifier = identifier
        item.isEnabled = isEnabled
        return item
    }

    @objc private func runEditCommandFromMenu(_ sender: NSMenuItem) {
        browser?.performEditCommand(ARCHCEFEditCommand(rawValue: UInt(sender.tag)))
    }

    @objc private func replaceMisspellingFromMenu(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        browser?.replaceMisspelling(withWord: word)
    }
    public func cefBrowserRunDialog(_ kind: ARCHCEFDialogKind, message: String, defaultText: String, completion: @escaping (Bool, String?) -> Void) {
        guard let uiDelegate else { return completion(kind == .alert, nil) }
        switch kind {
        case .confirm: uiDelegate.webContents(self, runJavaScriptConfirm: message) { completion($0, nil) }
        case .prompt: uiDelegate.webContents(self, runJavaScriptPrompt: message, defaultText: defaultText) { completion($0 != nil, $0) }
        default: uiDelegate.webContents(self, runJavaScriptAlert: message) { completion(true, nil) }
        }
    }
    public func cefBrowserRunLeavePageDialog(completion: @escaping (Bool) -> Void) {
        guard let uiDelegate else { return completion(true) }
        uiDelegate.webContents(self, runBeforeUnloadPanel: "", completion: completion)
    }
    public func cefBrowserDidResetDialogs() {
        uiDelegate?.webContentsDidCancelDialogs(self)
    }
    public func cefBrowserShouldDownloadURL(_ url: String, hasDocument: Bool) -> Bool {
        guard let uiDelegate, let url = URL(string: url) else { return true }
        return uiDelegate.webContents(self, shouldDownload: url, hasPage: hasDocument)
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
    /// Presents the request as a `URLAuthenticationChallenge`, the form WebKit uses, so the same sheet serves both engines. CEF does not count failed attempts, so the adapter counts the credentials it sent for each space until a page finishes loading; a request after one of them means it failed.
    public func cefBrowserDidReceiveAuthenticationChallenge(forHost host: String, port: Int32, realm: String, scheme: String, originURL: String, isProxy: Bool,
                                                            completion: @escaping (String?, String?) -> Void) {
        guard let uiDelegate else { return completion(nil, nil) }
        let method = switch scheme {
        case "digest": NSURLAuthenticationMethodHTTPDigest
        case "ntlm": NSURLAuthenticationMethodNTLM
        case "negotiate": NSURLAuthenticationMethodNegotiate
        default: NSURLAuthenticationMethodHTTPBasic
        }
        let space = isProxy
            ? URLProtectionSpace(proxyHost: host, port: Int(port), type: NSURLProtectionSpaceHTTPProxy, realm: realm, authenticationMethod: method)
            : URLProtectionSpace(host: host, port: Int(port), protocol: URL(string: originURL)?.scheme ?? "https", realm: realm, authenticationMethod: method)
        let key = "\(isProxy) \(host):\(port) \(realm)"
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: authenticationAttempts[key, default: 0],
                                                   failureResponse: nil, error: nil, sender: ChromiumAuthenticationSender.shared)
        uiDelegate.webContents(self, didReceiveAuthenticationChallenge: challenge) { [weak self] credential in
            if credential != nil { self?.authenticationAttempts[key, default: 0] += 1 }
            completion(credential?.user, credential?.password)
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

    public lazy var backForwardList: any EngineBackForwardList = ChromiumBackForwardList(webContents: webContents)
    public func load(_ request: URLRequest) { webContents.load(request) }
    public func reload() { webContents.reload() }
    public func reloadWithoutCache() { webContents.reloadWithoutCache() }
    public func stop() { webContents.stop() }
    public func goBack() { webContents.goBack() }
    public func goForward() { webContents.goForward() }
    public func go(to item: any EngineBackForwardListItem) {
        guard let item = item as? ChromiumBackForwardListItem, item.owner === webContents else { return }
        webContents.goToNavigationEntry(at: item.index, url: item.entryURL)
    }
}

/// A page in a Chromium tab's back-forward list. Its index records its position when read; its URL shows whether the entry is still there.
final class ChromiumBackForwardListItem: EngineBackForwardListItem {
    weak var owner: ChromiumWebContents?
    let index: Int
    let entryURL: String
    let url: URL
    let title: String

    init(_ entry: ARCHCEFNavigationEntry, owner: ChromiumWebContents) {
        self.owner = owner
        index = entry.index
        entryURL = entry.url
        url = URL(engineString: entry.url) ?? URL(string: "about:blank")!
        title = entry.title
    }
}

/// Reads CEF's list on each access, as the WebKit list reads `WKBackForwardList`.
final class ChromiumBackForwardList: EngineBackForwardList {
    private unowned let webContents: ChromiumWebContents

    init(webContents: ChromiumWebContents) {
        self.webContents = webContents
    }

    private var snapshot: (items: [ChromiumBackForwardListItem], current: Int) {
        let (entries, current) = webContents.navigationEntries
        return (entries.map { ChromiumBackForwardListItem($0, owner: webContents) }, current)
    }

    var backList: [any EngineBackForwardListItem] {
        let (items, current) = snapshot
        guard current > 0, current <= items.count else { return [] }
        return Array(items[..<current])
    }

    var forwardList: [any EngineBackForwardListItem] {
        let (items, current) = snapshot
        guard current >= 0, current + 1 < items.count else { return [] }
        return Array(items[(current + 1)...])
    }

    var currentItem: (any EngineBackForwardListItem)? {
        let (items, current) = snapshot
        return items.indices.contains(current) ? items[current] : nil
    }
}

/// `URLAuthenticationChallenge` needs a sender. The Chromium adapter answers through the CEF callback instead, so these calls do nothing.
private final class ChromiumAuthenticationSender: NSObject, URLAuthenticationChallengeSender {
    static let shared = ChromiumAuthenticationSender()
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
