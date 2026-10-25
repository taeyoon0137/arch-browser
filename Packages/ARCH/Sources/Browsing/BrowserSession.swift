// Owns each engine's application and, for each Persona, one runtime per engine (the Persona's profile and browser), each started when a tab first needs it, so tabs of both engines live side by side. Also owns sidebar state: Personas, spaces, favorites and the tabs they keep alive, tabs, tab folders, split views, and the closed-tab list. Archives inactive tabs on a timer. Opens the browser windows, main windows with the sidebar and small windows for links from other apps, and follows them as they become main and close; each window's own state and commands live in its `BrowserWindowModel`, which views, menus, and scripts reach through `activeWindow` or `sidebarTarget()`.
import AppKit
import ARCHEngine
import Combine
import Foundation
import Plugins

/// One engine's running pieces for one Persona: the engine's application, the Persona's profile in it, and the browser that owns the web contents of the Persona's tabs in that engine.
final class EngineRuntime {
    let kind: EngineKind
    let personaID: Persona.ID
    let application: any EngineApplication
    let context: any EngineBrowserContext
    let browser: any EngineBrowser

    init(kind: EngineKind, personaID: Persona.ID, application: any EngineApplication, context: any EngineBrowserContext, browser: any EngineBrowser) {
        self.kind = kind
        self.personaID = personaID
        self.application = application
        self.context = context
        self.browser = browser
    }
}

public final class BrowserSession: ObservableObject {
    private let registry: EngineRegistry
    private let userDataDirectory: URL
    /// Each running engine's application, started once.
    private var applications: [EngineKind: any EngineApplication] = [:]
    /// Each Persona's runtimes, from the Persona's first tab until quit.
    private var personaEngines: [Persona.ID: PersonaEngines] = [:]
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
    @Published public private(set) var downloads: [DownloadEntry] = []
    /// Downloads that finished while no window showed the library. The library button shows their count.
    @Published public private(set) var unseenDownloadIDs: Set<String> = []
    /// Counts the most recently closed tabs the user closed since they last pressed another key or clicked in the page. ⌘Z reopens them one at a time, newest first.
    public private(set) var undoableCloseCount = 0
    /// The app sets this to open its Settings window from the library.
    public var showSettings: (() -> Void)?
    /// The last 100 closed or archived tabs, oldest first. The newest reopens first.
    @Published private var closedTabs: [SessionSnapshot.TabRecord] = []
    private var archiveTimer: Timer?

    /// The results page of the search engine chosen in Settings.
    public static var searchURL: URL { SearchEngine.current.resultsURL }
    public static let newTabURL = URL(string: "https://www.google.com")!

    private let store: SessionStore
    private var cancellables: Set<AnyCancellable> = []
    private var tabObservers: [UUID: AnyCancellable] = [:]
    /// Each engine's running total of page process crashes.
    private var crashCounts: [EngineKind: Int] = [:]
    /// The engines' total of page process crashes, kept for the tab close log (III.8).
    public var rendererCrashCount: Int { crashCounts.values.reduce(0, +) }
    /// Tabs that only ever pointed at a file. They close once the engine creates the download.
    private var downloadOnlyTabIDs: Set<UUID> = []
    /// Pages of closed or engine-switched tabs whose downloads would stop if the pages closed, as on Chromium, each with the runtime that created it. Each stays open without a tab, on a blank page, until its own downloads are no longer in progress, paused, or interrupted.
    private var downloadPages: [(runtime: EngineRuntime, webContents: any EngineWebContents)] = []
    /// Created with the session at launch, so that clicking a notification from an earlier run still reveals its file.
    private let downloadNotifier = DownloadNotifier()
    /// The sheets that tabs asked for, which wait until a window shows their tab.
    let sheets = TabSheetQueue()
    /// Set while the app quits. Every sheet gets its safe answer at once, so that a page's next dialog cannot hold the quit.
    public var isQuitting = false {
        didSet {
            if isQuitting { sheets.cancelAll() }
        }
    }

    /// Loads the saved session, has the engines remove deleted Personas' stored data, then starts the default engine, or the first registered engine that starts when the default cannot. The other engines start when a tab first needs them.
    public init(registry: EngineRegistry = .shared, userDataDirectory: URL) throws {
        self.registry = registry
        self.userDataDirectory = userDataDirectory
        store = SessionStore(directory: userDataDirectory)
        // Without a saved session, or with a file that did not load, the session starts from an empty snapshot. Normalizing gives every Persona a space, so there is always a current space.
        let snapshot = store.load() ?? SessionSnapshot.empty.normalized()
        // An engine cannot remove the storage of a profile it has loaded, so the removal comes before any engine starts.
        personaDataRemoval = PersonaDataRemoval(ids: snapshot.removedPersonaIDs ?? [], registry: registry,
                                                configuration: Self.engineConfiguration(userDataDirectory: userDataDirectory))
        let candidates = [registry.defaultKind] + registry.registeredKinds.filter { $0 != registry.defaultKind }
        var primary: (any EngineApplication)?
        for kind in candidates where primary == nil {
            primary = Self.makeApplication(kind, registry: registry, userDataDirectory: userDataDirectory)
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
        sheets.windows = { [weak self] in self?.windows ?? [] }
        start(primary)
        // The default Persona's runtime of the primary engine starts with the session, so the other engine's runtime in that Persona, whenever it starts, takes its cookies from the primary engine.
        _ = runtime(for: primaryEngine, in: Persona.defaultID)
        restoreTabs(snapshot)
        restoreFavoriteTabs(snapshot)
        observeChanges()
        personaDataRemoval.didRemove = { [weak self] in self?.scheduleSave() }
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.archiveInactiveTabs() }
        nowPlaying = NowPlaying(session: self)
        // The session is created on the main thread, where the AI interface runs.
        MainActor.assumeIsolated { pageAssistant.attach(to: self) }
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
            if let tab = allTabs.first(where: { $0.id == record.selectedTabID }) { window.selectedTabID = tab.id }
        }
        for window in reopened where window.selectedTabID == nil {
            window.selectedTabID = window.firstFreeTab(inSpace: window.currentSpaceID)?.id
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

    /// Window rule 5: a main window's tabs stay open, and a small window closes with its tab or once a main window takes it. The window lets go of what it shows and leaves the list, and the panes it showed go to the windows whose split views have them, with their sheets. A main window's record stays for the next main window and, while no main window is open, the saved session, which the change of `windows` saves.
    @MainActor func windowWillClose(_ window: BrowserWindowModel) {
        window.prepareToClose()
        if window.kind == .main { windowsToReopen = [window.record] }
        windows.removeAll { $0 === window }
        windows.forEach { $0.updateShownTabs() }
        sheets.showNext()
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

    /// How long after Arch becomes active a link still counts as arriving while Arch was in the background, because the app that sends a link can activate Arch just before the link arrives. `docs/windows-personas.md` (Small window) says how the value was chosen.
    static let smallWindowActivationGrace: TimeInterval = 0.5

    /// Whether a link from another app opens in a small window: Arch was not active when the link arrived, or became active at `becameActiveAt`, less than `smallWindowActivationGrace` before `now`. A nil `becameActiveAt` means Arch has been active since it launched.
    public static func opensLinkInSmallWindow(isAppActive: Bool, becameActiveAt: Date?, now: Date) -> Bool {
        guard isAppActive else { return true }
        guard let becameActiveAt else { return false }
        return now.timeIntervalSince(becameActiveAt) < smallWindowActivationGrace
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

    /// Opens a small window, made key and ordered front, on a new tab for `webContents`, which a runtime of the Persona created. The tab stays in `tabs`, so that sheets, permissions, downloads, Now Playing, and `session.json` handle it as any other, while its space's list leaves it out.
    @discardableResult
    func openSmallWindow(_ webContents: any EngineWebContents, spaceID: UUID, personaID: Persona.ID) -> BrowserWindowModel {
        let tab = makeTab(webContents, id: UUID(), spaceID: spaceID, personaID: personaID, pinned: false)
        tab.isInSmallWindow = true
        tabs.append(tab)
        let window = makeWindow(from: SessionSnapshot.WindowRecord(id: UUID(), frame: nil, currentSpaceID: spaceID, selectedTabID: nil, isSidebarVisible: false), kind: .small)
        window.selectedTabID = tab.id
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
        target.selectedTabID = tab.id
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

    /// Runs an application with the session as its delegate and keeps it for the engine's runtimes.
    private func start(_ application: any EngineApplication) {
        application.delegate = self
        application.run()
        applications[application.engineKind] = application
    }

    /// The engine's application, started on first use. Returns nil when the engine cannot start.
    private func application(for kind: EngineKind) -> (any EngineApplication)? {
        if let application = applications[kind] { return application }
        guard let application = Self.makeApplication(kind, registry: registry, userDataDirectory: userDataDirectory) else { return nil }
        start(application)
        return application
    }

    /// The Persona's runtimes, created empty on first use.
    private func engines(of personaID: Persona.ID) -> PersonaEngines {
        if let engines = personaEngines[personaID] { return engines }
        let engines = PersonaEngines(personaID: personaID)
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

    /// Creates the Persona's profile and browser in the engine and connects them to the session: their downloads, the download settings, the remembered permissions, and the Persona's cookie copies. Returns nil when the engine cannot start or the Persona is not listed.
    private func startRuntime(_ kind: EngineKind, in engines: PersonaEngines) -> EngineRuntime? {
        guard let application = application(for: kind), let persona = personas.first(where: { $0.id == engines.personaID }) else { return nil }
        // Both engines create a profile before `createBrowserContext` returns.
        var created: (any EngineBrowserContext)?
        application.createBrowserContext(persona.contextAttributes) { created = try? $0.get() }
        guard let context = created else { return nil }
        let browser = application.createBrowser(EngineBrowserCreateParams(initialBounds: .zero), context: context, delegate: self, window: nil)
        let runtime = EngineRuntime(kind: kind, personaID: persona.id, application: application, context: context, browser: browser)
        engines.runtimes[kind] = runtime
        context.downloads.delegate = self
        followDownloadSettings(of: context)
        followSitePermissions(of: context)
        downloads += context.downloads.items.map { DownloadEntry(item: $0, personaID: persona.id) }
        browser.cookiesDidChange = { [weak engines] in engines?.cookieSync.scheduleCopy(from: kind) }
        // An engine that starts after another in the Persona has none of the Persona's cookies yet.
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

    /// A space's pinned or open tabs in sidebar order: the tabs of each folder, folder by folder, then the tabs outside folders.
    public func tabs(in spaceID: UUID, pinned: Bool) -> [Tab] {
        folders(in: spaceID, pinned: pinned).flatMap(tabs(in:)) + tabsOutsideFolders(in: spaceID, pinned: pinned)
    }

    /// Adds a space to the Persona and returns it. The space goes last in that Persona's group, because each Persona's spaces stay together in the order `normalized()` restores at launch.
    func makeSpace(in personaID: Persona.ID) -> Space {
        let tint = SpaceTint.colors[spaces.count % SpaceTint.colors.count]
        // The lowest number no space uses, so names do not repeat after a deletion.
        let number = (1...).first { number in !spaces.contains { $0.name == "Space \(number)" } }!
        let space = Space(name: "Space \(number)", tint: tint, personaID: personaID)
        let groupEnd = spaces.lastIndex { $0.resolvedPersonaID == personaID }.map { $0 + 1 } ?? spaces.endIndex
        spaces.insert(space, at: groupEnd)
        return space
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

    /// Removes a space. Its tabs and folders move to the space before it, or to the next one for the first space, so no tab closes, and every window on the space switches there.
    public func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let destination = spaces[index == 0 ? 1 : index - 1].id
        // The space's split view goes with it; its tabs join the destination as separate tabs.
        splitTabIDs[id] = nil
        // The moved tabs and folders go after the destination's own instead of among them. The tabs keep their folders.
        let moved = tabs.filter { $0.spaceID == id }
        let movedIDs = Set(moved.map(\.id))
        moved.forEach { $0.spaceID = destination }
        tabs.removeAll { movedIDs.contains($0.id) }
        tabs.append(contentsOf: moved)
        var movedFolders = folders.filter { $0.spaceID == id }
        for folderIndex in movedFolders.indices { movedFolders[folderIndex].spaceID = destination }
        folders = folders.filter { $0.spaceID != id } + movedFolders
        for window in windows where window.currentSpaceID == id { window.switchToSpace(destination) }
        spaces.remove(at: index)
    }

    func updateSpace(_ id: UUID, _ change: (inout Space) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        change(&spaces[index])
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

    /// Appends, in order, the favorites whose addresses are not favorites of the Persona of the sidebar target's current space yet, as favorites of that Persona, and returns how many it added. Import uses it for bookmarks.
    @discardableResult
    public func addFavorites(_ candidates: [Favorite]) -> Int {
        let personaID = sidebarTarget().currentSpace.resolvedPersonaID
        var addresses = Set(favorites.filter { $0.resolvedPersonaID == personaID }.map(\.url))
        let added = candidates.filter { addresses.insert($0.url).inserted }.map { candidate in
            var favorite = candidate
            favorite.personaID = personaID
            return favorite
        }
        favorites += added
        return added.count
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
        closeWhenPageAgrees(tab) { [weak self] in
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

    /// A web contents of the Persona in `engine`, or in the default engine, that opens `url` or the new tab page and restores `state` when given.
    func makeWebContents(url: URL?, engine: EngineKind?, state: Data?, in personaID: Persona.ID) -> any EngineWebContents {
        runtime(for: engine ?? defaultEngine, in: personaID).browser.createWebContents(EngineWebContentsConfiguration(initialURL: url ?? Self.newTabURL, restorableState: state))
    }

    /// The Persona of the space `id`, or of the sidebar target's current space when no space has that ID.
    private func personaID(ofSpace id: UUID) -> Persona.ID {
        (spaces.first { $0.id == id } ?? sidebarTarget().currentSpace).resolvedPersonaID
    }

    /// Adds a tab for `webContents`, which a runtime of the Persona `personaID` created, to the list of the space `spaceID` or, when that space belongs to another Persona, of the Persona's first space if it has one. A tab that restores or reopens passes its saved `id`. `select` selects it in the sidebar target.
    func adopt(_ webContents: any EngineWebContents, id: UUID = UUID(), spaceID: UUID, personaID: Persona.ID, pinned: Bool, select: Bool) -> Tab {
        let spaceID = self.personaID(ofSpace: spaceID) == personaID ? spaceID : spaces.first { $0.resolvedPersonaID == personaID }?.id ?? spaceID
        let tab = makeTab(webContents, id: id, spaceID: spaceID, personaID: personaID, pinned: pinned)
        tabs.append(tab)
        if select { sidebarTarget().selectedTabID = tab.id }
        return tab
    }

    /// Wraps `webContents` in a tab whose popups, dialogs, permission requests, and closing go through the session. The caller adds it to a space's list or gives it to a favorite.
    private func makeTab(_ webContents: any EngineWebContents, id: UUID, spaceID: UUID?, personaID: UUID, pinned: Bool) -> Tab {
        let tab = Tab(id: id, webContents: webContents, spaceID: spaceID, isPinned: pinned, personaID: personaID)
        // A tab a page opens comes from the page's runtime, so it belongs to the page's Persona, and it keeps the page as its opener. The window that shows the page shows the new tab, in the page's space, which is that window's current space, or in another small window beside a small window. A page that no window shows opens it behind, marked unread, in the page's space or, for a favorite's page, the sidebar target's current space.
        tab.openNewTab = { [weak self, weak tab] popup in
            guard let self, let tab else { return }
            self.runtime(for: popup.engineKind, in: personaID).browser.takeOwnership(of: popup)
            if let window = self.window(showing: tab) { return window.showOpenedPage(popup, personaID: personaID, opener: tab.webContents) }
            let opened = self.adopt(popup, spaceID: tab.spaceID ?? self.sidebarTarget().currentSpaceID, personaID: personaID, pinned: false, select: false)
            opened.opener = tab.webContents
            opened.isUnread = true
        }
        // The user cannot undo a tab closed by its page. A page also reports closing after the user closes its tab, when the tab is no longer in the list.
        tab.didClose = { [weak self, weak tab] in
            guard let self, let tab, self.allTabs.contains(where: { $0.id == tab.id }) else { return }
            self.closeTab(tab, reason: tab.hasCrashed ? .crash : .page)
            self.undoableCloseCount = 0
        }
        // Only the page's own dialogs go: a permission, sign-in, or leave-page question still applies.
        tab.didCancelDialogs = { [weak self, weak tab] in
            if let self, let tab { self.sheets.cancel(for: tab, pageDialogsOnly: true) }
        }
        // A leave-page sheet shows over its page. The window that shows the tab makes it the focused pane, or leaves the internal page over it when it is selected already, and the sidebar target selects a tab that no window shows.
        tab.requestSelection = { [weak self, weak tab] in
            guard let self, let tab else { return }
            guard let window = self.window(showing: tab) else { return self.sidebarTarget().selectedTabID = tab.id }
            if window.selectedTabID != tab.id {
                window.selectedTabID = tab.id
            } else if window.internalPage != nil {
                window.closeInternalPage()
            }
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
        // Closing a tab whose download has not started yet would cancel it, so such a tab waits for its download to appear. The engine is still inside its callback, so closing happens on the next turn of the run loop.
        tab.didOpenOnlyDownload = { [weak self, weak tab] downloads in
            guard let self, let tab else { return }
            if downloads {
                self.downloadOnlyTabIDs.insert(tab.id)
            } else {
                DispatchQueue.main.async { [weak self, weak tab] in
                    if let self, let tab { self.closeTab(tab, remember: false, reason: .download) }
                }
            }
        }
        tab.requestPermission = { [weak self, weak tab] request, completion in
            guard let self, let tab else { return completion(false) }
            self.decidePermission(request, for: tab, completion: completion)
        }
        // The page fills the window that shows it. A page that no window shows leaves fullscreen; the engine is still in its callback, so that happens on the next turn of the run loop.
        tab.didChangeFullscreen = { [weak self, weak tab] isFullscreen in
            guard let self, let tab else { return }
            if let window = self.window(showing: tab) {
                window.setPageFullscreen(isFullscreen, of: tab)
            } else if isFullscreen {
                DispatchQueue.main.async { [weak tab] in tab?.webContents.exitFullscreen() }
            }
        }
        // A link opened from a page's context menu opens behind the current tab, in the page's space (the current space for a favorite's page) and engine, marked unread.
        tab.openURLInNewTab = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.openTab(url: url, in: tab.spaceID, select: false, engine: tab.engineKind).isUnread = true
        }
        // A web link the user clicks with Shift opens in the preview panel of the page's window, in the page's engine and Persona.
        tab.previewLink = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.window(showing: tab)?.showPreview(of: url, engine: tab.engineKind, in: tab.personaID)
        }
        tab.presentAlert = { [weak self, weak tab] alert, isPageDialog, completion in
            guard let self, let tab else { return completion(.cancel) }
            self.enqueueSheet(alert, for: tab, isPageDialog: isPageDialog, completion: completion)
        }
        // Every change to a tab, such as a new address or name, is saved.
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self] _ in self?.scheduleSave() }
        return tab
    }

    /// Moves a tab to another engine: a web contents from the Persona's runtime for `kind` loads the tab's address and takes the old one's place, and the tab keeps its place, pin, space, and selection. Nothing changes when `kind` cannot start.
    public func switchEngine(of tab: Tab, to kind: EngineKind) {
        guard tab.engineKind != kind, allTabs.contains(where: { $0.id == tab.id }), let source = runtime(of: tab) else { return }
        let target = runtime(for: kind, in: tab.personaID)
        guard target.kind == kind else { return }
        // The page loads in the other engine once it has this engine's cookies, so the site stays signed in.
        engines(of: tab.personaID).cookieSync.copy(from: source, to: target) { [weak self, weak tab] in
            guard let self, let tab, tab.engineKind != kind, self.allTabs.contains(where: { $0.id == tab.id }) else { return }
            let old = tab.webContents
            let replacement = target.browser.createWebContents(EngineWebContentsConfiguration(initialURL: tab.url ?? Self.newTabURL))
            // Sheets and searches belong to the old page, and the window that selects the tab docks the new page's tools.
            self.sheets.cancel(for: tab)
            let window = self.windows.first { $0.selectedTabID == tab.id }
            if window?.isFindBarVisible == true { window?.hideFindBar() }
            tab.replaceWebContents(with: replacement)
            window?.devToolsDock.track(replacement.devTools)
            self.retire(old, of: tab.personaID)
            self.scheduleSave()
        }
    }

    /// Closes a tab the user asked to close once its page agrees: a page with a `beforeunload` handler can ask to stay. ⌘Z reopens a space's tab; a favorite's tab opens again from its favorite.
    public func requestCloseTab(_ tab: Tab) {
        let isUndoable = tab.spaceID != nil
        closeWhenPageAgrees(tab) { [weak self] in
            // ⌘Z cannot reopen a favorite's tab, so it reopens none of the tabs closed before it either, rather than an older tab in its place.
            if isUndoable { self?.undoableCloseCount += 1 } else { self?.forgetUndoableCloses() }
        }
    }

    /// Closes a tab once its page agrees to close, then runs `didClose`.
    private func closeWhenPageAgrees(_ tab: Tab, then didClose: @escaping () -> Void) {
        // Asking means closing the browser, which would stop its downloads, so such a tab closes at once; its kept page answers the handlers with Leave when it moves to a blank page.
        guard !tab.webContents.closingStopsDownloads else {
            closeTab(tab)
            return didClose()
        }
        tab.webContents.tryToClose { [weak self, weak tab] closing in
            guard closing, let self, let tab else { return }
            self.closeTab(tab)
            didClose()
        }
    }

    /// Closes a tab. `remember` adds it to the closed list so that it can reopen; a tab that only pointed at a file is not worth reopening, and a favorite's tab reopens from its favorite. `reason` goes to the tab close log.
    public func closeTab(_ tab: Tab, remember: Bool = true, reason: TabCloseReason = .user) {
        let index = tabs.firstIndex(where: { $0.id == tab.id })
        let favoriteID = favoriteTabs.first { $0.value === tab }?.key
        guard index != nil || favoriteID != nil else { return }
        recordClose(of: tab, reason: reason)
        windows.forEach { $0.setPageFullscreen(false, of: tab) }
        sheets.cancel(for: tab)
        if let index { tabs.remove(at: index) }
        if let favoriteID { favoriteTabs[favoriteID] = nil }
        tabObservers[tab.id] = nil
        retire(tab.webContents, of: tab.personaID)
        if remember, let spaceID = tab.spaceID {
            closedTabs.append(SessionSnapshot.TabRecord(id: tab.id, spaceID: spaceID, url: tab.url, title: tab.title, customTitle: tab.customTitle, isPinned: tab.isPinned, folderID: tab.folderID, engine: tab.engineKind, personaID: tab.personaID))
            if closedTabs.count > 100 { closedTabs.removeFirst() }
        }
        // Each main window that selected the tab selects one that no other window shows (window rule 3): for a page that closed itself, the listed tab of the page that opened it, as a sign-in popup closes once it has reported back; then the pane beside it, so the rest of its split view stays on screen, or else a listed open tab of the tab's space before a pinned one. A favorite's tab leaves the selection to a tab of the window's current space. A small window closes with its tab.
        let opener = reason == .page ? allTabs.first { $0.webContents === tab.opener && $0.isListedInSidebar } : nil
        let splitNeighbor = leaveSplitView(tab).flatMap { id in tabs.first { $0.id == id } }
        for window in windows where window.selectedTabID == tab.id {
            guard window.kind == .main else {
                window.close()
                continue
            }
            let siblings = tabs.filter { $0.spaceID == (tab.spaceID ?? window.currentSpaceID) && $0.isListedInSidebar }
            let candidates = [opener, splitNeighbor].compactMap { $0 } + siblings.filter { !$0.isPinned } + siblings
            window.selectedTabID = candidates.first { !window.isShownInAnotherWindow($0) }?.id
        }
    }

    public var hasClosedTabs: Bool { !closedTabs.isEmpty }

    /// Reopens the newest closed tab under its own ID in its original space and folder, or the sidebar target's current space if the original is gone, and selects it in the sidebar target.
    public func reopenLastClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        undoableCloseCount = max(0, undoableCloseCount - 1)
        let spaceID = spaces.contains(where: { $0.id == record.spaceID }) ? record.spaceID : sidebarTarget().currentSpaceID
        let personaID = personaID(ofSpace: spaceID)
        let tab = adopt(makeWebContents(url: record.url, engine: record.engine, state: nil, in: personaID), id: record.id ?? UUID(), spaceID: spaceID, personaID: personaID, pinned: record.isPinned, select: true)
        tab.customTitle = record.customTitle
        tab.folderID = existingFolderID(record.folderID, spaceID: spaceID, pinned: record.isPinned)
    }

    /// Pressing another key or clicking in the page makes ⌘Z undo there instead of reopening tabs.
    public func forgetUndoableCloses() {
        undoableCloseCount = 0
    }

    /// Swaps a space's tab with its neighbor in its folder, or among its space's pinned or open tabs outside folders.
    func moveTab(_ tab: Tab, up: Bool) {
        guard let spaceID = tab.spaceID, let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let siblings = tab.folderID == nil ? tabsOutsideFolders(in: spaceID, pinned: tab.isPinned) : tabs.filter { $0.folderID == tab.folderID }
        guard let position = siblings.firstIndex(where: { $0.id == tab.id }) else { return }
        let target = up ? position - 1 : position + 1
        guard siblings.indices.contains(target), let neighborIndex = tabs.firstIndex(where: { $0.id == siblings[target].id }) else { return }
        tabs.swapAt(index, neighborIndex)
    }

    /// Moves a dragged tab to `target`'s place and adopts its space, pinned state, and folder, allowing moves between pinned and open lists and into and out of folders. Within a list, dragging from above places the tab below the target.
    public func moveTab(_ id: UUID, to target: Tab) {
        guard id != target.id, let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target.id }) else { return }
        let tab = tabs[from]
        let isSameList = tab.spaceID == target.spaceID && tab.isPinned == target.isPinned && tab.folderID == target.folderID
        var reordered = tabs
        reordered.remove(at: from)
        guard let targetIndex = reordered.firstIndex(where: { $0.id == target.id }) else { return }
        tab.spaceID = target.spaceID
        tab.isPinned = target.isPinned
        tab.folderID = target.folderID
        reordered.insert(tab, at: isSameList && from < to ? targetIndex + 1 : targetIndex)
        tabs = reordered
    }

    /// Closes unpinned listed tabs inactive for `ARCHArchiveAfterHours` hours (default 12; 0 disables), so a small window's tab stays. The tabs windows show, each window's selected tab and the other panes of its split view, count as active now.
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
        let hours = defaults.object(forKey: "ARCHArchiveAfterHours") == nil ? 12 : defaults.integer(forKey: "ARCHArchiveAfterHours")
        guard hours > 0 else { return nil }
        return now.addingTimeInterval(-TimeInterval(hours) * 3600)
    }

    /// The tab stores the pinned flag; the session republishes changes for views that group tabs by it. A tab in a folder leaves it, because the folder stays in the other list.
    public func togglePinned(_ tab: Tab) {
        objectWillChange.send()
        tab.folderID = nil
        tab.isPinned.toggle()
    }

    /// Accepts only a full URL with a scheme and host, or a dotted host without spaces. Adds `https://` to a dotted host.
    public static func url(forInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = URL(string: text), parsed.scheme != nil, parsed.host != nil { return parsed }
        if !text.contains(" "), let parsed = URL(string: "https://\(text)"), parsed.host?.contains(".") == true { return parsed }
        return nil
    }

    /// Returns a site's results page for text that starts with a site search keyword and a space, the input URL, a web search URL for other text, or `nil` for empty text.
    static func destination(forInput input: String) -> URL? {
        if let search = SiteSearchStore.shared.match(input) { return search.shortcut.resultsURL(for: search.query) }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = url(forInput: text) { return url }
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url!
    }

    // MARK: Plugins

    /// The plugins of the default Persona, to which every plugin belongs until each Persona has plugins of its own. `nil` until the app loads its built-in plugins at launch.
    public private(set) var plugins: PluginManager?

    /// Creates the plugin manager with the built-in plugins the app ships. The app calls it once at launch.
    @MainActor public func loadPlugins(builtIns: [any BuiltInPlugin.Type]) {
        plugins = PluginManager(persona: Persona.defaultID, directory: userDataDirectory, builtIns: builtIns)
    }

    // MARK: Downloads

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

    // MARK: Site permissions

    /// The answers waiting for each permission sheet, keyed by tab, origin, and types, so that a page that asks again before the user answers gets the same sheet's answer.
    private var permissionWaiters: [String: [(Bool) -> Void]] = [:]

    /// Answers a site's request from the remembered answers, or asks with a sheet and remembers the user's answer. One remembered Don't Allow denies the whole request, and only a remembered Allow for every type in it grants it without asking. A request that is never remembered, such as one to record the screen or one from a page without a web address, always asks.
    private func decidePermission(_ request: EnginePermissionRequest, for tab: Tab, completion: @escaping (Bool) -> Void) {
        let store = SitePermissionStore.shared
        let context = runtime(of: tab)?.context
        // Chromium keeps every answer it receives, even the safe answer for a sheet that closed with its tab, so once it has the answer its kept answers return to the remembered ones.
        let answer = { [weak self] (granted: Bool) in
            completion(granted)
            guard let context else { return }
            DispatchQueue.main.async { self?.applyRememberedPermissions(for: request, to: context) }
        }
        let isRemembered = !request.types.isEmpty && request.types.allSatisfy(SitePermissionStore.remembers)
        let origin = isRemembered ? SitePermissionStore.origin(of: request.origin) : nil
        if let origin {
            let decisions = request.types.map { store.decision(for: $0, origin: origin) }
            if decisions.contains(.deny) { return answer(false) }
            if decisions.allSatisfy({ $0 == .allow }) { return answer(true) }
        }
        let key = "\(tab.id) \(request.origin.absoluteString) \(request.types.map(\.rawValue).sorted())"
        guard permissionWaiters[key] == nil else {
            permissionWaiters[key]?.append(answer)
            return
        }
        permissionWaiters[key] = [answer]
        enqueueSheet(Self.permissionAlert(for: request, remembersAnswer: origin != nil), for: tab) { [weak self] response in
            let waiters = self?.permissionWaiters.removeValue(forKey: key) ?? [answer]
            let granted = response == .alertFirstButtonReturn
            waiters.forEach { $0(granted) }
            // A sheet that closed without an answer, as when its tab closed, leaves nothing to remember.
            if let origin, response == .alertFirstButtonReturn || response == .alertSecondButtonReturn {
                store.set(granted ? .allow : .deny, for: request.types, origin: origin)
            }
        }
    }

    /// Gives a profile's own kept answers for the request's types the remembered answers, or none.
    func applyRememberedPermissions(for request: EnginePermissionRequest, to context: any EngineBrowserContext) {
        let origin = SitePermissionStore.origin(of: request.origin)
        for type in request.types {
            let decision = origin.flatMap { SitePermissionStore.shared.decision(for: type, origin: $0) }
            context.setRememberedPermission(decision.map { $0 == .allow }, for: type, origin: request.origin)
        }
    }

    /// Copies the remembered answers into a profile's own kept answers, now and after every change, such as one made in Settings.
    private func followSitePermissions(of context: any EngineBrowserContext) {
        let store = SitePermissionStore.shared
        let apply = { (origin: String, types: [EnginePermissionType]) in
            guard let url = URL(string: origin) else { return }
            for type in types {
                context.setRememberedPermission(store.decision(for: type, origin: origin).map { $0 == .allow }, for: type, origin: url)
            }
        }
        for (origin, answers) in store.decisions { apply(origin, Array(answers.keys)) }
        store.didChange
            .sink { apply($0.origin, $0.types) }
            .store(in: &cancellables)
    }

    /// Asks with a sheet on the window that shows the page, once a window shows it. The engine calls this from inside its own message loop, so the sheet never blocks. The answer reaches the engine once.
    private static func permissionAlert(for request: EnginePermissionRequest, remembersAnswer: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Allow \u{201C}\(request.origin.host ?? request.origin.absoluteString)\u{201D} to \(permissionDescription(for: request.types))?"
        if remembersAnswer {
            alert.informativeText = "Arch remembers your answer for this website. You can change it in Settings > Websites."
        }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don\u{2019}t Allow")
        return alert
    }

    // MARK: Sheets

    /// Queues a sheet for a tab, which shows on the window that shows the tab on screen (`TabSheetQueue`). While the app quits, the sheet gets the safe answer, `.cancel`, at once.
    func enqueueSheet(_ alert: NSAlert, for tab: Tab, isPageDialog: Bool = false, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !isQuitting else { return completion(.cancel) }
        sheets.enqueue(alert, for: tab, isPageDialog: isPageDialog, completion: completion)
    }

    private static func permissionDescription(for types: [EnginePermissionType]) -> String {
        let phrases = types.map { type -> String in
            switch type {
            case .camera: return "use the camera"
            case .microphone: return "use the microphone"
            case .screenCapture: return "record the screen"
            case .geolocation: return "see your location"
            case .notifications: return "send notifications"
            case .clipboard: return "read the clipboard"
            case .midi: return "use MIDI devices"
            }
        }
        return ListFormatter.localizedString(byJoining: phrases)
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

    /// Moves a tab dropped on another space's symbol after that space's own pinned or open tabs, outside its folders. The window that selects the tab follows it to its new space, so the sidebar keeps showing the page's tab.
    public func moveTab(_ id: UUID, toSpace spaceID: UUID) {
        guard spaces.contains(where: { $0.id == spaceID }), let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].spaceID != spaceID else { return }
        // The other panes of its split view stay together in the space it leaves.
        leaveSplitView(tabs[index])
        var reordered = tabs
        let tab = reordered.remove(at: index)
        tab.spaceID = spaceID
        tab.folderID = nil
        reordered.append(tab)
        tabs = reordered
        for window in windows where window.selectedTabID == tab.id { window.currentSpaceID = spaceID }
    }

    /// Moves a dragged tab after its space's pinned or open tabs outside folders, so that a drag can take a tab out of a folder even when no other tab sits outside folders in that list.
    public func moveTabToListEnd(_ id: UUID, pinned: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var reordered = tabs
        let tab = reordered.remove(at: index)
        tab.isPinned = pinned
        tab.folderID = nil
        reordered.append(tab)
        tabs = reordered
    }

    // MARK: Folders

    /// Every space's folders. The sidebar shows a space's pinned and open folders in this order, each list starting with its folders.
    @Published public private(set) var folders: [TabFolder] = []

    /// A space's folders among its pinned or open tabs, in sidebar order.
    public func folders(in spaceID: UUID, pinned: Bool) -> [TabFolder] {
        folders.filter { $0.spaceID == spaceID && $0.isPinned == pinned }
    }

    /// A space's folders in sidebar order: those among its pinned tabs, then those among its open tabs.
    public func folders(in spaceID: UUID) -> [TabFolder] {
        folders(in: spaceID, pinned: true) + folders(in: spaceID, pinned: false)
    }

    /// A folder's tabs in sidebar order.
    public func tabs(in folder: TabFolder) -> [Tab] {
        tabs.filter { $0.folderID == folder.id }
    }

    /// Whether `tab` sits in a collapsed folder, which shows it in the sidebar only while it is selected.
    func isInCollapsedFolder(_ tab: Tab) -> Bool {
        folders.contains { $0.id == tab.folderID && $0.isCollapsed }
    }

    /// A space's pinned or open tabs that are in no folder, in sidebar order. A small window's tab, which is in no folder, is left out until it moves to a main window.
    public func tabsOutsideFolders(in spaceID: UUID, pinned: Bool) -> [Tab] {
        tabs.filter { $0.spaceID == spaceID && $0.isPinned == pinned && $0.folderID == nil && $0.isListedInSidebar }
    }

    /// Moves a tab into a folder of its space, after the folder's own tabs. The tab joins the folder's pinned or open list.
    public func moveTab(_ id: UUID, toFolder folderID: UUID) {
        guard let folder = folders.first(where: { $0.id == folderID }), let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].spaceID == folder.spaceID, tabs[index].folderID != folderID else { return }
        var reordered = tabs
        let tab = reordered.remove(at: index)
        tab.isPinned = folder.isPinned
        tab.folderID = folderID
        reordered.append(tab)
        tabs = reordered
    }

    /// Takes a tab out of its folder.
    public func removeFromFolder(_ tab: Tab) {
        guard tab.folderID != nil else { return }
        takeOutOfFolder([tab])
    }

    public func toggleCollapsed(ofFolder id: UUID) {
        updateFolder(id) { $0.isCollapsed.toggle() }
    }

    /// Removes a folder and keeps its tabs.
    public func deleteFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        takeOutOfFolder(tabs(in: folder))
        folders.removeAll { $0.id == id }
        windows.forEach { $0.endRenamingFolder(id) }
    }

    /// Appends a folder to a space's pinned or open folders.
    func makeFolder(in spaceID: UUID, pinned: Bool) -> TabFolder {
        let folder = TabFolder(spaceID: spaceID, name: "New Folder", isPinned: pinned)
        folders.append(folder)
        return folder
    }

    /// Takes tabs of one folder out of it and puts them, in order, first among their list's tabs outside folders, just below the folders.
    private func takeOutOfFolder(_ moved: [Tab]) {
        guard let first = moved.first else { return }
        let movedIDs = Set(moved.map(\.id))
        var reordered = tabs.filter { !movedIDs.contains($0.id) }
        moved.forEach { $0.folderID = nil }
        let destination = reordered.firstIndex { $0.spaceID == first.spaceID && $0.isPinned == first.isPinned && $0.folderID == nil } ?? reordered.endIndex
        reordered.insert(contentsOf: moved, at: destination)
        tabs = reordered
    }

    func updateFolder(_ id: UUID, _ change: (inout TabFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        change(&folders[index])
    }

    /// `id` while it names a folder in that space's pinned or open list, so that a saved or closed tab returns to its folder unless the folder has gone or moved.
    private func existingFolderID(_ id: UUID?, spaceID: UUID, pinned: Bool) -> UUID? {
        folders.first { $0.id == id && $0.spaceID == spaceID && $0.isPinned == pinned }?.id
    }

    // MARK: Split view

    /// The most tabs a split view shows side by side.
    static let maximumPanes = 4
    /// Each space's split view: two to four of its tabs that share the page area, left to right. The page area shows a space's split view while one of its tabs is selected, and the selected tab is the focused pane.
    @Published private(set) var splitTabIDs: [UUID: [UUID]] = [:] {
        didSet {
            // The panes on screen change with the split views, and the sheets that can show change with them. A pane that joins a window's split view while another window shows its tab stays with that window.
            windows.forEach { $0.updateShownTabs() }
            windows.forEach(sheets.deferSheet(of:))
            sheets.showNext()
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

    /// Reopens the saved tabs and their split views.
    private func restoreTabs(_ snapshot: SessionSnapshot) {
        // Archive stale unpinned records before they have web contents.
        let cutoff = Self.archiveCutoff(now: Date())
        // The reopened tabs by their records' indexes, which the split views refer to.
        var restored: [Int: Tab] = [:]
        for (index, record) in snapshot.tabs.enumerated() where spaces.contains(where: { $0.id == record.spaceID }) {
            if !record.isPinned, let cutoff, let last = record.lastActivatedAt, last < cutoff {
                closedTabs.append(record)
                closeLog.record(TabCloseLogEntry(archived: record))
                continue
            }
            let personaID = personaID(ofSpace: record.spaceID)
            let tab = adopt(makeWebContents(url: record.url, engine: record.engine, state: record.state, in: personaID), id: record.id ?? UUID(), spaceID: record.spaceID, personaID: personaID, pinned: record.isPinned, select: false)
            tab.lastActivatedAt = record.lastActivatedAt ?? Date()
            tab.customTitle = record.customTitle
            tab.folderID = existingFolderID(record.folderID, spaceID: record.spaceID, pinned: record.isPinned)
            tab.isRestored = true
            // Loading a restored page does not count as a visit.
            tab.recordedURL = record.url
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
        store.scheduleSave { [weak self] in self?.snapshot() ?? SessionSnapshot(version: SessionSnapshot.currentVersion, spaces: [], currentSpaceID: UUID(), favorites: [], tabs: [], selectedTabIndex: nil) }
    }

    public func saveNow() {
        store.saveNow(snapshot())
    }

    /// The session as `session.json` keeps it. The windows are the open main windows, front to back, or the last main window while none is open, so that the next launch opens them. The front one's space and selection also go where older builds read them. Small windows are not kept: their tabs are saved as open tabs of their spaces (open decision 4).
    private func snapshot() -> SessionSnapshot {
        let mainWindows = windows.filter { $0.kind == .main }
        let windowRecords = mainWindows.isEmpty ? windowsToReopen : mainWindows.map(\.record)
        let front = windowRecords[0]
        return SessionSnapshot(version: SessionSnapshot.currentVersion, personas: personas, removedPersonaIDs: personaDataRemoval.pendingIDs, spaces: spaces, currentSpaceID: front.currentSpaceID, favorites: favorites,
                               tabs: tabs.map { SessionSnapshot.TabRecord(id: $0.id, spaceID: $0.spaceID ?? front.currentSpaceID, url: $0.url, title: $0.title, customTitle: $0.customTitle, isPinned: $0.isPinned, folderID: $0.folderID, lastActivatedAt: $0.lastActivatedAt, engine: $0.engineKind, state: $0.webContents.restorableState, personaID: $0.personaID) },
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

public enum CommandPaletteMode {
    case editCurrent
    case newTab
}

public enum CommandPaletteOrigin {
    /// A shortcut or menu command: the palette rises from below.
    case keyboard
    /// A control in the sidebar: the palette comes in from the sidebar's side.
    case sidebar
    /// The address pill: the palette comes out of the pill, and the pill's contents move toward it.
    case addressPill
}

extension BrowserSession: EngineApplicationDelegate {
    public func applicationDidInitialize(_ application: any EngineApplication) {}
    public func applicationDidQuitRunLoop(_ application: any EngineApplication) {}
    public func application(_ application: any EngineApplication, didCreateBrowser browser: any EngineBrowser) {}
    public func application(_ application: any EngineApplication, didCloseBrowser browser: any EngineBrowser) {}
    public func application(_ application: any EngineApplication, didChangeBrowserContextAttributes attributes: [EngineBrowserContextAttributes]) {}
    public func application(_ application: any EngineApplication, didReceiveRendererProcessCrash count: Int) { crashCounts[application.engineKind] = count }
}

/// The protocol's defaults apply: popups reach the session through their opener's `Tab.openNewTab`, and no engine reports new web contents to the browser's delegate.
extension BrowserSession: EngineBrowserDelegate {}

extension BrowserSession: EngineDownloadsDelegate {
    public func downloads(_ downloads: any EngineDownloads, didInitializeWith items: [any EngineDownloadItem]) {
        guard let personaID = runtime(owning: downloads)?.personaID else { return }
        self.downloads += items.filter { item in !self.downloads.contains { $0.id == item.id } }.map { DownloadEntry(item: $0, personaID: personaID) }
    }

    /// The library button shows a new download's progress, so the library itself stays as it is.
    public func downloads(_ downloads: any EngineDownloads, didCreate item: any EngineDownloadItem) {
        guard let personaID = runtime(owning: downloads)?.personaID else { return }
        self.downloads.append(DownloadEntry(item: item, personaID: personaID))
        let finishedTabIDs = downloadOnlyTabIDs
        downloadOnlyTabIDs.removeAll()
        // The engine is still choosing the file's destination, so the tabs close once that callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for tab in self.allTabs where finishedTabIDs.contains(tab.id) { self.closeTab(tab, remember: false, reason: .download) }
        }
    }

    /// Closes a page of the Persona that no tab shows any more, through the runtime that created it. A page whose downloads would stop with it stays open on a blank page until they finish.
    func retire(_ webContents: any EngineWebContents, of personaID: Persona.ID) {
        guard let runtime = personaEngines[personaID]?.runtimes[webContents.engineKind] else { return }
        if webContents.closingStopsDownloads {
            // Without a delegate the page's own questions, such as its leave-page check on the way to the blank page, get their default answers.
            webContents.uiDelegate = nil
            webContents.navigationController.load(URLRequest(url: URL(string: "about:blank")!))
            downloadPages.append((runtime, webContents))
        } else {
            runtime.browser.closeWebContents(webContents)
        }
    }

    /// Each kept page closes once its own downloads no longer need it.
    private func closeDownloadPagesIfIdle() {
        let idle = downloadPages.filter { !$0.webContents.closingStopsDownloads }
        guard !idle.isEmpty else { return }
        downloadPages.removeAll { page in idle.contains { $0.webContents === page.webContents } }
        for page in idle { page.runtime.browser.closeWebContents(page.webContents) }
    }

    /// The session also announces state changes because the sidebar icon and Clear button read download entry state through it.
    public func downloads(_ downloads: any EngineDownloads, didUpdate item: any EngineDownloadItem) {
        objectWillChange.send()
        guard let entry = self.downloads.first(where: { $0.id == item.id }) else { return }
        let wasFinished = entry.isFinished
        entry.refresh()
        if !wasFinished, entry.state == .completed, !windows.contains(where: \.isLibraryVisible) { unseenDownloadIDs.insert(entry.id) }
        if !wasFinished, entry.state == .completed { downloadNotifier.downloadDidFinish(entry) }
        closeDownloadPagesIfIdle()
    }

    public func downloads(_ downloads: any EngineDownloads, didRemove item: any EngineDownloadItem) {
        self.downloads.removeAll { $0.id == item.id }
        unseenDownloadIDs.remove(item.id)
        closeDownloadPagesIfIdle()
    }

    /// Saves in the downloads folder with an unused name, or opens a save panel when the profile is set to ask: a sheet on the key window, or a panel of its own over a small window. A small window closes with its tab, which a tab that only downloads does on the next turn of the run loop, and closing would cancel a sheet on it.
    public func downloads(_ downloads: any EngineDownloads, determineFilenameFor item: any EngineDownloadItem, defaultFilename: String, completion: @escaping (URL?) -> Void) {
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
