// Owns one runtime per engine (its application, profile, and browser), started when a tab first needs it, so tabs of both engines live side by side. Also owns sidebar state: spaces, favorites and the tabs they keep alive, tabs, tab folders, and the closed-tab list. Archives inactive tabs on a timer.
import AppKit
import ARCHEngine
import Combine
import Foundation
import PDFKit
import Plugins
import UniformTypeIdentifiers

/// One engine's running pieces: its application, the profile, and the browser that owns its tabs' web contents.
final class EngineRuntime {
    let kind: EngineKind
    let application: any EngineApplication
    let context: any EngineBrowserContext
    let browser: any EngineBrowser

    init(kind: EngineKind, application: any EngineApplication, context: any EngineBrowserContext, browser: any EngineBrowser) {
        self.kind = kind
        self.application = application
        self.context = context
        self.browser = browser
    }
}

public final class BrowserSession: ObservableObject {
    private let registry: EngineRegistry
    private let userDataDirectory: URL
    private var runtimes: [EngineKind: EngineRuntime] = [:]
    /// The engine that started with the session. Tabs fall back to it when another engine cannot start.
    private let primaryEngine: EngineKind
    private let cookieSync = CookieSync()
    /// The spaces' tabs. Favorites keep their own tabs in `favoriteTabs`.
    @Published public private(set) var tabs: [Tab] = []
    @Published public private(set) var spaces: [Space] = []
    @Published public private(set) var favorites: [Favorite] = []
    @Published public var currentSpaceID: UUID
    /// Selecting a tab switches to its space so the sidebar and page match.
    @Published public var selectedTabID: UUID? {
        didSet {
            // Selecting a tab, even the one under the page, leaves an internal page.
            internalPage = nil
            // Another tab ends the fullscreen of the page that filled the window.
            if fullscreenTabID != nil, fullscreenTabID != selectedTabID { exitPageFullscreen() }
            selectedTab?.lastActivatedAt = Date()
            recordActivation()
            if selectedTab?.isUnread == true { selectedTab?.isUnread = false }
            // A favorite's tab belongs to no space, so selecting it keeps the current one.
            if let spaceID = selectedTab?.spaceID, spaceID != currentSpaceID { currentSpaceID = spaceID }
            // Switching tabs ends the search because it belongs to one page.
            if isFindBarVisible, oldValue != selectedTabID {
                allTabs.first { $0.id == oldValue }?.webContents.stopFind()
                isFindBarVisible = false
                findResult = nil
            }
            deferVisibleSheet()
            showNextSheet()
            devToolsDock.track(selectedTab?.webContents.devTools)
            focusSelectedPane()
        }
    }
    @Published public var isSidebarVisible = true
    /// Where the selected tab's developer tools show.
    public let devToolsDock = DevToolsDock()
    /// The internal page covering the page area, opened by its address from the command palette.
    @Published public private(set) var internalPage: InternalPage?
    /// The tab whose page fills the window in fullscreen. Only engines that leave the transition to the app report it; WebKit shows fullscreen in its own window.
    @Published public private(set) var fullscreenTabID: UUID? {
        didSet {
            // The other panes of a split view leave the screen while the selected page fills the window, and their sheets wait until the panes return.
            deferVisibleSheet()
            showNextSheet()
        }
    }
    /// `nil` when the command palette is hidden.
    @Published public var commandPaletteMode: CommandPaletteMode?
    /// Counts palette openings and mode changes so each gets a fresh view.
    @Published public private(set) var commandPaletteGeneration = 0
    /// Where the open palette came from, which sets the direction it appears from.
    @Published public private(set) var commandPaletteOrigin = CommandPaletteOrigin.keyboard
    @Published public private(set) var isFindBarVisible = false
    /// Counts the requests to focus the find bar's field, such as ⌘F while the bar is already open.
    @Published public private(set) var findBarFocusRequests = 0
    /// The text in the find bar. Each change searches the selected tab while the bar is visible.
    @Published public var findText = "" {
        didSet { if findText != oldValue { runFind(forward: true) } }
    }
    /// The last result for `findText`. `nil` while no search has finished.
    @Published public private(set) var findResult: EngineFindResult?
    /// Downloads reported by the engine and not removed by the user, oldest first.
    @Published public private(set) var downloads: [DownloadEntry] = []
    /// The library takes the place of the space pages in the sidebar: downloads first, then other tools. Opening it marks every finished download as seen.
    @Published public var isLibraryVisible = false {
        didSet { if isLibraryVisible { unseenDownloadIDs.removeAll() } }
    }
    /// Downloads that finished while the library was closed. The library button shows their count.
    @Published public private(set) var unseenDownloadIDs: Set<String> = []
    /// The space whose name is being edited in the sidebar.
    @Published public var renamingSpaceID: UUID?
    /// The tab whose name is being edited in the sidebar.
    @Published public var renamingTabID: UUID?
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
    /// Pages of closed or engine-switched tabs whose downloads would stop if the pages closed, as on Chromium. Each stays open without a tab, on a blank page, until its own downloads are no longer in progress, paused, or interrupted.
    private var downloadPages: [(engine: EngineKind, webContents: any EngineWebContents)] = []
    /// Created with the session at launch, so that clicking a notification from an earlier run still reveals its file.
    private let downloadNotifier = DownloadNotifier()
    /// Sheets that tabs asked for, oldest first. They wait while their tab is not on screen.
    private var pendingSheets: [UUID: [PendingSheet]] = [:]
    private var visibleSheet: (tabID: UUID, alert: NSAlert, isPageDialog: Bool)?
    /// Set while the selected page renders as PDF for Print or Export as PDF, so a second request cannot start another.
    private var isRenderingPDF = false
    /// Set while the app quits. Every sheet gets its safe answer at once, so that a page's next dialog cannot hold the quit.
    public var isQuitting = false {
        didSet {
            if isQuitting { cancelAllSheets() }
        }
    }

    /// Starts the default engine, or the first registered engine that starts when the default cannot. The other engines start when a tab first needs them.
    public init(registry: EngineRegistry = .shared, userDataDirectory: URL) throws {
        self.registry = registry
        self.userDataDirectory = userDataDirectory
        let candidates = [registry.defaultKind] + registry.registeredKinds.filter { $0 != registry.defaultKind }
        var started: StartedEngine?
        for kind in candidates where started == nil {
            started = Self.startEngine(kind, registry: registry, userDataDirectory: userDataDirectory)
        }
        guard let started else { throw SessionError.noEngineStarted }
        primaryEngine = started.kind
        store = SessionStore(directory: userDataDirectory)
        let snapshot = store.load()
        let restoredSpaces = snapshot?.spaces ?? []
        let initialSpaces = restoredSpaces.isEmpty ? [Space(name: "Personal")] : restoredSpaces
        spaces = initialSpaces
        currentSpaceID = initialSpaces.first { $0.id == snapshot?.currentSpaceID }?.id ?? initialSpaces[0].id
        favorites = snapshot?.favorites ?? []
        folders = snapshot?.folders?.filter { folder in initialSpaces.contains { $0.id == folder.spaceID } } ?? []
        closedTabs = snapshot?.closedTabs ?? []
        cookieSync.runtimes = { [weak self] in self.map { Array($0.runtimes.values) } ?? [] }
        adoptRuntime(started)
        restoreTabs(snapshot)
        restoreFavoriteTabs(snapshot)
        observeChanges()
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

    private struct StartedEngine {
        let kind: EngineKind
        let application: any EngineApplication
        let context: any EngineBrowserContext
    }

    /// Creates an engine's application and its default profile. Returns nil when the engine cannot start.
    private static func startEngine(_ kind: EngineKind, registry: EngineRegistry, userDataDirectory: URL) -> StartedEngine? {
        guard let engine = registry.engine(for: kind) else { return nil }
        let configuration = EngineApplicationConfiguration(userDataDirectory: userDataDirectory,
                                                           cacheDirectory: userDataDirectory.appendingPathComponent("Cache"))
        guard let application = try? engine.makeApplication(configuration: configuration) else { return nil }
        var created: (any EngineBrowserContext)?
        let attributes = EngineBrowserContextAttributes(id: EngineBrowserContextID(rawValue: "default"), userVisibleName: "Default", type: .regular)
        application.createBrowserContext(attributes) { created = try? $0.get() }
        guard let context = created else { return nil }
        return StartedEngine(kind: kind, application: application, context: context)
    }

    /// Runs a started engine with the session as its delegate, creates its browser, and lists its downloads.
    @discardableResult
    private func adoptRuntime(_ started: StartedEngine) -> EngineRuntime {
        started.application.delegate = self
        started.application.run()
        let browser = started.application.createBrowser(EngineBrowserCreateParams(initialBounds: .zero), context: started.context, delegate: self, window: nil)
        let runtime = EngineRuntime(kind: started.kind, application: started.application, context: started.context, browser: browser)
        runtimes[started.kind] = runtime
        started.context.downloads.delegate = self
        followDownloadSettings(of: started.context)
        followSitePermissions(of: started.context)
        downloads += started.context.downloads.items.map(DownloadEntry.init)
        browser.cookiesDidChange = { [weak self] in self?.cookieSync.scheduleCopy(from: started.kind) }
        // An engine that starts after another has none of its cookies yet.
        if let source = runtimes.values.first(where: { $0.kind != started.kind }) {
            cookieSync.copy(from: source, to: runtime) {}
        }
        return runtime
    }

    /// The runtime for `kind`, started on first use. Falls back to the primary engine's runtime when `kind` cannot start.
    private func runtime(for kind: EngineKind) -> EngineRuntime {
        if let runtime = runtimes[kind] { return runtime }
        if let started = Self.startEngine(kind, registry: registry, userDataDirectory: userDataDirectory) {
            return adoptRuntime(started)
        }
        return runtimes[primaryEngine]!
    }

    private func runtime(owning downloads: any EngineDownloads) -> EngineRuntime? {
        runtimes.values.first { ($0.context.downloads as AnyObject) === (downloads as AnyObject) }
    }

    // MARK: Spaces

    public var currentSpace: Space {
        spaces.first { $0.id == currentSpaceID } ?? spaces[0]
    }

    /// A space's pinned or open tabs in sidebar order: the tabs of each folder, folder by folder, then the tabs outside folders.
    public func tabs(in spaceID: UUID, pinned: Bool) -> [Tab] {
        folders(in: spaceID, pinned: pinned).flatMap(tabs(in:)) + tabsOutsideFolders(in: spaceID, pinned: pinned)
    }

    public func addSpace() {
        let tint = SpaceTint.colors[spaces.count % SpaceTint.colors.count]
        // The lowest number no space uses, so names do not repeat after a deletion.
        let number = (1...).first { number in !spaces.contains { $0.name == "Space \(number)" } }!
        let space = Space(name: "Space \(number)", tint: tint)
        spaces.append(space)
        switchToSpace(space.id)
    }

    public func switchToSpace(_ id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        isLibraryVisible = false
        currentSpaceID = id
        // A selected favorite's tab belongs to no space; it stays open behind the space's own tab.
        if selectedTab?.spaceID != id {
            // The first tab row the sidebar shows, open tabs before pinned ones. Only a space whose tabs all sit in collapsed folders selects a hidden tab.
            let spaceTabs = tabs(in: id, pinned: false) + tabs(in: id, pinned: true)
            selectedTabID = (spaceTabs.first { !isInCollapsedFolder($0) } ?? spaceTabs.first)?.id
        }
    }

    public func switchToAdjacentSpace(forward: Bool) {
        guard let index = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        let next = (index + (forward ? 1 : spaces.count - 1)) % spaces.count
        switchToSpace(spaces[next].id)
    }

    /// Keeps the old name when the new one is empty.
    public func renameSpace(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { updateSpace(id) { $0.name = trimmed } }
        renamingSpaceID = nil
    }

    /// An empty name or the page's own title restores the page's title.
    public func renameTab(_ id: UUID, to name: String) {
        if let tab = tabs.first(where: { $0.id == id }) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.customTitle = trimmed.isEmpty || trimmed == tab.pageTitle ? nil : trimmed
            scheduleSave()
        }
        endRenaming(id)
    }

    /// Does not interrupt renaming another tab that may have started meanwhile.
    public func endRenaming(_ id: UUID) {
        if renamingTabID == id { renamingTabID = nil }
    }

    public func setTint(_ tint: SpaceTint, ofSpace id: UUID) {
        updateSpace(id) { $0.tint = tint }
    }

    public func setSymbol(_ symbol: String, ofSpace id: UUID) {
        updateSpace(id) { $0.symbol = symbol }
    }

    /// Moves a space one place left (`-1`) or right (`1`) in the switcher.
    public func moveSpace(_ id: UUID, by offset: Int) {
        guard let index = spaces.firstIndex(where: { $0.id == id }), spaces.indices.contains(index + offset) else { return }
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
        if currentSpaceID == id { switchToSpace(destination) }
        spaces.remove(at: index)
    }

    private func updateSpace(_ id: UUID, _ change: (inout Space) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        change(&spaces[index])
    }

    // MARK: Home pages

    /// Whether the selected tab shows a web page that can become a space's home page. An internal page over it has no address to use.
    public var canSetCurrentPageAsHome: Bool {
        guard internalPage == nil, let scheme = selectedTab?.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Makes the selected tab's page the home page of the space `id`, which need not be the current space.
    public func setCurrentPageAsHome(ofSpace id: UUID) {
        guard canSetCurrentPageAsHome, let url = selectedTab?.url else { return }
        updateSpace(id) { $0.homeURL = url }
    }

    public func clearHome(ofSpace id: UUID) {
        updateSpace(id) { $0.homeURL = nil }
    }

    /// Home needs a home page for the current space and no internal page or preview over the tab.
    public var canGoHome: Bool { !isSelectedPageCovered && currentSpace.homeURL != nil }

    /// Loads the current space's home page in the selected tab, or in a new tab when no tab is selected.
    public func goHome() {
        guard canGoHome, let url = currentSpace.homeURL else { return }
        guard let tab = selectedTab else {
            openTab(url: url)
            return
        }
        tab.forgetExternalAppDecline()
        tab.webContents.navigationController.load(URLRequest(url: url))
    }

    // MARK: Favorites

    /// The tab each opened favorite keeps alive, by favorite ID. Every space shows these tabs through their favorites instead of in its list, so a favorite's page stays the same across spaces, and archiving passes them by.
    @Published private(set) var favoriteTabs: [UUID: Tab] = [:]
    /// The favorites' tabs from the last session, by favorite ID. Each opens where it was when its favorite is next opened, so launching loads none of them.
    @Published private var savedFavoriteTabs: [UUID: SessionSnapshot.FavoriteTabRecord] = [:]

    public func addFavorite(_ tab: Tab) {
        guard let url = tab.url, !favorites.contains(where: { $0.url == url }) else { return }
        favorites.append(Favorite(url: url, title: tab.displayTitle))
    }

    /// Appends, in order, the favorites whose addresses are not favorites yet, and returns how many it added. Import uses it for bookmarks.
    @discardableResult
    public func addFavorites(_ candidates: [Favorite]) -> Int {
        var addresses = Set(favorites.map(\.url))
        let added = candidates.filter { addresses.insert($0.url).inserted }
        favorites += added
        return added.count
    }

    /// Removes a favorite once its tab, if it has one, agrees to close.
    public func removeFavorite(_ favorite: Favorite) {
        endFavoriteTab(favorite) { [weak self] in
            self?.favorites.removeAll { $0.id == favorite.id }
        }
    }

    /// Selects the favorite's own tab, opening it if needed: where it was when Arch last quit, or else at the favorite's address in the default engine.
    public func openFavorite(_ favorite: Favorite) {
        if let tab = favoriteTabs[favorite.id] {
            selectedTabID = tab.id
            return
        }
        let saved = savedFavoriteTabs.removeValue(forKey: favorite.id)
        let tab = makeTab(makeWebContents(url: saved?.url ?? favorite.url, engine: saved?.engine, state: saved?.state), spaceID: nil, pinned: false)
        if let saved {
            tab.isRestored = true
            // Loading a restored page does not count as a visit.
            tab.recordedURL = saved.url
        }
        favoriteTabs[favorite.id] = tab
        selectedTabID = tab.id
    }

    /// Ends the favorite's tab, as its Close menu item does. The favorite then opens at its own address again.
    public func closeFavorite(_ favorite: Favorite) {
        endFavoriteTab(favorite) {}
    }

    /// Whether the favorite has a tab of its own: an open one, or one saved from the last session.
    public func hasTab(_ favorite: Favorite) -> Bool {
        favoriteTabs[favorite.id] != nil || savedFavoriteTabs[favorite.id] != nil
    }

    /// The favorite whose tab is selected.
    public var selectedFavoriteID: UUID? {
        favoriteTabs.first { $0.value.id == selectedTabID }?.key
    }

    /// The favorites' open tabs, in favorite order.
    public var openFavoriteTabs: [Tab] {
        favorites.compactMap { favoriteTabs[$0.id] }
    }

    /// Forgets the favorite's saved tab and closes its open one once the page agrees, then runs `didEnd`.
    private func endFavoriteTab(_ favorite: Favorite, then didEnd: @escaping () -> Void) {
        savedFavoriteTabs[favorite.id] = nil
        guard let tab = favoriteTabs[favorite.id] else { return didEnd() }
        closeWhenPageAgrees(tab, then: didEnd)
    }

    // MARK: Previews

    /// The page in the preview panel over the page area, or nil while no panel shows. Its web contents belongs to no tab.
    @Published private(set) var preview: PagePreview?

    /// Whether an internal page or the preview panel covers the selected tab's page, so that the commands for the page in front leave the tab alone.
    private var isSelectedPageCovered: Bool { internalPage != nil || preview != nil }

    /// Previews a favorite in the default engine, which opening the favorite would use.
    func previewFavorite(_ favorite: Favorite) {
        showPreview(of: favorite.url, engine: defaultEngine)
    }

    /// Shows `url` in the panel, in place of any other preview, in a web contents of `engine` that no tab owns. A preview that opened with the same address stays as it is. The page cannot download, so closing the panel always closes the page at once.
    private func showPreview(of url: URL, engine: EngineKind) {
        guard preview?.openedURL != url else { return }
        closePreview()
        // The panel covers the page that a search or a region capture belongs to, so both end.
        hideFindBar()
        cancelRegionCapture()
        let webContents = runtime(for: engine).browser.createWebContents(EngineWebContentsConfiguration(initialURL: url, disallowDownloads: true))
        let preview = PagePreview(webContents: webContents, openedURL: url)
        // A page the preview opens, as for a link to a new window, becomes a selected tab in the current space and takes the panel's place. The engine is still in its callback, so the panel closes on the next turn of the run loop.
        preview.openNewTab = { [weak self, weak preview] popup in
            guard let self else { return }
            self.runtime(for: popup.engineKind).browser.takeOwnership(of: popup)
            _ = self.adopt(popup, spaceID: self.currentSpaceID, pinned: false, select: true)
            DispatchQueue.main.async { [weak self] in
                if let self, let preview, self.preview === preview { self.closePreview() }
            }
        }
        // A preview asks the user nothing, so its page's permission requests are denied. Chromium would keep the denial for the site, so its kept answers then return to the remembered ones.
        let previewEngine = webContents.engineKind
        preview.requestPermission = { [weak self] request, completion in
            completion(false)
            DispatchQueue.main.async { self?.applyRememberedPermissions(for: request, to: previewEngine) }
        }
        preview.didClose = { [weak self] in self?.closePreview() }
        self.preview = preview
    }

    /// Opens the page the panel shows, wherever the user went in it, in a new tab of the same engine with its page focused, and closes the panel.
    func openPreviewInTab() {
        guard let preview else { return }
        closePreview()
        openTab(url: preview.url, engine: preview.webContents.engineKind)
        focusPage()
    }

    /// Closes the panel and its page. Keyboard focus returns to the selected tab's page when it was in the panel, unless the click that closed the panel gave it to a field.
    func closePreview() {
        guard let preview else { return }
        self.preview = nil
        let view = preview.webContents.view
        let hadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
        // The page stops reporting to the panel before it closes.
        preview.webContents.uiDelegate = nil
        retire(preview.webContents)
        if hadFocus { focusPage(leaving: view) }
    }

    // MARK: Tabs

    public var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID } ?? favoriteTabs.values.first { $0.id == selectedTabID }
    }

    /// Every open tab: the spaces' tabs, then the favorites' tabs.
    public var allTabs: [Tab] { tabs + openFavoriteTabs }

    /// Opens a tab in `engine`, or in the default engine when no engine is given.
    @discardableResult
    public func openTab(url: URL? = nil, in spaceID: UUID? = nil, pinned: Bool = false, select: Bool = true, engine: EngineKind? = nil, state: Data? = nil) -> Tab {
        adopt(makeWebContents(url: url, engine: engine, state: state), spaceID: spaceID ?? currentSpaceID, pinned: pinned, select: select)
    }

    /// A web contents in `engine`, or in the default engine, that opens `url` or the new tab page and restores `state` when given.
    private func makeWebContents(url: URL?, engine: EngineKind?, state: Data?) -> any EngineWebContents {
        runtime(for: engine ?? defaultEngine).browser.createWebContents(EngineWebContentsConfiguration(initialURL: url ?? Self.newTabURL, restorableState: state))
    }

    /// Adds a tab for `webContents` to a space's list.
    private func adopt(_ webContents: any EngineWebContents, spaceID: UUID, pinned: Bool, select: Bool) -> Tab {
        let tab = makeTab(webContents, spaceID: spaceID, pinned: pinned)
        tabs.append(tab)
        if select { selectedTabID = tab.id }
        return tab
    }

    /// Wraps `webContents` in a tab whose popups, dialogs, permission requests, and closing go through the session. The caller adds it to a space's list or gives it to a favorite.
    private func makeTab(_ webContents: any EngineWebContents, spaceID: UUID?, pinned: Bool) -> Tab {
        let tab = Tab(webContents: webContents, spaceID: spaceID, isPinned: pinned)
        // A tab a page opens comes from the page's engine. A page that is not selected opens it behind the selected tab, in the page's space or, for a favorite's page, the current space, marked unread.
        tab.openNewTab = { [weak self, weak tab] popup in
            guard let self else { return }
            self.runtime(for: popup.engineKind).browser.takeOwnership(of: popup)
            guard let tab, tab.id != self.selectedTabID else {
                _ = self.adopt(popup, spaceID: self.currentSpaceID, pinned: false, select: true)
                return
            }
            self.adopt(popup, spaceID: tab.spaceID ?? self.currentSpaceID, pinned: false, select: false).isUnread = true
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
            if let self, let tab { self.selectedTabID = tab.id }
        }
        // Chromium does not report cookie changes, so a finished load is the moment to copy them.
        // Saving after each load keeps the page state that a crash would otherwise lose.
        // The page takes its host's remembered zoom.
        tab.didFinishLoad = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.cookieSync.scheduleCopy(from: tab.engineKind)
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
            guard let self, let tab else { return }
            if isFullscreen {
                self.fullscreenTabID = tab.id
            } else if self.fullscreenTabID == tab.id {
                self.fullscreenTabID = nil
            }
        }
        // A link opened from a page's context menu opens behind the current tab, in the page's space (the current space for a favorite's page) and engine, marked unread.
        tab.openURLInNewTab = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.openTab(url: url, in: tab.spaceID, select: false, engine: tab.engineKind).isUnread = true
        }
        // A web link the user clicks with Shift opens in the preview panel, in the page's engine.
        tab.previewLink = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.showPreview(of: url, engine: tab.engineKind)
        }
        tab.presentAlert = { [weak self, weak tab] alert, isPageDialog, completion in
            guard let self, let tab else { return completion(.cancel) }
            self.enqueueSheet(alert, for: tab, isPageDialog: isPageDialog, completion: completion)
        }
        // The session republishes changes to the selected tab so views that read it through the session refresh.
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self, weak tab] _ in
            guard let self else { return }
            if tab?.id == self.selectedTabID { self.objectWillChange.send() }
            self.scheduleSave()
        }
        return tab
    }

    /// Moves a tab to another engine: a web contents from `kind` loads the tab's address and takes the old one's place, and the tab keeps its place, pin, space, and selection. Nothing changes when `kind` cannot start.
    public func switchEngine(of tab: Tab, to kind: EngineKind) {
        guard tab.engineKind != kind, allTabs.contains(where: { $0.id == tab.id }) else { return }
        let target = runtime(for: kind)
        guard target.kind == kind, let source = runtimes[tab.engineKind] else { return }
        // The page loads in the other engine once it has this engine's cookies, so the site stays signed in.
        cookieSync.copy(from: source, to: target) { [weak self, weak tab] in
            guard let self, let tab, tab.engineKind != kind, self.allTabs.contains(where: { $0.id == tab.id }) else { return }
            let old = tab.webContents
            let replacement = target.browser.createWebContents(EngineWebContentsConfiguration(initialURL: tab.url ?? Self.newTabURL))
            // Sheets and searches belong to the old page.
            self.cancelSheets(for: tab)
            if tab.id == self.selectedTabID, self.isFindBarVisible { self.hideFindBar() }
            tab.replaceWebContents(with: replacement)
            if tab.id == self.selectedTabID { self.devToolsDock.track(replacement.devTools) }
            self.retire(old)
            self.scheduleSave()
        }
    }

    /// Closes a tab the user asked to close once its page agrees: a page with a `beforeunload` handler can ask to stay. ⌘Z reopens a space's tab; a favorite's tab opens again from its favorite.
    public func requestCloseTab(_ tab: Tab) {
        let isUndoable = tab.spaceID != nil
        closeWhenPageAgrees(tab) { [weak self] in
            if isUndoable { self?.undoableCloseCount += 1 }
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
        if fullscreenTabID == tab.id { fullscreenTabID = nil }
        cancelSheets(for: tab)
        if let index { tabs.remove(at: index) }
        if let favoriteID { favoriteTabs[favoriteID] = nil }
        tabObservers[tab.id] = nil
        retire(tab.webContents)
        if remember, let spaceID = tab.spaceID {
            closedTabs.append(SessionSnapshot.TabRecord(spaceID: spaceID, url: tab.url, title: tab.title, customTitle: tab.customTitle, isPinned: tab.isPinned, folderID: tab.folderID, engine: tab.engineKind))
            if closedTabs.count > 100 { closedTabs.removeFirst() }
        }
        // A focused pane hands the selection to the pane beside it, so the rest of its split view stays on screen; a favorite's tab leaves the selection to a tab of the current space.
        let splitNeighborID = leaveSplitView(tab)
        if selectedTabID == tab.id {
            let siblings = tabs.filter { $0.spaceID == (tab.spaceID ?? currentSpaceID) }
            selectedTabID = splitNeighborID ?? (siblings.first { !$0.isPinned } ?? siblings.first)?.id
        }
    }

    /// The preview panel or an internal page is what the user sees, so it closes instead of the tab under it.
    public func closeSelectedTab() {
        if preview != nil { return closePreview() }
        if internalPage != nil { return closeInternalPage() }
        selectedTab.map(requestCloseTab)
    }

    /// Closes other tabs in the selected tab's space, keeping pinned tabs.
    public func closeOtherTabs() {
        guard let selected = selectedTab else { return }
        for tab in tabs where tab.spaceID == selected.spaceID && !tab.isPinned && tab.id != selected.id {
            requestCloseTab(tab)
        }
    }

    public var hasClosedTabs: Bool { !closedTabs.isEmpty }

    /// Reopens the newest closed tab in its original space and folder, or the current space if the original is gone.
    public func reopenLastClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        undoableCloseCount = max(0, undoableCloseCount - 1)
        let spaceID = spaces.contains(where: { $0.id == record.spaceID }) ? record.spaceID : currentSpaceID
        let tab = openTab(url: record.url, in: spaceID, pinned: record.isPinned, engine: record.engine)
        tab.customTitle = record.customTitle
        tab.folderID = existingFolderID(record.folderID, spaceID: spaceID, pinned: record.isPinned)
    }

    /// Pressing another key or clicking in the page makes ⌘Z undo there instead of reopening tabs.
    public func forgetUndoableCloses() {
        undoableCloseCount = 0
    }

    /// The current space's tab rows in sidebar order: pinned first, then open. A collapsed folder shows only the selected tab.
    private var orderedTabs: [Tab] {
        (tabs(in: currentSpaceID, pinned: true) + tabs(in: currentSpaceID, pinned: false)).filter { $0.id == selectedTabID || !isInCollapsedFolder($0) }
    }

    public func selectTab(at index: Int) {
        let ordered = orderedTabs
        guard ordered.indices.contains(index) else { return }
        selectedTabID = ordered[index].id
    }

    public func selectLastTab() {
        if let last = orderedTabs.last { selectedTabID = last.id }
    }

    /// The ⌘-number shortcut for `tab`: 1 to 8 for the current space's first eight tabs, or 9 for its last tab beyond those.
    public func shortcutNumber(for tab: Tab) -> Int? {
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == tab.id }) else { return nil }
        if index < 8 { return index + 1 }
        return index == ordered.count - 1 ? 9 : nil
    }

    public func selectAdjacentTab(forward: Bool) {
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = ordered[(index + (forward ? 1 : ordered.count - 1)) % ordered.count].id
    }

    /// Swaps the selected tab with its neighbor in its folder, or among its space's pinned or open tabs outside folders.
    public func moveSelectedTab(up: Bool) {
        guard let selected = selectedTab, let spaceID = selected.spaceID, let index = tabs.firstIndex(where: { $0.id == selected.id }) else { return }
        let siblings = selected.folderID == nil ? tabsOutsideFolders(in: spaceID, pinned: selected.isPinned) : tabs.filter { $0.folderID == selected.folderID }
        guard let position = siblings.firstIndex(where: { $0.id == selected.id }) else { return }
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
        paneTabs.forEach { $0.lastActivatedAt = Date() }
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

    /// Loads a URL when the text parses as one, otherwise runs a web search.
    public func navigate(to input: String) {
        guard let url = Self.destination(forInput: input) else { return }
        if let tab = selectedTab {
            tab.forgetExternalAppDecline()
            tab.webContents.navigationController.load(URLRequest(url: url))
        } else {
            openTab(url: url)
        }
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

    // MARK: Command palette

    public func showCommandPalette(_ mode: CommandPaletteMode, from origin: CommandPaletteOrigin = .keyboard) {
        commandPaletteOrigin = origin
        if commandPaletteMode != mode { commandPaletteGeneration += 1 }
        commandPaletteMode = mode
    }
    public func dismissCommandPalette() {
        commandPaletteMode = nil
        focusPage()
    }

    public func submitCommandPalette(_ input: String) {
        defer {
            commandPaletteMode = nil
            focusPage()
        }
        if let page = InternalPage(address: input) { return internalPage = page }
        guard let mode = commandPaletteMode, let url = Self.destination(forInput: input) else { return }
        internalPage = nil
        switch mode {
        case .editCurrent where selectedTab != nil: navigate(to: input)
        case .editCurrent, .newTab: openTab(url: url)
        }
    }

    public func closeInternalPage() {
        internalPage = nil
        focusPage()
    }

    /// Ends the fullscreen of the page that fills the window, as Escape does.
    public func exitPageFullscreen() {
        guard let id = fullscreenTabID else { return }
        fullscreenTabID = nil
        allTabs.first { $0.id == id }?.webContents.exitFullscreen()
    }

    /// Returns keyboard focus to the page after the palette or the question popover closes. Runs after the next layout pass so a new tab's view is in the window. Given the view that focus is `leaving`, focus moves only while it is still there or nowhere, so a field the user clicked in the meantime keeps it.
    func focusPage(leaving previous: NSView? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.selectedTab?.webContents.view, let window = view.window else { return }
            if let previous, let responder = window.firstResponder, responder !== window,
               (responder as? NSView)?.isDescendant(of: previous) != true { return }
            // Keys must not reach a page an internal page covers.
            guard self.internalPage == nil else {
                window.makeFirstResponder(nil)
                return
            }
            window.makeFirstResponder(view.acceptsFirstResponder ? view : view.subviews.first)
        }
    }

    /// Moves keyboard focus to the selected tab's page from another pane of the split view on screen, which stays in the window and would keep the keys. Checks after the event that changed the selection, so a pane that a click selected has taken focus itself by then and keeps the element focused in it.
    private func focusSelectedPane() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isFocusInOtherPane = self.paneTabs.contains { pane in
                let view = pane.webContents.view
                return pane.id != self.selectedTabID && (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
            }
            if isFocusInOtherPane { self.focusPage() }
        }
    }

    // MARK: Plugins

    /// The plugins of the default Persona. `nil` until the app loads its built-in plugins at launch.
    public private(set) var plugins: PluginManager?
    /// Every plugin belongs to this Persona until Personas (III.12) exist. III.12 adopts it for the Persona that an earlier session loads into.
    private static let defaultPersonaID = PersonaID(uuidString: "BADC6939-A237-47E4-9A77-4009814D1BCA")!

    /// Creates the plugin manager with the built-in plugins the app ships. The app calls it once at launch.
    @MainActor public func loadPlugins(builtIns: [any BuiltInPlugin.Type]) {
        plugins = PluginManager(persona: Self.defaultPersonaID, builtIns: builtIns)
    }

    /// Closes the palette and runs a plugin command chosen in it on the selected tab.
    @MainActor public func runPluginCommand(_ command: PluginCommandRef) {
        guard let plugins else { return }
        let invocation = PluginInvocation(tab: selectedPluginTab)
        dismissCommandPalette()
        Task { await plugins.run(command, invocation) }
    }

    /// The selected tab before the manager applies a plugin's grant. Plugins see no tab under an internal page.
    private var selectedPluginTab: PluginTab? {
        guard internalPage == nil, let tab = selectedTab else { return nil }
        return PluginTab(id: tab.id, spaceID: tab.spaceID, title: tab.displayTitle, url: tab.url, engine: tab.engineKind, isPinned: tab.isPinned, isSelected: true)
    }

    // MARK: Find in page

    /// Opens the bar and searches the current text. While the bar is open, this only returns focus to its field without moving the match. The bar does not open under the preview panel, whose page it would not search.
    public func showFindBar() {
        guard selectedTab != nil, preview == nil else { return }
        findBarFocusRequests += 1
        guard !isFindBarVisible else { return }
        isFindBarVisible = true
        runFind(forward: true)
    }

    public func hideFindBar() {
        guard isFindBarVisible else { return }
        isFindBarVisible = false
        findResult = nil
        selectedTab?.webContents.stopFind()
        focusPage()
    }

    /// Moves to the next match and shows the find bar if hidden so the user can see the search.
    public func findNext() {
        if !isFindBarVisible { showFindBar() } else { runFind(forward: true) }
    }

    public func findPrevious() {
        if !isFindBarVisible { showFindBar() } else { runFind(forward: false) }
    }

    private func runFind(forward: Bool) {
        guard isFindBarVisible, let tab = selectedTab else { return }
        let text = findText
        guard !text.isEmpty else {
            tab.webContents.stopFind()
            findResult = nil
            return
        }
        tab.webContents.find(text, forward: forward, matchCase: false) { [weak self] result in
            // Ignore results for text the user has since changed.
            guard let self, self.isFindBarVisible, self.findText == text else { return }
            self.findResult = result
        }
    }

    // MARK: Downloads

    /// Shows the sidebar first if hidden because the library opens in it. With the sidebar hidden, the library always opens.
    public func toggleLibrary() {
        guard isSidebarVisible else {
            isSidebarVisible = true
            isLibraryVisible = true
            return
        }
        isLibraryVisible.toggle()
    }

    public func removeDownload(_ entry: DownloadEntry) {
        entry.item.remove()
    }

    public func clearFinishedDownloads() {
        downloads.filter(\.isFinished).forEach { $0.item.remove() }
    }

    /// The folder set in the primary engine's profile preferences, falling back to the user's Downloads folder, then the temporary folder.
    private var downloadsDirectory: URL {
        runtimes[primaryEngine]?.context.preferences.downloadFilePath
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

    /// Copies the saved download settings into a profile's preferences, which choose each download's destination, now and after every change to the defaults. A saved folder that no longer exists leaves the user's Downloads folder in use.
    private func followDownloadSettings(of context: any EngineBrowserContext) {
        let apply = {
            let defaults = UserDefaults.standard
            var isDirectory: ObjCBool = false
            let folder = defaults.string(forKey: Self.downloadsFolderKey).flatMap { path in
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? URL(fileURLWithPath: path, isDirectory: true) : nil
            }
            context.preferences.downloadFilePath = folder
            context.preferences.promptForDownloadPath = defaults.bool(forKey: Self.asksWhereToSaveDownloadsKey)
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
        let engine = tab.engineKind
        // Chromium keeps every answer it receives, even the safe answer for a sheet that closed with its tab, so once it has the answer its kept answers return to the remembered ones.
        let answer = { [weak self] (granted: Bool) in
            completion(granted)
            DispatchQueue.main.async { self?.applyRememberedPermissions(for: request, to: engine) }
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

    /// Gives the engine's own kept answers for the request's types the remembered answers, or none.
    private func applyRememberedPermissions(for request: EnginePermissionRequest, to engine: EngineKind) {
        guard let context = runtimes[engine]?.context else { return }
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
    private func enqueueSheet(_ alert: NSAlert, for tab: Tab, isPageDialog: Bool = false, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !isQuitting else { return completion(.cancel) }
        pendingSheets[tab.id, default: []].append(PendingSheet(alert: alert, isPageDialog: isPageDialog, completion: completion))
        showNextSheet()
    }

    /// The tabs whose sheets can show, the selected tab first: the panes on screen, or the selected tab alone while its page fills the window.
    private var sheetTabs: [Tab] {
        guard let selected = selectedTab else { return [] }
        if fullscreenTabID == selected.id { return [selected] }
        return [selected] + paneTabs.filter { $0.id != selected.id }
    }

    /// Shows the oldest waiting sheet of the selected tab, or else of another pane on screen, when no sheet is on screen. Nothing runs an app-modal alert inside an engine callback.
    private func showNextSheet() {
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
    private func deferVisibleSheet() {
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

    // Going to another page leaves an internal page, and reloading does not reach the page under it. While the preview panel shows, Back, Forward, and Reload act on its page instead of the tab under it.
    public func goBack() {
        if let preview { return preview.webContents.navigationController.goBack() }
        internalPage = nil
        selectedTab?.webContents.navigationController.goBack()
    }
    public func goForward() {
        if let preview { return preview.webContents.navigationController.goForward() }
        internalPage = nil
        selectedTab?.webContents.navigationController.goForward()
    }
    /// The selected tab's earlier pages, most recent first, for the History menu.
    public func recentBackItems(limit: Int) -> [any EngineBackForwardListItem] {
        guard let list = selectedTab?.webContents.navigationController.backForwardList else { return [] }
        return Array(list.backList.reversed().prefix(limit))
    }
    /// Pages keep running while the menu is open. Use an item only in its original tab, while that tab is selected. The item is one of the tab's pages, so the preview panel closes to show it.
    public func go(to item: any EngineBackForwardListItem, inTab tabID: UUID) {
        guard let tab = selectedTab, tab.id == tabID else { return }
        closePreview()
        internalPage = nil
        tab.webContents.navigationController.go(to: item)
    }
    public func reload() {
        if let preview { return preview.webContents.navigationController.reload() }
        guard internalPage == nil else { return }
        selectedTab?.webContents.navigationController.reload()
    }
    public func stopLoading() { selectedTab?.webContents.navigationController.stop() }
    /// Whether the selected tab's engine offers developer tools.
    public var canShowDeveloperTools: Bool { selectedTab?.webContents.devTools != nil }
    public var isShowingDeveloperTools: Bool { selectedTab?.webContents.devTools?.isOpen == true }
    /// Whether the docking side applies to the selected tab's tools. Tools that dock inside the page have their own controls.
    public var canChooseDevToolsSide: Bool { selectedTab?.webContents.devTools?.isPlacedByApp == true }
    public func toggleDeveloperTools() {
        guard let devTools = selectedTab?.webContents.devTools else { return }
        devToolsDock.track(devTools)
        devTools.isOpen ? devTools.close() : devTools.open()
    }
    public func focusCommandBar(from origin: CommandPaletteOrigin = .keyboard) { showCommandPalette(selectedTab == nil ? .newTab : .editCurrent, from: origin) }
    public func toggleSidebar() { isSidebarVisible.toggle() }

    // MARK: Zoom

    /// The factors that zooming in and out steps through, alike on both engines.
    private static let zoomFactors: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    /// Each host's zoom factor other than 1, as a `UserDefaults` dictionary keyed by host.
    private static let zoomFactorsKey = "ARCHZoomFactorsByHost"

    /// Zooming needs a selected tab that no internal page or preview covers.
    public var canZoom: Bool { selectedTab != nil && !isSelectedPageCovered }

    public func zoomIn() { changeZoom { current in Self.zoomFactors.first { $0 > current + 0.01 } } }
    public func zoomOut() { changeZoom { current in Self.zoomFactors.last { $0 < current - 0.01 } } }
    public func resetZoom() { changeZoom { _ in 1 } }

    /// Sets the selected tab's zoom from its current factor and remembers it for the page's host, so that the host's other open tabs follow. A page without a host keeps the factor until its next load.
    private func changeZoom(_ next: (Double) -> Double?) {
        guard canZoom, let tab = selectedTab, let factor = next(tab.webContents.zoomFactor) else { return }
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

    // MARK: Printing

    /// Whether Print and Export as PDF can act: a page is selected with no internal page or preview over it, no PDF is rendering, and its window shows no sheet.
    public var canPrint: Bool {
        guard let tab = selectedTab, !isSelectedPageCovered, !isRenderingPDF else { return false }
        return (tab.webContents.view.window ?? NSApp.mainWindow)?.attachedSheet == nil
    }

    /// Prints the selected page through the system print panel, a sheet on its window. Both engines render the page as PDF first, so the panel and its preview work the same on either.
    public func printPage() {
        renderSelectedPageAsPDF(failureMessage: "The page could not be printed.") { tab, document, window in
            guard let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
            operation.jobTitle = tab.displayTitle
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    /// Saves the selected page as a PDF file where the user chooses in a save panel on its window.
    public func exportPageAsPDF() {
        renderSelectedPageAsPDF(failureMessage: "The page could not be exported as PDF.") { [weak self] tab, document, window in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            // A slash would name a folder, and a colon shows as a slash in the Finder.
            panel.nameFieldStringValue = tab.displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".pdf"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                if !document.write(to: url) {
                    let alert = NSAlert()
                    alert.messageText = "The PDF could not be saved."
                    alert.informativeText = url.path
                    self?.enqueueSheet(alert, for: tab) { _ in }
                }
            }
        }
    }

    /// Renders the selected page as PDF and passes it on with the page's window while that tab is still selected; a tab the user left in the meantime drops the request. A failure shows a sheet on the tab.
    private func renderSelectedPageAsPDF(failureMessage: String, then use: @escaping (Tab, PDFDocument, NSWindow) -> Void) {
        guard canPrint, let tab = selectedTab else { return }
        isRenderingPDF = true
        tab.webContents.createPDF { [weak self] result in
            guard let self else { return }
            self.isRenderingPDF = false
            guard self.selectedTab === tab, let window = tab.webContents.view.window ?? NSApp.mainWindow else { return }
            if case .success(let data) = result, let document = PDFDocument(data: data) {
                use(tab, document, window)
            } else {
                let alert = NSAlert()
                alert.messageText = failureMessage
                self.enqueueSheet(alert, for: tab) { _ in }
            }
        }
    }

    // MARK: Capture

    /// The tab whose page shows the region capture overlay, from Capture Region until the user drags out a region or cancels.
    @Published public private(set) var regionCaptureTabID: UUID?

    /// Whether the capture commands can act: a page is selected and no internal page or preview covers it.
    public var canCapture: Bool { selectedTab != nil && !isSelectedPageCovered }

    /// Saves the visible part of the selected page as a PNG file in the captures folder and shows it in the Finder.
    public func captureViewport() {
        guard canCapture, let tab = selectedTab else { return }
        tab.webContents.captureViewport { [weak self] in self?.saveCapture($0, of: tab) }
    }

    /// Saves the whole selected page, including the parts scrolled out of view, as a PNG file in the captures folder and shows it in the Finder.
    public func captureFullPage() {
        guard canCapture, let tab = selectedTab else { return }
        tab.webContents.captureFullPage { [weak self] in self?.saveCapture($0, of: tab) }
    }

    /// Covers the selected page with an overlay where the user drags out the region to capture.
    public func beginRegionCapture() {
        guard canCapture, let tab = selectedTab else { return }
        regionCaptureTabID = tab.id
    }

    /// Captures the visible part of the page and keeps the region the user dragged out, given in the page view's coordinates.
    func finishRegionCapture(_ rect: CGRect) {
        guard let tab = selectedTab, tab.id == regionCaptureTabID else { return cancelRegionCapture() }
        regionCaptureTabID = nil
        focusPage()
        let view = tab.webContents.view
        let bounds = view.bounds
        let isFlipped = view.isFlipped
        tab.webContents.captureViewport { [weak self] image in
            self?.saveCapture(image.flatMap { PageCapture.crop($0, to: rect, of: bounds, isFlipped: isFlipped) }, of: tab)
        }
    }

    /// Removes the region capture overlay without capturing.
    func cancelRegionCapture() {
        guard regionCaptureTabID != nil else { return }
        regionCaptureTabID = nil
        focusPage()
    }

    /// Writes a capture to the captures folder and shows the file in the Finder. Encoding a long page takes a moment, so it runs off the main thread. A capture that failed or could not be written shows a sheet on its tab, if the tab is still open.
    private func saveCapture(_ image: NSImage?, of tab: Tab) {
        guard let image else { return showCaptureFailure("The page could not be captured.", for: tab) }
        let title = tab.displayTitle
        let date = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try PageCapture.save(image, title: title, date: date) }
            DispatchQueue.main.async {
                switch result {
                case .success(let file): NSWorkspace.shared.activateFileViewerSelecting([file])
                case .failure(let error): self?.showCaptureFailure("The capture could not be saved.", detail: error.localizedDescription, for: tab)
                }
            }
        }
    }

    private func showCaptureFailure(_ message: String, detail: String? = nil, for tab: Tab) {
        guard allTabs.contains(where: { $0 === tab }) else { return }
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        enqueueSheet(alert, for: tab) { _ in }
    }

    // MARK: Sharing

    /// The share button in the address pill, set when it joins the window.
    weak var shareButtonView: NSView?
    /// The picker holds its delegate weakly, so the last one stays here until the next share.
    private var sharePicker: PageSharePicker?

    /// Whether the selected tab shows a page to share. An internal page has nothing to share, and the preview panel hides the tab's page.
    public var canShareSelectedPage: Bool { !isSelectedPageCovered && selectedTab?.url != nil }

    /// Shows the system share picker for the selected tab's address and title, below the share button, or from the top of the window while the sidebar or the library hides the button.
    public func shareSelectedPage() {
        guard !isSelectedPageCovered, let tab = selectedTab, let url = tab.url else { return }
        let picker = PageSharePicker(url: url, title: tab.pageTitle, icon: tab.favicon)
        sharePicker = picker
        if let button = shareButtonView, button.window != nil, !isLibraryVisible {
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .maxY : .minY)
        } else if let content = (NSApp.mainWindow ?? tab.webContents.view.window)?.contentView {
            let bounds = content.bounds
            let top = NSRect(x: bounds.midX, y: content.isFlipped ? bounds.minY : bounds.maxY - 1, width: 1, height: 1)
            picker.show(relativeTo: top, of: content, preferredEdge: content.isFlipped ? .maxY : .minY)
        }
    }

    // MARK: Tab switcher

    /// Tab identifiers in the order the tabs were last selected, most recent first. Tabs not selected since launch are missing.
    private var activationOrder: [UUID] = []
    /// The tab the switcher highlights, which releasing Control selects. `nil` while the switcher is hidden.
    @Published public private(set) var tabSwitcherHighlightID: UUID?

    public var isTabSwitcherVisible: Bool { tabSwitcherHighlightID != nil }

    /// The current space's tabs and the favorites' open tabs, which every space shows, most recently selected first. Tabs not selected since launch follow by their last activation: restored tabs keep the one from the saved session, and tabs opened in the background count from their opening.
    public var recentTabs: [Tab] {
        let candidates = tabs.filter { $0.spaceID == currentSpaceID } + openFavoriteTabs
        let selected = activationOrder.compactMap { id in candidates.first { $0.id == id } }
        let selectedIDs = Set(activationOrder)
        return selected + candidates.filter { !selectedIDs.contains($0.id) }.sorted { $0.lastActivatedAt > $1.lastActivatedAt }
    }

    private func recordActivation() {
        guard let id = selectedTabID else { return }
        activationOrder.removeAll { $0 == id }
        activationOrder.insert(id, at: 0)
    }

    /// Opens the switcher on the tab selected before the current one, or on the least recent tab when going backward. The current space needs a second tab.
    public func showTabSwitcher(backward: Bool) {
        let recent = recentTabs
        guard recent.count > 1 else { return }
        let others = recent.filter { $0.id != selectedTabID }
        tabSwitcherHighlightID = (backward ? others.last : others.first)?.id
    }

    /// Moves the highlight to the next less recent tab, or toward the current one when going backward, wrapping at either end.
    public func moveTabSwitcherHighlight(backward: Bool) {
        guard let id = tabSwitcherHighlightID else { return }
        let recent = recentTabs
        guard !recent.isEmpty else { return cancelTabSwitcher() }
        // A highlighted tab that closed meanwhile counts as the first.
        let index = recent.firstIndex { $0.id == id } ?? 0
        tabSwitcherHighlightID = recent[(index + (backward ? recent.count - 1 : 1)) % recent.count].id
    }

    /// Selects the highlighted tab and gives its page keyboard focus. An open command palette closes, as when the palette's own tab row is chosen.
    public func commitTabSwitcher() {
        guard let id = tabSwitcherHighlightID else { return }
        tabSwitcherHighlightID = nil
        guard allTabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        if commandPaletteMode != nil { dismissCommandPalette() } else { focusPage() }
    }

    /// Closes the switcher and keeps the selected tab.
    public func cancelTabSwitcher() {
        if tabSwitcherHighlightID != nil { tabSwitcherHighlightID = nil }
    }

    // MARK: Tab close log

    /// Why each tab closed this launch, for the tab close log window.
    public let closeLog = TabCloseLog()

    /// Logs a closing tab with its crash count and the engines' total, and drops it from the switcher's order.
    private func recordClose(of tab: Tab, reason: TabCloseReason) {
        activationOrder.removeAll { $0 == tab.id }
        closeLog.record(TabCloseLogEntry(reason: reason, tab: tab, sessionCrashCount: rendererCrashCount))
    }

    // MARK: Site data

    /// Whether Clear Site Data can act: the selected tab shows a web page that no internal page or preview covers, and its window shows no sheet.
    public var canClearSiteData: Bool {
        guard !isSelectedPageCovered, let tab = selectedTab, SiteDataScope(url: tab.url) != nil else { return false }
        return (tab.webContents.view.window ?? NSApp.mainWindow)?.attachedSheet == nil
    }

    /// Asks with a sheet on the selected tab before clearing the data of its page's host.
    public func confirmClearSiteData() {
        guard canClearSiteData, let tab = selectedTab, let site = SiteDataScope(url: tab.url) else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the data stored by \u{201C}\(site.displayName)\u{201D}?"
        alert.informativeText = "Its cookies and other website data are removed from both engines, which signs you out of the site. Its open tabs load again."
        alert.addButton(withTitle: "Clear").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        enqueueSheet(alert, for: tab) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.clearSiteData(of: site) }
        }
    }

    /// Deletes the site's cookies from every engine at once, then each engine's other data for the site's origins, then reloads the site's tabs. An engine that has not started yet starts first, so that the cookies it keeps on disk cannot come back through a later copy.
    private func clearSiteData(of site: SiteDataScope) {
        availableEngines.forEach { _ = runtime(for: $0) }
        cookieSync.removeCookies(where: { site.contains($0) }) { [weak self] in
            guard let self else { return }
            let pages = self.allTabs.compactMap(\.url).filter { $0.host.map(site.contains(host:)) == true }
            let origins = Array(Set(site.origins + pages.compactMap(SiteDataScope.origin(of:))))
            let group = DispatchGroup()
            for runtime in self.runtimes.values {
                group.enter()
                runtime.browser.removeSiteData(for: origins) { group.leave() }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                for tab in self.allTabs where tab.url?.host.map(site.contains(host:)) == true {
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

    /// Moves a dragged space to `target`'s place in the switcher.
    public func moveSpace(_ id: UUID, to target: Space) {
        guard let from = spaces.firstIndex(where: { $0.id == id }), let to = spaces.firstIndex(where: { $0.id == target.id }), from != to else { return }
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
        if tab.id == selectedTabID { currentSpaceID = spaceID }
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
    /// The folder whose name is being edited in the sidebar.
    @Published public var renamingFolderID: UUID?

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

    /// Adds an empty folder after the space's folders among its pinned tabs, shows the space, and starts renaming the folder.
    public func addFolder(toSpace spaceID: UUID) {
        guard spaces.contains(where: { $0.id == spaceID }) else { return }
        switchToSpace(spaceID)
        renamingFolderID = makeFolder(in: spaceID, pinned: true).id
    }

    /// Puts a tab in a new folder among its space's pinned or open tabs and starts renaming the folder. A favorite's tab belongs to no space and stays out of folders.
    public func addToNewFolder(_ tab: Tab) {
        guard let spaceID = tab.spaceID else { return }
        let folder = makeFolder(in: spaceID, pinned: tab.isPinned)
        moveTab(tab.id, toFolder: folder.id)
        renamingFolderID = folder.id
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

    /// Keeps the old name when the new one is empty.
    public func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { updateFolder(id) { $0.name = trimmed } }
        endRenamingFolder(id)
    }

    /// Does not interrupt renaming another folder that may have started meanwhile.
    public func endRenamingFolder(_ id: UUID) {
        if renamingFolderID == id { renamingFolderID = nil }
    }

    public func toggleCollapsed(ofFolder id: UUID) {
        updateFolder(id) { $0.isCollapsed.toggle() }
    }

    /// Removes a folder and keeps its tabs.
    public func deleteFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        takeOutOfFolder(tabs(in: folder))
        folders.removeAll { $0.id == id }
        endRenamingFolder(id)
    }

    /// Appends a folder to a space's pinned or open folders.
    private func makeFolder(in spaceID: UUID, pinned: Bool) -> TabFolder {
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

    private func updateFolder(_ id: UUID, _ change: (inout TabFolder) -> Void) {
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

    /// The split view the page area shows: the selected tab's, if it is in one.
    private var splitOnScreen: [UUID]? {
        guard let selected = selectedTab, let spaceID = selected.spaceID, let ids = splitTabIDs[spaceID], ids.contains(selected.id) else { return nil }
        return ids
    }

    /// The tabs the page area shows, left to right: the selected tab's split view, or the selected tab alone.
    var paneTabs: [Tab] {
        guard let selected = selectedTab else { return [] }
        guard let ids = splitOnScreen else { return [selected] }
        return ids.compactMap { id in tabs.first { $0.id == id } }
    }

    /// Whether `tab` is a pane of the split view the page area shows.
    func isInSplitViewOnScreen(_ tab: Tab) -> Bool {
        splitOnScreen?.contains(tab.id) == true
    }

    /// Whether `tab` can open as a pane: it belongs to the selected tab's space, the page area does not show it yet, and the panes it joins have room.
    public func canOpenInSplitView(_ tab: Tab) -> Bool {
        let panes = panesJoined(by: tab)
        return !panes.isEmpty && !panes.contains(tab.id) && panes.count < Self.maximumPanes
    }

    /// Opens `tab` as a pane at `index` among the panes it joins, or after the last, and selects it. The result becomes the space's split view, in place of an earlier one. A tab that is already a pane on screen moves to `index`.
    public func openInSplitView(_ tab: Tab, at index: Int? = nil) {
        guard let spaceID = tab.spaceID else { return }
        var ids = panesJoined(by: tab)
        var position = min(index ?? ids.count, ids.count)
        if let current = ids.firstIndex(of: tab.id) {
            ids.remove(at: current)
            if current < position { position -= 1 }
        }
        ids.insert(tab.id, at: position)
        guard (2...Self.maximumPanes).contains(ids.count) else { return }
        splitTabIDs[spaceID] = ids
        // Selecting the tab again would close an internal page over it.
        if selectedTabID != tab.id { selectedTabID = tab.id }
    }

    /// Whether the menu bar's Open in Split View can act: the selected tab can open as a pane, and no internal page covers it.
    public var canOpenSelectedTabInSplitView: Bool {
        internalPage == nil && selectedTab.map(canOpenInSplitView) == true
    }

    public func openSelectedTabInSplitView() {
        guard canOpenSelectedTabInSplitView, let tab = selectedTab else { return }
        openInSplitView(tab)
    }

    /// Takes `tab` out of its split view and leaves the tab open. When it was the focused pane, the pane that takes its place is selected, so the rest of the split view stays on screen.
    func closePane(_ tab: Tab) {
        let neighborID = leaveSplitView(tab)
        if selectedTabID == tab.id, let neighborID { selectedTabID = neighborID }
    }

    /// The panes `tab` joins, left to right: those on screen, which are a split view or the selected tab alone. The selected tab shown alone joins its space's split view instead or, without one, the tab selected before it. Empty when `tab` is in another space or has no tab to join.
    private func panesJoined(by tab: Tab) -> [UUID] {
        guard let selected = selectedTab, let spaceID = tab.spaceID, selected.spaceID == spaceID else { return [] }
        let onScreen = paneTabs.map(\.id)
        guard onScreen == [tab.id] else { return onScreen }
        if let split = splitTabIDs[spaceID] { return split }
        return recentTabs.first { $0.id != tab.id && $0.spaceID == tab.spaceID }.map { [$0.id] } ?? []
    }

    /// Removes `tab` from its space's split view, which ends once fewer than two tabs remain. Returns the pane that takes its place: the one after it, or the one before for the last pane.
    @discardableResult
    private func leaveSplitView(_ tab: Tab) -> UUID? {
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

    private func restoreTabs(_ snapshot: SessionSnapshot?) {
        guard let snapshot else { return }
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
            let tab = openTab(url: record.url, in: record.spaceID, pinned: record.isPinned, select: false, engine: record.engine, state: record.state)
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
        selectedTabID = selected?.id ?? tabs.first { $0.spaceID == currentSpaceID }?.id
    }

    /// Keeps the favorites' tabs from the last session until their favorites open them. The tab that was selected opens now, so the window shows the page it showed.
    private func restoreFavoriteTabs(_ snapshot: SessionSnapshot?) {
        for record in snapshot?.favoriteTabs ?? [] where favorites.contains(where: { $0.id == record.favoriteID }) {
            savedFavoriteTabs[record.favoriteID] = record
        }
        if let favorite = favorites.first(where: { $0.id == snapshot?.selectedFavoriteID }) { openFavorite(favorite) }
    }

    private func observeChanges() {
        Publishers.Merge4($tabs.map { _ in () }, $spaces.map { _ in () }, $favorites.map { _ in () }, $currentSpaceID.map { _ in () })
            .merge(with: $selectedTabID.map { _ in () })
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
        SessionSnapshot(version: SessionSnapshot.currentVersion, spaces: spaces, currentSpaceID: currentSpaceID, favorites: favorites,
                        tabs: tabs.map { SessionSnapshot.TabRecord(spaceID: $0.spaceID ?? currentSpaceID, url: $0.url, title: $0.title, customTitle: $0.customTitle, isPinned: $0.isPinned, folderID: $0.folderID, lastActivatedAt: $0.lastActivatedAt, engine: $0.engineKind, state: $0.webContents.restorableState) },
                        folders: folders, selectedTabIndex: tabs.firstIndex { $0.id == selectedTabID }, closedTabs: closedTabs,
                        splitViews: splitViewRecords, favoriteTabs: favoriteTabRecords, selectedFavoriteID: selectedFavoriteID)
    }

    /// The favorites' open tabs and the saved ones not opened since launch, in favorite order.
    private var favoriteTabRecords: [SessionSnapshot.FavoriteTabRecord] {
        favorites.compactMap { favorite in
            guard let tab = favoriteTabs[favorite.id] else { return savedFavoriteTabs[favorite.id] }
            return SessionSnapshot.FavoriteTabRecord(favoriteID: favorite.id, url: tab.url, engine: tab.engineKind, state: tab.webContents.restorableState)
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

extension BrowserSession: EngineBrowserDelegate {
    public func browser(_ browser: any EngineBrowser, didCreateNewWebContents webContents: any EngineWebContents, isActive: Bool) {
        _ = adopt(webContents, spaceID: currentSpaceID, pinned: false, select: isActive)
    }
}

extension BrowserSession: EngineDownloadsDelegate {
    public func downloads(_ downloads: any EngineDownloads, didInitializeWith items: [any EngineDownloadItem]) {
        self.downloads += items.filter { item in !self.downloads.contains { $0.id == item.id } }.map(DownloadEntry.init)
    }

    /// The library button shows a new download's progress, so the library itself stays as it is.
    public func downloads(_ downloads: any EngineDownloads, didCreate item: any EngineDownloadItem) {
        self.downloads.append(DownloadEntry(item: item))
        let finishedTabIDs = downloadOnlyTabIDs
        downloadOnlyTabIDs.removeAll()
        // The engine is still choosing the file's destination, so the tabs close once that callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for tab in self.allTabs where finishedTabIDs.contains(tab.id) { self.closeTab(tab, remember: false, reason: .download) }
        }
    }

    /// Closes a page that no tab shows any more. A page whose downloads would stop with it stays open on a blank page until they finish.
    private func retire(_ webContents: any EngineWebContents) {
        if webContents.closingStopsDownloads {
            // Without a delegate the page's own questions, such as its leave-page check on the way to the blank page, get their default answers.
            webContents.uiDelegate = nil
            webContents.navigationController.load(URLRequest(url: URL(string: "about:blank")!))
            downloadPages.append((webContents.engineKind, webContents))
        } else {
            runtimes[webContents.engineKind]?.browser.closeWebContents(webContents)
        }
    }

    /// Each kept page closes once its own downloads no longer need it.
    private func closeDownloadPagesIfIdle() {
        let idle = downloadPages.filter { !$0.webContents.closingStopsDownloads }
        guard !idle.isEmpty else { return }
        downloadPages.removeAll { page in idle.contains { $0.webContents === page.webContents } }
        for page in idle { runtimes[page.engine]?.browser.closeWebContents(page.webContents) }
    }

    /// The session also announces state changes because the sidebar icon and Clear button read download entry state through it.
    public func downloads(_ downloads: any EngineDownloads, didUpdate item: any EngineDownloadItem) {
        objectWillChange.send()
        guard let entry = self.downloads.first(where: { $0.id == item.id }) else { return }
        let wasFinished = entry.isFinished
        entry.refresh()
        if !wasFinished, entry.state == .completed, !isLibraryVisible { unseenDownloadIDs.insert(entry.id) }
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
