// Owns one runtime per engine (its application, profile, and browser), started when a tab first needs it, so tabs of both engines live side by side. Also owns sidebar state: spaces, favorites, tabs, and the closed-tab list. Archives inactive tabs on a timer.
import AppKit
import ARCHEngine
import Combine
import Foundation

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
            if let tab = selectedTab, tab.spaceID != currentSpaceID { currentSpaceID = tab.spaceID }
            // Switching tabs ends the search because it belongs to one page.
            if isFindBarVisible, oldValue != selectedTabID {
                tabs.first { $0.id == oldValue }?.webContents.stopFind()
                isFindBarVisible = false
                findResult = nil
            }
            deferVisibleSheet()
            showNextSheet()
        }
    }
    @Published public var isSidebarVisible = true
    /// The internal page covering the page area, opened by its address from the command palette.
    @Published public private(set) var internalPage: InternalPage?
    /// The tab whose page fills the window in fullscreen. Only engines that leave the transition to the app report it; WebKit shows fullscreen in its own window.
    @Published public private(set) var fullscreenTabID: UUID?
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

    public static let searchURL = URL(string: "https://www.google.com/search")!
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
    /// Sheets that tabs asked for, oldest first. They wait while their tab is not selected.
    private var pendingSheets: [UUID: [PendingSheet]] = [:]
    private var visibleSheet: (tabID: UUID, alert: NSAlert, isPageDialog: Bool)?
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
        closedTabs = snapshot?.closedTabs ?? []
        cookieSync.runtimes = { [weak self] in self.map { Array($0.runtimes.values) } ?? [] }
        adoptRuntime(started)
        restoreTabs(snapshot)
        observeChanges()
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.archiveInactiveTabs() }
        // Tabs restored at launch can ask before the window exists; their sheets show once it does.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)
            .sink { [weak self] _ in self?.showNextSheet() }
            .store(in: &cancellables)
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

    public func tabs(in spaceID: UUID, pinned: Bool) -> [Tab] {
        tabs.filter { $0.spaceID == spaceID && $0.isPinned == pinned }
    }

    public func addSpace() {
        let tint = SpaceTint.allCases[spaces.count % SpaceTint.allCases.count]
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
        if selectedTab?.spaceID != id {
            selectedTabID = (tabs(in: id, pinned: false).first ?? tabs(in: id, pinned: true).first)?.id
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

    /// Removes a space. Its tabs move to the space before it, or to the next one for the first space, so no tab closes.
    public func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let destination = spaces[index == 0 ? 1 : index - 1].id
        // The moved tabs go after the destination's own tabs instead of among them.
        let moved = tabs.filter { $0.spaceID == id }
        let movedIDs = Set(moved.map(\.id))
        moved.forEach { $0.spaceID = destination }
        tabs.removeAll { movedIDs.contains($0.id) }
        tabs.append(contentsOf: moved)
        if currentSpaceID == id { switchToSpace(destination) }
        spaces.remove(at: index)
    }

    private func updateSpace(_ id: UUID, _ change: (inout Space) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        change(&spaces[index])
    }

    // MARK: Favorites

    public func addFavorite(_ tab: Tab) {
        guard let url = tab.url, !favorites.contains(where: { $0.url == url }) else { return }
        favorites.append(Favorite(url: url, title: tab.displayTitle))
    }

    public func removeFavorite(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
    }

    /// Reuses an open tab for the same site in the current space, or opens a new tab.
    public func openFavorite(_ favorite: Favorite) {
        if let host = favorite.url.host, let existing = tabs.first(where: { $0.spaceID == currentSpaceID && $0.url?.host == host }) {
            selectedTabID = existing.id
        } else {
            openTab(url: favorite.url)
        }
    }

    // MARK: Tabs

    public var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Opens a tab in `engine`, or in the default engine when no engine is given.
    @discardableResult
    public func openTab(url: URL? = nil, in spaceID: UUID? = nil, pinned: Bool = false, select: Bool = true, engine: EngineKind? = nil, state: Data? = nil) -> Tab {
        let webContents = runtime(for: engine ?? defaultEngine).browser.createWebContents(EngineWebContentsConfiguration(initialURL: url ?? Self.newTabURL, restorableState: state))
        return adopt(webContents, spaceID: spaceID ?? currentSpaceID, pinned: pinned, select: select)
    }

    private func adopt(_ webContents: any EngineWebContents, spaceID: UUID, pinned: Bool, select: Bool) -> Tab {
        let tab = Tab(webContents: webContents, spaceID: spaceID, isPinned: pinned)
        // A tab a page opens comes from the page's engine.
        tab.openNewTab = { [weak self] popup in
            guard let self else { return }
            self.runtime(for: popup.engineKind).browser.takeOwnership(of: popup)
            _ = self.adopt(popup, spaceID: self.currentSpaceID, pinned: false, select: true)
        }
        // The user cannot undo a tab closed by its page. A page also reports closing after the user closes its tab, when the tab is no longer in the list.
        tab.didClose = { [weak self, weak tab] in
            guard let self, let tab, self.tabs.contains(where: { $0.id == tab.id }) else { return }
            self.closeTab(tab)
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
        tab.didFinishLoad = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.cookieSync.scheduleCopy(from: tab.engineKind)
            self.scheduleSave()
        }
        // Closing a tab whose download has not started yet would cancel it, so such a tab waits for its download to appear. The engine is still inside its callback, so closing happens on the next turn of the run loop.
        tab.didOpenOnlyDownload = { [weak self, weak tab] downloads in
            guard let self, let tab else { return }
            if downloads {
                self.downloadOnlyTabIDs.insert(tab.id)
            } else {
                DispatchQueue.main.async { [weak self, weak tab] in
                    if let self, let tab { self.closeTab(tab, remember: false) }
                }
            }
        }
        tab.requestPermission = { [weak self, weak tab] request, completion in
            guard let self, let tab else { return completion(false) }
            self.enqueueSheet(Self.permissionAlert(for: request), for: tab) { completion($0 == .alertFirstButtonReturn) }
        }
        tab.didChangeFullscreen = { [weak self, weak tab] isFullscreen in
            guard let self, let tab else { return }
            if isFullscreen {
                self.fullscreenTabID = tab.id
            } else if self.fullscreenTabID == tab.id {
                self.fullscreenTabID = nil
            }
        }
        // A link opened from a page's context menu opens behind the current tab, in the page's space and engine.
        tab.openURLInNewTab = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.openTab(url: url, in: tab.spaceID, select: false, engine: tab.engineKind)
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
        tabs.append(tab)
        if select { selectedTabID = tab.id }
        return tab
    }

    /// Moves a tab to another engine: a web contents from `kind` loads the tab's address and takes the old one's place, and the tab keeps its place, pin, space, and selection. Nothing changes when `kind` cannot start.
    public func switchEngine(of tab: Tab, to kind: EngineKind) {
        guard tab.engineKind != kind, tabs.contains(where: { $0.id == tab.id }) else { return }
        let target = runtime(for: kind)
        guard target.kind == kind, let source = runtimes[tab.engineKind] else { return }
        // The page loads in the other engine once it has this engine's cookies, so the site stays signed in.
        cookieSync.copy(from: source, to: target) { [weak self, weak tab] in
            guard let self, let tab, tab.engineKind != kind, self.tabs.contains(where: { $0.id == tab.id }) else { return }
            let old = tab.webContents
            let replacement = target.browser.createWebContents(EngineWebContentsConfiguration(initialURL: tab.url ?? Self.newTabURL))
            // Sheets and searches belong to the old page.
            self.cancelSheets(for: tab)
            if tab.id == self.selectedTabID, self.isFindBarVisible { self.hideFindBar() }
            tab.replaceWebContents(with: replacement)
            self.retire(old)
            self.scheduleSave()
        }
    }

    /// Closes a tab the user asked to close once its page agrees: a page with a `beforeunload` handler can ask to stay.
    public func requestCloseTab(_ tab: Tab) {
        // Asking means closing the browser, which would stop its downloads, so such a tab closes at once; its kept page answers the handlers with Leave when it moves to a blank page.
        guard !tab.webContents.closingStopsDownloads else {
            closeTab(tab)
            undoableCloseCount += 1
            return
        }
        tab.webContents.tryToClose { [weak self, weak tab] closing in
            guard closing, let self, let tab else { return }
            self.closeTab(tab)
            self.undoableCloseCount += 1
        }
    }

    /// Closes a tab. `remember` adds it to the closed list so that it can reopen; a tab that only pointed at a file is not worth reopening.
    public func closeTab(_ tab: Tab, remember: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if fullscreenTabID == tab.id { fullscreenTabID = nil }
        cancelSheets(for: tab)
        tabs.remove(at: index)
        tabObservers[tab.id] = nil
        retire(tab.webContents)
        if remember {
            closedTabs.append(SessionSnapshot.TabRecord(spaceID: tab.spaceID, url: tab.url, title: tab.title, customTitle: tab.customTitle, isPinned: tab.isPinned, engine: tab.engineKind))
            if closedTabs.count > 100 { closedTabs.removeFirst() }
        }
        if selectedTabID == tab.id {
            let siblings = tabs.filter { $0.spaceID == tab.spaceID }
            selectedTabID = (siblings.first { !$0.isPinned } ?? siblings.first)?.id
        }
    }

    /// An internal page is what the user sees, so it closes instead of the tab under it.
    public func closeSelectedTab() {
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

    /// Reopens the newest closed tab in its original space, or the current space if the original is gone.
    public func reopenLastClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        undoableCloseCount = max(0, undoableCloseCount - 1)
        let spaceID = spaces.contains(where: { $0.id == record.spaceID }) ? record.spaceID : currentSpaceID
        openTab(url: record.url, in: spaceID, pinned: record.isPinned, engine: record.engine).customTitle = record.customTitle
    }

    /// Pressing another key or clicking in the page makes ⌘Z undo there instead of reopening tabs.
    public func forgetUndoableCloses() {
        undoableCloseCount = 0
    }

    /// The current space's tabs in sidebar order: pinned first, then open.
    private var orderedTabs: [Tab] {
        tabs(in: currentSpaceID, pinned: true) + tabs(in: currentSpaceID, pinned: false)
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

    /// Swaps the selected tab with its neighbor in the same space and pinned or open list.
    public func moveSelectedTab(up: Bool) {
        guard let selected = selectedTab, let index = tabs.firstIndex(where: { $0.id == selected.id }) else { return }
        let siblings = tabs(in: selected.spaceID, pinned: selected.isPinned)
        guard let position = siblings.firstIndex(where: { $0.id == selected.id }) else { return }
        let target = up ? position - 1 : position + 1
        guard siblings.indices.contains(target), let neighborIndex = tabs.firstIndex(where: { $0.id == siblings[target].id }) else { return }
        tabs.swapAt(index, neighborIndex)
    }

    /// Moves a dragged tab to `target`'s place and adopts its space and pinned state, allowing moves between pinned and open lists. Within a list, dragging from above places the tab below the target.
    public func moveTab(_ id: UUID, to target: Tab) {
        guard id != target.id, let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target.id }) else { return }
        let tab = tabs[from]
        let isSameList = tab.spaceID == target.spaceID && tab.isPinned == target.isPinned
        var reordered = tabs
        reordered.remove(at: from)
        guard let targetIndex = reordered.firstIndex(where: { $0.id == target.id }) else { return }
        tab.spaceID = target.spaceID
        tab.isPinned = target.isPinned
        reordered.insert(tab, at: isSameList && from < to ? targetIndex + 1 : targetIndex)
        tabs = reordered
    }

    /// Closes unpinned tabs inactive for `ARCHArchiveAfterHours` hours (default 12; 0 disables). The selected tab counts as active now.
    public func archiveInactiveTabs() {
        guard let cutoff = Self.archiveCutoff(now: Date()) else { return }
        selectedTab?.lastActivatedAt = Date()
        for tab in tabs where !tab.isPinned && tab.lastActivatedAt < cutoff {
            closeTab(tab)
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

    /// The tab stores the pinned flag; the session republishes changes for views that group tabs by it.
    public func togglePinned(_ tab: Tab) {
        objectWillChange.send()
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

    /// Returns the input URL, a web search URL for other text, or `nil` for empty text.
    static func destination(forInput input: String) -> URL? {
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
        tabs.first { $0.id == id }?.webContents.exitFullscreen()
    }

    /// Returns keyboard focus to the page after the palette closes. Runs after the next layout pass so a new tab's view is in the window.
    private func focusPage() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.selectedTab?.webContents.view, let window = view.window else { return }
            // Keys must not reach a page an internal page covers.
            guard self.internalPage == nil else {
                window.makeFirstResponder(nil)
                return
            }
            window.makeFirstResponder(view.acceptsFirstResponder ? view : view.subviews.first)
        }
    }

    // MARK: Find in page

    /// Opens the bar and searches the current text. While the bar is open, this only returns focus to its field without moving the match.
    public func showFindBar() {
        guard selectedTab != nil else { return }
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

    // MARK: Site permissions

    /// Asks with a sheet on the page's window, or on the main window while the page is not on screen. The engine calls this from inside its own message loop, so the sheet never blocks and a request without any window is denied. The answer reaches the engine once.
    private static func permissionAlert(for request: EnginePermissionRequest) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Allow \u{201C}\(request.origin.host ?? request.origin.absoluteString)\u{201D} to \(permissionDescription(for: request.types))?"
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

    /// Queues a sheet for a tab. Sheets show one at a time and only while their tab is selected, so a background page cannot cover the page in front.
    private func enqueueSheet(_ alert: NSAlert, for tab: Tab, isPageDialog: Bool = false, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !isQuitting else { return completion(.cancel) }
        pendingSheets[tab.id, default: []].append(PendingSheet(alert: alert, isPageDialog: isPageDialog, completion: completion))
        showNextSheet()
    }

    /// Shows the selected tab's oldest waiting sheet when no sheet is on screen. Nothing runs an app-modal alert inside an engine callback.
    private func showNextSheet() {
        guard visibleSheet == nil, let tab = selectedTab, var queue = pendingSheets[tab.id], !queue.isEmpty,
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

    /// Puts away the sheet of a tab that is no longer selected, as when a link from another app opens a new tab. It shows again first when its tab is selected.
    private func deferVisibleSheet() {
        guard let visibleSheet, visibleSheet.tabID != selectedTabID, let window = visibleSheet.alert.window.sheetParent else { return }
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

    // Going to another page leaves an internal page, and reloading does not reach the page under it.
    public func goBack() {
        internalPage = nil
        selectedTab?.webContents.navigationController.goBack()
    }
    public func goForward() {
        internalPage = nil
        selectedTab?.webContents.navigationController.goForward()
    }
    /// The selected tab's earlier pages, most recent first, for the History menu.
    public func recentBackItems(limit: Int) -> [any EngineBackForwardListItem] {
        guard let list = selectedTab?.webContents.navigationController.backForwardList else { return [] }
        return Array(list.backList.reversed().prefix(limit))
    }
    /// Pages keep running while the menu is open. Use an item only in its original tab, while that tab is selected.
    public func go(to item: any EngineBackForwardListItem, inTab tabID: UUID) {
        guard let tab = selectedTab, tab.id == tabID else { return }
        internalPage = nil
        tab.webContents.navigationController.go(to: item)
    }
    public func reload() {
        guard internalPage == nil else { return }
        selectedTab?.webContents.navigationController.reload()
    }
    public func stopLoading() { selectedTab?.webContents.navigationController.stop() }
    /// Whether the selected tab's engine offers developer tools.
    public var canShowDeveloperTools: Bool { selectedTab?.webContents.devTools != nil }
    public func showDeveloperTools() { selectedTab?.webContents.devTools?.open() }
    public func focusCommandBar(from origin: CommandPaletteOrigin = .keyboard) { showCommandPalette(selectedTab == nil ? .newTab : .editCurrent, from: origin) }
    public func toggleSidebar() { isSidebarVisible.toggle() }

    // MARK: Persistence

    private func restoreTabs(_ snapshot: SessionSnapshot?) {
        guard let snapshot else { return }
        // Archive stale unpinned records before they have web contents.
        let cutoff = Self.archiveCutoff(now: Date())
        var selected: Tab?
        for (index, record) in snapshot.tabs.enumerated() where spaces.contains(where: { $0.id == record.spaceID }) {
            if !record.isPinned, let cutoff, let last = record.lastActivatedAt, last < cutoff {
                closedTabs.append(record)
                continue
            }
            let tab = openTab(url: record.url, in: record.spaceID, pinned: record.isPinned, select: false, engine: record.engine, state: record.state)
            tab.lastActivatedAt = record.lastActivatedAt ?? Date()
            tab.customTitle = record.customTitle
            tab.isRestored = true
            // Loading a restored page does not count as a visit.
            tab.recordedURL = record.url
            if index == snapshot.selectedTabIndex { selected = tab }
        }
        selectedTabID = selected?.id ?? tabs.first { $0.spaceID == currentSpaceID }?.id
    }

    private func observeChanges() {
        Publishers.Merge4($tabs.map { _ in () }, $spaces.map { _ in () }, $favorites.map { _ in () }, $currentSpaceID.map { _ in () })
            .merge(with: $selectedTabID.map { _ in () })
            .merge(with: $closedTabs.map { _ in () })
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
                        tabs: tabs.map { SessionSnapshot.TabRecord(spaceID: $0.spaceID, url: $0.url, title: $0.title, customTitle: $0.customTitle, isPinned: $0.isPinned, lastActivatedAt: $0.lastActivatedAt, engine: $0.engineKind, state: $0.webContents.restorableState) },
                        selectedTabIndex: tabs.firstIndex { $0.id == selectedTabID }, closedTabs: closedTabs)
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
            for tab in self.tabs where finishedTabIDs.contains(tab.id) { self.closeTab(tab, remember: false) }
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
