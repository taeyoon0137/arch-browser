// Chromium is the primary engine. This adapter implements the `ARCHEngine` protocols using the Chromium Embedded Framework (CEF) through the Objective-C bridge.
import AppKit
import ARCHEngine
import CEFBridge
import Foundation

public final class ChromiumEngine: Engine {
    public let kind: EngineKind = .chromium
    public let capabilities: Set<EngineCapability> = [.devTools, .pictureInPicture, .cookies]
    /// Chromium runs no web extensions until VI.1, which gives the CEF version here.
    public let extensionRuntimeVersion: String? = nil
    let frameworkPath: String
    let helperPath: String?
    private let accessibility = MainActor.assumeIsolated { ChromiumAccessibility() }

    /// Returns `nil` if the framework directory is missing, allowing the app to fall back to WebKit.
    public init?(frameworkPath: String, helperPath: String?) {
        guard FileManager.default.fileExists(atPath: frameworkPath) else { return nil }
        self.frameworkPath = frameworkPath
        self.helperPath = helperPath
    }

    public enum StartError: Error {
        case initializationFailed
        /// CEF refused the profile of a context with a storage identifier.
        case profileUnavailable
    }

    public func makeApplication(configuration: EngineApplicationConfiguration) throws -> any EngineApplication {
        // A removal that a quit cut short leaves a renamed profile, which goes here even when no list names its Persona any more, as after a session that did not load.
        Self.deleteRemovedProfiles(in: configuration.chromiumProfileRoots)
        guard ARCHCEFRuntime.initialize(withFrameworkPath: frameworkPath, helperPath: helperPath, cachePath: configuration.chromiumRootCache.path) else {
            throw StartError.initializationFailed
        }
        // The engine starts on the main thread, where the flags live.
        MainActor.assumeIsolated { accessibility.start() }
        return ChromiumApplication(configuration: configuration)
    }

    /// CEF may keep a loaded profile's files open, so nothing is removed while it runs. Otherwise the profile's directories get a new name at once, which no context loads, and are deleted in the background. The report waits for the deletion, so a quit before it finishes leaves the identifier to a later launch.
    public func removeStoredData(forStorage identifier: UUID, configuration: EngineApplicationConfiguration, completion: @escaping (Bool) -> Void) {
        guard !ARCHCEFRuntime.isInitialized() else { return completion(false) }
        let roots = configuration.chromiumProfileRoots
        let profiles = roots.map { $0.appendingPathComponent(Self.profileName(forStorage: identifier)) }
        // A missing directory has nothing to move, and one that does not move stays for the check below.
        for profile in profiles {
            try? FileManager.default.moveItem(at: profile, to: profile.appendingPathExtension(Self.removedProfileExtension))
        }
        Self.deleteRemovedProfiles(in: roots) {
            let leftovers = profiles + profiles.map { $0.appendingPathExtension(Self.removedProfileExtension) }
            completion(!leftovers.contains { FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    /// The profile of a context with a storage identifier is named by this prefix and the identifier. A removed one also has the extension until its deletion finishes.
    private static let profileNamePrefix = "Persona-"
    private static let removedProfileExtension = "removed"
    /// Deletes removed profiles one at a time, so that two deletions never race over one directory.
    private static let profileDeletionQueue = DispatchQueue(label: "xyz.taeyoon.arch.chromium.profile-deletion", qos: .utility)

    fileprivate static func profileName(forStorage identifier: UUID) -> String {
        profileNamePrefix + identifier.uuidString
    }

    /// Deletes, in the background, every profile directory that `removeStoredData` renamed under `roots`, then calls `completion` on the main thread.
    private static func deleteRemovedProfiles(in roots: [URL], completion: @escaping () -> Void = {}) {
        profileDeletionQueue.async {
            for root in roots {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                for name in names where name.hasPrefix(profileNamePrefix) && (name as NSString).pathExtension == removedProfileExtension {
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
                }
            }
            DispatchQueue.main.async(execute: completion)
        }
    }
}

private extension EngineApplicationConfiguration {
    /// CEF's root cache path. The global profile is `Default` under it, and the profile of a context with a storage identifier is `Persona-<UUID>` beside it.
    var chromiumRootCache: URL { cacheDirectory.appendingPathComponent("Chromium") }

    /// The directories that hold Chromium profiles: the root cache path and, for a root under the user's Application Support directory, its counterpart under the user's Caches directory, where Chromium keeps each profile's HTTP and code caches.
    var chromiumProfileRoots: [URL] {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path + "/"
        let rootCache = chromiumRootCache.path
        guard rootCache.hasPrefix(applicationSupport) else { return [chromiumRootCache] }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return [chromiumRootCache, caches.appendingPathComponent(String(rootCache.dropFirst(applicationSupport.count)))]
    }

    func chromiumProfile(forStorage identifier: UUID) -> URL {
        chromiumRootCache.appendingPathComponent(ChromiumEngine.profileName(forStorage: identifier))
    }
}

public final class ChromiumApplication: EngineApplication {
    public let engineKind: EngineKind = .chromium
    public weak var delegate: (any EngineApplicationDelegate)?
    let configuration: EngineApplicationConfiguration
    var contexts: [EngineBrowserContextID: ChromiumBrowserContext] = [:]

    init(configuration: EngineApplicationConfiguration) {
        self.configuration = configuration
    }

    public var version: String { "Chromium (CEF)" }
    public func run() { delegate?.applicationDidInitialize(self) }
    public func tryToTerminate(completion: @escaping (Bool) -> Void) { completion(true) }
    public var availableBrowserContextAttributes: [EngineBrowserContextAttributes] { contexts.values.map(\.attributes) }
    /// A context without a storage identifier uses CEF's global request context; one with an identifier gets a request context of its own, which browsers can use at once.
    public func createBrowserContext(_ attributes: EngineBrowserContextAttributes, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void) {
        let requestContext: ARCHCEFRequestContext?
        if let identifier = attributes.storageIdentifier {
            requestContext = ARCHCEFRequestContext(cachePath: configuration.chromiumProfile(forStorage: identifier).path)
        } else {
            requestContext = .global
        }
        guard let requestContext else { return completion(.failure(ChromiumEngine.StartError.profileUnavailable)) }
        let context = ChromiumBrowserContext(attributes: attributes, requestContext: requestContext)
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
    public func browserContext(_ id: EngineBrowserContextID, type: EngineBrowserContextType) -> (any EngineBrowserContext)? { contexts[id] }
    public func deleteBrowserContext(_ id: EngineBrowserContextID) throws { contexts[id] = nil }
    public func createBrowser(_ params: EngineBrowserCreateParams, context: any EngineBrowserContext, delegate: any EngineBrowserDelegate, window: NSWindow?) -> any EngineBrowser {
        let browser = ChromiumBrowser(sessionID: UUID().uuidString, context: Self.chromiumContext(context), delegate: delegate, window: window)
        self.delegate?.application(self, didCreateBrowser: browser)
        return browser
    }
    private static func chromiumContext(_ context: any EngineBrowserContext) -> ChromiumBrowserContext {
        guard let context = context as? ChromiumBrowserContext else {
            preconditionFailure("Chromium browsers require a Chromium browser context")
        }
        return context
    }
}

/// One profile, whose request context keeps its cookies, site storage, caches, and permission answers for the app's lifetime.
public final class ChromiumBrowserContext: EngineBrowserContext {
    public let attributes: EngineBrowserContextAttributes
    public var preferences = EnginePreferences()
    weak var application: ChromiumApplication?
    let chromiumDownloads = ChromiumDownloads()
    let requestContext: ARCHCEFRequestContext

    init(attributes: EngineBrowserContextAttributes, requestContext: ARCHCEFRequestContext) {
        self.attributes = attributes
        self.requestContext = requestContext
    }

    public var id: EngineBrowserContextID { attributes.id }
    public var type: EngineBrowserContextType { attributes.type }
    public var userVisibleName: String { attributes.userVisibleName }
    public var downloads: any EngineDownloads { chromiumDownloads }
    public var extensions: (any EngineExtensions)? { nil }

    /// Chromium keeps every answer its own prompt gives, such as one for geolocation or notifications, and gives it without asking again, so the kept answers follow the app's.
    public func setRememberedPermission(_ allowed: Bool?, for type: EnginePermissionType, origin: URL) {
        let permission: ARCHCEFPermission = switch type {
        case .camera: .camera
        case .microphone: .microphone
        case .screenCapture: .screenCapture
        case .geolocation: .geolocation
        case .notifications: .notifications
        case .clipboard: .clipboard
        case .midi: .midi
        }
        let setting: ARCHCEFPermissionSetting = switch allowed {
        case true?: .allow
        case false?: .block
        case nil: .ask
        }
        requestContext.setPermissionSetting(setting, forPermissions: permission, origin: origin.absoluteString)
    }
}

/// The tabs of one context. Cookies and site data go through the context's request context.
public final class ChromiumBrowser: EngineBrowser {
    public let sessionID: String
    let chromiumContext: ChromiumBrowserContext
    public weak var window: NSWindow?
    public weak var delegate: (any EngineBrowserDelegate)?
    private var ownedWebContents: [ChromiumWebContents] = []
    /// CEF does not report cookie changes, so this is never called.
    public var cookiesDidChange: (() -> Void)?

    init(sessionID: String, context: ChromiumBrowserContext, delegate: any EngineBrowserDelegate, window: NSWindow?) {
        self.sessionID = sessionID
        self.chromiumContext = context
        self.delegate = delegate
        self.window = window
    }

    public var context: any EngineBrowserContext { chromiumContext }
    private var requestContext: ARCHCEFRequestContext { chromiumContext.requestContext }

    public func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents {
        let webContents = ChromiumWebContents(sessionID: UUID().uuidString, context: chromiumContext, requestContext: requestContext, configuration: configuration)
        ownedWebContents.append(webContents)
        return webContents
    }
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
    public func allCookies(completion: @escaping ([EngineCookie]) -> Void) {
        requestContext.visitAllCookies { cookies in completion(cookies.map(Self.engineCookie)) }
    }
    public func setCookie(_ cookie: EngineCookie, for url: URL) {
        requestContext.setCookie(Self.bridgeCookie(cookie), forURL: url.absoluteString)
    }
    public func setCookies(_ cookies: [EngineCookie], completion: @escaping () -> Void) {
        let addressed = cookies.compactMap { cookie in cookie.originURL.map { (Self.bridgeCookie(cookie), $0.absoluteString) } }
        requestContext.setCookies(addressed.map(\.0), forURLs: addressed.map(\.1), completion: completion)
    }
    public func removeCookie(named name: String, for url: URL) {
        requestContext.deleteCookies(forURL: url.absoluteString, name: name)
    }
    public func removeCookies(where shouldRemove: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void) {
        requestContext.deleteCookies(passingTest: { shouldRemove(Self.engineCookie($0)) }, completion: completion)
    }
    /// Chromium keeps this data by origin. The bridge clears it in a hidden browser, so no tab keeps the DevTools client it needs.
    public func removeSiteData(for origins: [URL], completion: @escaping () -> Void) {
        requestContext.clearStorage(forOrigins: origins.map(\.absoluteString), completion: completion)
    }
    private static func engineCookie(_ cookie: ARCHCEFCookie) -> EngineCookie {
        let sameSite: EngineCookieSameSite = switch cookie.sameSite {
        case .unspecified: .unspecified
        case .noRestriction: .noRestriction
        case .lax: .lax
        case .strict: .strict
        @unknown default: .unspecified
        }
        return EngineCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, expires: cookie.expires, isSecure: cookie.secure,
                            isHTTPOnly: cookie.httpOnly, sameSite: sameSite)
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
        value.sameSite = switch cookie.sameSite {
        // Chromium refuses a `SameSite=None` cookie that is not secure, so such a cookie keeps no policy, which Chromium treats as `lax`.
        case .noRestriction: cookie.isSecure ? .noRestriction : .unspecified
        case .unspecified: .unspecified
        case .lax: .lax
        case .strict: .strict
        }
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
    public weak var pageScriptDelegate: (any EnginePageScriptDelegate)?
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
    /// The profile the page loads in. Popups load in the same one.
    private let requestContext: ARCHCEFRequestContext
    /// The icon URL that last gave each host's pages their icon in this tab, by lowercase host.
    private var iconURLsByHost: [String: URL] = [:]
    /// Advances with each icon load and each move to another host, so that only the latest load shows its icon.
    private var iconGeneration = 0
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
    /// The page scripts, which a page this one opens starts with.
    private var pageScripts: [EnginePageScript]
    /// The page's video in picture in picture, from the engine's start until AVKit has finished stopping.
    private var pictureInPicture: ChromiumPictureInPicture?
    public lazy var navigationController: any EngineNavigationController = ChromiumNavigationController(webContents: self)

    init(sessionID: String, context: ChromiumBrowserContext?, requestContext: ARCHCEFRequestContext, configuration: EngineWebContentsConfiguration) {
        self.sessionID = sessionID
        self.context = context
        self.requestContext = requestContext
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.view.wantsLayer = true
        self.url = configuration.initialURL
        self.pageScripts = configuration.pageScripts
        super.init()
        browser = ARCHCEFBrowser(parentView: view, url: configuration.initialURL?.absoluteString ?? "about:blank", requestContext: requestContext,
                                 pageScripts: Self.bridgeScripts(pageScripts), delegate: self)
        browser?.allowsDownloads = !configuration.disallowDownloads
    }

    /// Adopts a popup that a page of `opener` opened, which CEF created in the opener's browsing context and profile with the opener's page scripts. The popup may download, as a WebKit popup may.
    private init(popup: ARCHCEFBrowser, opener: ChromiumWebContents) {
        self.sessionID = UUID().uuidString
        self.context = opener.context
        self.requestContext = opener.requestContext
        self.view = popup.parentView
        self.view.wantsLayer = true
        self.url = URL(engineString: popup.currentURL)
        self.pageScripts = opener.pageScripts
        self.browser = popup
        super.init()
        popup.delegate = self
    }

    public enum PDFError: Error {
        case exportFailed
    }

    public enum ScriptError: Error {
        /// The function threw, or the main frame had no document to run it in or did not answer within ten seconds.
        case failed
    }

    public private(set) var favicon: NSImage?
    public var loadProgress: Double { isLoading ? 0.5 : 1 }
    public private(set) var themeColor: NSColor?
    /// CEF cannot fill a back-forward list, so a restored tab only loads its last address.
    public var restorableState: Data? { nil }
    public private(set) var isAudible = false
    public private(set) var isFullscreen = false
    public var mediaSession: any EngineMediaSession { chromiumMediaSession }
    /// Follows each frame's media as the helper's renderer script reports it.
    private lazy var chromiumMediaSession = ScriptMediaSession { [weak self] frame, action in
        let bridgeAction: ARCHCEFMediaAction = switch action {
        case .play: .play
        case .pause: .pause
        case .previousTrack: .previousTrack
        case .nextTrack: .nextTrack
        }
        self?.browser?.performMediaAction(bridgeAction, inFrame: frame)
    }
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
    /// The helper's renderer runs the script in the page's world and replies with its result, which `executeJavaScript` cannot return and the DevTools protocol would return only by attaching a debugger. The page's scripts can change what the script sees there, which changes only the page's own text. Chromium's own pages, such as the error page it shows in place of a page that failed to load, are unreadable.
    public func readableContent(limit: Int, completion: @escaping (Result<EngineReadableContent, Error>) -> Void) {
        guard let browser else { return completion(.failure(EngineReadableContentError.unreadable)) }
        browser.evaluateScript("(\(EngineReadableContent.script))(\(limit))") { result in
            completion(Result {
                let content = try EngineReadableContent(scriptResult: result)
                guard !Self.internalSchemes.contains(content.url.scheme?.lowercased() ?? "") else { throw EngineReadableContentError.unreadable }
                return content
            })
        }
    }
    public func setPageScripts(_ scripts: [EnginePageScript]) {
        pageScripts = scripts
        browser?.setPageScripts(Self.bridgeScripts(scripts))
    }
    /// The helper's renderer calls the function in the page's world, where every world's scripts run, and replies with its result, which `executeJavaScript` cannot return.
    public func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {
        guard let browser else { return completion(.failure(ScriptError.failed)) }
        browser.callPageScriptFunction(script, inWorld: world) { succeeded, result in
            completion(succeeded ? .success(result) : .failure(ScriptError.failed))
        }
    }
    public func postPageScriptMessage(_ json: String, toWorld world: String) {
        browser?.postPageScriptMessage(json, toWorld: world)
    }
    private static func bridgeScripts(_ scripts: [EnginePageScript]) -> [ARCHCEFPageScript] {
        scripts.map { ARCHCEFPageScript(world: $0.world, source: $0.source, runsAtDocumentEnd: $0.injectionTime == .documentEnd, mainFrameOnly: $0.mainFrameOnly) }
    }
    public func insertStylesheet(_ css: String, identifier: String) {
        let escaped = css.replacingOccurrences(of: "`", with: "\\`")
        browser?.executeJavaScript("(function(){var s=document.getElementById('arch-style-\(identifier)');if(!s){s=document.createElement('style');s.id='arch-style-\(identifier)';document.documentElement.appendChild(s);}s.textContent=`\(escaped)`;})();")
    }
    public func removeStylesheet(identifier: String) {
        browser?.executeJavaScript("document.getElementById('arch-style-\(identifier)')?.remove();")
    }
    public func captureViewport(completion: @escaping (NSImage?) -> Void) {
        captureScreenshot(beyondViewport: false, completion: completion)
    }
    public func captureFullPage(completion: @escaping (NSImage?) -> Void) {
        captureScreenshot(beyondViewport: true, completion: completion)
    }
    /// The DevTools protocol captures in device pixels. The image's size is in points, as AppKit images and WebKit's snapshots are.
    private func captureScreenshot(beyondViewport: Bool, completion: @escaping (NSImage?) -> Void) {
        guard let browser else { return completion(nil) }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        browser.captureScreenshot(beyondViewport: beyondViewport) { data in
            guard let data, let image = NSImage(data: data), let pixels = image.representations.first else { return completion(nil) }
            image.size = NSSize(width: CGFloat(pixels.pixelsWide) / scale, height: CGFloat(pixels.pixelsHigh) / scale)
            completion(image)
        }
    }
    public func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {
        guard let browser else { return completion(.failure(PDFError.exportFailed)) }
        browser.printToPDF { completion($0.map { .success($0) } ?? .failure(PDFError.exportFailed)) }
    }
    public func print() { browser?.print() }
    public func exitFullscreen() {
        if isFullscreen { browser?.exitFullscreen(willResize: true) }
    }
    /// The tools close with the page. CEF reports their close only once the browser has closed, when this object may be gone, so the app learns of it now. The engine ends the page's picture in picture as the browser closes, also unreported then, so the system's window closes now.
    public func discard() {
        (devTools as? ChromiumDevTools)?.setView(nil)
        MainActor.assumeIsolated { pictureInPicture?.engineDidStop() }
        browser?.close()
    }
    public var closingStopsDownloads: Bool { browser?.hasDownloadsInProgress == true }
    public func tryToClose(completion: @escaping (Bool) -> Void) {
        guard let browser else { return completion(true) }
        browser.tryClose(completion: completion)
    }
    public private(set) lazy var devTools: (any EngineDevTools)? = ChromiumDevTools(webContents: self)

    fileprivate var hasDevTools: Bool { browser?.hasDevTools == true }
    fileprivate func showDevTools() { browser?.showDevTools() }
    fileprivate func closeDevTools() { browser?.closeDevTools() }

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
    /// CEF reports the main frame's address when a document commits and on same-document navigations, such as `history.pushState`, but reports icon URLs only once a document finishes loading or changes its icon links, and never for a page back from the back-forward cache. So the icon stays while the tab stays on one host, as WebKit's stays until the next document finishes loading, and the next report replaces it; a page on another host starts with the icon that host's pages last showed in this tab, or with none.
    public func cefBrowserDidChangeURL(_ url: String) {
        let previousURL = self.url
        self.url = URL(string: url)
        uiDelegate?.webContentsDidChangeURL(self)
        guard !FaviconLoader.keepsIcon(from: previousURL, to: self.url) else { return }
        iconGeneration += 1
        if favicon != nil {
            favicon = nil
            uiDelegate?.webContentsDidChangeFavicon(self)
        }
        if let host = self.url?.host?.lowercased(), let iconURL = iconURLsByHost[host] { loadFavicon(iconURL) }
    }
    public func cefBrowserDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        if !isLoading { authenticationAttempts.removeAll() }
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        uiDelegate?.webContentsDidChangeLoadingState(self)
    }
    public func cefBrowserDidFinishLoadingDocument() { uiDelegate?.webContentsDidFinishLoadingDocument(self) }
    public func cefBrowserDidChangeFaviconURLs(_ urls: [String]) {
        guard let iconURL = urls.lazy.compactMap(URL.init(string:)).first ?? url.flatMap(FaviconLoader.defaultIconURL(for:)) else { return }
        loadFavicon(iconURL)
    }
    /// Shows the icon at `iconURL` and remembers it for the page's host, unless another icon load starts or the tab moves to another host while it loads, so that an earlier page's icon never replaces a later one's; a page that changes its address on the same host meanwhile, as with `history.pushState`, keeps it.
    private func loadFavicon(_ iconURL: URL) {
        iconGeneration += 1
        let generation = iconGeneration
        let host = url?.host?.lowercased()
        FaviconLoader.load(iconURL) { [weak self] image in
            guard let self, let image, generation == self.iconGeneration else { return }
            if let host { self.iconURLsByHost[host] = iconURL }
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
    /// A link the user clicked with Shift reaches the navigation delegate as one for a new window, as on the WebKit engine. No other navigation asks the delegate.
    public func cefBrowserShouldOpenNewWindow(withURL url: String) -> Bool {
        guard let navigationDelegate, let target = URL(engineString: url) else { return true }
        return navigationDelegate.webContents(self, decidePolicyFor: EngineNavigationAction(url: target, disposition: .newWindow, isUserInitiated: true)) == .allow
    }
    /// Only the UI delegate adopts popups, so without one the page opens none, as on the WebKit engine.
    public func cefBrowserCanAdoptPopup() -> Bool { uiDelegate != nil }
    /// A popup keeps its `window.opener`, and it reaches the UI delegate as a WebKit popup does.
    public func cefBrowserDidOpenPopup(_ popup: ARCHCEFBrowser, targetURL: String, disposition: ARCHCEFPopupDisposition) {
        guard let uiDelegate else { return }
        let engineDisposition: EngineNavigationDisposition = switch disposition {
        case .backgroundTab: .newBackgroundTab
        case .popup: .newPopup
        case .window: .newWindow
        default: .newForegroundTab
        }
        uiDelegate.webContents(self, didCreateNewWebContents: ChromiumWebContents(popup: popup, opener: self), targetURL: URL(engineString: targetURL),
                               disposition: engineDisposition)
    }
    public func cefBrowserDidClose() {
        contextMenu?.cancelTracking()
        uiDelegate?.webContentsDidClose(self)
    }

    /// Chromium asks the system spell checker for suggestions only in the profile's spelling language. That language offers none for words in other languages, such as an English word when the system language is Korean. Try the system's preferred languages in order instead.
    private static func systemSpellingSuggestions(for word: String) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        for identifier in Locale.preferredLanguages {
            let language = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
            if let guesses = NSSpellChecker.shared.guesses(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0), !guesses.isEmpty {
                return guesses
            }
        }
        return []
    }

    /// Puts the spelling and editing items CEF can run into the menu, lets the UI delegate add the rest, and shows the menu at the click.
    public func cefBrowserRunContextMenu(_ params: ARCHCEFContextMenuParams, completion: @escaping () -> Void) {
        guard let uiDelegate, view.window != nil else { return completion() }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !params.misspelledWord.isEmpty {
            let suggestions = params.spellingSuggestions.isEmpty ? Self.systemSpellingSuggestions(for: params.misspelledWord) : params.spellingSuggestions
            for word in suggestions {
                let item = engineMenuItem(word, EngineContextMenuItem.spellingSuggestion, #selector(replaceMisspellingFromMenu(_:)), isEnabled: true)
                item.representedObject = word
                menu.addItem(item)
            }
            if suggestions.isEmpty {
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
                                               selectedText: params.selectionText.isEmpty ? nil : params.selectionText, isEditable: params.isEditable,
                                               isInMainFrame: params.isInMainFrame)
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
    /// CEF reports a main frame's address once its navigation commits, so `url` is still the page's while a navigation turns into a download.
    public func cefBrowserDidStart(_ download: ARCHCEFDownload, suggestedName: String, decision: @escaping (String?, Bool) -> Void) {
        guard let downloads = context?.chromiumDownloads else { return decision(nil, true) }
        downloads.begin(download, from: self, pageURL: url, suggestedName: suggestedName, decision: decision)
    }
    public func cefBrowserDidUpdate(_ download: ARCHCEFDownload) {
        context?.chromiumDownloads.update(download)
    }
    /// The UI delegate decides whether to grant the site's request. Camera and microphone access also require the system's permission for this app: a request for a device the system denies the app is denied without asking, and otherwise the system's permission is requested before the page gets access.
    public func cefBrowserDidRequestPermissions(_ permissions: ARCHCEFPermission, fromOrigin origin: String, decision: @escaping (Bool) -> Void) {
        let mapping: [(ARCHCEFPermission, EnginePermissionType)] = [(.camera, .camera), (.microphone, .microphone), (.screenCapture, .screenCapture), (.geolocation, .geolocation),
                                                                   (.notifications, .notifications), (.clipboard, .clipboard), (.midi, .midi)]
        let types = mapping.filter { permissions.contains($0.0) }.map(\.1)
        let mediaTypes = EngineCaptureAccess.mediaTypes(for: types)
        guard let uiDelegate, !types.isEmpty, !EngineCaptureAccess.isRefusedBySystem(mediaTypes) else { return decision(false) }
        let request = EnginePermissionRequest(origin: URL(string: origin) ?? URL(string: "about:blank")!, types: types)
        uiDelegate.webContents(self, requestPermission: request) { granted in
            guard granted else { return decision(false) }
            EngineCaptureAccess.requestAccess(for: mediaTypes, completion: decision)
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
    public func cefBrowserDevToolsDidOpen(_ view: NSView) {
        (devTools as? ChromiumDevTools)?.setView(view)
    }

    public func cefBrowserDevToolsDidClose() {
        (devTools as? ChromiumDevTools)?.setView(nil)
    }

    public func cefBrowserDidChangeAudible(_ isAudible: Bool) {
        self.isAudible = isAudible
        uiDelegate?.webContentsDidChangeAudibleState(self)
    }
    public func cefBrowserDidChangeMedia(_ media: [String: Any]?, frame: String) {
        chromiumMediaSession.update(document: frame, report: media)
    }

    /// The video plays in the system's window from a layer below the page. The window's return button asks the UI delegate to show the page.
    public func cefBrowserDidStartPictureInPicture(naturalSize: NSSize, sourceRect: NSRect) {
        guard let browser else { return }
        MainActor.assumeIsolated {
            let session = ChromiumPictureInPicture(browser: browser) { [weak self] in
                guard let self else { return }
                self.uiDelegate?.webContentsDidRequestActivation(self)
            } didFinish: { [weak self] session in
                if self?.pictureInPicture === session { self?.pictureInPicture = nil }
            }
            pictureInPicture = session
            session.start(in: view, below: browser.browserView, sourceRect: sourceRect, naturalSize: naturalSize)
        }
    }

    public func cefBrowserDidReceivePictureInPictureFrame(_ surface: IOSurfaceRef, contentRect: NSRect) {
        MainActor.assumeIsolated { pictureInPicture?.enqueue(surface, contentRect: contentRect) }
    }

    public func cefBrowserDidChangePictureInPicturePlaying(_ playing: Bool, canPlayPause: Bool) {
        MainActor.assumeIsolated { pictureInPicture?.update(isPlaying: playing, canPlayPause: canPlayPause) }
    }

    /// The session stays until AVKit has finished stopping.
    public func cefBrowserDidStopPictureInPicture() {
        MainActor.assumeIsolated { pictureInPicture?.engineDidStop() }
    }

    public func cefBrowserDidReceivePageScriptMessage(_ json: String, world: String, frameURL: String, isMainFrame: Bool, reply: @escaping (String?) -> Void) {
        let reply = EnginePageScriptReply(reply)
        guard let pageScriptDelegate else { return reply.send(nil) }
        pageScriptDelegate.webContents(self, didReceive: EnginePageScriptMessage(world: world, frameURL: URL(engineString: frameURL), isMainFrame: isMainFrame, json: json),
                                       reply: reply.send)
    }

    public func cefBrowserDidChangeThemeColor(_ color: String) {
        let themeColor = Self.color(fromCanvasStyle: color)
        guard themeColor != self.themeColor else { return }
        self.themeColor = themeColor
        uiDelegate?.webContentsDidChangeThemeColor(self)
    }

    /// Reads `#rrggbb` or `rgba(r, g, b, a)`, the two forms a canvas writes. A transparent color counts as none.
    static func color(fromCanvasStyle style: String) -> NSColor? {
        if style.hasPrefix("#"), style.count == 7, let value = Int(style.dropFirst(), radix: 16) {
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        guard style.hasPrefix("rgba("), style.hasSuffix(")") else { return nil }
        let parts = style.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[3] > 0 else { return nil }
        return NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts[3])
    }

    /// Alloy style leaves the window's transition to the app, which the UI delegate makes.
    public func cefBrowserDidChangeFullscreen(_ isFullscreen: Bool) {
        self.isFullscreen = isFullscreen
        if isFullscreen {
            uiDelegate?.webContentsDidRequestEnterFullscreen(self)
        } else {
            uiDelegate?.webContentsDidRequestExitFullscreen(self)
        }
    }
    /// Reports the crash, then reloads the page once. The page stays blank after two consecutive crashes on the same URL.
    public func cefBrowserRenderProcessDidTerminate() {
        // The page's frames never report their media again.
        chromiumMediaSession.removeAllDocuments()
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

/// Chromium's developer tools, which CEF shows inside a view of the bridge's, without a browser of their own; the app places the view beside the page or in a window. CEF offers no way to pick a panel.
final class ChromiumDevTools: EngineDevTools {
    private unowned let webContents: ChromiumWebContents
    private(set) var view: NSView?
    var didChangeView: (() -> Void)?
    var isPlacedByApp: Bool { true }

    init(webContents: ChromiumWebContents) {
        self.webContents = webContents
    }

    fileprivate func setView(_ view: NSView?) {
        guard view !== self.view else { return }
        self.view = view
        didChangeView?()
    }

    var isOpen: Bool { webContents.hasDevTools }
    func open() { webContents.showDevTools() }
    func close() { webContents.closeDevTools() }
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
