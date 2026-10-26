// Web extensions on Chromium, through the extension runtime that Arch's engine adds to CEF (an experimental API, VI.1): every tab stays an Alloy style browser, and each profile's own Chromium extension system loads the app's packages unpacked, runs their backgrounds and content scripts, and keeps their storage. The app's windows reach the `tabs` and `windows` APIs as client windows, and action popups, the tabs and windows extensions open, and prompts go to the app through the delegate.
import AppKit
import ARCHEngine
import CEFBridge
import Foundation

/// One profile's extensions. Chromium keeps the extensions it loaded in the profile and starts them with it at later launches, so once the app says so (`stopUnloadedExtensions()`), after its first pass of loads or as the profile starts while it loads none, the adapter switches off, as soon as Chromium lists it, every extension that the app has not loaded in this run; the app loads its enabled ones again each run. Everything runs on the main thread, CEF's UI thread: the asynchronous calls move there first.
final class ChromiumExtensions: NSObject, EngineExtensions, @unchecked Sendable {
    weak var delegate: (any EngineExtensionsDelegate)?
    private unowned let context: ChromiumBrowserContext
    private var requestContext: ARCHCEFRequestContext { context.requestContext }
    /// What the app loaded in this run, by identifier.
    private var loaded: [String: EngineExtension] = [:]
    /// The extensions whose load has not finished, which Chromium may list before the load ends.
    private var loading: Set<String> = []
    /// The extensions that loaded once in this run. A first load of a package installed before the engine started, which Chromium already runs from the same folder and version, keeps Chromium's copy, so that it does not reinstall on every launch; later loads and packages installed in this run, as after an update, reload the package, since Chromium read its copy when the profile started.
    private var loadedInRun: Set<String> = []
    /// Set at the app's first `stopUnloadedExtensions()`, from which on the adapter switches off what the app has not loaded.
    private var stopsUnloaded = false
    /// The extensions' names, from Chromium's last list, for actions without a title.
    private var names: [String: String] = [:]
    private var windows: [UUID: ChromiumExtensionWindow] = [:]
    private var focusedWindowID: UUID?
    /// Completions of window requests that wait for the app to report the window.
    private var pendingWindows: [UUID: [(ARCHCEFExtensionWindow?) -> Void]] = [:]
    /// The actions of each tab's page, by identifier, as Chromium gave them since the last change.
    private var actionCache: [ObjectIdentifier: [String: EngineExtensionAction]] = [:]

    /// Starts the profile's extension runtime with the adapter as its delegate.
    init(context: ChromiumBrowserContext) {
        self.context = context
        super.init()
        context.requestContext.extensionsDelegate = self
        switchOffUnloadedExtensions()
    }

    func stopUnloadedExtensions() {
        stopsUnloaded = true
        switchOffUnloadedExtensions()
    }

    // MARK: Loading

    func check(_ packageURL: URL) async throws {
        try ChromiumPackageCheck.check(packageURL)
    }

    /// Loads the package unpacked from its folder, whose manifest's `key` gives the extension the app's identifier, then switches it on and sets where its host permissions apply: on every site its manifest asks for when the user granted them all, or else on a click, which leaves the user to allow it on a site. Chromium grants the API permissions the manifest asks for, which are those the app's install grants.
    func load(_ extension: EngineExtension) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.main.async { self.startLoading(`extension`) { continuation.resume(with: $0) } }
        }
    }

    private func startLoading(_ extension: EngineExtension, completion: @escaping (Result<Void, any Error>) -> Void) {
        let id = `extension`.id
        let path = `extension`.packageURL.resolvingSymlinksInPath().path
        loading.insert(id)
        requestContext.extensions { [weak self] installed in
            guard let self else { return completion(.failure(ChromiumExtensionError.notLoaded)) }
            let copy = installed.first { $0.identifier == id }.map { (path: $0.path, version: $0.version) }
            let keepsCopy = Self.keepsCopy(copy, of: `extension`, at: path, loadedInRun: self.loadedInRun.contains(id), engineStartedAt: self.context.application?.startedAt)
            let finish: (Result<Void, any Error>) -> Void = { result in
                self.loading.remove(id)
                if case .success = result {
                    self.loadedInRun.insert(id)
                    self.loaded[id] = `extension`
                    self.requestContext.setExtension(id, enabled: true)
                    self.requestContext.setExtension(id, siteAccess: Self.siteAccess(for: `extension`))
                    self.actionCache.removeAll()
                }
                completion(result)
            }
            if keepsCopy { return finish(.success(())) }
            self.requestContext.loadExtension(atPath: path) { loadedID, error in
                guard let loadedID else { return finish(.failure(ChromiumExtensionError.refused(error ?? ""))) }
                guard loadedID == id else {
                    // A package without the app's key, which Chromium names by its folder; the copy it made goes.
                    self.requestContext.removeExtension(loadedID)
                    return finish(.failure(ChromiumExtensionError.otherIdentifier))
                }
                finish(.success(()))
            }
        }
    }

    /// Whether a load from the folder at `path` keeps the copy that Chromium runs (`copy`, with its folder and version) instead of loading the package again: only at the extension's first load in the run, for a package installed before the engine started, whose folder and version the copy has, as Chromium read it when the profile started.
    static func keepsCopy(_ copy: (path: String, version: String)?, of extension: EngineExtension, at path: String, loadedInRun: Bool, engineStartedAt: Date?) -> Bool {
        guard !loadedInRun, let copy, let installedAt = `extension`.installedAt, let engineStartedAt, installedAt < engineStartedAt else { return false }
        return copy.path == path && copy.version == ChromiumManifest(packageAt: `extension`.packageURL)?.version
    }

    /// Every site the manifest asks for when the grant has them all, or every web page; otherwise on a click. Patterns compare with their schemes and hosts in lowercase, as the app's grants write them and Chromium reads them. The patterns for schemes other than `http`, `https`, and `*`, which the app's grants cannot hold and the install sheet never showed, are left out, since Arch's engine keeps extensions out of `file:` pages. A pattern with a port, which the install sheet never showed either, keeps the click.
    static func siteAccess(for extension: EngineExtension) -> ARCHCEFExtensionSiteAccess {
        let asked = Set((ChromiumManifest(packageAt: `extension`.packageURL)?.hostPatterns ?? []).map(lowercasingSchemeAndHost).filter(isWebPattern))
        return `extension`.sites.contains("<all_urls>") || asked.isSubset(of: `extension`.sites) ? .onAllSites : .onClick
    }

    /// Whether the pattern, with its scheme in lowercase, is `<all_urls>` or has the scheme `http`, `https`, or `*`, as the app's grants do.
    static func isWebPattern(_ pattern: String) -> Bool {
        guard pattern != "<all_urls>" else { return true }
        guard let separator = pattern.range(of: "://") else { return false }
        return ["http", "https", "*"].contains(pattern[..<separator.lowerBound])
    }

    /// The match pattern with its scheme and host in lowercase; its path keeps its case.
    static func lowercasingSchemeAndHost(_ pattern: String) -> String {
        guard let separator = pattern.range(of: "://") else { return pattern }
        let rest = pattern[separator.upperBound...]
        let pathStart = rest.firstIndex(of: "/") ?? rest.endIndex
        return pattern[..<separator.lowerBound].lowercased() + "://" + rest[..<pathStart].lowercased() + rest[pathStart...]
    }

    /// Switches the extension off, which keeps its storage and keeps it off at later launches.
    func unload(_ id: String) {
        loaded[id] = nil
        actionCache.removeAll()
        requestContext.setExtension(id, enabled: false)
    }

    /// Uninstalls the extension from the profile, which deletes its storage.
    func removeData(of id: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                self.loadedInRun.remove(id)
                self.requestContext.removeExtension(id)
                continuation.resume()
            }
        }
    }

    /// Notes the names of the extensions that Chromium lists and, once `stopUnloadedExtensions()` has been called, switches off each one that Chromium runs and the app has not loaded or is not loading.
    private func switchOffUnloadedExtensions() {
        requestContext.extensions { [weak self] installed in
            guard let self else { return }
            for item in installed {
                self.names[item.identifier] = item.name
                guard self.stopsUnloaded, item.isEnabled, self.loaded[item.identifier] == nil, !self.loading.contains(item.identifier) else { continue }
                self.requestContext.setExtension(item.identifier, enabled: false)
            }
        }
    }

    // MARK: Actions

    func action(of id: String, for tab: any EngineWebContents) -> EngineExtensionAction? {
        guard loaded[id] != nil, let contents = ownContents(tab), let browser = contents.browser else { return nil }
        let key = ObjectIdentifier(browser)
        if actionCache[key] == nil {
            let scale = contents.view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            var actions: [String: EngineExtensionAction] = [:]
            for action in requestContext.extensionActions(for: browser, scale: scale) {
                actions[action.extensionIdentifier] = EngineExtensionAction(label: action.title.isEmpty ? names[action.extensionIdentifier] ?? "" : action.title, icon: action.icon,
                                                                           badgeText: action.badgeText, isEnabled: action.isEnabled, wantsSiteAccess: action.wantsSiteAccess)
            }
            actionCache[key] = actions
        }
        return actionCache[key]?[id]
    }

    func performAction(of id: String, for tab: any EngineWebContents) {
        guard loaded[id] != nil, let browser = ownContents(tab)?.browser else { return }
        requestContext.runExtensionAction(id, in: browser)
    }

    func grantSiteAccess(of id: String, for tab: any EngineWebContents) {
        guard loaded[id] != nil, let browser = ownContents(tab)?.browser else { return }
        requestContext.grantExtensionSiteAccess(id, in: browser)
    }

    /// The web contents of this profile, the only ones its extensions see.
    private func ownContents(_ tab: any EngineWebContents) -> ChromiumWebContents? {
        guard let contents = tab as? ChromiumWebContents, contents.context === context else { return nil }
        return contents
    }

    // MARK: Windows

    /// Each reported window becomes one client window, kept while the window stays, which lists the profile's tabs in the window's order. Chromium tells extensions what opened, closed, moved, and became active, and a tab that leaves one window and joins another in the same report is detached and attached. A window with the identity of a window before it in the report is left out.
    func setWindows(_ reported: [EngineExtensionWindow], focusedWindowID: UUID?) {
        var listed: Set<UUID> = []
        for report in reported where listed.insert(report.id).inserted {
            let window = windows[report.id] ?? makeWindow(report.id)
            window.follow(report.window)
            let tabs = report.tabs.compactMap { ownContents($0) }
            let browsers = tabs.compactMap(\.browser)
            let active = report.activeTab.flatMap { activeTab in tabs.firstIndex { $0 === activeTab } } ?? -1
            window.window.setTabs(browsers, activeIndex: active)
        }
        for (id, window) in windows where !listed.contains(id) {
            window.close()
            windows[id] = nil
        }
        if self.focusedWindowID != focusedWindowID {
            self.focusedWindowID.flatMap { windows[$0] }?.window.setFocused(false)
            self.focusedWindowID = focusedWindowID
        }
        focusedWindowID.flatMap { windows[$0] }?.window.setFocused(true)
        for (id, completions) in pendingWindows where windows[id] != nil {
            pendingWindows[id] = nil
            completions.forEach { $0(windows[id]?.window) }
        }
    }

    private func makeWindow(_ id: UUID) -> ChromiumExtensionWindow {
        let window = ChromiumExtensionWindow(requestContext: requestContext)
        windows[id] = window
        return window
    }
}

extension ChromiumExtensions: ARCHCEFExtensionsDelegate {
    func cefExtensionsDidChange() {
        actionCache.removeAll()
        switchOffUnloadedExtensions()
    }

    func cefExtensionActionDidChange(_ extensionIdentifier: String, browser: ARCHCEFBrowser?) {
        actionCache.removeAll()
        guard loaded[extensionIdentifier] != nil else { return }
        delegate?.extensions(self, didUpdateActionOf: extensionIdentifier)
    }

    func cefExtensionsShouldShowPopup(_ popup: ARCHCEFExtensionPopup, for browser: ARCHCEFBrowser) -> Bool {
        guard let delegate, let tab = browser.delegate as? ChromiumWebContents, let view = ChromiumExtensionPopup(popup) else { return false }
        return delegate.extensions(self, present: .view(view), ofExtension: popup.extensionIdentifier, for: tab)
    }

    func cefExtensionsOpenTab(withURL url: String, in window: ARCHCEFExtensionWindow?, active: Bool, index: Int, completion: @escaping (ARCHCEFBrowser?) -> Void) -> Bool {
        guard let delegate else { return false }
        let windowID = window.flatMap { window in windows.first { $0.value.window === window }?.key }
        delegate.extensions(self, openTabWith: URL(engineString: url), inWindow: windowID, active: active, index: index >= 0 ? index : nil) { [weak self] contents in
            completion(contents.flatMap { self?.ownContents($0)?.browser })
        }
        return true
    }

    func cefExtensionsActivate(_ browser: ARCHCEFBrowser) {
        guard let tab = browser.delegate as? ChromiumWebContents else { return }
        delegate?.extensions(self, activate: tab)
    }

    func cefExtensionsClose(_ browser: ARCHCEFBrowser) {
        guard let tab = browser.delegate as? ChromiumWebContents else { return browser.close() }
        delegate?.extensions(self, close: tab)
    }

    func cefExtensionsOpenWindow(withURLs urls: [String], focused: Bool, completion: @escaping (ARCHCEFExtensionWindow?) -> Void) -> Bool {
        guard let delegate else { return false }
        delegate.extensions(self, openWindowWith: urls.compactMap(URL.init(engineString:)), focused: focused) { [weak self] id in
            guard let self, let id else { return completion(nil) }
            if let window = self.windows[id] { return completion(window.window) }
            self.pendingWindows[id, default: []].append(completion)
        }
        return true
    }

    /// Install prompts, from the store install flow, are refused without asking.
    func cefExtensionsShowPrompt(_ kind: ARCHCEFExtensionPromptKind, extension extensionIdentifier: String, browser: ARCHCEFBrowser?, messages: [String],
                                 completion: @escaping (Bool) -> Void) -> Bool {
        guard let delegate, kind != .install else { return false }
        let tab = browser.flatMap { $0.delegate as? ChromiumWebContents }
        let prompt = EngineExtensionPrompt(kind: kind == .reload ? .reload(messages) : .permissions(messages), tab: tab)
        delegate.extensions(self, extension: extensionIdentifier, asks: prompt, completion: completion)
        return true
    }
}

/// One of the app's windows as Chromium's extensions see it. CEF's client window reads its frame and state from an AppKit window that holds a given view, and keeps that window for its life, while the window that shows an app window changes and can be none; so each client window has a hidden stand-in of its own that answers with the frame, minimized, zoomed, and full screen state of the window that shows it. The stand-in never shows, and `windows.remove` and focus requests, which reach it, do nothing.
final class ChromiumExtensionWindow {
    let window: ARCHCEFExtensionWindow
    private let standIn: StandInWindow

    init(requestContext: ARCHCEFRequestContext) {
        standIn = StandInWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: true)
        standIn.isReleasedWhenClosed = false
        standIn.isExcludedFromWindowsMenu = true
        // A borderless window always has a content view.
        window = requestContext.makeExtensionWindow(for: standIn.contentView!)
    }

    /// Answers from the AppKit window that shows the app window, or from the stand-in's own state while no window shows it.
    func follow(_ shown: NSWindow?) {
        standIn.shown = shown
    }

    func close() {
        window.close()
    }

    /// Reads the shown window's frame and state at each question, so that a move, a resize, or full screen needs no new report.
    private final class StandInWindow: NSWindow {
        weak var shown: NSWindow?
        override var frame: NSRect { shown?.frame ?? super.frame }
        override var isMiniaturized: Bool { shown?.isMiniaturized ?? false }
        override var isZoomed: Bool { shown?.isZoomed ?? false }
        /// The full screen flag comes from the shown window; the rest of the mask stays the stand-in's own, which AppKit lays it out by.
        override var styleMask: NSWindow.StyleMask {
            get { shown?.styleMask.contains(.fullScreen) == true ? super.styleMask.union(.fullScreen) : super.styleMask }
            set { super.styleMask = newValue }
        }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func performClose(_ sender: Any?) {}
        override func makeKeyAndOrderFront(_ sender: Any?) {}
    }
}

/// A popup page from Chromium's runtime, as the app shows it.
final class ChromiumExtensionPopup: EngineExtensionPopupView {
    private let popup: ARCHCEFExtensionPopup
    let view: NSView
    var sizeDidChange: ((CGSize) -> Void)?
    var didClose: (() -> Void)?

    /// Nil for a popup that has closed.
    init?(_ popup: ARCHCEFExtensionPopup) {
        guard let view = popup.view else { return nil }
        self.popup = popup
        self.view = view
        popup.sizeDidChange = { [weak self] size in self?.sizeDidChange?(size) }
        popup.didClose = { [weak self] in
            let didClose = self?.didClose
            self?.didClose = nil
            didClose?()
        }
    }

    var preferredSize: CGSize { popup.preferredSize }

    func close() {
        popup.close()
    }
}

enum ChromiumExtensionError: LocalizedError {
    case refused(String)
    case otherIdentifier
    case notLoaded

    var errorDescription: String? {
        switch self {
        case let .refused(reason): return reason.isEmpty ? "Chromium did not load it." : reason
        case .otherIdentifier: return "Chromium knows the package by another identifier, as its manifest has no key."
        case .notLoaded: return "Chromium did not load it."
        }
    }
}
