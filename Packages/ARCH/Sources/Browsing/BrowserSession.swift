// Owns each engine's application and, for each Persona, one runtime per engine (the Persona's profile and browser), each started when a tab first needs it, so tabs of both engines live side by side, and the Persona's plugins. Also owns sidebar state: Personas, spaces, favorites and the tabs they keep alive, tabs, tab folders, split views, and the closed-tab list, and the app-wide stores it keeps in its folder: history, remembered site permissions, site search, and the live folders' items (`LiveFolderTabs.swift`). Archives inactive tabs on a timer, which also unloads inactive pinned tabs and favorites' tabs, as memory pressure unloads every tab that no window shows. Opens the browser windows, main windows with the sidebar and small windows for links from other apps, and follows them as they become main and close; each window's own state and commands live in its `BrowserWindowModel`, which views, menus, and scripts reach through `activeWindow` or `sidebarTarget()`.
import AppKit
import ARCHEngine
import Combine
import Extensions
import Foundation
import History
import LiveFolders
import Plugins

/// One engine's running pieces for one Persona: the Persona's profile in the engine and the browser that owns the web contents of the Persona's tabs in that engine. The session keeps the engine's application.
final class EngineRuntime {
    let kind: EngineKind
    let personaID: Persona.ID
    let context: any EngineBrowserContext
    let browser: any EngineBrowser

    init(kind: EngineKind, personaID: Persona.ID, context: any EngineBrowserContext, browser: any EngineBrowser) {
        self.kind = kind
        self.personaID = personaID
        self.context = context
        self.browser = browser
    }
}

public final class BrowserSession: ObservableObject {
    private let registry: EngineRegistry
    /// The folder that holds every file the session keeps: `session.json`, Chromium's profiles in `Cache/Chromium`, the plugins, the browser import's record, and the files of `history`, `sitePermissions`, and `siteSearch`. WebKit keeps its website data where the system puts it for the app.
    public let userDataDirectory: URL
    /// The pages visited in every Persona. The tabs record their pages there, and the palette, the History window, and imports read and add pages.
    public let history: HistoryStore
    /// The remembered answers to websites' permission requests in every Persona, which Settings ▸ Websites changes.
    public let sitePermissions: SitePermissionStore
    /// The keyword shortcuts that the palette searches and Settings ▸ Site Search and imports change.
    public let siteSearch: SiteSearchStore
    /// Whether macOS lets Arch show notifications, which the download notifier, the permission card, and Settings ▸ Websites share.
    public let notificationAuthorization = NotificationAuthorization()
    /// Keeps the live folders up to date: `live-folders.json`, the private feed addresses in the Keychain, the refresh schedule, and the fetches. The session registers its live folders and applies each refresh to their tabs (`LiveFolderTabs.swift`).
    let liveFolderService: LiveFolderService
    /// Each live folder's unread count, refresh, failure, and dismissed items, which its row and menu show.
    let liveFolderStatuses = LiveFolderStatuses()
    /// Each feed folder's icon, the `/favicon.ico` of its feed's host, which the rows of its items' tabs show until their pages load, and the icon address it came from, loaded once per folder and launch.
    var liveFolderIcons: [UUID: (url: URL, image: NSImage?)] = [:]
    /// The live folders' subscriptions to the folders, the app's activation, and the windows' spaces.
    var liveFolderObservers: Set<AnyCancellable> = []
    /// Each running engine's application, started once.
    private var applications: [EngineKind: any EngineApplication] = [:]
    /// The engines whose application did not start the last time the session tried, which run no web extensions meanwhile.
    private var enginesThatDidNotStart: Set<EngineKind> = []
    /// Each Persona's runtimes, from the Persona's first tab until quit, and its plugins.
    private var personaEngines: [Persona.ID: PersonaEngines] = [:]
    /// The runtimes of Personas deleted since launch, kept without tabs until quit, because the download items in their rows refer to their download lists and profiles unowned.
    private var retiredPersonaEngines: [PersonaEngines] = []
    /// The engine that started with the session. Tabs fall back to it when another engine cannot start.
    private let primaryEngine: EngineKind
    /// The deleted Personas whose stored data is still on disk.
    private let personaDataRemoval: PersonaDataRemoval
    /// The spaces' tabs. Favorites keep their own tabs in `favoriteTabs`.
    @Published public private(set) var tabs: [Tab] = []
    /// Every Persona, the default one among them. Each space, favorite, and tab belongs to one.
    @Published public private(set) var personas: [Persona] = []
    @Published public private(set) var spaces: [Space] = []
    @Published public private(set) var favorites: [Favorite] = []
    /// The active window's selected tab. Now Playing and AppleScript's `active tab` follow it.
    @Published public private(set) var focusedTabID: UUID?
    /// Downloads reported by the engine and not removed by the user, oldest first.
    @Published public private(set) var downloads: [DownloadEntry] = [] {
        didSet { downloadSummary.refresh(from: downloads) }
    }
    /// What the library button and the downloads list's Clear button show of `downloads`. Their progress publishes there rather than from the session, so that it does not redraw every view that follows the session.
    let downloadSummary = DownloadSummary()
    /// The entries of downloads that finished while no window showed the library. The library button shows their count.
    @Published public private(set) var unseenDownloadIDs: Set<UUID> = []
    /// Counts the most recently closed tabs the user closed since they last pressed another key or clicked in the page. ⌘Z reopens them one at a time, newest first.
    public private(set) var undoableCloseCount = 0
    /// The app sets this to open its Settings window from the library.
    public var showSettings: (() -> Void)?
    /// The app sets this to open Settings ▸ Plugins at a plugin in a Persona with the open panel for the plugin's version for an engine, for Install <Engine> Version… in the site settings popover, with the tab's space, which the review names with the Persona.
    public var installEngineVersion: ((Persona.ID, Space.ID?, PluginID, EngineKind) -> Void)?
    /// The app sets this to open Settings ▸ Plugins at a Persona with the store sheet started for an extension identifier, for the Web Store's entry points in the site settings popover and the palette (`docs/web-store.md`, Entry points), with the space of the tab or the window, which the review names with the Persona.
    public var installFromWebStore: ((Persona.ID, Space.ID?, String) -> Void)?
    /// Downloads extensions from the Web Store and stages them in any Persona's plugins, and keeps each Persona's update check for the run (`docs/web-store.md`).
    public let webStore: WebStoreInstaller
    /// `NativeMessagingHosts/` in `userDataDirectory`, which every Persona's web extensions reach native apps through, with Arch's links to the host manifests that native app vendors install for other browsers, and the proof gate on them (`docs/password-managers.md`).
    public let nativeMessagingHosts: NativeMessagingHostLinks
    /// The app sets this to open the built-in terminal, where the New Live Folder sheet sends the user to install `gh` and sign in (live folder rule 3).
    public var openTerminal: (() -> Void)?
    /// The last `SessionSnapshot.maximumClosedTabs` closed or archived tabs, oldest first. The newest reopens first.
    @Published private var closedTabs: [SessionSnapshot.TabRecord] = []
    /// Archives inactive tabs and unloads inactive bookmarks every 30 minutes.
    private var archiveTimer: Timer?
    /// Unloads tabs that no window shows when macOS reports memory pressure (bookmark rule 5).
    private var memoryPressure: MemoryPressureMonitor?

    /// The results page of the search engine chosen in Settings.
    public static var searchURL: URL { SearchEngine.current.resultsURL }
    /// The page a tab opens without an address: the home page of the search engine chosen in Settings.
    public static var newTabURL: URL { SearchEngine.current.homeURL }

    private let store: SessionStore
    private var cancellables: Set<AnyCancellable> = []
    private var tabObservers: [UUID: AnyCancellable] = [:]
    /// Each engine's running total of page process crashes.
    private var crashCounts: [EngineKind: Int] = [:]
    /// The engines' total of page process crashes, kept for the tab close log.
    public var rendererCrashCount: Int { crashCounts.values.reduce(0, +) }
    /// Tabs that only ever pointed at a file. Each closes once the engine creates the download its page started.
    private var downloadOnlyTabIDs: Set<UUID> = []
    /// The downloads a page's `PageDownloadGate` let through. WebKit asks for a destination again when Resume starts a download over without resume data, which the gate does not count again.
    private let admittedDownloads = NSHashTable<AnyObject>.weakObjects()
    /// Pages of closed or engine-switched tabs whose downloads would stop if the pages closed, as on Chromium, each with the runtime that created it. Each stays open without a tab, on a blank page, until its own downloads are no longer in progress, paused, or interrupted.
    private var downloadPages: [(runtime: EngineRuntime, webContents: any EngineWebContents)] = []
    /// Created with the session at launch, so that clicking a notification from an earlier run still reveals its file.
    private let downloadNotifier: DownloadNotifier
    /// The prompts that tabs asked for, which a window shows as cards over their tabs' panes.
    let prompts = TabPromptQueue()
    /// Set while the app quits. Every prompt ends at once without the user, so that a page's next dialog cannot hold the quit and every engine callback has its answer before the engines shut down. A quit that does not happen, as when a window's own sheet holds it, opens the prompt queue again.
    public var isQuitting = false {
        didSet {
            if isQuitting { prompts.close() } else { prompts.reopen() }
        }
    }

    /// Loads the saved session and the stores in `userDataDirectory`, removes deleted Personas' stored data, then starts the default engine, or the first registered engine that starts when the default cannot. The other engines start when a tab first needs them. Every Persona's plugin manager offers `builtInPlugins`, the plugins the app ships. `cefVersion` is the CEF version of Arch's Chromium engine, whose Chromium version `webStore` asks the Web Store with, or nil without that engine. `nativeMessagingHostFolders` are the folders where native app vendors install host manifests for other browsers, which `nativeMessagingHosts` reads without changing them, and `chromiumNativeMessagingHosts` is the system folder that Arch's Chromium engine reads host manifests from itself, which its gate counts, or nil without that engine.
    public init(registry: EngineRegistry = .shared, userDataDirectory: URL, builtInPlugins: [any BuiltInPlugin.Type], cefVersion: String?, nativeMessagingHostFolders: [URL] = [],
                chromiumNativeMessagingHosts: URL? = nil) throws {
        self.registry = registry
        self.userDataDirectory = userDataDirectory
        self.builtInPlugins = builtInPlugins
        webStore = WebStoreInstaller(client: WebStoreClient(productVersion: cefVersion.flatMap(WebStoreClient.chromiumVersion(inCEFVersion:)) ?? ""))
        // The app makes the session on the main thread.
        nativeMessagingHosts = MainActor.assumeIsolated {
            NativeMessagingHostLinks(directory: userDataDirectory.appendingPathComponent("NativeMessagingHosts", isDirectory: true), folders: nativeMessagingHostFolders,
                                     chromiumFolder: chromiumNativeMessagingHosts)
        }
        store = SessionStore(directory: userDataDirectory)
        history = HistoryStore(directory: userDataDirectory)
        sitePermissions = SitePermissionStore(directory: userDataDirectory)
        siteSearch = SiteSearchStore(directory: userDataDirectory)
        permissionAnswers = SitePermissionAnswers(store: sitePermissions, notifications: notificationAuthorization)
        downloadNotifier = DownloadNotifier(authorization: notificationAuthorization)
        // Without a saved session, or with a file that did not load, the session starts from an empty snapshot. Normalizing gives every Persona a space, so there is always a current space.
        let snapshot = store.load() ?? SessionSnapshot.empty.normalized()
        // The session is created on the main thread, where the live folders' service runs. While a file that did not decode is set aside, its live folders keep their entries and Keychain items for a repaired file.
        let keepsUnknownLiveFolders = store.keepsUnknownLiveFolders
        liveFolderService = MainActor.assumeIsolated {
            LiveFolderService(store: LiveFolderStore(fileURL: userDataDirectory.appendingPathComponent(LiveFolderStore.fileName)), keepsUnknownFolders: keepsUnknownLiveFolders)
        }
        // An engine cannot remove the storage of a profile it has loaded, so the removal comes before any engine starts.
        personaDataRemoval = PersonaDataRemoval(ids: snapshot.removedPersonaIDs ?? [], registry: registry,
                                                configuration: Self.engineConfiguration(userDataDirectory: userDataDirectory)) {
            let pluginDataRemoved = PluginManager.removeData(ofPersona: $0, in: userDataDirectory)
            let cookieRecordRemoved = CookieSync.removeRecord(ofPersona: $0, in: userDataDirectory)
            return pluginDataRemoved && cookieRecordRemoved
        }
        let candidates = [registry.defaultKind] + registry.registeredKinds.filter { $0 != registry.defaultKind }
        var primary: (any EngineApplication)?
        for kind in candidates where primary == nil {
            primary = Self.makeApplication(kind, registry: registry, userDataDirectory: userDataDirectory)
            if primary == nil { enginesThatDidNotStart.insert(kind) }
        }
        guard let primary else { throw SessionError.noEngineStarted }
        primaryEngine = primary.engineKind
        // The windows open once the app has built its menus (`restoreWindows()`). Normalizing gives every snapshot a window.
        windowsToReopen = snapshot.windows ?? []
        personas = snapshot.personas ?? []
        spaces = snapshot.spaces
        favorites = snapshot.favorites
        folders = snapshot.folders?.filter { folder in snapshot.spaces.contains { $0.id == folder.spaceID } } ?? []
        closedTabs = snapshot.closedTabs ?? []
        start(primary)
        MainActor.assumeIsolated {
            nativeMessagingHosts.gateWidens = { [weak self] in await self?.takeGatedVersionsOutOfChromium() }
        }
        // The default Persona's runtime of the primary engine starts with the session, so the other engine's runtime in that Persona, whenever it starts, takes its cookies from the primary engine.
        _ = runtime(for: primaryEngine, in: Persona.defaultID)
        restoreTabs(snapshot)
        restoreFavoriteTabs(snapshot)
        observeChanges()
        personaDataRemoval.didRemove = { [weak self] in self?.scheduleSave() }
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.archiveInactiveTabs()
            self?.unloadInactiveTabs(pressure: nil)
        }
        memoryPressure = MemoryPressureMonitor { [weak self] in self?.unloadInactiveTabs(pressure: $0) }
        nowPlaying = NowPlaying(session: self)
        // The session is created on the main thread, where the AI interface and the plugins run.
        MainActor.assumeIsolated {
            pageAssistant.attach(to: self)
            pluginPages.attach(to: self)
            hooks.attach(to: self)
            startLiveFolders()
        }
    }

    public enum SessionError: Error {
        case noEngineStarted
    }

    // MARK: Windows

    /// The open browser windows, the most recently main first.
    @Published public private(set) var windows: [BrowserWindowModel] = []
    /// The AppKit side of each open window, which owns the window.
    private var windowControllers: [BrowserWindowController] = []
    /// The main windows that open while none is open, front to back: the saved session's until they open, then the last main window that closed. The saved session keeps them while no main window is open. Never empty.
    private var windowsToReopen: [SessionSnapshot.WindowRecord]

    /// The browser window that page commands act on: the one of either kind that last became main, which stays the target while Settings or History is key (window rule 7). Nil while no browser window is open.
    public var activeWindow: BrowserWindowModel? { windows.first }

    /// The main window that last became main, or nil while none is open. Menu validation and other checks read it, because they must not create a window.
    public var lastMainWindow: BrowserWindowModel? { windows.first { $0.kind == .main } }

    /// The window that sidebar commands act on: the last main window, or, while none is open, the front one of the main windows that reopen from `windowsToReopen` (window rule 7).
    public func sidebarTarget() -> BrowserWindowModel { lastMainWindow ?? reopenWindows(windowsToReopen)[0] }

    /// The Persona of the sidebar target, read without opening a window: the last main window's, or, while none is open, that of the space the front window of `windowsToReopen` would open on, or of the first space once that one is gone, as `currentSpace` falls back. The Bookmarks menu lists its favorites.
    var sidebarTargetPersonaID: Persona.ID {
        if let window = lastMainWindow { return window.personaID }
        return (spaces.first { $0.id == windowsToReopen[0].currentSpaceID } ?? spaces[0]).resolvedPersonaID
    }

    /// Opens the saved session's main windows once at launch, after the app has built its menus.
    public func restoreWindows() {
        if windows.isEmpty { reopenWindows(windowsToReopen) }
    }

    /// New Window: opens a main window on the active window's current space, or on the last main window's while none is open, with no tab selected (open decision 8).
    @discardableResult
    public func openWindow() -> BrowserWindowModel {
        let spaceID = activeWindow?.currentSpaceID ?? windowsToReopen[0].currentSpaceID
        let window = makeWindow(from: SessionSnapshot.WindowRecord(id: UUID(), frame: nil, currentSpaceID: spaceID, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        window.nsWindow?.makeKeyAndOrderFront(nil)
        return window
    }

    /// Opens main windows as their records describe them, front to back, and returns them in that order. Each shows its saved tab, which a window in front of it then gives up when it shows the tab as a pane of its split view (window rule 2), or its space's first free tab when the tab has closed (window rule 3).
    @discardableResult
    private func reopenWindows(_ records: [SessionSnapshot.WindowRecord]) -> [BrowserWindowModel] {
        // Created back to front, so that `windows` lists them front to back.
        let reopened = Array(records.reversed().map { makeWindow(from: $0, kind: .main) }.reversed())
        // Selecting before the windows show puts the pages in place when they first draw. Every window takes its own tab before any window falls back, so that no window falls back to a tab that another one had.
        for (window, record) in zip(reopened, records) {
            if let tab = allTabs.first(where: { $0.id == record.selectedTabID }) { window.selectTab(tab.id) }
        }
        for window in reopened where window.selectedTabID == nil {
            window.selectTab(window.firstFreeTab(inSpace: window.currentSpaceID)?.id)
        }
        // The front window comes forward last, so it becomes key.
        reopened.reversed().forEach { $0.nsWindow?.makeKeyAndOrderFront(nil) }
        return reopened
    }

    /// Creates a hidden window of `kind` as `record` describes it, on the first space when the record's space is gone. A window without a frame cascades from the window of its kind that last became main. It goes first in `windows`, as it is about to come to the front, before its views exist.
    private func makeWindow(from record: SessionSnapshot.WindowRecord, kind: BrowserWindowKind) -> BrowserWindowModel {
        let source = windows.first { $0.kind == kind }?.nsWindow
        var record = record
        if !spaces.contains(where: { $0.id == record.currentSpaceID }) { record.currentSpaceID = spaces[0].id }
        let window = BrowserWindowModel(session: self, record: record, kind: kind)
        windows.insert(window, at: 0)
        windowControllers.append(BrowserWindowController(model: window, cascadingFrom: source))
        updateFocusedTab()
        return window
    }

    /// Makes `window` the active window.
    func windowDidBecomeMain(_ window: BrowserWindowModel) {
        if let index = windows.firstIndex(where: { $0 === window }), index > 0 {
            var reordered = windows
            reordered.insert(reordered.remove(at: index), at: 0)
            windows = reordered
        }
        updateFocusedTab()
    }

    /// Window rule 5: a main window's tabs stay open, and a small window closes with its tab or once a main window takes it. The window lets go of what it shows and leaves the list, and the panes it showed go to the windows whose split views have them, with their prompts. A main window's record stays for the next main window and, while no main window is open, the saved session, which the change of `windows` saves.
    @MainActor func windowWillClose(_ window: BrowserWindowModel) {
        // The tabs the window showed were in view until now, as the archive timer and the saved session count the tabs of open windows, also when closing the last main window quits.
        window.paneTabs.forEach { $0.lastActivatedAt = Date() }
        window.prepareToClose()
        if window.kind == .main { windowsToReopen = [window.record] }
        windows.removeAll { $0 === window }
        windows.forEach { $0.updateShownTabs() }
        updateFocusedTab()
        // AppKit goes on closing the window after this, so its controller, which owns it, goes on the next turn of the run loop.
        if let index = windowControllers.firstIndex(where: { $0.model === window }) {
            let controller = windowControllers.remove(at: index)
            DispatchQueue.main.async { withExtendedLifetime(controller) {} }
        }
    }

    /// The window that shows the tab, as its selected tab or a pane of its split view, or nil while no window shows it.
    func window(showing tab: Tab) -> BrowserWindowModel? {
        windows.first { $0.shows(tab) }
    }

    /// Whether a window shows the tab or, while no main window is open, a main window that reopens from `windowsToReopen` will show it, as its saved tab or a pane of that tab's split view. A live folder's plan keeps such an item tab, also at launch before the saved session's windows open.
    func windowShowsOrWillShow(_ tab: Tab) -> Bool {
        if window(showing: tab) != nil { return true }
        guard lastMainWindow == nil else { return false }
        return windowsToReopen.contains { record in
            guard let selectedID = record.selectedTabID else { return false }
            return selectedID == tab.id || splitTabIDs.values.contains { $0.contains(selectedID) && $0.contains(tab.id) }
        }
    }

    /// The browser window whose AppKit window is `nsWindow`, or nil for any other window, such as Settings or the developer tools.
    public func window(for nsWindow: NSWindow?) -> BrowserWindowModel? {
        guard let nsWindow else { return nil }
        return windows.first { $0.nsWindow === nsWindow }
    }

    /// Window rule 2: before `window` shows the tab it selected, every other window that shows the tab gives it up (`BrowserWindowModel.giveUp(_:)`). The panes that no window shows any longer, the ones given up and the ones `window` left, then show again in the windows whose split views have them (window rule 1).
    func release(_ tab: Tab?, except window: BrowserWindowModel) {
        if let tab {
            for other in windows where other !== window && other.shows(tab) { other.giveUp(tab) }
        }
        windows.forEach { $0.updateShownTabs() }
    }

    /// The tab of `focusedTabID`.
    public var focusedTab: Tab? { allTabs.first { $0.id == focusedTabID } }

    /// Follows a window's new selection.
    func windowDidSelect(_ window: BrowserWindowModel) {
        if window === activeWindow { updateFocusedTab() }
    }

    /// Makes the active window's selected tab the focused tab. Every change of the active window or of its selection goes through here, so `focusedTabID` publishes each one.
    private func updateFocusedTab() {
        let id = activeWindow?.selectedTabID
        if focusedTabID != id { focusedTabID = id }
    }

    /// Stops the page reader's replies after `window`'s reader hides or the window closes: those about the tabs the window shows while another window shows the reader, or every reply once no other window does.
    @MainActor func pageReaderDidHide(in window: BrowserWindowModel) {
        if windows.contains(where: { $0 !== window && $0.isPageReaderVisible }) {
            pageAssistant.stopReaderReplies(ofTabs: window.shownTabIDs)
        } else {
            pageAssistant.stopReaderReplies()
        }
    }

    /// Closes the question popovers that windows show about the tab's page, which the tab has left.
    @MainActor func closePageQuestions(ofTab id: UUID) {
        windows.forEach { $0.closePageQuestion(ofTab: id) }
    }

    // MARK: Small windows

    /// Settings ▸ General saves under this key whether links from other apps may open in small windows.
    public static let opensLinksInSmallWindowKey = "ARCHOpensLinksInSmallWindow"

    /// Whether links from other apps may open in small windows while nothing is saved under `opensLinksInSmallWindowKey`.
    public static let opensLinksInSmallWindowByDefault = true

    /// How long after Arch becomes active a link still counts as arriving while Arch was in the background, because the app that sends a link can activate Arch just before the link arrives. `docs/windows-personas.md` (Small window) says how the value was chosen.
    static let smallWindowActivationGrace: TimeInterval = 0.5

    /// Whether a link from another app opens in a small window, judged by timing alone, so the caller checks the preference under `opensLinksInSmallWindowKey` first: Arch was not active when the link arrived, or became active at `becameActiveAt`, less than `smallWindowActivationGrace` before `now`. A nil `becameActiveAt` means Arch has been active since it launched.
    public static func opensLinkInSmallWindow(isAppActive: Bool, becameActiveAt: Date?, now: Date) -> Bool {
        guard isAppActive else { return true }
        guard let becameActiveAt else { return false }
        return now.timeIntervalSince(becameActiveAt) < smallWindowActivationGrace
    }

    /// The web address that a link from another app or an `open location` script names, or `nil` when it names none: only an http or https address opens, so a file, `mailto:`, or other address is dropped. A script's text may lack a scheme, so it is read as the address field reads it. AppKit escapes that text, spaces among them, so it is read with its escapes decoded first, then as it came for escapes the script wrote itself, as in a query's `%20`; escapes in a host stand for text that is no address.
    public static func webAddress(forOpened opened: URL) -> URL? {
        let address: URL?
        if opened.scheme != nil {
            address = opened
        } else {
            let text = opened.absoluteString
            address = text.removingPercentEncoding.flatMap(url(forInput:))
                ?? url(forInput: text).flatMap { $0.host(percentEncoded: true)?.contains("%") == false ? $0 : nil }
        }
        guard let scheme = address?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return address
    }

    /// The app sets this to name Move to Main Window's shortcut, which Settings can change, in the small window's button.
    public var moveToMainWindowShortcut: () -> String? = { nil }

    /// Opens `url` in a small window of its own, made key and ordered front, in a new tab of the default engine. The tab belongs to the space it moves to: the last main window's current space, or the last closed main window's, or the first space once that one is gone, and to that space's Persona (open decision 6).
    @discardableResult
    public func openSmallWindow(url: URL) -> BrowserWindowModel {
        let lastSpaceID = lastMainWindow?.currentSpaceID ?? windowsToReopen[0].currentSpaceID
        let spaceID = spaces.contains { $0.id == lastSpaceID } ? lastSpaceID : spaces[0].id
        let personaID = personaID(ofSpace: spaceID)
        return openSmallWindow(makeWebContents(url: url, engine: nil, state: nil, in: personaID), spaceID: spaceID, personaID: personaID)
    }

    /// Opens a small window, made key and ordered front, on a new tab for `webContents`, which a runtime of the Persona created. The tab moves to the space `spaceID`, or to the Persona's preferred space when that space belongs to another Persona. It stays in `tabs`, so that sheets, permissions, downloads, Now Playing, and `session.json` handle it as any other, while its space's list leaves it out.
    @discardableResult
    func openSmallWindow(_ webContents: any EngineWebContents, spaceID: UUID, personaID: Persona.ID) -> BrowserWindowModel {
        let spaceID = self.spaceID(spaceID, orPreferredIn: personaID)
        let tab = makeTab(webContents, id: UUID(), spaceID: spaceID, personaID: personaID, pinned: false)
        tab.isInSmallWindow = true
        tabs.append(tab)
        let window = makeWindow(from: SessionSnapshot.WindowRecord(id: UUID(), frame: nil, currentSpaceID: spaceID, selectedTabID: nil, isSidebarVisible: false), kind: .small)
        window.selectTab(tab.id)
        window.nsWindow?.makeKeyAndOrderFront(nil)
        window.focusPage()
        return window
    }

    /// Move to Main Window: the small window's tab joins the end of its space's open tabs, and the sidebar target selects it, which takes it from the small window (window rule 2) and so closes that window, then comes forward with the page focused. The page moves without loading again. The tab's space is still there, because deleting a space moves its tabs, a small window's among them.
    public func moveToMainWindow(_ smallWindow: BrowserWindowModel) {
        guard smallWindow.kind == .small, let tab = smallWindow.selectedTab, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.isInSmallWindow = false
        var reordered = tabs
        reordered.append(reordered.remove(at: index))
        tabs = reordered
        let target = sidebarTarget()
        target.selectTab(tab.id)
        target.nsWindow?.makeKeyAndOrderFront(nil)
        target.focusPage()
    }

    // MARK: Engines

    /// The engines a tab can use.
    public var availableEngines: [EngineKind] { registry.registeredKinds }

    /// The engine for new tabs that no page opened. Settings changes it, and the change applies to the next new tab.
    public var defaultEngine: EngineKind {
        get { registry.defaultKind }
        set {
            objectWillChange.send()
            registry.defaultKind = newValue
        }
    }

    /// Where every engine keeps its data.
    private static func engineConfiguration(userDataDirectory: URL) -> EngineApplicationConfiguration {
        EngineApplicationConfiguration(userDataDirectory: userDataDirectory, cacheDirectory: userDataDirectory.appendingPathComponent("Cache"))
    }

    /// Creates an engine's application. Returns nil when the engine cannot start.
    private static func makeApplication(_ kind: EngineKind, registry: EngineRegistry, userDataDirectory: URL) -> (any EngineApplication)? {
        guard let engine = registry.engine(for: kind) else { return nil }
        return try? engine.makeApplication(configuration: engineConfiguration(userDataDirectory: userDataDirectory))
    }

    /// Makes the session the application's delegate and keeps the application for the engine's runtimes.
    private func start(_ application: any EngineApplication) {
        application.delegate = self
        applications[application.engineKind] = application
    }

    /// The engine's application, started on first use. Returns nil when the engine cannot start.
    private func application(for kind: EngineKind) -> (any EngineApplication)? {
        if let application = applications[kind] { return application }
        guard let application = Self.makeApplication(kind, registry: registry, userDataDirectory: userDataDirectory) else {
            enginesThatDidNotStart.insert(kind)
            return nil
        }
        enginesThatDidNotStart.remove(kind)
        start(application)
        return application
    }

    /// The Persona's runtimes and plugins, created empty on first use.
    private func engines(of personaID: Persona.ID) -> PersonaEngines {
        if let engines = personaEngines[personaID] { return engines }
        let engines = PersonaEngines(personaID: personaID, cookieRecord: CookieSync.recordURL(ofPersona: personaID, in: userDataDirectory))
        personaEngines[personaID] = engines
        return engines
    }

    /// The Persona's runtime for `kind`, started on first use. Falls back to the Persona's runtime of the primary engine when `kind` cannot start, so a page never leaves its Persona's profile.
    func runtime(for kind: EngineKind, in personaID: Persona.ID) -> EngineRuntime {
        let engines = engines(of: personaID)
        if let runtime = engines.runtimes[kind] ?? startRuntime(kind, in: engines) { return runtime }
        // Every Persona that pages use is listed, the primary engine runs from launch, and both engines create profiles without failing.
        guard let runtime = engines.runtimes[primaryEngine] ?? startRuntime(primaryEngine, in: engines) else {
            preconditionFailure("No profile for the Persona \(personaID)")
        }
        return runtime
    }

    /// Creates the Persona's profile and browser in the engine and connects them to the session: the Persona's web extensions, their downloads, the download settings, the remembered permissions, and the Persona's cookie copies. Returns nil when the engine cannot start or the Persona is not listed.
    private func startRuntime(_ kind: EngineKind, in engines: PersonaEngines) -> EngineRuntime? {
        guard let application = application(for: kind), let persona = personas.first(where: { $0.id == engines.personaID }) else { return nil }
        // Both engines create a profile before `createBrowserContext` returns.
        var created: (any EngineBrowserContext)?
        application.createBrowserContext(storageIdentifier: persona.storageIdentifier) { created = try? $0.get() }
        guard let context = created else { return nil }
        let browser = application.createBrowser(context: context)
        let runtime = EngineRuntime(kind: kind, personaID: persona.id, context: context, browser: browser)
        engines.runtimes[kind] = runtime
        if let extensions = context.extensions { MainActor.assumeIsolated { engines.webExtensions?.profileDidStart(with: extensions, of: kind) } }
        context.downloads.delegate = self
        context.delegate = self
        followDownloadSettings(of: context)
        permissionAnswers.follow(context)
        downloads += context.downloads.items.map { DownloadEntry(item: $0, personaID: persona.id) }
        browser.cookiesDidChange = { [weak engines] in engines?.cookieSync.scheduleCopy(from: kind) }
        // An engine that starts after another in the Persona takes what the running engine changed since the two stores last agreed. This first copy of a launch reads the Persona's record of that agreement, so it also carries what one engine changed while the other was not running (`CookieSync`).
        if let source = engines.runtimes.values.first(where: { $0.kind != kind }) {
            engines.cookieSync.copy(from: source, to: runtime) {}
        }
        return runtime
    }

    /// The runtime that created the tab's web contents.
    private func runtime(of tab: Tab) -> EngineRuntime? {
        personaEngines[tab.personaID]?.runtimes[tab.engineKind]
    }

    /// The runtime whose profile keeps the download list.
    private func runtime(owning downloads: any EngineDownloads) -> EngineRuntime? {
        personaEngines.values.flatMap(\.runtimes.values).first { ($0.context.downloads as AnyObject) === (downloads as AnyObject) }
    }

    // MARK: Spaces

    /// A space's pinned or open tabs in sidebar order: the tabs inside each folder, at every level, then the tabs outside folders (`FolderTree.tabs(in:pinned:)`).
    public func tabs(in spaceID: UUID, pinned: Bool) -> [Tab] {
        folderTree.tabs(in: spaceID, pinned: pinned)
    }

    /// Adds a space to the Persona and returns it, named `name` or else as `newSpaceName(among:)` names it, and with the next tint of the rotation.
    func makeSpace(in personaID: Persona.ID, named name: String? = nil) -> Space {
        let space = Space(name: name ?? Self.newSpaceName(among: spaces), tint: Self.newSpaceTint(among: spaces), personaID: personaID)
        insert(space)
        return space
    }

    /// The name of a new space without one: "Space" with the lowest number no space in `spaces` uses, so names do not repeat after a deletion.
    static func newSpaceName(among spaces: [Space]) -> String {
        (1...).lazy.map { "Space \($0)" }.first { name in !spaces.contains { $0.name == name } }!
    }

    /// The tint of a new space: the next of the rotation after `spaces`.
    static func newSpaceTint(among spaces: [Space]) -> SpaceTint {
        SpaceTint.colors[spaces.count % SpaceTint.colors.count]
    }

    /// Puts the space last in its Persona's group, because each Persona's spaces stay together in the order `normalized()` restores at launch.
    private func insert(_ space: Space) {
        let groupEnd = spaces.lastIndex { $0.resolvedPersonaID == space.resolvedPersonaID }.map { $0 + 1 } ?? spaces.endIndex
        spaces.insert(space, at: groupEnd)
    }

    public func setTint(_ tint: SpaceTint, ofSpace id: UUID) {
        updateSpace(id) { $0.tint = tint }
    }

    public func setSymbol(_ symbol: String, ofSpace id: UUID) {
        updateSpace(id) { $0.symbol = symbol }
    }

    /// Moves a space one place left (`-1`) or right (`1`) in the switcher, within its Persona's group.
    public func moveSpace(_ id: UUID, by offset: Int) {
        guard let index = spaces.firstIndex(where: { $0.id == id }), spaces.indices.contains(index + offset),
              spaces[index + offset].resolvedPersonaID == spaces[index].resolvedPersonaID else { return }
        spaces.swapAt(index, index + offset)
    }

    /// Whether the space can go: every Persona keeps at least one space.
    func canDeleteSpace(_ id: UUID) -> Bool {
        spaces.first { $0.id == id }.map { spaces(in: $0.resolvedPersonaID).count > 1 } == true
    }

    /// Removes a space, unless it is its Persona's last. Its tabs and nested folders move to the space before it in its Persona's group, or to the next one for the group's first space, so no tab closes or leaves its Persona, and every window on the space switches there.
    public func deleteSpace(_ id: UUID) {
        guard canDeleteSpace(id), let space = spaces.first(where: { $0.id == id }) else { return }
        let group = spaces(in: space.resolvedPersonaID)
        guard let index = group.firstIndex(where: { $0.id == id }) else { return }
        let destination = group[index == 0 ? 1 : index - 1].id
        // The space's split view goes with it; its tabs join the destination as separate tabs.
        splitTabIDs[id] = nil
        // The moved tabs and folders go after the destination's own instead of among them. The tabs keep their folders, and the folders their parents, so the tree moves whole.
        let moved = tabs.filter { $0.spaceID == id }
        let movedIDs = Set(moved.map(\.id))
        moved.forEach { $0.spaceID = destination }
        // One change, so that what follows the session's tabs never sees the moved ones leave.
        tabs = tabs.filter { !movedIDs.contains($0.id) } + moved
        var movedFolders = folders.filter { $0.spaceID == id }
        for folderIndex in movedFolders.indices { movedFolders[folderIndex].spaceID = destination }
        folders = folders.filter { $0.spaceID != id } + movedFolders
        for window in windows where window.currentSpaceID == id { window.switchToSpace(destination) }
        spaces.removeAll { $0.id == id }
    }

    func updateSpace(_ id: UUID, _ change: (inout Space) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        change(&spaces[index])
    }

    // MARK: Personas

    /// The Persona's spaces in switcher order.
    public func spaces(in personaID: Persona.ID) -> [Space] {
        spaces.filter { $0.resolvedPersonaID == personaID }
    }

    /// The Persona's favorites in their order.
    public func favorites(in personaID: Persona.ID) -> [Favorite] {
        favorites.filter { $0.resolvedPersonaID == personaID }
    }

    /// The listed Persona with the ID, or nil once it is deleted.
    func persona(withID id: Persona.ID) -> Persona? {
        personas.first { $0.id == id }
    }

    /// The Persona's name alone, as the space header's prefix before the space's name, or nil while the default Persona is the only one, so that nothing names Personas until the user adds one. The Persona pickers of Settings ▸ Plugins and the import sheet, which show no space, list `Persona.name`.
    func displayedName(ofPersona id: Persona.ID) -> String? {
        displayedPlace(ofPersona: id, space: nil)
    }

    /// How the interface names a Persona from a place (Persona rule 7 in `docs/windows-personas.md`): "Work / Research" for the Persona and `space`, the Persona's name alone without a space, or nil while the default Persona is the only one.
    func displayedPlace(ofPersona id: Persona.ID, space: Space?) -> String? {
        Self.displayedPlace(ofPersona: id, space: space, among: personas)
    }

    /// `displayedPlace(ofPersona:space:)` among `personas`, also nil for a Persona that is no longer listed, for callers that hold the Personas, such as the sheets' texts, Settings ▸ Plugins' reviews, and tests.
    public static func displayedPlace(ofPersona id: Persona.ID, space: Space?, among personas: [Persona]) -> String? {
        guard personas.count > 1, let persona = personas.first(where: { $0.id == id }) else { return nil }
        return space.map { "\(persona.name) / \($0.name)" } ?? persona.name
    }

    /// The space a tab of the Persona joins when no space of the Persona is given: the last main window's current space while it belongs to the Persona, else the Persona's first space. Every listed Persona has a space; for one that is gone, the first space.
    func preferredSpace(in personaID: Persona.ID) -> Space {
        if let space = lastMainWindow?.currentSpace, space.resolvedPersonaID == personaID { return space }
        return spaces.first { $0.resolvedPersonaID == personaID } ?? spaces[0]
    }

    /// The guard of every move of a tab to another space, drop targets included: a tab's pages keep their Persona's storage, so the tab moves only to a space of its Persona (Persona rule 3).
    func canMoveTab(_ id: UUID, toSpace spaceID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), let space = spaces.first(where: { $0.id == spaceID }) else { return false }
        return space.resolvedPersonaID == tab.personaID
    }

    /// The name of the one space a new Persona starts with.
    static let newPersonaSpaceName = "Personal"

    /// Appends a Persona with one space named Personal and returns it. Its profiles and plugins start when a window of it first needs them.
    func addPersona(named name: String) -> Persona {
        let persona = Persona(name: name)
        add(persona, spaces: [Space(name: Self.newPersonaSpaceName, tint: Self.newSpaceTint(among: spaces), personaID: persona.id)])
        return persona
    }

    /// Appends `persona` with its spaces, of which every Persona has at least one.
    private func add(_ persona: Persona, spaces: [Space]) {
        personas.append(persona)
        spaces.forEach(insert)
    }

    /// The window's sheet passes only a name with text in it.
    func renamePersona(_ id: Persona.ID, to name: String) {
        guard let index = personas.firstIndex(where: { $0.id == id }) else { return }
        personas[index].name = name
    }

    /// Every Persona but the default one can go.
    public func canDeletePersona(_ id: Persona.ID) -> Bool {
        id != Persona.defaultID && persona(withID: id) != nil
    }

    /// Removes a Persona other than the default one with everything it owns. Its tabs close into the closed list without asking their pages, and its cookies, website data, and plugin data leave the Mac at the next launch, when no engine has its profiles loaded.
    func deletePersona(_ id: Persona.ID) {
        guard canDeletePersona(id), let destination = spaces.first(where: { $0.resolvedPersonaID != id }) else { return }
        // Its previews close, and every main window on its spaces moves to the first space of the first remaining Persona, where window rule 3 picks the tab. A small window closes below with its tab.
        for window in windows {
            if window.preview?.personaID == id { window.closePreview() }
            if window.kind == .main, window.personaID == id { window.switchToSpace(destination.id) }
        }
        for tab in allTabs where tab.personaID == id { closeTab(tab, reason: .persona) }
        undoableCloseCount = 0
        // Its unfinished downloads stop, and the pages kept for them close. Finished rows stay in the library.
        downloads.filter { $0.personaID == id && !$0.isFinished }.forEach { $0.item.cancel() }
        for page in downloadPages where page.runtime.personaID == id { page.runtime.browser.closeWebContents(page.webContents) }
        downloadPages.removeAll { $0.runtime.personaID == id }
        // Its spaces go with their folders and split views, and its favorites with the tabs saved for them.
        let spaceIDs = Set(spaces(in: id).map(\.id))
        spaceIDs.forEach { splitTabIDs[$0] = nil }
        folders.removeAll { spaceIDs.contains($0.spaceID) }
        favorites(in: id).forEach { savedFavoriteTabs[$0.id] = nil }
        favorites.removeAll { $0.resolvedPersonaID == id }
        spaces.removeAll { $0.resolvedPersonaID == id }
        personas.removeAll { $0.id == id }
        // Its browsers close, and its plugins stop. Download items refer to their lists and profiles unowned, so its runtimes stay until quit.
        if let engines = personaEngines.removeValue(forKey: id) {
            MainActor.assumeIsolated { closePlugins(of: engines) }
            engines.runtimes.values.forEach { $0.browser.closeAllWebContents() }
            retiredPersonaEngines.append(engines)
        }
        // The Web Store's update results for its plugins go with them.
        MainActor.assumeIsolated { webStore.forget(id) }
        personaDataRemoval.removeAtNextLaunch(id)
        saveNow()
    }

    // MARK: Home pages

    public func clearHome(ofSpace id: UUID) {
        updateSpace(id) { $0.homeURL = nil }
    }

    // MARK: Favorites

    /// The tab each opened favorite keeps alive, by favorite ID. Every space shows these tabs through their favorites instead of in its list, so a favorite's page stays the same across spaces, and archiving passes them by.
    @Published private(set) var favoriteTabs: [UUID: Tab] = [:]
    /// The favorites' tabs from the last session, by favorite ID. Each opens where it was when its favorite is next opened, so launching loads none of them.
    @Published private var savedFavoriteTabs: [UUID: SessionSnapshot.FavoriteTabRecord] = [:]

    /// Adds the tab's page to the favorites of the tab's Persona, unless it is one of them already.
    public func addFavorite(_ tab: Tab) {
        guard let url = tab.url, !favorites.contains(where: { $0.url == url && $0.resolvedPersonaID == tab.personaID }) else { return }
        favorites.append(Favorite(url: url, title: tab.displayTitle, personaID: tab.personaID))
    }

    /// Appends, in order, the favorites whose addresses are not favorites of the Persona yet, as favorites of that Persona, and returns how many it added. Import uses it for bookmarks.
    @discardableResult
    public func addFavorites(_ candidates: [Favorite], in personaID: Persona.ID) -> Int {
        var addresses = Set(favorites.filter { $0.resolvedPersonaID == personaID }.map(\.url))
        let added = candidates.filter { addresses.insert($0.url).inserted }.map { candidate in
            var favorite = candidate
            favorite.personaID = personaID
            return favorite
        }
        favorites += added
        return added.count
    }

    /// Changes the favorite with the ID, as Use Current Page as Saved Page and Edit Favorite… do (`SavedPage.swift`).
    func updateFavorite(_ id: UUID, _ change: (inout Favorite) -> Void) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        change(&favorites[index])
    }

    /// Removes a favorite once its tab, if it has one, agrees to close.
    public func removeFavorite(_ favorite: Favorite) {
        endFavoriteTab(favorite) { [weak self] in
            self?.favorites.removeAll { $0.id == favorite.id }
        }
    }

    /// The favorite's own tab, opened if needed: where it was when Arch last quit, or else at the favorite's address in the default engine.
    func openTab(for favorite: Favorite) -> Tab {
        if let tab = favoriteTabs[favorite.id] { return tab }
        let saved = savedFavoriteTabs.removeValue(forKey: favorite.id)
        let tab = makeTab(makeWebContents(url: saved?.url ?? favorite.url, engine: saved?.engine, state: saved?.state, in: favorite.resolvedPersonaID), id: saved?.id ?? UUID(), spaceID: nil, personaID: favorite.resolvedPersonaID, pinned: false)
        if let saved {
            tab.isRestored = true
            // Loading a restored page does not count as a visit.
            tab.recordedURL = saved.url
        }
        favoriteTabs[favorite.id] = tab
        return tab
    }

    /// Ends the favorite's tab, as its Close menu item does. The favorite then opens at its own address again.
    public func closeFavorite(_ favorite: Favorite) {
        endFavoriteTab(favorite) {}
    }

    /// Whether the favorite's page is open: its tab exists and has its engine's page, which an automatic unload takes away until a window shows the tab again (bookmark rule 5). A tab saved from the last session does not count until the favorite is opened.
    public func hasOpenPage(_ favorite: Favorite) -> Bool {
        favoriteTabs[favorite.id]?.isLoaded == true
    }

    /// Whether the favorite has a tab of its own: an open one, or one saved from the last session.
    public func hasTab(_ favorite: Favorite) -> Bool {
        favoriteTabs[favorite.id] != nil || savedFavoriteTabs[favorite.id] != nil
    }

    /// The favorites' open tabs, in favorite order.
    public var openFavoriteTabs: [Tab] {
        favorites.compactMap { favoriteTabs[$0.id] }
    }

    /// Forgets the favorite's saved tab and closes its open one once the page agrees, then runs `didEnd`. As with ⌘W on the tab, ⌘Z then reopens none of the tabs closed before it.
    private func endFavoriteTab(_ favorite: Favorite, then didEnd: @escaping () -> Void) {
        savedFavoriteTabs[favorite.id] = nil
        guard let tab = favoriteTabs[favorite.id] else { return didEnd() }
        whenPageAgreesToLeave(tab) { [weak self] tab in
            self?.closeTab(tab)
            self?.forgetUndoableCloses()
            didEnd()
        }
    }

    // MARK: Tabs

    /// Every open tab: the spaces' tabs, then the favorites' tabs.
    public var allTabs: [Tab] { tabs + openFavoriteTabs }

    /// Opens a tab in `engine`, or in the default engine when no engine is given, in the space `spaceID` or the sidebar target's current space. `select` selects it in the sidebar target. Views and menus that act on a window open tabs through `BrowserWindowModel` instead.
    @discardableResult
    public func openTab(url: URL? = nil, in spaceID: UUID? = nil, pinned: Bool = false, select: Bool = true, engine: EngineKind? = nil, state: Data? = nil) -> Tab {
        let spaceID = spaceID ?? sidebarTarget().currentSpaceID
        let personaID = personaID(ofSpace: spaceID)
        return adopt(makeWebContents(url: url, engine: engine, state: state, in: personaID), spaceID: spaceID, personaID: personaID, pinned: pinned, select: select)
    }

    /// A web contents of the Persona in `engine`, or in the default engine, that opens `url` or the new tab page and restores `state` when given. Its first document runs the app's page scripts and those of the Persona's enabled plugins (`TabUnloading.pageScripts(withPluginScripts:)`), which Chromium receives only with the browser it creates.
    func makeWebContents(url: URL?, engine: EngineKind?, state: Data?, in personaID: Persona.ID) -> any EngineWebContents {
        let pageScripts = TabUnloading.pageScripts(withPluginScripts: MainActor.assumeIsolated { plugins(in: personaID).contributions.pageScripts })
        return runtime(for: engine ?? defaultEngine, in: personaID).browser.createWebContents(EngineWebContentsConfiguration(initialURL: url ?? Self.newTabURL, restorableState: state, pageScripts: pageScripts))
    }

    /// The Persona of the space `id`, or of the sidebar target's current space when no space has that ID.
    func personaID(ofSpace id: UUID) -> Persona.ID {
        (spaces.first { $0.id == id } ?? sidebarTarget().currentSpace).resolvedPersonaID
    }

    /// The space `id` while it belongs to the Persona, or else the Persona's preferred space, so that a page's tab joins only a space of the page's Persona (Persona rule 3).
    private func spaceID(_ id: UUID, orPreferredIn personaID: Persona.ID) -> UUID {
        spaces.first { $0.id == id }?.resolvedPersonaID == personaID ? id : preferredSpace(in: personaID).id
    }

    /// Adds a tab for `webContents`, which a runtime of the Persona `personaID` created or which stands in for a restored tab's page, to the list of the space `spaceID` or, when that space belongs to another Persona, of the Persona's preferred space. A tab that restores or reopens passes its saved `id`. `select` selects it in the sidebar target.
    func adopt(_ webContents: any EngineWebContents, id: UUID = UUID(), spaceID: UUID, personaID: Persona.ID, pinned: Bool, select: Bool) -> Tab {
        let spaceID = self.spaceID(spaceID, orPreferredIn: personaID)
        let tab = makeTab(webContents, id: id, spaceID: spaceID, personaID: personaID, pinned: pinned)
        tabs.append(tab)
        if select { sidebarTarget().selectTab(tab.id) }
        return tab
    }

    /// Wraps `webContents` in a tab whose popups, dialogs, permission requests, and closing go through the session. The caller adds it to a space's list or gives it to a favorite.
    func makeTab(_ webContents: any EngineWebContents, id: UUID, spaceID: UUID?, personaID: UUID, pinned: Bool) -> Tab {
        let tab = Tab(id: id, webContents: webContents, spaceID: spaceID, isPinned: pinned, personaID: personaID)
        // A tab a page opens comes from the page's runtime, so it belongs to the page's Persona, and it keeps the page as its opener. The window that shows the page shows the new tab, in the page's space, which is that window's current space, or in another small window beside a small window. A page that no window shows opens it behind, marked unread, in the page's space or, for a favorite's page, its Persona's preferred space.
        tab.openNewTab = { [weak self, weak tab] popup in
            guard let self, let tab else { return }
            self.runtime(for: popup.engineKind, in: personaID).browser.takeOwnership(of: popup)
            if let window = self.window(showing: tab) { return window.showOpenedPage(popup, personaID: personaID, opener: tab.webContents) }
            let opened = self.adopt(popup, spaceID: tab.spaceID ?? self.preferredSpace(in: personaID).id, personaID: personaID, pinned: false, select: false)
            opened.opener = tab.webContents
            opened.isUnread = true
        }
        // A page that the engine loads only in another web contents of the tab's profile, as WebKit loads a web extension's pages, takes the tab's place as on an engine switch. A tab that has closed drops it.
        tab.takeReplacement = { [weak self, weak tab] replacement in
            guard let self, let tab, self.allTabs.contains(where: { $0.id == tab.id }) else { return }
            self.runtime(for: replacement.engineKind, in: personaID).browser.takeOwnership(of: replacement)
            self.replaceWebContents(of: tab, with: replacement)
        }
        // The user cannot undo a tab closed by its page. A page also reports closing after the user closes its tab, when the tab is no longer in the list.
        tab.didClose = { [weak self, weak tab] in
            guard let self, let tab, self.allTabs.contains(where: { $0.id == tab.id }) else { return }
            self.closeTab(tab, reason: tab.hasCrashed ? .crash : .page)
            self.undoableCloseCount = 0
        }
        // Only the page's own dialogs go: a permission, sign-in, or leave-page question still applies.
        tab.didCancelDialogs = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.prompts.dismiss(tabID: tab.id, pageDialogsOnly: true)
        }
        // A leave-page card shows over its page. The window that shows the tab makes it the focused pane, or leaves the internal page over it when it is selected already, and another window selects a tab that no window shows.
        tab.requestSelection = { [weak self, weak tab] in
            guard let self, let tab else { return }
            guard let window = self.window(showing: tab) else { return self.selectUnshownTab(tab) }
            if window.selectedTabID != tab.id {
                window.selectTab(tab.id)
            } else if window.internalPage != nil {
                window.closeInternalPage()
            }
        }
        // The page asks to be seen, as the return button of its picture-in-picture window does: the tab is selected as above, and its window comes forward, out of the Dock if it is minimized, with the app.
        tab.requestActivation = { [weak self, weak tab] in
            guard let self, let tab else { return }
            tab.requestSelection?()
            guard let window = self.window(showing: tab)?.nsWindow else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        // Chromium does not report cookie changes, so a finished load is the moment to copy them.
        // Saving after each load keeps the page state that a crash would otherwise lose.
        // The page takes its host's remembered zoom.
        tab.didFinishLoad = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.personaEngines[tab.personaID]?.cookieSync.scheduleCopy(from: tab.engineKind)
            self.scheduleSave()
            self.applyZoom(to: tab)
        }
        // Closing a tab whose download has not started yet would cancel it, so such a tab waits for its download to appear. The engine is still inside its callback, so closing happens on the next turn of the run loop. A pinned tab unloads to its saved page and keeps its place.
        tab.didOpenOnlyDownload = { [weak self, weak tab] downloads in
            guard let self, let tab else { return }
            if downloads {
                self.downloadOnlyTabIDs.insert(tab.id)
            } else {
                DispatchQueue.main.async { [weak self, weak tab] in
                    if let self, let tab { self.closeTab(tab, reason: .download) }
                }
            }
        }
        tab.requestPermission = { [weak self, weak tab] request, completion in
            guard let self, let tab else { return completion(false) }
            self.permissionAnswers.answer(request, forTab: tab.id, in: self.runtime(of: tab)?.context, identity: PromptSiteIdentity.make(for: request.origin, in: tab), ask: { makeContent, response in
                self.enqueuePrompt(making: makeContent, for: tab, completion: response)
            }, completion: completion)
        }
        tab.recordVisit = { [weak self] url, title in self?.history.record(url, title: title) }
        // The page fills the window that shows it. A page that no window shows leaves fullscreen; the engine is still in its callback, so that happens on the next turn of the run loop.
        tab.didChangeFullscreen = { [weak self, weak tab] isFullscreen in
            guard let self, let tab else { return }
            if let window = self.window(showing: tab) {
                window.setPageFullscreen(isFullscreen, of: tab)
            } else if isFullscreen {
                DispatchQueue.main.async { [weak tab] in tab?.webContents.exitFullscreen() }
            }
        }
        // A link opened from a page's context menu opens behind the current tab, in the page's space (its Persona's preferred space for a favorite's page) and engine, marked unread.
        tab.openURLInNewTab = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.openTab(url: url, in: tab.spaceID ?? self.preferredSpace(in: tab.personaID).id, select: false, engine: tab.engineKind).isUnread = true
        }
        // Search with in a page's context menu shows the results for the page's selection as a page the tab opens: in a new tab that the window showing the page selects, in the page's engine and Persona, or behind, marked unread, when no window shows the page.
        tab.searchInNewTab = { [weak self, weak tab] text in
            guard let self, let tab else { return }
            let url = Self.searchResultsURL(for: text)
            if let window = self.window(showing: tab) {
                return window.showOpenedPage(self.makeWebContents(url: url, engine: tab.engineKind, state: nil, in: tab.personaID), personaID: tab.personaID)
            }
            self.openTab(url: url, in: tab.spaceID ?? self.preferredSpace(in: tab.personaID).id, select: false, engine: tab.engineKind).isUnread = true
        }
        // A web link the user clicks with Shift opens in the preview panel of the page's window, in the page's engine and Persona.
        tab.previewLink = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.window(showing: tab)?.showPreview(of: url, engine: tab.engineKind, in: tab.personaID)
        }
        tab.presentPrompt = { [weak self, weak tab] content, completion in
            guard let self, let tab else { return completion(.dismissed) }
            self.enqueuePrompt(content, for: tab, completion: completion)
        }
        // Every change to what `session.json` keeps of a tab, such as a new address or name, is saved.
        tabObservers[tab.id] = tab.persistedChanges.sink { [weak self] in self?.scheduleSave() }
        return tab
    }

    /// Creates the page of a tab that has none, as a window does before it first shows the tab: a web contents of the tab's Persona at the address, in the engine, and with the page state that its stand-in keeps (`UnloadedWebContents`). A tab that has its page keeps it.
    func loadPage(of tab: Tab) {
        tab.loadPage { makeWebContents(url: $0, engine: $1, state: $2, in: tab.personaID) }
    }

    /// Selects a tab that no window shows. A space's tab goes to the front main window on its space, or else to the front main window of its Persona, which then shows the tab's space, so that a window of another Persona keeps its Persona / Space while one of the tab's Persona is open; only without either does it go to the sidebar target. A favorite's tab belongs to no space and leaves a window on its current space, so it goes to the front main window of its Persona, or else to the sidebar target moved to the Persona's preferred space, so that the window offers the tab's favorites and plugins.
    func selectUnshownTab(_ tab: Tab) {
        let window = windows.first { $0.kind == .main && tab.spaceID != nil && $0.currentSpaceID == tab.spaceID }
            ?? windows.first { $0.kind == .main && $0.personaID == tab.personaID } ?? sidebarTarget()
        if tab.spaceID == nil, window.personaID != tab.personaID { window.currentSpaceID = preferredSpace(in: tab.personaID).id }
        window.selectTab(tab.id)
    }

    /// Moves a tab to another engine: a web contents from the Persona's runtime for `kind` loads the tab's address and takes the old one's place, and the tab keeps its place, pin, space, and selection. Nothing changes when `kind` cannot start, or for a tab without its page: only a tab that no window has shown since launch lacks one, and the site settings popover offers the switch for a shown tab only.
    public func switchEngine(of tab: Tab, to kind: EngineKind) {
        guard tab.engineKind != kind, tab.isLoaded, allTabs.contains(where: { $0.id == tab.id }), let source = runtime(of: tab) else { return }
        let target = runtime(for: kind, in: tab.personaID)
        guard target.kind == kind else { return }
        // The page loads in the other engine once it has this engine's cookies, so the site stays signed in.
        engines(of: tab.personaID).cookieSync.copy(from: source, to: target) { [weak self, weak tab] in
            guard let self, let tab, tab.engineKind != kind, self.allTabs.contains(where: { $0.id == tab.id }) else { return }
            self.replaceWebContents(of: tab, with: self.makeWebContents(url: tab.url, engine: kind, state: nil, in: tab.personaID))
        }
    }

    /// Puts `replacement`, which the Persona's runtime for its engine owns, in place of the tab's web contents and closes the old one. Prompts and searches belong to the old page, and the window that selects the tab docks the new page's tools.
    private func replaceWebContents(of tab: Tab, with replacement: any EngineWebContents) {
        let old = tab.webContents
        prompts.dismiss(tabID: tab.id)
        let window = windows.first { $0.selectedTabID == tab.id }
        if window?.isFindBarVisible == true { window?.hideFindBar() }
        tab.replaceWebContents(with: replacement)
        window?.devToolsDock.track(tab)
        retire(old, of: tab.personaID)
        scheduleSave()
    }

    /// Closes a tab the user asked to close once its page agrees, as ⌘W, the row's button, Close Tab, Close Other Tabs, and a small window's close do: a page with a `beforeunload` handler can ask to stay. What closing does follows the tab's kind (`TabCloseAction`): a pinned tab unloads, a favorite's tab ends and opens again from its favorite, and any other tab joins the closed list, which ⌘Z reopens.
    public func requestCloseTab(_ tab: Tab) {
        whenPageAgreesToLeave(tab) { [weak self] tab in
            guard let self else { return }
            let action = TabCloseAction.of(tab, reason: .user)
            self.perform(action, on: tab, reason: .user)
            // ⌘Z reopens only a tab that joined the closed list, so after an unload or a favorite's end it reopens none of the tabs closed before either, rather than an older tab in its place.
            if action == .close(remember: true) { self.undoableCloseCount += 1 } else { self.forgetUndoableCloses() }
        }
    }

    /// Delete Tab: takes a pinned tab out of its list into the closed list once its page agrees, where closing it only unloads it (bookmark rule 4). ⌘Z reopens it pinned in its folder with its saved page. A favorite's tab has no row to delete, and a live folder item's tab, which never joins the closed list, is dismissed instead.
    public func requestDeleteTab(_ tab: Tab) {
        guard tab.spaceID != nil, tab.liveItemID == nil else { return }
        whenPageAgreesToLeave(tab) { [weak self] tab in
            guard let self, self.perform(.close(remember: true), on: tab, reason: .user) else { return }
            self.undoableCloseCount += 1
        }
    }

    /// Runs `leave` with the tab once its page agrees to leave, which a page with a `beforeunload` handler can refuse, for a close the user asked for from the tab's row, its favorite, or a menu. While the tab's leave-page card shows, that card is the question, so the tab only comes forward to show it; otherwise the tab's prompts end first (`TabPromptQueue.endForClose`). The user's request replaces an automatic unload's that waits for the page, so the page's question shows.
    func whenPageAgreesToLeave(_ tab: Tab, then leave: @escaping (Tab) -> Void) {
        guard prompts.endForClose(tabID: tab.id) else {
            tab.requestSelection?()
            return
        }
        tab.answersBeforeUnloadWithStay = false
        // Asking means closing the browser, which would stop its downloads, so such a tab leaves at once; its kept page answers the handlers with Leave when it moves to a blank page.
        guard !tab.webContents.closingStopsDownloads else { return leave(tab) }
        tab.webContents.tryToClose { [weak tab] agrees in
            guard agrees, let tab else { return }
            leave(tab)
        }
    }

    /// Closes a tab without asking its page, as `TabCloseAction.of(_:reason:)` decides for the tab and `reason`, and returns whether the tab was still open: a pinned tab unloads, a favorite's tab ends, a live folder item's tab is dismissed, and any other tab leaves its list, into the closed list unless it only pointed at a file. Every path that closes a tab comes here: the user's closes once the page agrees, the page's own `window.close()` and a crashed page that the engine closes, an extension's `tabs.remove`, a tab that only pointed at a file, Delete Persona, and archiving. `reason` goes to the tab close log when the tab leaves its list.
    @discardableResult
    public func closeTab(_ tab: Tab, reason: TabCloseReason = .user) -> Bool {
        perform(TabCloseAction.of(tab, reason: reason), on: tab, reason: reason)
    }

    /// Does what `action` does to the tab and returns whether the tab was still open for it, as a page that agrees to close late can find its tab closed meanwhile.
    @discardableResult
    func perform(_ action: TabCloseAction, on tab: Tab, reason: TabCloseReason) -> Bool {
        switch action {
        case .unload: return unloadToSavedPage(tab, reason: reason)
        case .end, .close: return removeTab(tab, closedRecord: action.closedRecord(of: tab), reason: reason)
        case .dismiss: return MainActor.assumeIsolated { dismissItem(tab, reason: reason) }
        }
    }

    /// Takes a tab out of its space's list or its favorite and returns whether it was still there: a window that shows its page in fullscreen leaves it, its prompts end, it leaves the tab close log's `reason` and each window's switcher order, its page closes (`retire`), `closedRecord` joins the closed list, and each window that selected it selects another tab (`moveSelections(awayFrom:reason:)`).
    @discardableResult
    func removeTab(_ tab: Tab, closedRecord: SessionSnapshot.TabRecord?, reason: TabCloseReason) -> Bool {
        guard tabs.contains(where: { $0.id == tab.id }) || favoriteTabs.values.contains(where: { $0 === tab }) else { return false }
        windows.forEach { $0.setPageFullscreen(false, of: tab) }
        // Ending the tab's prompts runs the code that asked for them before `dismiss` returns. The lists are read afterwards, and a tab that closed meanwhile is left alone.
        prompts.dismiss(tabID: tab.id)
        let index = tabs.firstIndex(where: { $0.id == tab.id })
        let favoriteID = favoriteTabs.first { $0.value === tab }?.key
        guard index != nil || favoriteID != nil else { return false }
        recordClose(of: tab, reason: reason)
        if let index { tabs.remove(at: index) }
        if let favoriteID { favoriteTabs[favoriteID] = nil }
        tabObservers[tab.id] = nil
        downloadOnlyTabIDs.remove(tab.id)
        retire(tab.webContents, of: tab.personaID)
        if let closedRecord { addToClosedList(closedRecord) }
        moveSelections(awayFrom: tab, reason: reason)
        return true
    }

    /// Takes the list that a live folder's plan gives (`LiveFolderTabs.applying`) and drops the tabs that the plan removed: tabs without their pages that no window shows (`LiveFolderReconciler`), so no page closes and nothing joins the closed list or the tab close log. Each leaves its split view, the windows' switcher order, and the prompts that wait for it.
    func replaceTabs(with tabs: [Tab], removing removed: [Tab]) {
        self.tabs = tabs
        for tab in removed {
            tabObservers[tab.id] = nil
            downloadOnlyTabIDs.remove(tab.id)
            prompts.dismiss(tabID: tab.id)
            leaveSplitView(tab)
            windows.forEach { $0.forgetActivation(of: tab.id) }
        }
    }

    /// Closing a pinned tab (bookmark rule 4), which returns whether the tab was still listed: its page closes as a closed tab's does, but the tab keeps its place, folder, and ID with a stand-in at its saved page, without page state, that shows the site's icon, or a live folder item's its folder's. A window that shows its page in fullscreen leaves it, its prompts end, and it leaves its split view; each window that selected it selects another tab before the stand-in takes its place, so that no window loads the page again. Nothing joins the closed list or the tab close log.
    @discardableResult
    private func unloadToSavedPage(_ tab: Tab, reason: TabCloseReason) -> Bool {
        guard tabs.contains(where: { $0 === tab }) else { return false }
        windows.forEach { $0.setPageFullscreen(false, of: tab) }
        // Ending the tab's prompts runs the code that asked for them, which can close the tab, so the list is read again afterwards.
        prompts.dismiss(tabID: tab.id)
        guard tabs.contains(where: { $0 === tab }) else { return false }
        downloadOnlyTabIDs.remove(tab.id)
        moveSelections(awayFrom: tab, reason: reason)
        retire(tab.unloadToSavedPage(), of: tab.personaID)
        if let standIn = tab.webContents as? UnloadedWebContents {
            standIn.loadSiteIcon()
            if tab.liveItemID != nil, let icon = tab.folderID.flatMap({ liveFolderIcons[$0]?.image }) { standIn.showIcon(icon) }
        }
        loadPageIfShown(tab)
        return true
    }

    /// Each main window that selected a tab that closes or unloads selects another as `tabToSelect(after:opener:splitNeighbor:among:spaceID:isShownInAnotherWindow:)` picks: for a page that closed itself, the opener is the listed tab of the page that opened it, as a sign-in popup closes once it has reported back. A favorite's tab leaves the selection to a tab of the window's current space. A small window closes with its tab. The tab leaves its split view first, and the opener is read after it.
    private func moveSelections(awayFrom tab: Tab, reason: TabCloseReason) {
        let splitNeighbor = leaveSplitView(tab).flatMap { id in tabs.first { $0.id == id } }
        let opener = reason == .page ? allTabs.first { $0.webContents === tab.opener && $0.isListedInSidebar } : nil
        for window in windows where window.selectedTabID == tab.id {
            guard window.kind == .main else {
                window.close()
                continue
            }
            let next = Self.tabToSelect(after: tab, opener: opener, splitNeighbor: splitNeighbor, among: tabs, spaceID: tab.spaceID ?? window.currentSpaceID,
                                        isShownInAnotherWindow: window.isShownInAnotherWindow)
            window.selectTab(next?.id)
        }
    }

    /// The tab that a window selects after its selected `tab` closes or unloads, one that no other window shows (window rule 3): `opener`, then `splitNeighbor`, so the rest of a split view stays on screen, or else a listed open tab of `spaceID` among `tabs` before a pinned one, or nil for the empty page. A pinned tab without its page is passed over: it is closed (bookmark rule 4), so selecting it would load a page the user closed or has not opened since launch, and two pinned tabs whose saved pages are files would download them in turn.
    static func tabToSelect(after tab: Tab, opener: Tab?, splitNeighbor: Tab?, among tabs: [Tab], spaceID: UUID?, isShownInAnotherWindow: (Tab) -> Bool) -> Tab? {
        let siblings = tabs.filter { $0 !== tab && $0.spaceID == spaceID && $0.isListedInSidebar }
        let candidates = [opener, splitNeighbor].compactMap { $0 } + siblings.filter { !$0.isPinned } + siblings
        return candidates.first { $0 !== tab && ($0.isLoaded || !$0.isPinned) && !isShownInAnotherWindow($0) }
    }

    /// Gives an unloaded tab its page again at once when a window shows it after all, as one that a window selected while its page was asked to leave.
    private func loadPageIfShown(_ tab: Tab) {
        if window(showing: tab) != nil { loadPage(of: tab) }
    }

    /// Closes a page of the Persona that no tab shows any more, through the runtime that created it. A page whose downloads would stop with it stays open on a blank page until they finish. A tab without its page has none to close.
    func retire(_ webContents: any EngineWebContents, of personaID: Persona.ID) {
        guard !(webContents is UnloadedWebContents), let runtime = personaEngines[personaID]?.runtimes[webContents.engineKind] else { return }
        if webContents.closingStopsDownloads {
            // Without a delegate the page's own questions, such as its leave-page check on the way to the blank page, get their default answers. Its developer tools close with its tab.
            webContents.uiDelegate = nil
            webContents.devTools?.close()
            webContents.navigationController.load(URLRequest(url: URL(string: "about:blank")!))
            downloadPages.append((runtime, webContents))
        } else {
            runtime.browser.closeWebContents(webContents)
        }
    }

    /// Adds a closed or archived tab's record to the closed list as the list keeps it (`SessionSnapshot.TabRecord.closed`), dropping the oldest beyond `SessionSnapshot.maximumClosedTabs`.
    private func addToClosedList(_ record: SessionSnapshot.TabRecord) {
        closedTabs.append(record.closed)
        if closedTabs.count > SessionSnapshot.maximumClosedTabs { closedTabs.removeFirst(closedTabs.count - SessionSnapshot.maximumClosedTabs) }
    }

    public var hasClosedTabs: Bool { !closedTabs.isEmpty }

    /// Reopens the newest closed tab under its own ID in its original space and folder, with its saved page when it was pinned, and selects it in the sidebar target. When its space is gone, it reopens in its Persona's preferred space, or in the sidebar target's current space once its Persona is gone too.
    public func reopenLastClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        undoableCloseCount = max(0, undoableCloseCount - 1)
        let spaceID = if spaces.contains(where: { $0.id == record.spaceID }) {
            record.spaceID
        } else if let personaID = record.personaID, persona(withID: personaID) != nil {
            preferredSpace(in: personaID).id
        } else {
            sidebarTarget().currentSpaceID
        }
        let personaID = personaID(ofSpace: spaceID)
        let tab = adopt(makeWebContents(url: record.url, engine: record.engine, state: nil, in: personaID), id: record.id ?? UUID(), spaceID: spaceID, personaID: personaID, pinned: record.isPinned, select: true)
        // Nothing else enters a live folder (live folder rule 4).
        let folderID = existingFolderID(record.folderID, spaceID: spaceID, pinned: record.isPinned)
        tab.reopen(record, folderID: folderTree.isLive(folderID) ? nil : folderID)
    }

    /// Duplicate: opens a copy of a space's tab right after it, in its list and folder, at its current address in its engine, and returns it for the window to select. A pinned copy keeps the original's saved page (bookmark rule 2). A favorite's tab and a small window's tab have no row to duplicate, and a live folder item's tab none whose copy could enter its folder.
    func duplicateTab(_ tab: Tab) -> Tab? {
        guard let spaceID = tab.spaceID, tab.isListedInSidebar, tab.liveItemID == nil, let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }
        let copy = makeTab(makeWebContents(url: tab.url, engine: tab.engineKind, state: nil, in: tab.personaID), id: UUID(), spaceID: spaceID, personaID: tab.personaID, pinned: tab.isPinned)
        copy.folderID = tab.folderID
        copy.savedPage = tab.savedPage
        tabs.insert(copy, at: index + 1)
        return copy
    }

    /// Pressing another key or clicking in the page makes ⌘Z undo there instead of reopening tabs.
    public func forgetUndoableCloses() {
        undoableCloseCount = 0
    }

    /// Moves a tab next to `neighbor`, before or after it, while both are open tabs of one space outside folders, as for a tab a web extension opens, and reports whether it moved; otherwise the tab stays where it is.
    @discardableResult
    func placeTab(_ tab: Tab, nextTo neighbor: Tab, after: Bool) -> Bool {
        guard tab.id != neighbor.id, neighbor.spaceID == tab.spaceID, !tab.isPinned, !neighbor.isPinned, tab.folderID == nil, neighbor.folderID == nil, neighbor.isListedInSidebar,
              let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        var reordered = tabs
        reordered.remove(at: from)
        guard let to = reordered.firstIndex(where: { $0.id == neighbor.id }) else { return false }
        reordered.insert(tab, at: after ? to + 1 : to)
        tabs = reordered
        return true
    }

    /// Swaps a space's tab with its neighbor in its folder, or among its space's pinned or open tabs outside folders. A live folder's tabs keep their source's order (live folder rule 4).
    func moveTab(_ tab: Tab, up: Bool) {
        guard let spaceID = tab.spaceID, !folderTree.isLive(tab.folderID), let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let siblings = tab.folderID == nil ? tabsOutsideFolders(in: spaceID, pinned: tab.isPinned) : tabs.filter { $0.folderID == tab.folderID }
        guard let position = siblings.firstIndex(where: { $0.id == tab.id }) else { return }
        let target = up ? position - 1 : position + 1
        guard siblings.indices.contains(target), let neighborIndex = tabs.firstIndex(where: { $0.id == siblings[target].id }) else { return }
        tabs.swapAt(index, neighborIndex)
    }

    /// Moves a dragged tab to `target`'s place and adopts its space, pinned state, and folder, allowing moves between pinned and open lists and into and out of folders. Within a list, dragging from above places the tab below the target. A target in a space of another Persona, or in a live folder, which nothing else enters and whose tabs keep their source's order (live folder rule 4), leaves the tab where it is. A live folder item's tab dragged out becomes an ordinary tab.
    public func moveTab(_ id: UUID, to target: Tab) {
        guard id != target.id, let spaceID = target.spaceID, canMoveTab(id, toSpace: spaceID), !folders.contains(where: { $0.id == target.folderID && $0.live != nil }),
              let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target.id }) else { return }
        let tab = tabs[from]
        let isSameList = tab.spaceID == target.spaceID && tab.isPinned == target.isPinned && tab.folderID == target.folderID
        var reordered = tabs
        reordered.remove(at: from)
        guard let targetIndex = reordered.firstIndex(where: { $0.id == target.id }) else { return }
        movingItemTabs {
            tab.spaceID = spaceID
            tab.isPinned = target.isPinned
            tab.folderID = target.folderID
            reordered.insert(tab, at: isSameList && from < to ? targetIndex + 1 : targetIndex)
            tabs = reordered
        }
    }

    /// Runs a change of tabs' places, then makes each live folder item's tab that the change took out of its folder an ordinary tab, and gives the folder a new tab for the item, marked read (live folder rule 4). Every move of a tab goes through here, so a tab leaves its live folder the same way whether it is dragged, moved to another folder or space, or unpinned.
    private func movingItemTabs(_ change: () -> Void) {
        let left = LiveFolderTabs.itemTabsLeaving(tabs, during: change)
        if !left.isEmpty { MainActor.assumeIsolated { itemTabsDidLeave(left) } }
    }

    /// Settings ▸ Sidebar saves under this key how many hours an unpinned tab stays open without being selected; 0 turns archiving off.
    public static let archiveAfterHoursKey = "ARCHArchiveAfterHours"

    /// The hours while nothing is saved under `archiveAfterHoursKey`.
    public static let archiveAfterHoursByDefault = 12

    /// Closes unpinned listed tabs inactive for the hours saved under `archiveAfterHoursKey` (`archiveAfterHoursByDefault` while none are; 0 disables), so a small window's tab stays. The tabs windows show, each window's selected tab and the other panes of its split view, count as active now.
    public func archiveInactiveTabs() {
        guard let cutoff = Self.archiveCutoff(now: Date()) else { return }
        windows.flatMap(\.paneTabs).forEach { $0.lastActivatedAt = Date() }
        for tab in tabs where tab.isListedInSidebar && !tab.isPinned && tab.lastActivatedAt < cutoff {
            closeTab(tab, reason: .archive)
            undoableCloseCount = 0
        }
    }

    /// `nil` when archiving is disabled.
    private static func archiveCutoff(now: Date) -> Date? {
        let defaults = UserDefaults.standard
        let hours = defaults.object(forKey: archiveAfterHoursKey) == nil ? archiveAfterHoursByDefault : defaults.integer(forKey: archiveAfterHoursKey)
        guard hours > 0 else { return nil }
        return now.addingTimeInterval(-TimeInterval(hours) * 3600)
    }

    /// The tab stores the pinned flag; the session republishes changes for views that group tabs by it. A tab in a folder leaves it, because the folder stays in the other list; a live folder item's tab becomes an ordinary tab without its saved page.
    public func togglePinned(_ tab: Tab) {
        objectWillChange.send()
        movingItemTabs {
            tab.folderID = nil
            tab.isPinned.toggle()
        }
    }

    /// Accepts only a full URL with a scheme and host, a file URL, which has no host, or an address without spaces whose host is dotted, `localhost` or a name under it, or an IPv6 address in brackets. Adds `http://` to an address on this Mac, where development servers run without TLS, and `https://` to the others. `localhost:3000` is thus an address, though it parses as a URL whose scheme is `localhost`. A file URL loads as typed, so the address of a dropped file that the palette shows reloads the file instead of sending its path to the search engine.
    public static func url(forInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = URL(string: text), let scheme = parsed.scheme, parsed.host != nil || scheme.lowercased() == "file" { return parsed }
        guard !text.contains(" "), let parsed = URL(string: "https://\(text)"), let host = parsed.host?.lowercased(), !host.isEmpty else { return nil }
        if isOnThisMac(host) { return URL(string: "http://\(text)") }
        return host.contains(".") || host.contains(":") ? parsed : nil
    }

    /// Whether `host`, in lowercase, names this Mac: `localhost`, a name under it, or a loopback address (127.0.0.0/8 or ::1).
    private static func isOnThisMac(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return withUnsafeBytes(of: &ipv4) { $0[0] } == 127 }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, host, &ipv6) == 1 && withUnsafeBytes(of: &ipv6) { Array($0) } == [UInt8](repeating: 0, count: 15) + [1]
    }

    /// Returns a site's results page for text that starts with a site search keyword and a space, the input URL, a web search URL for other text, such as a keyword whose template makes no web address, or `nil` for empty text.
    static func destination(forInput input: String, siteSearch: SiteSearchStore) -> URL? {
        if let search = siteSearch.match(input), let url = search.shortcut.resultsURL(for: search.query) { return url }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = url(forInput: text) { return url }
        return searchResultsURL(for: text)
    }

    /// The results page of the search engine chosen in Settings for `text`.
    static func searchResultsURL(for text: String) -> URL {
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url!
    }

    // MARK: Plugins

    /// The plugins the app ships, which every Persona's manager offers.
    private let builtInPlugins: [any BuiltInPlugin.Type]
    /// Connects each tab to its Persona's plugins.
    private let pluginPages = PluginPages()
    /// Hosts each Persona's web extensions in the windows and tabs.
    private let webExtensionHost = SessionWebExtensionHost()

    /// The Persona's plugins, kept in its folder under the app's Application Support folder, created on first use, with the runtime of its web extensions, which reach the native apps that the host manifests in `nativeMessagingHosts` name, under the proof gate that staging and the review also follow.
    @MainActor public func plugins(in personaID: Persona.ID) -> PluginManager {
        let engines = engines(of: personaID)
        if let plugins = engines.plugins { return plugins }
        let webExtensions = WebExtensionRuntime(persona: personaID, host: webExtensionHost, hostLinks: nativeMessagingHosts)
        // The host knows the session before the manager asks the runtime which engines run extensions.
        webExtensionHost.follow(webExtensions, of: personaID, in: self)
        let plugins = PluginManager(persona: personaID, directory: userDataDirectory, builtIns: builtInPlugins, runtimes: [webExtensions])
        plugins.nativeAppGate = nativeMessagingHosts
        engines.plugins = plugins
        engines.webExtensions = webExtensions
        // Profiles that started before the runtime, as the default Persona's in the primary engine at launch.
        for runtime in engines.runtimes.values {
            if let extensions = runtime.context.extensions { webExtensions.profileDidStart(with: extensions, of: runtime.kind) }
        }
        pluginPages.follow(plugins, of: personaID)
        return plugins
    }

    /// Has every Persona's web extension runtime take out of Chromium the versions that the proof gate comes to refuse, as under the links a pass is about to make (`NativeMessagingHostLinks.gateWidens`). A Persona whose runtime the session has not made yet does so when it makes it, as its profiles' starts reach the runtime.
    @MainActor private func takeGatedVersionsOutOfChromium() async {
        for runtime in personaEngines.values.compactMap(\.webExtensions) {
            await runtime.takeGatedVersionsOutOfChromium()
        }
    }

    /// The runtime of the Persona's web extensions, for their actions in the site settings popover.
    @MainActor public func webExtensions(in personaID: Persona.ID) -> WebExtensionRuntime? {
        _ = plugins(in: personaID)
        return engines(of: personaID).webExtensions
    }

    /// The registered engines that run web extensions on this Mac, each with its extension runtime's version, without starting any of them. An engine whose application did not start is not one of them.
    var extensionRuntimeVersions: [EngineKind: String] {
        var versions: [EngineKind: String] = [:]
        for kind in registry.registeredKinds where !enginesThatDidNotStart.contains(kind) {
            guard let engine = registry.engine(for: kind), engine.capabilities.contains(.extensions), let version = engine.extensionRuntimeVersion else { continue }
            versions[kind] = version
        }
        return versions
    }

    /// The Persona's profiles in the engines that run web extensions, by engine, which start if they have not started. An engine whose application or profile does not start is left out: unlike a tab's runtime, it takes no other engine's profile, which would run each extension twice there.
    func extensionEngines(in personaID: Persona.ID) -> [EngineKind: any EngineExtensions] {
        guard personas.contains(where: { $0.id == personaID }) else { return [:] }
        let personaEngines = engines(of: personaID)
        var engines: [EngineKind: any EngineExtensions] = [:]
        for kind in extensionRuntimeVersions.keys {
            engines[kind] = (personaEngines.runtimes[kind] ?? startRuntime(kind, in: personaEngines))?.context.extensions
        }
        return engines
    }

    /// Stops a deleted Persona's plugins for good and drops its manager, so that they write nothing more to the Persona's folder, which goes at the next launch. Its web extensions leave the engines with them.
    @MainActor private func closePlugins(of engines: PersonaEngines) {
        pluginPages.stopFollowing(engines.personaID)
        webExtensionHost.stopFollowing(engines.personaID)
        engines.plugins?.close()
        engines.plugins = nil
        engines.webExtensions = nil
    }

    /// Reloads the Persona's tabs whose pages the plugin's page scripts cover, so that the scripts of a plugin the user just switched on run there.
    @MainActor public func reloadTabs(coveredByPageScriptsOf id: PluginID, in personaID: Persona.ID) {
        let plugins = plugins(in: personaID)
        for tab in allTabs where tab.personaID == personaID && tab.url.map({ plugins.pageScriptsCover($0, of: id) }) == true {
            tab.webContents.navigationController.reload()
        }
    }

    // MARK: Site permissions

    /// Answers the tabs' permission requests from `sitePermissions` or with a card on the tab, and keeps each profile's own kept answers in line with `sitePermissions`.
    let permissionAnswers: SitePermissionAnswers

    // MARK: Prompts

    /// Queues a prompt for a tab, which a card shows over the tab's pane while a window shows the tab (`TabPromptQueue`). While the app quits, it ends at once without the user.
    func enqueuePrompt(_ content: PromptContent, for tab: Tab, completion: @escaping (PromptResponse) -> Void) {
        prompts.enqueue(content, for: tab.id, completion: completion)
    }

    /// Queues a prompt whose content `makeContent` makes again each time a card shows it, from what is true then.
    func enqueuePrompt(making makeContent: @escaping () -> PromptContent, for tab: Tab, completion: @escaping (PromptResponse) -> Void) {
        prompts.enqueue(makeContent(), for: tab.id, makeContent: makeContent, completion: completion)
    }

    // MARK: Zoom

    /// Each host's zoom factor other than 1, as a `UserDefaults` dictionary keyed by host.
    private static let zoomFactorsKey = "ARCHZoomFactorsByHost"

    /// Sets a tab's zoom and remembers it for the page's host, so that the host's other open tabs follow. A page without a host keeps the factor until its next load.
    func setZoom(_ factor: Double, of tab: Tab) {
        guard let host = tab.webContents.url?.host else {
            tab.webContents.zoomFactor = factor
            return
        }
        let defaults = UserDefaults.standard
        var factors = defaults.dictionary(forKey: Self.zoomFactorsKey) as? [String: Double] ?? [:]
        factors[host] = abs(factor - 1) < 0.001 ? nil : factor
        defaults.set(factors, forKey: Self.zoomFactorsKey)
        for tab in allTabs where tab.webContents.url?.host == host { applyZoom(to: tab) }
    }

    /// Gives a tab its host's remembered zoom factor, or 1 for a host without one.
    private func applyZoom(to tab: Tab) {
        let factors = UserDefaults.standard.dictionary(forKey: Self.zoomFactorsKey) as? [String: Double]
        let factor = tab.webContents.url?.host.flatMap { factors?[$0] } ?? 1
        if abs(tab.webContents.zoomFactor - factor) > 0.001 { tab.webContents.zoomFactor = factor }
    }

    // MARK: Tab close log

    /// Why each tab closed this launch, for the tab close log window.
    public let closeLog = TabCloseLog()

    /// Logs a closing tab with its crash count and the engines' total, and drops it from each window's switcher order.
    private func recordClose(of tab: Tab, reason: TabCloseReason) {
        windows.forEach { $0.forgetActivation(of: tab.id) }
        closeLog.record(TabCloseLogEntry(reason: reason, tab: tab, sessionCrashCount: rendererCrashCount))
    }

    // MARK: Site data

    /// Deletes the site's cookies from every engine of the Persona at once, then each engine's other data for the site's origins, then reloads the Persona's tabs of the site. An engine that has not started for the Persona yet starts first, so that the cookies it keeps on disk cannot come back through a later copy.
    func clearSiteData(of site: SiteDataScope, in personaID: Persona.ID) {
        availableEngines.forEach { _ = runtime(for: $0, in: personaID) }
        let engines = engines(of: personaID)
        let isSiteTab = { (tab: Tab) in tab.personaID == personaID && tab.url?.host.map(site.contains(host:)) == true }
        engines.cookieSync.removeCookies(where: { site.contains($0) }) { [weak self] in
            guard let self else { return }
            let pages = self.allTabs.filter(isSiteTab).compactMap(\.url)
            let origins = Array(Set(site.origins + pages.compactMap(SiteDataScope.origin(of:))))
            let group = DispatchGroup()
            for runtime in engines.runtimes.values {
                group.enter()
                runtime.browser.removeSiteData(for: origins) { group.leave() }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                for tab in self.allTabs where isSiteTab(tab) {
                    tab.webContents.navigationController.reloadWithoutCache()
                }
            }
        }
    }

    // MARK: Now Playing

    /// Shows the media of the focused or most recently audible tab in Now Playing and sends the media keys to it.
    private var nowPlaying: NowPlaying?

    // MARK: Page reader and questions

    /// The conversations of the page reader and the question popover, which windows show. It follows the session's tabs once the session exists.
    public let pageAssistant = PageAssistant()
    /// Posts the tabs' and downloads' events to the AI interface's hooks and applies their actions, once the session exists.
    private let hooks = BrowserHooks()

    // MARK: Drag and drop

    /// Moves a dragged favorite to `target`'s place.
    public func moveFavorite(_ id: UUID, to target: Favorite) {
        guard let from = favorites.firstIndex(where: { $0.id == id }), let to = favorites.firstIndex(where: { $0.id == target.id }), from != to else { return }
        var reordered = favorites
        reordered.insert(reordered.remove(at: from), at: to)
        favorites = reordered
    }

    /// Moves a dragged space to `target`'s place in the switcher, when both belong to the same Persona.
    public func moveSpace(_ id: UUID, to target: Space) {
        guard let from = spaces.firstIndex(where: { $0.id == id }), let to = spaces.firstIndex(where: { $0.id == target.id }), from != to,
              spaces[from].resolvedPersonaID == spaces[to].resolvedPersonaID else { return }
        var reordered = spaces
        reordered.insert(reordered.remove(at: from), at: to)
        spaces = reordered
    }

    /// Moves a tab dropped on another space's symbol after that space's own pinned or open tabs, outside its folders. The window that selects the tab follows it to its new space, so the sidebar keeps showing the page's tab. A space of another Persona refuses the tab.
    public func moveTab(_ id: UUID, toSpace spaceID: UUID) {
        guard canMoveTab(id, toSpace: spaceID), let moving = tabs.first(where: { $0.id == id }), moving.spaceID != spaceID else { return }
        // The other panes of its split view stay together in the space it leaves.
        leaveSplitView(moving)
        guard let index = tabs.firstIndex(where: { $0 === moving }) else { return }
        var reordered = tabs
        let tab = reordered.remove(at: index)
        movingItemTabs {
            tab.spaceID = spaceID
            tab.folderID = nil
            reordered.append(tab)
            tabs = reordered
        }
        for window in windows where window.selectedTabID == tab.id { window.currentSpaceID = spaceID }
    }

    /// Moves a dragged tab after its space's pinned or open tabs outside folders, so that a drag can take a tab out of a folder even when no other tab sits outside folders in that list.
    public func moveTabToListEnd(_ id: UUID, pinned: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var reordered = tabs
        let tab = reordered.remove(at: index)
        movingItemTabs {
            tab.isPinned = pinned
            tab.folderID = nil
            reordered.append(tab)
            tabs = reordered
        }
    }

    // MARK: Folders

    /// Every space's folders. Among the folders of each parent, or at the top of each space's pinned or open list, the sidebar shows them in this order.
    @Published public private(set) var folders: [TabFolder] = []

    /// The folders and tabs as the sidebar nests them (bookmark rule 6), which the rows, the folder menus, and the moves below ask.
    var folderTree: FolderTree {
        FolderTree(folders: folders, tabs: tabs)
    }

    /// A space's folders in its pinned or open list, at every level.
    public func folders(in spaceID: UUID, pinned: Bool) -> [TabFolder] {
        folders.filter { $0.spaceID == spaceID && $0.isPinned == pinned }
    }

    /// A space's folders at every level: those among its pinned tabs, then those among its open tabs.
    public func folders(in spaceID: UUID) -> [TabFolder] {
        folders(in: spaceID, pinned: true) + folders(in: spaceID, pinned: false)
    }

    /// A space's pinned or open tabs that are in no folder, in sidebar order. A small window's tab, which is in no folder, is left out until it moves to a main window.
    public func tabsOutsideFolders(in spaceID: UUID, pinned: Bool) -> [Tab] {
        tabs.filter { $0.spaceID == spaceID && $0.isPinned == pinned && $0.folderID == nil && $0.isListedInSidebar }
    }

    /// Moves a tab into an ordinary folder of its space, at any level, after the folder's own tabs. The tab joins the folder's pinned or open list. Nothing else enters a live folder (live folder rule 4).
    public func moveTab(_ id: UUID, toFolder folderID: UUID) {
        guard let folder = folders.first(where: { $0.id == folderID }), folder.live == nil, let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].spaceID == folder.spaceID, tabs[index].folderID != folderID else { return }
        var reordered = tabs
        let tab = reordered.remove(at: index)
        movingItemTabs {
            tab.isPinned = folder.isPinned
            tab.folderID = folderID
            reordered.append(tab)
            tabs = reordered
        }
    }

    /// Move Out of Folder: moves a tab into its folder's parent, or out of folders, first among the tabs there.
    public func moveOutOfFolder(_ tab: Tab) {
        changeFolderTree { $0.moveTabOut(tab) }
    }

    /// Move to Folder for a folder: moves it with everything it holds into another folder of its list, last among that folder's folders, as `FolderTree.canMoveFolder(_:into:)` allows.
    public func moveFolder(_ id: UUID, into parentID: UUID) {
        changeFolderTree { $0.moveFolder(id, into: parentID) }
    }

    /// Move Out of Folder for a folder: moves it with everything it holds up one level, right after the folder it leaves.
    public func moveFolderOut(_ id: UUID) {
        changeFolderTree { $0.moveFolderOut(id) }
    }

    /// A folder's drag among the rows: moves it with everything it holds to where `FolderTree.dropTarget(for:at:)` put it.
    func moveFolder(_ id: UUID, to target: FolderTree.DropTarget) {
        changeFolderTree { $0.moveFolder(id, to: target) }
    }

    /// The guard of a folder's drop on another space's symbol: a space of the folder's Persona other than its own, to which every tab inside the folder can move (Persona rule 3).
    func canMoveFolder(_ id: UUID, toSpace spaceID: UUID) -> Bool {
        guard let folder = folders.first(where: { $0.id == id }), folder.spaceID != spaceID,
              let from = spaces.first(where: { $0.id == folder.spaceID }), let to = spaces.first(where: { $0.id == spaceID }),
              from.resolvedPersonaID == to.resolvedPersonaID else { return false }
        return folderTree.tabs(inside: id).allSatisfy { canMoveTab($0.id, toSpace: spaceID) }
    }

    /// Moves a folder dropped on another space's symbol, with the folders and tabs inside it, last among the folders at the top of that space's list of its kind (`FolderTree.moveFolder(_:toSpace:)`). As for a dropped tab, its tabs leave the split view of the space they leave, and a window that selects one of them follows it to the space.
    public func moveFolder(_ id: UUID, toSpace spaceID: UUID) {
        guard canMoveFolder(id, toSpace: spaceID) else { return }
        let carried = folderTree.tabs(inside: id)
        carried.forEach { leaveSplitView($0) }
        changeFolderTree { $0.moveFolder(id, toSpace: spaceID) }
        for window in windows where carried.contains(where: { $0.id == window.selectedTabID }) { window.currentSpaceID = spaceID }
    }

    public func toggleCollapsed(ofFolder id: UUID) {
        updateFolder(id) { $0.isCollapsed.toggle() }
    }

    /// Expands every collapsed folder that holds the folder `id`, so that the folder's row shows.
    func expandFolders(holding id: UUID) {
        for ancestor in folderTree.ancestors(of: id) where ancestor.isCollapsed {
            updateFolder(ancestor.id) { $0.isCollapsed = false }
        }
    }

    /// Delete Folder: removes a folder and keeps what it holds. Its folders take its place in its parent, or at the top of its list, and its tabs go first among the tabs there. A live folder's item tabs close instead (`deleteLiveFolder(_:)`).
    public func deleteFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        if folder.live != nil { return MainActor.assumeIsolated { deleteLiveFolder(id) } }
        changeFolderTree { $0.deleteFolder(id) }
        windows.forEach { $0.endRenamingFolder(id) }
    }

    /// Appends a folder to a space's pinned or open list: at the top of the list, or last among the folders of `parentID`, a folder of that list in which `FolderTree.canAddFolder(inside:)` allows one.
    func makeFolder(in spaceID: UUID, pinned: Bool, inside parentID: UUID? = nil) -> TabFolder {
        var folder = TabFolder(spaceID: spaceID, name: "New Folder", isPinned: pinned)
        folder.parentID = parentID
        folders.append(folder)
        return folder
    }

    /// Appends a folder made elsewhere, such as New Live Folder…'s, which then follows its space's other folders in its list.
    func appendFolder(_ folder: TabFolder) {
        folders.append(folder)
    }

    /// Applies a change of the folder tree to the session's folders and tabs. Both are set, so that the session publishes a change even when only a tab's folder changed. A live folder item's tab that the change takes out of its folder becomes an ordinary tab.
    func changeFolderTree(_ change: (inout FolderTree) -> Void) {
        // The tree's changes set the moved tabs' folders as they run.
        movingItemTabs {
            var tree = folderTree
            change(&tree)
            folders = tree.folders
            tabs = tree.tabs
        }
    }

    func updateFolder(_ id: UUID, _ change: (inout TabFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        change(&folders[index])
    }

    /// `id` while it names a folder in that space's pinned or open list, so that a saved or closed tab returns to its folder unless the folder has gone or moved.
    private func existingFolderID(_ id: UUID?, spaceID: UUID, pinned: Bool) -> UUID? {
        folders.first { $0.id == id && $0.spaceID == spaceID && $0.isPinned == pinned }?.id
    }

    // MARK: Browser import

    /// Adds what a profile of another browser brings to `destination`, leaving out what is there already (see `SidebarImport.Plan`): the Persona when it is new, the spaces, pinned folders, and favorites, and the pinned tabs, each opened in the default engine without being selected and saved at its imported address (bookmark rule 2). `record` then holds what the row brought in place of the profile's earlier entry, and no longer the IDs of items that are gone; the caller writes it once every row is in. Returns what the row added.
    public func addImport(_ row: SidebarImport, to destination: SidebarImport.Destination, record: inout SidebarImport.Record) -> SidebarImport.Counts {
        let plan = SidebarImport.Plan(row, to: destination, entry: record.entry(for: row.profile), in: importSidebar)
        if let persona = plan.newPersona {
            add(persona, spaces: plan.spaces)
        } else {
            plan.spaces.forEach(insert)
        }
        folders += plan.folders
        addFavorites(plan.favorites, in: plan.personaID)
        for pinned in plan.pinnedTabs {
            let tab = makeTab(makeWebContents(url: pinned.url, engine: nil, state: nil, in: plan.personaID), id: pinned.id, spaceID: spaceID(pinned.spaceID, orPreferredIn: plan.personaID), personaID: plan.personaID, pinned: true)
            // It opens as a restored tab does, so it is marked before it joins the list that the hooks follow.
            tab.takeImport(pinned)
            tabs.append(tab)
        }
        record.update(plan.entry)
        record.removeGoneItems(in: importSidebar)
        return plan.counts
    }

    /// The sidebar as the browser import's plan resolves a row against it.
    private var importSidebar: SidebarImport.Sidebar {
        SidebarImport.Sidebar(personas: personas, spaces: spaces, folders: folders, favorites: favorites, tabs: tabs.compactMap(SidebarImport.Sidebar.TabState.init))
    }

    // MARK: Split view

    /// The most tabs a split view shows side by side.
    static let maximumPanes = 4
    /// Each space's split view: two to four of its tabs that share the page area, left to right. The page area shows a space's split view while one of its tabs is selected, and the selected tab is the focused pane.
    @Published private(set) var splitTabIDs: [UUID: [UUID]] = [:] {
        didSet {
            // The panes on screen change with the split views, and the prompt cards that show change with them. A pane that joins a window's split view while another window shows its tab stays with that window.
            windows.forEach { $0.updateShownTabs() }
        }
    }

    /// Makes `tabIDs` the space's split view, in place of an earlier one.
    func setSplitView(_ tabIDs: [UUID], ofSpace spaceID: UUID) {
        splitTabIDs[spaceID] = tabIDs
    }

    /// Removes `tab` from its space's split view, which ends once fewer than two tabs remain. Returns the pane that takes its place: the one after it, or the one before for the last pane.
    @discardableResult
    func leaveSplitView(_ tab: Tab) -> UUID? {
        guard let spaceID = tab.spaceID, var ids = splitTabIDs[spaceID], let index = ids.firstIndex(of: tab.id) else { return nil }
        ids.remove(at: index)
        splitTabIDs[spaceID] = ids.count >= 2 ? ids : nil
        return ids.indices.contains(index) ? ids[index] : ids.last
    }

    /// The split views for `session.json`, in the order of their spaces, each as indexes into the tab list.
    private var splitViewRecords: [[Int]] {
        spaces.compactMap { splitTabIDs[$0.id] }.map { ids in ids.compactMap { id in tabs.firstIndex { $0.id == id } } }
    }

    /// Rebuilds the split views `session.json` recorded from the tabs that reopened, keyed by their records' indexes. A split view returns while two to four of its tabs reopened in one space.
    private func restoreSplitViews(_ records: [[Int]], from restored: [Int: Tab]) {
        for record in records {
            let panes = record.compactMap { restored[$0] }
            guard let spaceID = panes.first?.spaceID, (2...Self.maximumPanes).contains(panes.count), splitTabIDs[spaceID] == nil,
                  panes.allSatisfy({ $0.spaceID == spaceID }), Set(panes.map(\.id)).count == panes.count else { continue }
            splitTabIDs[spaceID] = panes.map(\.id)
        }
    }

    // MARK: Persistence

    /// Reopens the saved tabs and their split views. A tab gets its page as a window first shows it (`loadPage(of:)`), so launching starts no page for a tab that no window shows; until then its stand-in keeps the record's address, title, engine, and page state, which saving writes back unchanged.
    private func restoreTabs(_ snapshot: SessionSnapshot) {
        // Archive stale unpinned records before they have web contents.
        let cutoff = Self.archiveCutoff(now: Date())
        // The reopened tabs by their records' indexes, which the split views refer to.
        var restored: [Int: Tab] = [:]
        for (index, record) in snapshot.tabs.enumerated() where spaces.contains(where: { $0.id == record.spaceID }) {
            if !record.isPinned, let cutoff, let last = record.lastActivatedAt, last < cutoff {
                addToClosedList(record)
                closeLog.record(TabCloseLogEntry(archived: record))
                continue
            }
            let personaID = personaID(ofSpace: record.spaceID)
            let page = UnloadedWebContents(record: record, defaultEngine: defaultEngine)
            page.loadSiteIcon()
            let tab = adopt(page, id: record.id ?? UUID(), spaceID: record.spaceID, personaID: personaID, pinned: record.isPinned, select: false)
            tab.restore(record, folderID: existingFolderID(record.folderID, spaceID: record.spaceID, pinned: record.isPinned))
            restored[index] = tab
        }
        restoreSplitViews(snapshot.splitViews ?? [], from: restored)
    }

    /// Keeps the favorites' tabs from the last session until their favorites open them. The tabs that saved windows selected open now, so that those windows show the pages they showed.
    private func restoreFavoriteTabs(_ snapshot: SessionSnapshot) {
        let selectedIDs = Set((snapshot.windows ?? []).compactMap(\.selectedTabID))
        for record in snapshot.favoriteTabs ?? [] where favorites.contains(where: { $0.id == record.favoriteID }) {
            savedFavoriteTabs[record.favoriteID] = record
        }
        for favorite in favorites {
            guard let id = savedFavoriteTabs[favorite.id]?.id, selectedIDs.contains(id) else { continue }
            _ = openTab(for: favorite)
        }
    }

    private func observeChanges() {
        // Opening, closing, and bringing a window forward change the windows the file keeps and their order. The window controllers save frame changes themselves.
        let windowChanges = $windows.map { windows in
            Publishers.MergeMany(windows.map { Publishers.Merge3($0.$currentSpaceID.map { _ in () }, $0.$selectedTabID.map { _ in () }, $0.$isSidebarVisible.map { _ in () }) })
        }.switchToLatest()
        Publishers.Merge4($tabs.map { _ in () }, $spaces.map { _ in () }, $favorites.map { _ in () }, windowChanges)
            .merge(with: $personas.map { _ in () }, $closedTabs.map { _ in () })
            .merge(with: $favoriteTabs.map { _ in () }, $savedFavoriteTabs.map { _ in () }, $folders.map { _ in () }, $splitTabIDs.map { _ in () })
            .dropFirst()
            .sink { [weak self] in self?.scheduleSave() }
            .store(in: &cancellables)
    }

    /// Saves the session once changes stop for half a second. The window controllers call it for frame changes, which no published value reports.
    func scheduleSave() {
        store.scheduleSave { [weak self] in self?.snapshot() }
    }

    @discardableResult
    public func saveNow() -> Result<Void, Error> {
        store.saveNow(snapshot())
    }

    /// The app saves the session before confirming quit. Stop live folders and flush each Persona's cookie record only once the app actually terminates.
    public func finishWritesAtQuit() {
        MainActor.assumeIsolated { liveFolderService.stop() }
        personaEngines.values.forEach { $0.cookieSync.saveAtQuit() }
        CookieSync.finishWrites()
    }

    /// The session as `session.json` keeps it. The windows are the open main windows, front to back, or the last main window while none is open, so that the next launch opens them. The front one's space and selection also go where older builds read them. Small windows are not kept: their tabs are saved as open tabs of their spaces (open decision 4). The tabs windows show are recorded as active now, as the archive timer counts them, so that the next launch does not archive a tab that was in view until the app quit.
    private func snapshot() -> SessionSnapshot {
        let mainWindows = windows.filter { $0.kind == .main }
        let windowRecords = mainWindows.isEmpty ? windowsToReopen : mainWindows.map(\.record)
        let front = windowRecords[0]
        let now = Date()
        let shownIDs = Set(windows.flatMap(\.paneTabs).map(\.id))
        return SessionSnapshot(version: SessionSnapshot.currentVersion, personas: personas, removedPersonaIDs: personaDataRemoval.pendingIDs, spaces: spaces, currentSpaceID: front.currentSpaceID, favorites: favorites,
                               tabs: tabs.map { SessionSnapshot.TabRecord($0, spaceID: $0.spaceID ?? front.currentSpaceID, lastActivatedAt: shownIDs.contains($0.id) ? now : $0.lastActivatedAt) },
                               folders: folders, selectedTabIndex: tabs.firstIndex { $0.id == front.selectedTabID }, closedTabs: closedTabs,
                               splitViews: splitViewRecords, favoriteTabs: favoriteTabRecords, selectedFavoriteID: favoriteTabs.first { $0.value.id == front.selectedTabID }?.key, windows: windowRecords)
    }

    /// The favorites' open tabs and the saved ones not opened since launch, in favorite order.
    private var favoriteTabRecords: [SessionSnapshot.FavoriteTabRecord] {
        favorites.compactMap { favorite in
            guard let tab = favoriteTabs[favorite.id] else { return savedFavoriteTabs[favorite.id] }
            return SessionSnapshot.FavoriteTabRecord(id: tab.id, favoriteID: favorite.id, url: tab.url, engine: tab.engineKind, state: tab.webContents.restorableState)
        }
    }
}

// MARK: Unloading

extension BrowserSession {
    /// Unloads the loaded tabs that no window shows and that `TabUnloading.tabsToUnload` picks (bookmark rule 5): for the archive timer without `pressure`, after the hours that Settings ▸ Sidebar saves under `TabUnloading.unloadAfterHoursKey`, or at the memory pressure source's level.
    func unloadInactiveTabs(pressure: UnloadPressure?) {
        let candidates = allTabs.compactMap(unloadCandidate)
        for id in TabUnloading.tabsToUnload(candidates, now: Date(), after: TabUnloading.unloadAfterHours(), pressure: pressure) {
            if let tab = allTabs.first(where: { $0.id == id }) { unloadAutomatically(tab) }
        }
    }

    /// The tab as automatic unloading weighs it, with what keeps it loaded, or nil for a tab without its page, one that a window shows, and one whose page has not answered an earlier unload yet.
    private func unloadCandidate(_ tab: Tab) -> UnloadCandidate? {
        guard tab.isLoaded, window(showing: tab) == nil, !tab.answersBeforeUnloadWithStay else { return nil }
        let page = tab.webContents
        var exclusions: Set<UnloadExclusion> = []
        if tab.isAudible || page.mediaSession.playbackState == .playing { exclusions.insert(.media) }
        if page.isInPictureInPicture { exclusions.insert(.pictureInPicture) }
        if tab.isCapturingMedia { exclusions.insert(.capture) }
        if tab.hasTypedInput { exclusions.insert(.typedInput) }
        if let origin = tab.url.flatMap(SitePermissionStore.origin(of:)), sitePermissions.decision(for: .notifications, origin: origin) == .allow {
            exclusions.insert(.notifications)
        }
        if prompts.hasPrompt(for: tab.id) { exclusions.insert(.prompt) }
        if page.closingStopsDownloads || downloadOnlyTabIDs.contains(tab.id) { exclusions.insert(.downloads) }
        if tab.isInSmallWindow { exclusions.insert(.smallWindow) }
        if page.devTools?.isOpen == true { exclusions.insert(.developerTools) }
        if allTabs.contains(where: { $0.opener === page && window(showing: $0) != nil }) { exclusions.insert(.opener) }
        let kind: UnloadCandidate.Kind = tab.spaceID == nil ? .favorite : tab.isPinned ? .pinned : .open
        return UnloadCandidate(id: tab.id, kind: kind, lastActivatedAt: tab.lastActivatedAt, exclusions: exclusions)
    }

    /// Asks the tab's page to leave as closing does, but answers a Chromium page's leave-page question with Stay without a card, and unloads the tab in place once the page agrees; a page that stays keeps its tab loaded until the next try. WebKit agrees at once, so there its typed text exclusion keeps a draft. A close the user asks for meanwhile takes over the question (`whenPageAgreesToLeave`), and the page's answer then reaches only that close. A Chromium tab that a window starts to show meanwhile still unloads once its page agrees, since CEF is already closing the browser, and loads again at once without its page state (`docs/bookmarks.md`, risk 9).
    private func unloadAutomatically(_ tab: Tab) {
        let page = tab.webContents
        tab.answersBeforeUnloadWithStay = true
        page.tryToClose { [weak self, weak tab] agrees in
            guard let self, let tab, tab.webContents === page, tab.answersBeforeUnloadWithStay else { return }
            tab.answersBeforeUnloadWithStay = false
            if agrees { self.unloadKeepingPage(tab) }
        }
    }

    /// An automatic unload: the tab keeps its place, folder, split view, and ID, and a favorite's tab its favorite, with a stand-in that keeps its address, title, icon, and its engine's page state (`Tab.unloadKeepingPage()`), while its page closes. Nothing joins the closed list or the tab close log, and its row keeps its icon, so it requests none. A window loads each pane again as it shows the split view.
    private func unloadKeepingPage(_ tab: Tab) {
        guard allTabs.contains(where: { $0 === tab }) else { return }
        // A prompt that came after the page was asked to leave ends; its code can close the tab, so the lists are read again afterwards.
        prompts.dismiss(tabID: tab.id)
        guard allTabs.contains(where: { $0 === tab }), tab.isLoaded else { return }
        // The favorites grid reads from the session whether a favorite's page is open (`hasOpenPage(_:)`).
        if tab.spaceID == nil { objectWillChange.send() }
        retire(tab.unloadKeepingPage(), of: tab.personaID)
        loadPageIfShown(tab)
    }
}

public enum CommandPaletteMode {
    case editCurrent
    case newTab
}

public enum CommandPaletteOrigin {
    /// A shortcut or menu command: the palette rises from below.
    case keyboard
    /// A control in the sidebar: the palette comes in from the sidebar's side.
    case sidebar
    /// The address pill, clicked or through Open Location (⌘L): the palette comes out of the pill, and the pill's contents move toward it. Without the pill on screen, as in a small window or with the sidebar hidden, the palette opens as from the keyboard.
    case addressPill
}

extension BrowserSession: EngineApplicationDelegate {
    public func application(_ application: any EngineApplication, didReceiveRendererProcessCrash count: Int) { crashCounts[application.engineKind] = count }
}

extension BrowserSession: EngineBrowserContextDelegate {
    /// A service worker of a Persona's profile opens a page, as `clients.openWindow()` does after a click on its notification: in a new tab of that Persona in the profile's engine, in the current space of the Persona's front main window, or without one in the Persona's preferred space, selected, with its window and the app in front, as the page's own `focus()` brings its tab. A window of another Persona keeps its Persona / Space while one of the Persona is open. A quit opens none.
    public func browserContext(_ context: any EngineBrowserContext, openTabWith url: URL, completion: @escaping ((any EngineWebContents)?) -> Void) {
        guard !isQuitting,
              let runtime = personaEngines.values.lazy.flatMap(\.runtimes.values).first(where: { ($0.context as AnyObject) === (context as AnyObject) }) else {
            return completion(nil)
        }
        let spaceID = windows.first { $0.kind == .main && $0.personaID == runtime.personaID }?.currentSpaceID ?? preferredSpace(in: runtime.personaID).id
        let tab = openTab(url: url, in: spaceID, select: false, engine: runtime.kind)
        tab.requestActivation?()
        completion(tab.webContents)
    }
}

// MARK: Downloads

extension BrowserSession {
    /// Opening the library marks every finished download as seen, which clears the library button's count.
    func markDownloadsSeen() {
        unseenDownloadIDs.removeAll()
    }

    public func removeDownload(_ entry: DownloadEntry) {
        entry.item.remove()
    }

    public func clearFinishedDownloads() {
        downloads.filter(\.isFinished).forEach { $0.item.remove() }
    }

    /// The downloads in progress or paused. Quitting stops them, and the next launch does not list them.
    public var unfinishedDownloadCount: Int {
        downloads.count { !$0.isFinished }
    }

    /// The downloads folder saved in Settings, falling back to the user's Downloads folder, then the temporary folder.
    private var downloadsDirectory: URL {
        Self.savedDownloadsFolder
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Adds a counter to `filename` until the name is unused in `directory`.
    static func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            counter += 1
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
        }
        return candidate
    }

    // MARK: Download settings

    /// Settings saves the downloads folder's path and whether to ask where to save each download under these keys.
    public static let downloadsFolderKey = "ARCHDownloadsFolder"
    public static let asksWhereToSaveDownloadsKey = "ARCHAskWhereToSaveDownloads"

    /// The downloads folder saved in Settings, or nil when none is saved or the saved folder no longer exists.
    private static var savedDownloadsFolder: URL? {
        var isDirectory: ObjCBool = false
        return UserDefaults.standard.string(forKey: downloadsFolderKey).flatMap { path in
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
    }

    /// Copies the saved download settings into a profile's preferences, which choose each download's destination, now and after every change to the defaults. A saved folder that no longer exists leaves the user's Downloads folder in use.
    private func followDownloadSettings(of context: any EngineBrowserContext) {
        let apply = {
            context.preferences.downloadFilePath = Self.savedDownloadsFolder
            context.preferences.promptForDownloadPath = UserDefaults.standard.bool(forKey: Self.asksWhereToSaveDownloadsKey)
        }
        apply()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in apply() }
            .store(in: &cancellables)
    }

    /// Each kept page closes once its own downloads no longer need it.
    private func closeDownloadPagesIfIdle() {
        let idle = downloadPages.filter { !$0.webContents.closingStopsDownloads }
        guard !idle.isEmpty else { return }
        downloadPages.removeAll { page in idle.contains { $0.webContents === page.webContents } }
        for page in idle { page.runtime.browser.closeWebContents(page.webContents) }
    }
}

extension BrowserSession: EngineDownloadsDelegate {
    /// The download's entry. Engines number downloads per profile, so the item, not its ID, names one download among every Persona's.
    private func entry(for item: any EngineDownloadItem) -> DownloadEntry? {
        downloads.first { $0.item === item }
    }

    /// The library button shows a new download's progress, so the library itself stays as it is. The tab that only pointed at the file closes; another such tab waits for its own download, which closing it first would cancel.
    public func downloads(_ downloads: any EngineDownloads, didCreate item: any EngineDownloadItem) {
        guard let personaID = runtime(owning: downloads)?.personaID else { return }
        self.downloads.append(DownloadEntry(item: item, personaID: personaID))
        guard let tab = allTabs.first(where: { downloadOnlyTabIDs.contains($0.id) && $0.webContents === item.webContents }) else { return }
        downloadOnlyTabIDs.remove(tab.id)
        // The engine is still choosing the file's destination, so the tab closes once that callback returns.
        DispatchQueue.main.async { [weak self, weak tab] in
            if let self, let tab { self.closeTab(tab, reason: .download) }
        }
    }

    /// The entry's row and `downloadSummary` show the change; the session itself publishes nothing for it.
    public func downloads(_ downloads: any EngineDownloads, didUpdate item: any EngineDownloadItem) {
        guard let entry = entry(for: item) else { return }
        let wasFinished = entry.isFinished
        entry.refresh()
        downloadSummary.refresh(from: self.downloads)
        if !wasFinished, entry.state == .completed, !windows.contains(where: \.isLibraryVisible) { unseenDownloadIDs.insert(entry.id) }
        if !wasFinished, entry.state == .completed { downloadNotifier.downloadDidFinish(entry) }
        closeDownloadPagesIfIdle()
    }

    public func downloads(_ downloads: any EngineDownloads, didRemove item: any EngineDownloadItem) {
        if let entry = entry(for: item) { unseenDownloadIDs.remove(entry.id) }
        self.downloads.removeAll { $0.item === item }
        closeDownloadPagesIfIdle()
    }

    /// A download from a tab's page that `PageDownloadGate` holds waits for the answer to a card over the tab, and a refused one ends and leaves the downloads list, so that a page that keeps trying adds no rows; a tab that only pointed at the file, or a page without a tab, has nothing to ask about. The others go on as `chooseDestination` says.
    public func downloads(_ downloads: any EngineDownloads, determineFilenameFor item: any EngineDownloadItem, defaultFilename: String, completion: @escaping (URL?) -> Void) {
        let choose = { [weak self] in self?.chooseDestination(in: downloads, defaultFilename: defaultFilename, completion: completion) ?? completion(nil) }
        guard let tab = allTabs.first(where: { $0.webContents === item.webContents }), !tab.isDownloadOnly, !admittedDownloads.contains(item) else { return choose() }
        let decide = { [weak self] (allowed: Bool) in
            guard allowed else {
                completion(nil)
                return item.remove()
            }
            self?.admittedDownloads.add(item)
            choose()
        }
        switch tab.pageDownloads.admit(decide) {
        case .allow: decide(true)
        case .deny: decide(false)
        case .wait: break
        case .ask: askToAllowDownloads(from: tab)
        }
    }

    /// Asks with a card over the tab whether its page may download more files (`TabPromptContent.pageDownloads`). Only Allow allows; Don't Allow and a card that ended without the user, as when the tab closes, answer no.
    private func askToAllowDownloads(from tab: Tab) {
        let content = TabPromptContent.pageDownloads(pageURL: tab.url, identity: PromptSiteIdentity.make(for: tab.url, in: tab))
        enqueuePrompt(content, for: tab) { [weak tab] response in
            guard let tab else { return }
            let allowed = TabPromptContent.pageDownloadsResult(response)
            tab.pageDownloads.answer(allowed).forEach { $0(allowed) }
        }
    }

    /// Saves in the downloads folder with an unused name, or opens a save panel when the profile is set to ask: a sheet on the key window, or a panel of its own over a small window. A small window closes with its tab, which a tab that only downloads does on the next turn of the run loop, and closing would cancel a sheet on it.
    private func chooseDestination(in downloads: any EngineDownloads, defaultFilename: String, completion: @escaping (URL?) -> Void) {
        guard runtime(owning: downloads)?.context.preferences.promptForDownloadPath == true else {
            return completion(Self.uniqueDestination(for: defaultFilename, in: downloadsDirectory))
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFilename
        panel.directoryURL = downloadsDirectory
        let finish = { (response: NSApplication.ModalResponse) in completion(response == .OK ? panel.url : nil) }
        if let window = NSApp.keyWindow, self.window(for: window)?.kind != .small {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
