// Owns each engine's application and, for each Persona, one runtime per engine (the Persona's profile and browser), each started when a tab first needs it, so tabs of both engines live side by side. Also owns sidebar state: Personas, spaces, favorites and the tabs they keep alive, tabs, tab folders, split views, and the closed-tab list. Archives inactive tabs on a timer. The browser window's own state and commands live in its `BrowserWindowModel`, which the session forwards to for the views, menus, and scripts that still reach them here.
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
    /// The state and commands of the one browser window. Created once the session's own state exists, because it reads the session.
    private var windowModel: BrowserWindowModel!
    /// Downloads reported by the engine and not removed by the user, oldest first.
    @Published public private(set) var downloads: [DownloadEntry] = []
    /// Downloads that finished while the library was closed. The library button shows their count.
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
    /// Sheets that tabs asked for, oldest first. They wait while their tab is not on screen.
    private var pendingSheets: [UUID: [PendingSheet]] = [:]
    private var visibleSheet: (tabID: UUID, alert: NSAlert, isPageDialog: Bool)?
    /// Set while the app quits. Every sheet gets its safe answer at once, so that a page's next dialog cannot hold the quit.
    public var isQuitting = false {
        didSet {
            if isQuitting { cancelAllSheets() }
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
        personas = snapshot.personas ?? []
        spaces = snapshot.spaces
        currentSpaceID = snapshot.spaces.first { $0.id == snapshot.currentSpaceID }?.id ?? snapshot.spaces[0].id
        favorites = snapshot.favorites
        folders = snapshot.folders?.filter { folder in snapshot.spaces.contains { $0.id == folder.spaceID } } ?? []
        closedTabs = snapshot.closedTabs ?? []
        windowModel = BrowserWindowModel(session: self, currentSpaceID: currentSpaceID)
        // Views still read the window's state through the session, so they hear of its changes here.
        windowModel.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        start(primary)
        // The default Persona's runtime of the primary engine starts with the session, so the other engine's runtime in that Persona, whenever it starts, takes its cookies from the primary engine.
        _ = runtime(for: primaryEngine, in: Persona.defaultID)
        restoreTabs(snapshot)
        restoreFavoriteTabs(snapshot)
        observeChanges()
        personaDataRemoval.didRemove = { [weak self] in self?.scheduleSave() }
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.archiveInactiveTabs() }
        // Tabs restored at launch can ask before the window exists; their sheets show once it does.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)
            .sink { [weak self] _ in self?.showNextSheet() }
            .store(in: &cancellables)
        nowPlaying = NowPlaying(session: self)
        // The session is created on the main thread, where the AI interface runs.
        MainActor.assumeIsolated { pageAssistant.attach(to: self) }
    }

    public enum SessionError: Error {
        case noEngineStarted
    }

    // MARK: Window state mirrors

    /// The window's current space, mirrored for the views that still read and assign it here. Assigning it changes the window's. Nothing subscribes to its publisher.
    @Published public var currentSpaceID: UUID {
        didSet { if !isMirroringWindow { windowModel.currentSpaceID = currentSpaceID } }
    }
    /// The window's selected tab, mirrored as `currentSpaceID` is. `NowPlaying` and `PageAssistant` subscribe to its publisher. Assigning it selects the tab in the window, even the tab already selected, so that an internal page over it closes.
    @Published public var selectedTabID: UUID? {
        didSet { if !isMirroringWindow { windowModel.selectedTabID = selectedTabID } }
    }
    /// Set while the mirrors take the window's values, so that those values do not go back to the window.
    private var isMirroringWindow = false

    /// Copies the window's current space and selected tab into the mirrors. A mirror that already holds the value, as after an assignment here, does not publish it again.
    func mirrorWindowSelection() {
        isMirroringWindow = true
        defer { isMirroringWindow = false }
        if currentSpaceID != windowModel.currentSpaceID { currentSpaceID = windowModel.currentSpaceID }
        if selectedTabID != windowModel.selectedTabID { selectedTabID = windowModel.selectedTabID }
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

    /// Removes a space. Its tabs and folders move to the space before it, or to the next one for the first space, so no tab closes.
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
        if windowModel.currentSpaceID == id { windowModel.switchToSpace(destination) }
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

    /// Appends, in order, the favorites whose addresses are not favorites of the current space's Persona yet, as favorites of that Persona, and returns how many it added. Import uses it for bookmarks.
    @discardableResult
    public func addFavorites(_ candidates: [Favorite]) -> Int {
        let personaID = windowModel.currentSpace.resolvedPersonaID
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

    /// Opens a tab in `engine`, or in the default engine when no engine is given, in the space `spaceID` or the window's current space. `select` selects it in the window.
    @discardableResult
    public func openTab(url: URL? = nil, in spaceID: UUID? = nil, pinned: Bool = false, select: Bool = true, engine: EngineKind? = nil, state: Data? = nil) -> Tab {
        let spaceID = spaceID ?? windowModel.currentSpaceID
        let personaID = personaID(ofSpace: spaceID)
        return adopt(makeWebContents(url: url, engine: engine, state: state, in: personaID), spaceID: spaceID, personaID: personaID, pinned: pinned, select: select)
    }

    /// A web contents of the Persona in `engine`, or in the default engine, that opens `url` or the new tab page and restores `state` when given.
    func makeWebContents(url: URL?, engine: EngineKind?, state: Data?, in personaID: Persona.ID) -> any EngineWebContents {
        runtime(for: engine ?? defaultEngine, in: personaID).browser.createWebContents(EngineWebContentsConfiguration(initialURL: url ?? Self.newTabURL, restorableState: state))
    }

    /// The Persona of the space `id`, or of the window's current space when no space has that ID.
    private func personaID(ofSpace id: UUID) -> Persona.ID {
        (spaces.first { $0.id == id } ?? windowModel.currentSpace).resolvedPersonaID
    }

    /// Adds a tab for `webContents`, which a runtime of the Persona `personaID` created, to the list of the space `spaceID` or, when that space belongs to another Persona, of the Persona's first space if it has one. A tab that restores or reopens passes its saved `id`. `select` selects it in the window.
    func adopt(_ webContents: any EngineWebContents, id: UUID = UUID(), spaceID: UUID, personaID: Persona.ID, pinned: Bool, select: Bool) -> Tab {
        let spaceID = self.personaID(ofSpace: spaceID) == personaID ? spaceID : spaces.first { $0.resolvedPersonaID == personaID }?.id ?? spaceID
        let tab = makeTab(webContents, id: id, spaceID: spaceID, personaID: personaID, pinned: pinned)
        tabs.append(tab)
        if select { windowModel.selectedTabID = tab.id }
        return tab
    }

    /// Wraps `webContents` in a tab whose popups, dialogs, permission requests, and closing go through the session. The caller adds it to a space's list or gives it to a favorite.
    private func makeTab(_ webContents: any EngineWebContents, id: UUID, spaceID: UUID?, personaID: UUID, pinned: Bool) -> Tab {
        let tab = Tab(id: id, webContents: webContents, spaceID: spaceID, isPinned: pinned, personaID: personaID)
        // A tab a page opens comes from the page's runtime, so it belongs to the page's Persona. A page that is not selected opens it behind the selected tab, in the page's space or, for a favorite's page, the current space, marked unread.
        tab.openNewTab = { [weak self, weak tab] popup in
            guard let self else { return }
            self.runtime(for: popup.engineKind, in: personaID).browser.takeOwnership(of: popup)
            guard let tab, tab.id != self.windowModel.selectedTabID else {
                _ = self.adopt(popup, spaceID: self.windowModel.currentSpaceID, personaID: personaID, pinned: false, select: true)
                return
            }
            self.adopt(popup, spaceID: tab.spaceID ?? self.windowModel.currentSpaceID, personaID: personaID, pinned: false, select: false).isUnread = true
        }
        // The user cannot undo a tab closed by its page. A page also reports closing after the user closes its tab, when the tab is no longer in the list.
        tab.didClose = { [weak self, weak tab] in
            guard let self, let tab, self.allTabs.contains(where: { $0.id == tab.id }) else { return }
            self.closeTab(tab, reason: tab.hasCrashed ? .crash : .page)
            self.undoableCloseCount = 0
        }
        // Only the page's own dialogs go: a permission, sign-in, or leave-page question still applies.
        tab.didCancelDialogs = { [weak self, weak tab] in
            if let self, let tab { self.cancelSheets(for: tab, pageDialogsOnly: true) }
        }
        tab.requestSelection = { [weak self, weak tab] in
            if let self, let tab { self.windowModel.selectedTabID = tab.id }
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
        tab.didChangeFullscreen = { [weak self, weak tab] isFullscreen in
            if let self, let tab { self.windowModel.setPageFullscreen(isFullscreen, of: tab) }
        }
        // A link opened from a page's context menu opens behind the current tab, in the page's space (the current space for a favorite's page) and engine, marked unread.
        tab.openURLInNewTab = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.openTab(url: url, in: tab.spaceID, select: false, engine: tab.engineKind).isUnread = true
        }
        // A web link the user clicks with Shift opens in the preview panel, in the page's engine and Persona.
        tab.previewLink = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.windowModel.showPreview(of: url, engine: tab.engineKind, in: tab.personaID)
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
            // Sheets and searches belong to the old page.
            self.cancelSheets(for: tab)
            if tab.id == self.windowModel.selectedTabID, self.windowModel.isFindBarVisible { self.windowModel.hideFindBar() }
            tab.replaceWebContents(with: replacement)
            if tab.id == self.windowModel.selectedTabID { self.windowModel.devToolsDock.track(replacement.devTools) }
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
        windowModel.setPageFullscreen(false, of: tab)
        cancelSheets(for: tab)
        if let index { tabs.remove(at: index) }
        if let favoriteID { favoriteTabs[favoriteID] = nil }
        tabObservers[tab.id] = nil
        retire(tab.webContents, of: tab.personaID)
        if remember, let spaceID = tab.spaceID {
            closedTabs.append(SessionSnapshot.TabRecord(id: tab.id, spaceID: spaceID, url: tab.url, title: tab.title, customTitle: tab.customTitle, isPinned: tab.isPinned, folderID: tab.folderID, engine: tab.engineKind, personaID: tab.personaID))
            if closedTabs.count > 100 { closedTabs.removeFirst() }
        }
        // A focused pane hands the selection to the pane beside it, so the rest of its split view stays on screen; a favorite's tab leaves the selection to a tab of the current space.
        let splitNeighborID = leaveSplitView(tab)
        if windowModel.selectedTabID == tab.id {
            let siblings = tabs.filter { $0.spaceID == (tab.spaceID ?? windowModel.currentSpaceID) }
            windowModel.selectedTabID = splitNeighborID ?? (siblings.first { !$0.isPinned } ?? siblings.first)?.id
        }
    }

    public var hasClosedTabs: Bool { !closedTabs.isEmpty }

    /// Reopens the newest closed tab under its own ID in its original space and folder, or the current space if the original is gone.
    public func reopenLastClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        undoableCloseCount = max(0, undoableCloseCount - 1)
        let spaceID = spaces.contains(where: { $0.id == record.spaceID }) ? record.spaceID : windowModel.currentSpaceID
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

    /// Closes unpinned tabs inactive for `ARCHArchiveAfterHours` hours (default 12; 0 disables). The tabs on screen, the selected tab and the other panes of its split view, count as active now.
    public func archiveInactiveTabs() {
        guard let cutoff = Self.archiveCutoff(now: Date()) else { return }
        windowModel.paneTabs.forEach { $0.lastActivatedAt = Date() }
        for tab in tabs where !tab.isPinned && tab.lastActivatedAt < cutoff {
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
        plugins = PluginManager(persona: Persona.defaultID, builtIns: builtIns)
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

    /// Asks with a sheet on the page's window, or on the main window while the page is not on screen. The engine calls this from inside its own message loop, so the sheet never blocks and a request without any window is denied. The answer reaches the engine once.
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

    private struct PendingSheet {
        let alert: NSAlert
        /// An `alert`, `confirm`, or `prompt` from the page, which the engine can cancel.
        let isPageDialog: Bool
        let completion: (NSApplication.ModalResponse) -> Void
    }

    /// Queues a sheet for a tab. Sheets show one at a time and only while their tab is on screen, as the selected tab or another pane of its split view, so a background page cannot cover the page in front.
    func enqueueSheet(_ alert: NSAlert, for tab: Tab, isPageDialog: Bool = false, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !isQuitting else { return completion(.cancel) }
        pendingSheets[tab.id, default: []].append(PendingSheet(alert: alert, isPageDialog: isPageDialog, completion: completion))
        showNextSheet()
    }

    /// The tabs whose sheets can show, the selected tab first: the panes on screen, or the selected tab alone while its page fills the window.
    private var sheetTabs: [Tab] {
        guard let selected = windowModel.selectedTab else { return [] }
        if windowModel.fullscreenTabID == selected.id { return [selected] }
        return [selected] + windowModel.paneTabs.filter { $0.id != selected.id }
    }

    /// Shows the oldest waiting sheet of the selected tab, or else of another pane on screen, when no sheet is on screen. Nothing runs an app-modal alert inside an engine callback.
    func showNextSheet() {
        guard visibleSheet == nil, let tab = sheetTabs.first(where: { pendingSheets[$0.id]?.isEmpty == false }), var queue = pendingSheets[tab.id],
              let window = tab.webContents.view.window ?? NSApp.mainWindow else { return }
        let sheet = queue.removeFirst()
        pendingSheets[tab.id] = queue.isEmpty ? nil : queue
        visibleSheet = (tab.id, sheet.alert, sheet.isPageDialog)
        sheet.alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return sheet.completion(response) }
            self.visibleSheet = nil
            if response == Self.deferredSheetResponse {
                self.pendingSheets[tab.id, default: []].insert(sheet, at: 0)
            } else {
                sheet.completion(response)
            }
            self.showNextSheet()
        }
    }

    /// Ends a sheet without answering it, so that it can show again.
    private static let deferredSheetResponse = NSApplication.ModalResponse(rawValue: -1_100)

    /// Puts away the sheet of a tab that is no longer on screen, as when a link from another app opens a new tab. It shows again first when its tab is back on screen.
    func deferVisibleSheet() {
        guard let visibleSheet, !sheetTabs.contains(where: { $0.id == visibleSheet.tabID }), let window = visibleSheet.alert.window.sheetParent else { return }
        window.endSheet(visibleSheet.alert.window, returnCode: Self.deferredSheetResponse)
    }

    /// Gives a tab's sheets the safe answer, `.cancel`, including the one on screen: all of them when the tab closes, or only the page's dialogs when the engine cancels those. The queue changes first, so that ending the visible sheet does not show one that is going too.
    private func cancelSheets(for tab: Tab, pageDialogsOnly: Bool = false) {
        let queue = pendingSheets.removeValue(forKey: tab.id) ?? []
        let waiting = pageDialogsOnly ? queue.filter(\.isPageDialog) : queue
        let kept = pageDialogsOnly ? queue.filter { !$0.isPageDialog } : []
        if !kept.isEmpty { pendingSheets[tab.id] = kept }
        if let visibleSheet, visibleSheet.tabID == tab.id, !pageDialogsOnly || visibleSheet.isPageDialog,
           let window = visibleSheet.alert.window.sheetParent {
            window.endSheet(visibleSheet.alert.window, returnCode: .cancel)
        }
        waiting.forEach { $0.completion(.cancel) }
    }

    private func cancelAllSheets() {
        let waiting = pendingSheets.values.flatMap { $0 }
        pendingSheets = [:]
        if let visibleSheet, let window = visibleSheet.alert.window.sheetParent {
            window.endSheet(visibleSheet.alert.window, returnCode: .cancel)
        }
        waiting.forEach { $0.completion(.cancel) }
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

    /// Logs a closing tab with its crash count and the engines' total, and drops it from the switcher's order.
    private func recordClose(of tab: Tab, reason: TabCloseReason) {
        windowModel.forgetActivation(of: tab.id)
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

    /// Shows the media of the selected or most recently audible tab in Now Playing and sends the media keys to it.
    private var nowPlaying: NowPlaying?

    // MARK: Page reader and questions

    /// The page reader beside the page and the question popover over it. It follows the session's tabs once the session exists.
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

    /// Moves a tab dropped on another space's symbol after that space's own pinned or open tabs, outside its folders. The window follows the selected tab to its new space, so the sidebar keeps showing the page's tab.
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
        if tab.id == windowModel.selectedTabID { windowModel.currentSpaceID = spaceID }
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

    /// A space's pinned or open tabs that are in no folder, in sidebar order.
    public func tabsOutsideFolders(in spaceID: UUID, pinned: Bool) -> [Tab] {
        tabs.filter { $0.spaceID == spaceID && $0.isPinned == pinned && $0.folderID == nil }
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
        windowModel.endRenamingFolder(id)
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
            // The panes on screen change with the split views, and the sheets that can show change with them.
            deferVisibleSheet()
            showNextSheet()
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

    private func restoreTabs(_ snapshot: SessionSnapshot) {
        // Archive stale unpinned records before they have web contents.
        let cutoff = Self.archiveCutoff(now: Date())
        var selected: Tab?
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
            if index == snapshot.selectedTabIndex { selected = tab }
            restored[index] = tab
        }
        restoreSplitViews(snapshot.splitViews ?? [], from: restored)
        // A selected favorite's tab takes the selection once `restoreFavoriteTabs` opens it, so no space tab stands in for it and counts as just used.
        guard !favorites.contains(where: { $0.id == snapshot.selectedFavoriteID }) else { return }
        windowModel.selectedTabID = selected?.id ?? tabs.first { $0.spaceID == windowModel.currentSpaceID }?.id
    }

    /// Keeps the favorites' tabs from the last session until their favorites open them. The tab that was selected opens now, so the window shows the page it showed.
    private func restoreFavoriteTabs(_ snapshot: SessionSnapshot) {
        for record in snapshot.favoriteTabs ?? [] where favorites.contains(where: { $0.id == record.favoriteID }) {
            savedFavoriteTabs[record.favoriteID] = record
        }
        if let favorite = favorites.first(where: { $0.id == snapshot.selectedFavoriteID }) { windowModel.openFavorite(favorite) }
    }

    private func observeChanges() {
        Publishers.Merge4($tabs.map { _ in () }, $spaces.map { _ in () }, $favorites.map { _ in () }, windowModel.$currentSpaceID.map { _ in () })
            .merge(with: windowModel.$selectedTabID.map { _ in () }, $personas.map { _ in () })
            .merge(with: $closedTabs.map { _ in () })
            .merge(with: $favoriteTabs.map { _ in () }, $savedFavoriteTabs.map { _ in () }, $folders.map { _ in () }, $splitTabIDs.map { _ in () })
            .dropFirst()
            .sink { [weak self] in self?.scheduleSave() }
            .store(in: &cancellables)
    }

    private func scheduleSave() {
        store.scheduleSave { [weak self] in self?.snapshot() ?? SessionSnapshot(version: SessionSnapshot.currentVersion, spaces: [], currentSpaceID: UUID(), favorites: [], tabs: [], selectedTabIndex: nil) }
    }

    public func saveNow() {
        store.saveNow(snapshot())
    }

    private func snapshot() -> SessionSnapshot {
        SessionSnapshot(version: SessionSnapshot.currentVersion, personas: personas, removedPersonaIDs: personaDataRemoval.pendingIDs, spaces: spaces, currentSpaceID: windowModel.currentSpaceID, favorites: favorites,
                        tabs: tabs.map { SessionSnapshot.TabRecord(id: $0.id, spaceID: $0.spaceID ?? windowModel.currentSpaceID, url: $0.url, title: $0.title, customTitle: $0.customTitle, isPinned: $0.isPinned, folderID: $0.folderID, lastActivatedAt: $0.lastActivatedAt, engine: $0.engineKind, state: $0.webContents.restorableState, personaID: $0.personaID) },
                        folders: folders, selectedTabIndex: tabs.firstIndex { $0.id == windowModel.selectedTabID }, closedTabs: closedTabs,
                        splitViews: splitViewRecords, favoriteTabs: favoriteTabRecords, selectedFavoriteID: windowModel.selectedFavoriteID)
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
        if !wasFinished, entry.state == .completed, !windowModel.isLibraryVisible { unseenDownloadIDs.insert(entry.id) }
        if !wasFinished, entry.state == .completed { downloadNotifier.downloadDidFinish(entry) }
        closeDownloadPagesIfIdle()
    }

    public func downloads(_ downloads: any EngineDownloads, didRemove item: any EngineDownloadItem) {
        self.downloads.removeAll { $0.id == item.id }
        unseenDownloadIDs.remove(item.id)
        closeDownloadPagesIfIdle()
    }

    /// Saves in the downloads folder with an unused name, or opens a save panel when the profile is set to ask.
    public func downloads(_ downloads: any EngineDownloads, determineFilenameFor item: any EngineDownloadItem, defaultFilename: String, completion: @escaping (URL?) -> Void) {
        guard runtime(owning: downloads)?.context.preferences.promptForDownloadPath == true else {
            return completion(Self.uniqueDestination(for: defaultFilename, in: downloadsDirectory))
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFilename
        panel.directoryURL = downloadsDirectory
        let finish = { (response: NSApplication.ModalResponse) in completion(response == .OK ? panel.url : nil) }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

// MARK: Window forwarding

/// The window's state and commands for the views, menus, scripts, and features that still reach them through the session. Each member forwards to the window's model.
extension BrowserSession {
    public var currentSpace: Space { windowModel.currentSpace }
    public var selectedTab: Tab? { windowModel.selectedTab }
    public var selectedFavoriteID: UUID? { windowModel.selectedFavoriteID }
    public var recentTabs: [Tab] { windowModel.recentTabs }
    var paneTabs: [Tab] { windowModel.paneTabs }
    var preview: PagePreview? { windowModel.preview }
    public var devToolsDock: DevToolsDock { windowModel.devToolsDock }
    public var internalPage: InternalPage? { windowModel.internalPage }
    public var fullscreenTabID: UUID? { windowModel.fullscreenTabID }
    public var regionCaptureTabID: UUID? { windowModel.regionCaptureTabID }
    public var tabSwitcherHighlightID: UUID? { windowModel.tabSwitcherHighlightID }
    public var isTabSwitcherVisible: Bool { windowModel.isTabSwitcherVisible }
    public var commandPaletteGeneration: Int { windowModel.commandPaletteGeneration }
    public var commandPaletteOrigin: CommandPaletteOrigin { windowModel.commandPaletteOrigin }
    public var isFindBarVisible: Bool { windowModel.isFindBarVisible }
    public var findBarFocusRequests: Int { windowModel.findBarFocusRequests }
    public var findResult: EngineFindResult? { windowModel.findResult }

    public var isSidebarVisible: Bool {
        get { windowModel.isSidebarVisible }
        set { windowModel.isSidebarVisible = newValue }
    }
    public var isLibraryVisible: Bool {
        get { windowModel.isLibraryVisible }
        set { windowModel.isLibraryVisible = newValue }
    }
    public var commandPaletteMode: CommandPaletteMode? {
        get { windowModel.commandPaletteMode }
        set { windowModel.commandPaletteMode = newValue }
    }
    public var findText: String {
        get { windowModel.findText }
        set { windowModel.findText = newValue }
    }
    public var renamingSpaceID: UUID? {
        get { windowModel.renamingSpaceID }
        set { windowModel.renamingSpaceID = newValue }
    }
    public var renamingTabID: UUID? {
        get { windowModel.renamingTabID }
        set { windowModel.renamingTabID = newValue }
    }
    public var renamingFolderID: UUID? {
        get { windowModel.renamingFolderID }
        set { windowModel.renamingFolderID = newValue }
    }
    var shareButtonView: NSView? {
        get { windowModel.shareButtonView }
        set { windowModel.shareButtonView = newValue }
    }

    public var canSetCurrentPageAsHome: Bool { windowModel.canSetCurrentPageAsHome }
    public var canGoHome: Bool { windowModel.canGoHome }
    public var canShowDeveloperTools: Bool { windowModel.canShowDeveloperTools }
    public var isShowingDeveloperTools: Bool { windowModel.isShowingDeveloperTools }
    public var canChooseDevToolsSide: Bool { windowModel.canChooseDevToolsSide }
    public var canZoom: Bool { windowModel.canZoom }
    public var canPrint: Bool { windowModel.canPrint }
    public var canCapture: Bool { windowModel.canCapture }
    public var canShareSelectedPage: Bool { windowModel.canShareSelectedPage }
    public var canClearSiteData: Bool { windowModel.canClearSiteData }
    public var canOpenSelectedTabInSplitView: Bool { windowModel.canOpenSelectedTabInSplitView }

    public func addSpace() { windowModel.addSpace() }
    public func switchToSpace(_ id: UUID) { windowModel.switchToSpace(id) }
    public func switchToAdjacentSpace(forward: Bool) { windowModel.switchToAdjacentSpace(forward: forward) }
    public func renameSpace(_ id: UUID, to name: String) { windowModel.renameSpace(id, to: name) }
    public func renameTab(_ id: UUID, to name: String) { windowModel.renameTab(id, to: name) }
    public func endRenaming(_ id: UUID) { windowModel.endRenaming(id) }
    public func addFolder(toSpace spaceID: UUID) { windowModel.addFolder(toSpace: spaceID) }
    public func addToNewFolder(_ tab: Tab) { windowModel.addToNewFolder(tab) }
    public func renameFolder(_ id: UUID, to name: String) { windowModel.renameFolder(id, to: name) }
    public func endRenamingFolder(_ id: UUID) { windowModel.endRenamingFolder(id) }
    public func setCurrentPageAsHome(ofSpace id: UUID) { windowModel.setCurrentPageAsHome(ofSpace: id) }
    public func goHome() { windowModel.goHome() }
    public func navigate(to input: String) { windowModel.navigate(to: input) }
    public func openFavorite(_ favorite: Favorite) { windowModel.openFavorite(favorite) }
    func previewFavorite(_ favorite: Favorite) { windowModel.previewFavorite(favorite) }
    func openPreviewInTab() { windowModel.openPreviewInTab() }
    func closePreview() { windowModel.closePreview() }

    public func closeSelectedTab() { windowModel.closeSelectedTab() }
    public func closeOtherTabs() { windowModel.closeOtherTabs() }
    public func selectTab(at index: Int) { windowModel.selectTab(at: index) }
    public func selectLastTab() { windowModel.selectLastTab() }
    public func shortcutNumber(for tab: Tab) -> Int? { windowModel.shortcutNumber(for: tab) }
    public func selectAdjacentTab(forward: Bool) { windowModel.selectAdjacentTab(forward: forward) }
    public func moveSelectedTab(up: Bool) { windowModel.moveSelectedTab(up: up) }

    public func showCommandPalette(_ mode: CommandPaletteMode, from origin: CommandPaletteOrigin = .keyboard) { windowModel.showCommandPalette(mode, from: origin) }
    public func dismissCommandPalette() { windowModel.dismissCommandPalette() }
    public func submitCommandPalette(_ input: String) { windowModel.submitCommandPalette(input) }
    public func focusCommandBar(from origin: CommandPaletteOrigin = .keyboard) { windowModel.focusCommandBar(from: origin) }
    public func closeInternalPage() { windowModel.closeInternalPage() }
    public func exitPageFullscreen() { windowModel.exitPageFullscreen() }
    func focusPage(leaving previous: NSView? = nil) { windowModel.focusPage(leaving: previous) }
    @MainActor public func runPluginCommand(_ command: PluginCommandRef) { windowModel.runPluginCommand(command) }

    public func showFindBar() { windowModel.showFindBar() }
    public func hideFindBar() { windowModel.hideFindBar() }
    public func findNext() { windowModel.findNext() }
    public func findPrevious() { windowModel.findPrevious() }
    public func toggleSidebar() { windowModel.toggleSidebar() }
    public func toggleLibrary() { windowModel.toggleLibrary() }

    public func goBack() { windowModel.goBack() }
    public func goForward() { windowModel.goForward() }
    public func recentBackItems(limit: Int) -> [any EngineBackForwardListItem] { windowModel.recentBackItems(limit: limit) }
    public func go(to item: any EngineBackForwardListItem, inTab tabID: UUID) { windowModel.go(to: item, inTab: tabID) }
    public func reload() { windowModel.reload() }
    public func stopLoading() { windowModel.stopLoading() }
    public func toggleDeveloperTools() { windowModel.toggleDeveloperTools() }
    public func zoomIn() { windowModel.zoomIn() }
    public func zoomOut() { windowModel.zoomOut() }
    public func resetZoom() { windowModel.resetZoom() }
    public func printPage() { windowModel.printPage() }
    public func exportPageAsPDF() { windowModel.exportPageAsPDF() }
    public func captureViewport() { windowModel.captureViewport() }
    public func captureFullPage() { windowModel.captureFullPage() }
    public func beginRegionCapture() { windowModel.beginRegionCapture() }
    func finishRegionCapture(_ rect: CGRect) { windowModel.finishRegionCapture(rect) }
    func cancelRegionCapture() { windowModel.cancelRegionCapture() }
    public func shareSelectedPage() { windowModel.shareSelectedPage() }
    public func confirmClearSiteData() { windowModel.confirmClearSiteData() }

    public func showTabSwitcher(backward: Bool) { windowModel.showTabSwitcher(backward: backward) }
    public func moveTabSwitcherHighlight(backward: Bool) { windowModel.moveTabSwitcherHighlight(backward: backward) }
    public func commitTabSwitcher() { windowModel.commitTabSwitcher() }
    public func cancelTabSwitcher() { windowModel.cancelTabSwitcher() }

    func isInSplitViewOnScreen(_ tab: Tab) -> Bool { windowModel.isInSplitViewOnScreen(tab) }
    public func canOpenInSplitView(_ tab: Tab) -> Bool { windowModel.canOpenInSplitView(tab) }
    public func openInSplitView(_ tab: Tab, at index: Int? = nil) { windowModel.openInSplitView(tab, at: index) }
    public func openSelectedTabInSplitView() { windowModel.openSelectedTabInSplitView() }
    func closePane(_ tab: Tab) { windowModel.closePane(tab) }
}
