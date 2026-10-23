// Owns the engine application, one profile, and one browser for the window. Also owns sidebar state: spaces, favorites, tabs, and the closed-tab list. Archives inactive tabs on a timer.
import AppKit
import ARCHEngine
import Combine
import Foundation

public final class BrowserSession: ObservableObject {
    public let application: any EngineApplication
    public let context: any EngineBrowserContext
    public private(set) var browser: (any EngineBrowser)!
    @Published public private(set) var tabs: [Tab] = []
    @Published public private(set) var spaces: [Space] = []
    @Published public private(set) var favorites: [Favorite] = []
    @Published public var currentSpaceID: UUID
    /// Selecting a tab also switches to its space so the sidebar and page show the same space.
    @Published public var selectedTabID: UUID? {
        didSet {
            selectedTab?.lastActivatedAt = Date()
            if let tab = selectedTab, tab.spaceID != currentSpaceID { currentSpaceID = tab.spaceID }
            // Switching tabs ends the search because it belongs to one page.
            if isFindBarVisible, oldValue != selectedTabID {
                tabs.first { $0.id == oldValue }?.webContents.stopFind()
                isFindBarVisible = false
                findResult = nil
            }
            showNextSheet()
        }
    }
    /// The downloads popover opens from the sidebar, so hiding the sidebar closes it.
    @Published public var isSidebarVisible = true {
        didSet { if !isSidebarVisible { isDownloadsPopoverVisible = false } }
    }
    /// `nil` when the command palette is hidden.
    @Published public var commandPaletteMode: CommandPaletteMode?
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
    @Published public var isDownloadsPopoverVisible = false
    /// The last 100 closed or archived tabs, oldest first. Reopening takes the newest.
    @Published private var closedTabs: [SessionSnapshot.TabRecord] = []
    private var archiveTimer: Timer?

    public static let searchURL = URL(string: "https://www.google.com/search")!
    public static let newTabURL = URL(string: "https://www.google.com")!

    private let store: SessionStore
    private var cancellables: Set<AnyCancellable> = []
    private var tabObservers: [UUID: AnyCancellable] = [:]
    /// Tabs that only ever pointed at a file. They close once the engine creates the download.
    private var downloadOnlyTabIDs: Set<UUID> = []
    /// Sheets that tabs asked for, oldest first. They wait while their tab is not selected.
    private var pendingSheets: [UUID: [PendingSheet]] = [:]
    private var visibleSheet: (tabID: UUID, alert: NSAlert)?

    public init(engine: any Engine, userDataDirectory: URL) throws {
        let configuration = EngineApplicationConfiguration(userDataDirectory: userDataDirectory,
                                                           cacheDirectory: userDataDirectory.appendingPathComponent("Cache"))
        application = try engine.makeApplication(configuration: configuration)
        var created: (any EngineBrowserContext)?
        let attributes = EngineBrowserContextAttributes(id: EngineBrowserContextID(rawValue: "default"), userVisibleName: "Default", type: .regular)
        application.createBrowserContext(attributes) { created = try? $0.get() }
        guard let context = created else { throw SessionError.contextUnavailable }
        self.context = context
        store = SessionStore(directory: userDataDirectory)
        let snapshot = store.load()
        let restoredSpaces = snapshot?.spaces ?? []
        let initialSpaces = restoredSpaces.isEmpty ? [Space(name: "Personal")] : restoredSpaces
        spaces = initialSpaces
        currentSpaceID = initialSpaces.first { $0.id == snapshot?.currentSpaceID }?.id ?? initialSpaces[0].id
        favorites = snapshot?.favorites ?? []
        closedTabs = snapshot?.closedTabs ?? []
        application.run()
        browser = application.createBrowser(EngineBrowserCreateParams(initialBounds: .zero), context: context, delegate: self, window: nil)
        context.downloads.delegate = self
        downloads = context.downloads.items.map(DownloadEntry.init)
        restoreTabs(snapshot)
        observeChanges()
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.archiveInactiveTabs() }
        // Tabs restored at launch can ask before the window exists; their sheets show once it does.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)
            .sink { [weak self] _ in self?.showNextSheet() }
            .store(in: &cancellables)
    }

    public enum SessionError: Error {
        case contextUnavailable
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
        let space = Space(name: "Space \(spaces.count + 1)", tint: tint)
        spaces.append(space)
        switchToSpace(space.id)
    }

    public func switchToSpace(_ id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
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

    // MARK: Favorites

    public func addFavorite(_ tab: Tab) {
        guard let url = tab.url, !favorites.contains(where: { $0.url == url }) else { return }
        favorites.append(Favorite(url: url, title: tab.displayTitle))
    }

    public func removeFavorite(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
    }

    /// Reuses an open tab for the same site in the current space. Opens a new tab if none matches.
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

    @discardableResult
    public func openTab(url: URL? = nil, in spaceID: UUID? = nil, pinned: Bool = false, select: Bool = true) -> Tab {
        let webContents = browser.createWebContents(EngineWebContentsConfiguration(initialURL: url ?? Self.newTabURL))
        return adopt(webContents, spaceID: spaceID ?? currentSpaceID, pinned: pinned, select: select)
    }

    private func adopt(_ webContents: any EngineWebContents, spaceID: UUID, pinned: Bool, select: Bool) -> Tab {
        let tab = Tab(webContents: webContents, spaceID: spaceID, isPinned: pinned)
        tab.openNewTab = { [weak self] popup in
            guard let self else { return }
            self.browser.takeOwnership(of: popup)
            _ = self.adopt(popup, spaceID: self.currentSpaceID, pinned: false, select: true)
        }
        tab.didClose = { [weak self, weak tab] in
            if let self, let tab { self.closeTab(tab) }
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
        tab.presentAlert = { [weak self, weak tab] alert, completion in
            guard let self, let tab else { return completion(.cancel) }
            self.enqueueSheet(alert, for: tab, completion: completion)
        }
        // The session republishes changes to the selected tab so views that read the tab through the session refresh.
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self, weak tab] _ in
            guard let self else { return }
            if tab?.id == self.selectedTabID { self.objectWillChange.send() }
            self.scheduleSave()
        }
        tabs.append(tab)
        if select { selectedTabID = tab.id }
        return tab
    }

    /// Closes a tab. `remember` adds it to the closed list so that it can reopen; a tab that only pointed at a file is not worth reopening.
    public func closeTab(_ tab: Tab, remember: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        cancelSheets(for: tab)
        tabs.remove(at: index)
        tabObservers[tab.id] = nil
        browser.closeWebContents(tab.webContents)
        if remember {
            closedTabs.append(SessionSnapshot.TabRecord(spaceID: tab.spaceID, url: tab.url, title: tab.title, isPinned: tab.isPinned))
            if closedTabs.count > 100 { closedTabs.removeFirst() }
        }
        if selectedTabID == tab.id {
            let siblings = tabs.filter { $0.spaceID == tab.spaceID }
            selectedTabID = (siblings.first { !$0.isPinned } ?? siblings.first)?.id
        }
    }

    public func closeSelectedTab() {
        selectedTab.map { closeTab($0) }
    }

    /// Keeps pinned tabs and the selected tab; closes the rest of the selected tab's space.
    public func closeOtherTabs() {
        guard let selected = selectedTab else { return }
        for tab in tabs where tab.spaceID == selected.spaceID && !tab.isPinned && tab.id != selected.id {
            closeTab(tab)
        }
    }

    /// Restores the newest closed tab into its space, or the current space when that space is gone.
    public func reopenLastClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        let spaceID = spaces.contains(where: { $0.id == record.spaceID }) ? record.spaceID : currentSpaceID
        openTab(url: record.url, in: spaceID, pinned: record.isPinned)
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

    public func selectAdjacentTab(forward: Bool) {
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = ordered[(index + (forward ? 1 : ordered.count - 1)) % ordered.count].id
    }

    /// Swaps the selected tab with its neighbor in its own list, pinned or open, within its space.
    public func moveSelectedTab(up: Bool) {
        guard let selected = selectedTab, let index = tabs.firstIndex(where: { $0.id == selected.id }) else { return }
        let siblings = tabs(in: selected.spaceID, pinned: selected.isPinned)
        guard let position = siblings.firstIndex(where: { $0.id == selected.id }) else { return }
        let target = up ? position - 1 : position + 1
        guard siblings.indices.contains(target), let neighborIndex = tabs.firstIndex(where: { $0.id == siblings[target].id }) else { return }
        tabs.swapAt(index, neighborIndex)
    }

    /// Closes unpinned tabs not activated within `ARCHArchiveAfterHours` hours (default 12; 0 disables). The selected tab counts as active now.
    public func archiveInactiveTabs() {
        guard let cutoff = Self.archiveCutoff(now: Date()) else { return }
        selectedTab?.lastActivatedAt = Date()
        for tab in tabs where !tab.isPinned && tab.lastActivatedAt < cutoff {
            closeTab(tab)
        }
    }

    /// `nil` when archiving is disabled.
    private static func archiveCutoff(now: Date) -> Date? {
        let defaults = UserDefaults.standard
        let hours = defaults.object(forKey: "ARCHArchiveAfterHours") == nil ? 12 : defaults.integer(forKey: "ARCHArchiveAfterHours")
        guard hours > 0 else { return nil }
        return now.addingTimeInterval(-TimeInterval(hours) * 3600)
    }

    /// The tab stores the pinned flag. The session republishes the change for views that group tabs by this flag.
    public func togglePinned(_ tab: Tab) {
        objectWillChange.send()
        tab.isPinned.toggle()
    }

    /// Loads a URL when the text parses as one, otherwise runs a web search.
    public func navigate(to input: String) {
        guard let url = Self.destination(forInput: input) else { return }
        if let tab = selectedTab {
            tab.webContents.navigationController.load(URLRequest(url: url))
        } else {
            openTab(url: url)
        }
    }

    /// Returns a URL only for a full URL with a scheme and host, or a dotted host without spaces. Adds `https://` to a dotted host.
    public static func url(forInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = URL(string: text), parsed.scheme != nil, parsed.host != nil { return parsed }
        if !text.contains(" "), let parsed = URL(string: "https://\(text)"), parsed.host?.contains(".") == true { return parsed }
        return nil
    }

    /// Returns the input URL or, if the text is not a URL, a web search URL. Returns `nil` for empty text.
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
        guard let mode = commandPaletteMode, let url = Self.destination(forInput: input) else { return }
        switch mode {
        case .editCurrent where selectedTab != nil: navigate(to: input)
        case .editCurrent, .newTab: openTab(url: url)
        }
    }

    /// Returns keyboard focus to the page after the palette closes. Runs after the next layout pass so a newly opened tab's view is in the window.
    private func focusPage() {
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.selectedTab?.webContents.view, let window = view.window else { return }
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

    /// Shows the sidebar first if hidden because the downloads popover opens from it.
    public func toggleDownloadsPopover() {
        if !isSidebarVisible { isSidebarVisible = true }
        isDownloadsPopoverVisible.toggle()
    }

    public func removeDownload(_ entry: DownloadEntry) {
        entry.item.remove()
    }

    public func clearFinishedDownloads() {
        downloads.filter(\.isFinished).forEach { $0.item.remove() }
    }

    /// The folder set in the profile preferences, falling back to the user's Downloads folder, then the temporary folder.
    private var downloadsDirectory: URL {
        context.preferences.downloadFilePath
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
        let completion: (NSApplication.ModalResponse) -> Void
    }

    /// Queues a sheet for a tab. Sheets show one at a time and only while their tab is selected, so a background page cannot cover the page in front.
    private func enqueueSheet(_ alert: NSAlert, for tab: Tab, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        pendingSheets[tab.id, default: []].append(PendingSheet(alert: alert, completion: completion))
        showNextSheet()
    }

    /// Shows the selected tab's oldest waiting sheet when no sheet is on screen. Nothing runs an app-modal alert inside an engine callback.
    private func showNextSheet() {
        guard visibleSheet == nil, let tab = selectedTab, var queue = pendingSheets[tab.id], !queue.isEmpty,
              let window = tab.webContents.view.window ?? NSApp.mainWindow else { return }
        let sheet = queue.removeFirst()
        pendingSheets[tab.id] = queue.isEmpty ? nil : queue
        visibleSheet = (tab.id, sheet.alert)
        sheet.alert.beginSheetModal(for: window) { [weak self] response in
            self?.visibleSheet = nil
            sheet.completion(response)
            self?.showNextSheet()
        }
    }

    /// Gives a closing tab's sheets the safe answer, `.cancel`, including the one on screen.
    private func cancelSheets(for tab: Tab) {
        if let visibleSheet, visibleSheet.tabID == tab.id, let window = visibleSheet.alert.window.sheetParent {
            window.endSheet(visibleSheet.alert.window, returnCode: .cancel)
        }
        pendingSheets.removeValue(forKey: tab.id)?.forEach { $0.completion(.cancel) }
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

    public func goBack() { selectedTab?.webContents.navigationController.goBack() }
    public func goForward() { selectedTab?.webContents.navigationController.goForward() }
    public func reload() { selectedTab?.webContents.navigationController.reload() }
    public func stopLoading() { selectedTab?.webContents.navigationController.stop() }
    public func focusCommandBar(from origin: CommandPaletteOrigin = .keyboard) { showCommandPalette(selectedTab == nil ? .newTab : .editCurrent, from: origin) }
    public func toggleSidebar() { isSidebarVisible.toggle() }

    // MARK: Persistence

    private func restoreTabs(_ snapshot: SessionSnapshot?) {
        guard let snapshot else { return }
        // Stale unpinned records are archived here, before any web contents exists for them.
        let cutoff = Self.archiveCutoff(now: Date())
        var selected: Tab?
        for (index, record) in snapshot.tabs.enumerated() where spaces.contains(where: { $0.id == record.spaceID }) {
            if !record.isPinned, let cutoff, let last = record.lastActivatedAt, last < cutoff {
                closedTabs.append(record)
                continue
            }
            let tab = openTab(url: record.url, in: record.spaceID, pinned: record.isPinned, select: false)
            tab.lastActivatedAt = record.lastActivatedAt ?? Date()
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
        store.scheduleSave { [weak self] in self?.snapshot() ?? SessionSnapshot(spaces: [], currentSpaceID: UUID(), favorites: [], tabs: [], selectedTabIndex: nil) }
    }

    public func saveNow() {
        store.saveNow(snapshot())
    }

    private func snapshot() -> SessionSnapshot {
        SessionSnapshot(spaces: spaces, currentSpaceID: currentSpaceID, favorites: favorites,
                        tabs: tabs.map { SessionSnapshot.TabRecord(spaceID: $0.spaceID, url: $0.url, title: $0.title, isPinned: $0.isPinned, lastActivatedAt: $0.lastActivatedAt) },
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
}

extension BrowserSession: EngineBrowserDelegate {
    public func browser(_ browser: any EngineBrowser, didCreateNewWebContents webContents: any EngineWebContents, isActive: Bool) {
        _ = adopt(webContents, spaceID: currentSpaceID, pinned: false, select: isActive)
    }
}

extension BrowserSession: EngineDownloadsDelegate {
    public func downloads(_ downloads: any EngineDownloads, didInitializeWith items: [any EngineDownloadItem]) {
        self.downloads = items.map(DownloadEntry.init)
    }

    /// A new download opens the downloads list so the user can see it start. The list stays closed when the sidebar it opens from is hidden.
    public func downloads(_ downloads: any EngineDownloads, didCreate item: any EngineDownloadItem) {
        self.downloads.append(DownloadEntry(item: item))
        if isSidebarVisible { isDownloadsPopoverVisible = true }
        let finishedTabIDs = downloadOnlyTabIDs
        downloadOnlyTabIDs.removeAll()
        // The engine is still choosing the file's destination, so the tabs close once that callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for tab in self.tabs where finishedTabIDs.contains(tab.id) { self.closeTab(tab, remember: false) }
        }
    }

    /// The session also announces state changes because the sidebar icon and Clear button read download entry state through it.
    public func downloads(_ downloads: any EngineDownloads, didUpdate item: any EngineDownloadItem) {
        objectWillChange.send()
        self.downloads.first { $0.id == item.id }?.refresh()
    }

    public func downloads(_ downloads: any EngineDownloads, didRemove item: any EngineDownloadItem) {
        self.downloads.removeAll { $0.id == item.id }
    }

    /// Saves in the downloads folder with an unused name, or opens a save panel when the profile is set to ask.
    public func downloads(_ downloads: any EngineDownloads, determineFilenameFor item: any EngineDownloadItem, defaultFilename: String, completion: @escaping (URL?) -> Void) {
        guard context.preferences.promptForDownloadPath else {
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
