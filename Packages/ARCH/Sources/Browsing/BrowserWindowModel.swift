// The state of one browser window and the commands that act on it. A window shows its current space, its selected tab with that tab's split view, an internal page, a page in fullscreen, the preview panel, the page reader, the question popover, and one tab's sheet, and it holds what the user does there: the command palette, find, renaming, region capture, the tab switcher, the docked developer tools, and sharing. The session owns everything else: Personas, spaces, favorites, tabs, folders, split views, the closed list, downloads, the sheets waiting for their tabs, the page reader's conversations, engines, and persistence.
import AI
import AppKit
import ARCHEngine
import Combine
import Foundation
import PDFKit
import Plugins
import SwiftUI
import UniformTypeIdentifiers

/// The state of one browser window: what it shows and what the user is doing in it. Its commands read and change the user's data through the session.
public final class BrowserWindowModel: ObservableObject {
    unowned let session: BrowserSession

    /// The space the sidebar shows.
    @Published public var currentSpaceID: UUID
    /// Selecting a tab switches to its space so the sidebar and page match. Another window that shows the tab gives it up first (window rule 2).
    @Published public var selectedTabID: UUID? {
        didSet {
            // The window shows its selected tab, and another window that shows the tab lets go of its sheet, page fullscreen, and docked tools before this window takes them.
            updateShownTabs()
            session.release(selectedTab, except: self)
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
                session.allTabs.first { $0.id == oldValue }?.webContents.stopFind()
                isFindBarVisible = false
                findResult = nil
            }
            // The question popover belongs to the page it opened over.
            if oldValue != selectedTabID { MainActor.assumeIsolated { closePageQuestion() } }
            session.sheets.deferSheet(of: self)
            session.sheets.showNext()
            session.windowDidSelect(self)
            devToolsDock.track(selectedTab?.webContents.devTools)
            followSelectedTab()
            focusSelectedPane()
        }
    }
    @Published public var isSidebarVisible = true
    /// The library takes the place of the space pages in the sidebar: downloads first, then other tools. Opening it marks every finished download as seen.
    @Published public var isLibraryVisible = false {
        didSet { if isLibraryVisible { session.markDownloadsSeen() } }
    }
    /// Where the selected tab's developer tools show.
    public let devToolsDock = DevToolsDock()
    /// The AppKit window, set when it is created. Sheets, printing, export, sharing, and Clear Site Data use it.
    public weak var nsWindow: NSWindow?
    /// The internal page covering the page area, opened by its address from the command palette.
    @Published public private(set) var internalPage: InternalPage?
    /// The tab whose page fills the window in fullscreen. Only engines that leave the transition to the app report it; WebKit shows fullscreen in its own window.
    @Published public private(set) var fullscreenTabID: UUID? {
        didSet {
            // The other panes of a split view leave the screen while the selected page fills the window, and their sheets wait until the panes return.
            session.sheets.deferSheet(of: self)
            session.sheets.showNext()
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
    /// The space whose name is being edited in the sidebar.
    @Published public var renamingSpaceID: UUID?
    /// The tab whose name is being edited in the sidebar.
    @Published public var renamingTabID: UUID?
    /// Republishes the selected tab's changes, so that views that read the tab through the window refresh.
    private var selectedTabObserver: AnyCancellable?

    init(session: BrowserSession, currentSpaceID: UUID) {
        self.session = session
        self.currentSpaceID = currentSpaceID
    }

    // MARK: Spaces

    public var currentSpace: Space {
        session.spaces.first { $0.id == currentSpaceID } ?? session.spaces[0]
    }

    /// Adds a space to the current space's Persona and shows it.
    public func addSpace() {
        switchToSpace(session.makeSpace(in: currentSpace.resolvedPersonaID).id)
    }

    public func switchToSpace(_ id: UUID) {
        guard session.spaces.contains(where: { $0.id == id }) else { return }
        isLibraryVisible = false
        // A selected favorite's tab belongs to no space and shows in the current one. It stays selected while the space stays, and stays open behind a new space's own tab.
        let selectedSpaceID = selectedTab.map { $0.spaceID ?? currentSpaceID }
        currentSpaceID = id
        if selectedSpaceID != id { selectedTabID = firstFreeTab(inSpace: id)?.id }
    }

    /// The first tab row of the space that the sidebar shows and no other window shows, open tabs before pinned ones (window rule 3). Only a space whose free tabs all sit in collapsed folders gives a hidden tab.
    func firstFreeTab(inSpace id: UUID) -> Tab? {
        let spaceTabs = (session.tabs(in: id, pinned: false) + session.tabs(in: id, pinned: true)).filter { !isShownInAnotherWindow($0) }
        return spaceTabs.first { !session.isInCollapsedFolder($0) } ?? spaceTabs.first
    }

    public func switchToAdjacentSpace(forward: Bool) {
        let spaces = session.spaces
        guard let index = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        let next = (index + (forward ? 1 : spaces.count - 1)) % spaces.count
        switchToSpace(spaces[next].id)
    }

    /// Keeps the old name when the new one is empty.
    public func renameSpace(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { session.updateSpace(id) { $0.name = trimmed } }
        renamingSpaceID = nil
    }

    /// An empty name or the page's own title restores the page's title. The session saves the name, as it saves every change to a tab.
    public func renameTab(_ id: UUID, to name: String) {
        if let tab = session.tabs.first(where: { $0.id == id }) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.customTitle = trimmed.isEmpty || trimmed == tab.pageTitle ? nil : trimmed
        }
        endRenaming(id)
    }

    /// Does not interrupt renaming another tab that may have started meanwhile.
    public func endRenaming(_ id: UUID) {
        if renamingTabID == id { renamingTabID = nil }
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
        session.updateSpace(id) { $0.homeURL = url }
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

    /// Selects the favorite's own tab, which the session opens if needed.
    public func openFavorite(_ favorite: Favorite) {
        selectedTabID = session.openTab(for: favorite).id
    }

    /// The favorite whose tab is selected.
    public var selectedFavoriteID: UUID? {
        session.favoriteTabs.first { $0.value.id == selectedTabID }?.key
    }

    // MARK: Previews

    /// The page in the preview panel over the page area, or nil while no panel shows. Its web contents belongs to no tab.
    @Published private(set) var preview: PagePreview?

    /// Whether an internal page or the preview panel covers the selected tab's page, so that the commands for the page in front leave the tab alone.
    private var isSelectedPageCovered: Bool { internalPage != nil || preview != nil }

    /// Previews a favorite in the default engine and the favorite's Persona, which opening the favorite would use.
    func previewFavorite(_ favorite: Favorite) {
        showPreview(of: favorite.url, engine: session.defaultEngine, in: favorite.resolvedPersonaID)
    }

    /// Shows `url` in the panel, in place of any other preview, in a web contents of the Persona's runtime for `engine` that no tab owns. A preview that opened with the same address stays as it is. The page cannot download, so closing the panel always closes the page at once.
    func showPreview(of url: URL, engine: EngineKind, in personaID: Persona.ID) {
        guard preview?.openedURL != url else { return }
        closePreview()
        // The panel covers the page that a search or a region capture belongs to, so both end.
        hideFindBar()
        cancelRegionCapture()
        let runtime = session.runtime(for: engine, in: personaID)
        let webContents = runtime.browser.createWebContents(EngineWebContentsConfiguration(initialURL: url, disallowDownloads: true))
        let preview = PagePreview(webContents: webContents, personaID: personaID, openedURL: url)
        // A page the preview opens, as for a link to a new window, comes from the preview's runtime, so it becomes a selected tab of the preview's Persona and takes the panel's place. The engine is still in its callback, so the panel closes on the next turn of the run loop.
        preview.openNewTab = { [weak self, weak preview] popup in
            guard let self else { return }
            runtime.browser.takeOwnership(of: popup)
            self.selectedTabID = self.session.adopt(popup, spaceID: self.currentSpaceID, personaID: personaID, pinned: false, select: false).id
            DispatchQueue.main.async { [weak self] in
                if let self, let preview, self.preview === preview { self.closePreview() }
            }
        }
        // A preview asks the user nothing, so its page's permission requests are denied. Chromium would keep the denial for the site, so its kept answers then return to the remembered ones.
        preview.requestPermission = { [weak self] request, completion in
            completion(false)
            DispatchQueue.main.async { self?.session.applyRememberedPermissions(for: request, to: runtime.context) }
        }
        preview.didClose = { [weak self] in self?.closePreview() }
        self.preview = preview
    }

    /// Opens the page the panel shows, wherever the user went in it, in a new tab of the same engine and Persona with its page focused, and closes the panel.
    func openPreviewInTab() {
        guard let preview else { return }
        closePreview()
        let webContents = session.makeWebContents(url: preview.url, engine: preview.webContents.engineKind, state: nil, in: preview.personaID)
        selectedTabID = session.adopt(webContents, spaceID: currentSpaceID, personaID: preview.personaID, pinned: false, select: false).id
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
        session.retire(preview.webContents, of: preview.personaID)
        if hadFocus { focusPage(leaving: view) }
    }

    // MARK: Tabs

    public var selectedTab: Tab? {
        session.tabs.first { $0.id == selectedTabID } ?? session.favoriteTabs.values.first { $0.id == selectedTabID }
    }

    /// The tabs whose pages the window shows, left to right: its selected tab and each other pane of its split view that no other window shows. At most one window shows a tab (window rule 1), because a page's view has one superview.
    @Published private(set) var shownTabIDs: [UUID] = []

    /// Whether the window shows `tab`, as its selected tab or a pane of its split view.
    func shows(_ tab: Tab) -> Bool {
        shownTabIDs.contains(tab.id)
    }

    /// Whether another window shows `tab`. Selection this window makes on its own passes such a tab by (window rule 3).
    func isShownInAnotherWindow(_ tab: Tab) -> Bool {
        session.windows.contains { $0 !== self && $0.shows(tab) }
    }

    /// Follows a change of the selection or of the split views: the window keeps its selected tab and the panes it shows already, and takes each other pane that no other window shows.
    func updateShownTabs() {
        let ids = paneTabs.filter { $0.id == selectedTabID || shownTabIDs.contains($0.id) || !isShownInAnotherWindow($0) }.map(\.id)
        if ids != shownTabIDs { shownTabIDs = ids }
    }

    /// Lets another window take `tab` (window rule 2). The window selects its fallback when `tab` is its selected tab. When `tab` is another pane of its split view, the window keeps its selection and leaves the pane to the other window, ending the page's fullscreen and putting away its sheet here first.
    func giveUp(_ tab: Tab) {
        shownTabIDs.removeAll { $0 == tab.id }
        if tab.id == selectedTabID {
            selectedTabID = fallbackTab(excluding: tab.id)?.id
        } else {
            if fullscreenTabID == tab.id { exitPageFullscreen() }
            session.sheets.deferSheet(of: self)
        }
    }

    /// The tab the window selects when another window takes its tab: the most recent of `recentTabs` other than `excluding` that no other window shows, or nil for the empty page.
    func fallbackTab(excluding id: UUID) -> Tab? {
        recentTabs.first { $0.id != id && !isShownInAnotherWindow($0) }
    }

    /// Opens a tab at `url` in the current space and the default engine, and selects it.
    func openTab(url: URL) {
        selectedTabID = session.openTab(url: url, in: currentSpaceID, select: false).id
    }

    private func followSelectedTab() {
        selectedTabObserver = selectedTab?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Records whether the tab's page fills the window.
    func setPageFullscreen(_ isFullscreen: Bool, of tab: Tab) {
        if isFullscreen {
            fullscreenTabID = tab.id
        } else if fullscreenTabID == tab.id {
            fullscreenTabID = nil
        }
    }

    /// The preview panel or an internal page is what the user sees, so it closes instead of the tab under it. A window with no tab selected closes itself while another browser window stays open.
    public func closeSelectedTab() {
        if preview != nil { return closePreview() }
        if internalPage != nil { return closeInternalPage() }
        if let tab = selectedTab { return session.requestCloseTab(tab) }
        if session.windows.count > 1 { nsWindow?.performClose(nil) }
    }

    /// Closes other tabs in the selected tab's space, keeping pinned tabs.
    public func closeOtherTabs() {
        guard let selected = selectedTab else { return }
        for tab in session.tabs where tab.spaceID == selected.spaceID && !tab.isPinned && tab.id != selected.id {
            session.requestCloseTab(tab)
        }
    }

    /// The current space's tab rows in sidebar order: pinned first, then open. A collapsed folder shows only the selected tab.
    private var orderedTabs: [Tab] {
        (session.tabs(in: currentSpaceID, pinned: true) + session.tabs(in: currentSpaceID, pinned: false)).filter { $0.id == selectedTabID || !session.isInCollapsedFolder($0) }
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
        selectedTab.map { session.moveTab($0, up: up) }
    }

    /// Loads a URL when the text parses as one, otherwise runs a web search.
    public func navigate(to input: String) {
        guard let url = BrowserSession.destination(forInput: input) else { return }
        if let tab = selectedTab {
            tab.forgetExternalAppDecline()
            tab.webContents.navigationController.load(URLRequest(url: url))
        } else {
            openTab(url: url)
        }
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
        guard let mode = commandPaletteMode, let url = BrowserSession.destination(forInput: input) else { return }
        internalPage = nil
        switch mode {
        case .editCurrent where selectedTab != nil: navigate(to: input)
        case .editCurrent, .newTab: openTab(url: url)
        }
    }

    public func focusCommandBar(from origin: CommandPaletteOrigin = .keyboard) { showCommandPalette(selectedTab == nil ? .newTab : .editCurrent, from: origin) }

    public func closeInternalPage() {
        internalPage = nil
        focusPage()
    }

    /// Ends the fullscreen of the page that fills the window, as Escape does.
    public func exitPageFullscreen() {
        guard let id = fullscreenTabID else { return }
        fullscreenTabID = nil
        session.allTabs.first { $0.id == id }?.webContents.exitFullscreen()
    }

    /// Returns keyboard focus to the page after the palette or the question popover closes. Runs after the next layout pass so a new tab's view is in the window, and leaves a page that another window has taken in the meantime alone. Given the view that focus is `leaving`, focus moves only while it is still there or nowhere, so a field the user clicked in the meantime keeps it.
    func focusPage(leaving previous: NSView? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.selectedTab?.webContents.view, let window = view.window, window === self.nsWindow else { return }
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
            let isFocusInOtherPane = self.tabsOnScreen.contains { pane in
                let view = pane.webContents.view
                return pane.id != self.selectedTabID && (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
            }
            if isFocusInOtherPane { self.focusPage() }
        }
    }

    // MARK: Plugins

    /// Closes the palette and runs a plugin command chosen in it on the selected tab.
    @MainActor public func runPluginCommand(_ command: PluginCommandRef) {
        guard let plugins = session.plugins else { return }
        let invocation = PluginInvocation(tab: selectedPluginTab)
        dismissCommandPalette()
        Task { await plugins.run(command, invocation) }
    }

    /// The selected tab before the manager applies a plugin's grant. Plugins see no tab under an internal page.
    private var selectedPluginTab: PluginTab? {
        guard internalPage == nil, let tab = selectedTab else { return nil }
        return PluginTab(id: tab.id, spaceID: tab.spaceID, title: tab.displayTitle, url: tab.url, engine: tab.engineKind, isPinned: tab.isPinned, isSelected: true)
    }

    // MARK: Page reader and questions

    /// Whether the page reader shows beside the page.
    @Published public private(set) var isPageReaderVisible = false
    /// The question popover over the selected tab's page while it is open. It closes when another tab is selected or the tab loads another page.
    @Published private(set) var pageQuestion: PageQuestion?

    /// The reader opens beside a selected tab that no internal page covers, and closes at any time.
    public var canTogglePageReader: Bool {
        isPageReaderVisible || (selectedTab != nil && internalPage == nil)
    }

    /// Shows or hides the page reader. Showing it summarizes the selected tab's page unless its conversation has begun or AI is off for its site; hiding it has the session stop the reader's replies (`BrowserSession.pageReaderDidHide`).
    @MainActor public func togglePageReader() {
        withAnimation(SidebarView.pageSpring) { isPageReaderVisible.toggle() }
        if isPageReaderVisible {
            selectedTab.map(session.pageAssistant.readerDidShow)
        } else {
            session.pageReaderDidHide(in: self)
        }
    }

    /// Whether the palette offers Ask About This Page: a provider can answer, and the selected tab shows a page that no internal page covers.
    @MainActor var canAskAboutPage: Bool {
        guard internalPage == nil, let url = selectedTab?.url else { return false }
        return PageAssistant.isQuestionAvailable && PageAssistant.canRead(url)
    }

    @MainActor func askAboutPage() {
        guard canAskAboutPage, let tab = selectedTab else { return }
        openPageQuestion(in: tab, selection: nil)
    }

    /// From the page's context menu, so the tab is this window's selected tab: a click in another pane selects that pane's tab first.
    @MainActor func askAboutSelection(_ text: String, in tab: Tab) {
        guard PageAssistant.isQuestionAvailable, let url = tab.url, PageAssistant.canRead(url) else { return }
        openPageQuestion(in: tab, selection: AISelection(pageURL: url, pageTitle: tab.pageTitle, text: text))
    }

    /// Closes the popover the user dismissed and gives the page keyboard focus again.
    @MainActor func dismissPageQuestion() {
        closePageQuestion()
        focusPage()
    }

    /// Closes the popover when it is about the tab's page.
    @MainActor func closePageQuestion(ofTab id: UUID) {
        if pageQuestion?.tabID == id { closePageQuestion() }
    }

    @MainActor private func openPageQuestion(in tab: Tab, selection: AISelection?) {
        pageQuestion?.conversation.cancel()
        pageQuestion = PageQuestion(tabID: tab.id, selection: selection, conversation: session.pageAssistant.makeQuestionConversation(forTab: tab.id))
    }

    @MainActor private func closePageQuestion() {
        guard let pageQuestion else { return }
        pageQuestion.conversation.cancel()
        self.pageQuestion = nil
    }

    // MARK: Sheets

    /// The sheet the window shows for a tab on its screen. The session's sheet queue sets and clears it.
    var visibleSheet: TabSheet?

    /// The tabs whose pages the window shows now, the selected tab first: the panes of its split view that it shows, or the selected tab alone while its page fills the window. Their sheets can show on this window. None once the window has let go of its tabs as it closes.
    var tabsOnScreen: [Tab] {
        guard let selected = selectedTab, shows(selected) else { return [] }
        if fullscreenTabID == selected.id { return [selected] }
        return [selected] + paneTabs.filter { $0.id != selected.id && shows($0) }
    }

    // MARK: Closing

    /// The window's space and selected tab, which the session keeps once the window closes.
    var record: WindowRecord { WindowRecord(currentSpaceID: currentSpaceID, selectedTabID: selectedTabID) }

    /// Lets go of what the window shows as it closes, so that other windows can show its tabs, which stay open (window rule 5): the page reader's replies about them, the palette, find, region capture, page fullscreen, the preview panel, the question popover, the sheet, which shows again in the next window that shows its tab, and the docked developer tools.
    @MainActor func prepareToClose() {
        if isPageReaderVisible { session.pageReaderDidHide(in: self) }
        commandPaletteMode = nil
        hideFindBar()
        cancelRegionCapture()
        exitPageFullscreen()
        closePreview()
        closePageQuestion()
        shownTabIDs = []
        session.sheets.deferSheet(of: self)
        devToolsDock.track(nil)
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

    // MARK: Sidebar and library

    public func toggleSidebar() { isSidebarVisible.toggle() }

    /// Shows the sidebar first if hidden because the library opens in it. With the sidebar hidden, the library always opens.
    public func toggleLibrary() {
        guard isSidebarVisible else {
            isSidebarVisible = true
            isLibraryVisible = true
            return
        }
        isLibraryVisible.toggle()
    }

    // MARK: Navigation

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

    // MARK: Developer tools

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

    // MARK: Zoom

    /// The factors that zooming in and out steps through, alike on both engines.
    private static let zoomFactors: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// Zooming needs a selected tab that no internal page or preview covers.
    public var canZoom: Bool { selectedTab != nil && !isSelectedPageCovered }

    public func zoomIn() { changeZoom { current in Self.zoomFactors.first { $0 > current + 0.01 } } }
    public func zoomOut() { changeZoom { current in Self.zoomFactors.last { $0 < current - 0.01 } } }
    public func resetZoom() { changeZoom { _ in 1 } }

    /// Sets the selected tab's zoom from its current factor. The session remembers it for the page's host.
    private func changeZoom(_ next: (Double) -> Double?) {
        guard canZoom, let tab = selectedTab, let factor = next(tab.webContents.zoomFactor) else { return }
        session.setZoom(factor, of: tab)
    }

    // MARK: Printing

    /// Set while the selected page renders as PDF for Print or Export as PDF, so a second request cannot start another.
    private var isRenderingPDF = false

    /// Whether Print and Export as PDF can act: a page is selected with no internal page or preview over it, no PDF is rendering, and the window shows no sheet.
    public var canPrint: Bool {
        guard selectedTab != nil, !isSelectedPageCovered, !isRenderingPDF else { return false }
        return nsWindow?.attachedSheet == nil
    }

    /// Prints the selected page through the system print panel, a sheet on the window. Both engines render the page as PDF first, so the panel and its preview work the same on either.
    public func printPage() {
        renderSelectedPageAsPDF(failureMessage: "The page could not be printed.") { tab, document, window in
            guard let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
            operation.jobTitle = tab.displayTitle
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    /// Saves the selected page as a PDF file where the user chooses in a save panel on the window.
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
                    self?.session.enqueueSheet(alert, for: tab) { _ in }
                }
            }
        }
    }

    /// Renders the selected page as PDF and passes it on with the window while that tab is still selected; a tab the user left in the meantime drops the request. A failure shows a sheet on the tab.
    private func renderSelectedPageAsPDF(failureMessage: String, then use: @escaping (Tab, PDFDocument, NSWindow) -> Void) {
        guard canPrint, let tab = selectedTab else { return }
        isRenderingPDF = true
        tab.webContents.createPDF { [weak self] result in
            guard let self else { return }
            self.isRenderingPDF = false
            guard self.selectedTab === tab, let window = self.nsWindow else { return }
            if case .success(let data) = result, let document = PDFDocument(data: data) {
                use(tab, document, window)
            } else {
                let alert = NSAlert()
                alert.messageText = failureMessage
                self.session.enqueueSheet(alert, for: tab) { _ in }
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
        guard session.allTabs.contains(where: { $0 === tab }) else { return }
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        session.enqueueSheet(alert, for: tab) { _ in }
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
        } else if let content = nsWindow?.contentView {
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
        let candidates = session.tabs.filter { $0.spaceID == currentSpaceID } + session.openFavoriteTabs
        let selected = activationOrder.compactMap { id in candidates.first { $0.id == id } }
        let selectedIDs = Set(activationOrder)
        return selected + candidates.filter { !selectedIDs.contains($0.id) }.sorted { $0.lastActivatedAt > $1.lastActivatedAt }
    }

    private func recordActivation() {
        guard let id = selectedTabID else { return }
        activationOrder.removeAll { $0 == id }
        activationOrder.insert(id, at: 0)
    }

    /// Drops a closing tab from the switcher's order.
    func forgetActivation(of tabID: UUID) {
        activationOrder.removeAll { $0 == tabID }
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
        guard session.allTabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        if commandPaletteMode != nil { dismissCommandPalette() } else { focusPage() }
    }

    /// Closes the switcher and keeps the selected tab.
    public func cancelTabSwitcher() {
        if tabSwitcherHighlightID != nil { tabSwitcherHighlightID = nil }
    }

    // MARK: Site data

    /// Whether Clear Site Data can act: the selected tab shows a web page that no internal page or preview covers, and the window shows no sheet.
    public var canClearSiteData: Bool {
        guard !isSelectedPageCovered, SiteDataScope(url: selectedTab?.url) != nil else { return false }
        return nsWindow?.attachedSheet == nil
    }

    /// Asks with a sheet on the selected tab before clearing the data of its page's host.
    public func confirmClearSiteData() {
        guard canClearSiteData, let tab = selectedTab, let site = SiteDataScope(url: tab.url) else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the data stored by \u{201C}\(site.displayName)\u{201D}?"
        alert.informativeText = "Its cookies and other website data are removed from both engines, which signs you out of the site. Its open tabs load again."
        alert.addButton(withTitle: "Clear").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let personaID = tab.personaID
        session.enqueueSheet(alert, for: tab) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.session.clearSiteData(of: site, in: personaID) }
        }
    }

    // MARK: Folders

    /// The folder whose name is being edited in the sidebar.
    @Published public var renamingFolderID: UUID?

    /// Adds an empty folder after the space's folders among its pinned tabs, shows the space, and starts renaming the folder.
    public func addFolder(toSpace spaceID: UUID) {
        guard session.spaces.contains(where: { $0.id == spaceID }) else { return }
        switchToSpace(spaceID)
        renamingFolderID = session.makeFolder(in: spaceID, pinned: true).id
    }

    /// Puts a tab in a new folder among its space's pinned or open tabs and starts renaming the folder. A favorite's tab belongs to no space and stays out of folders.
    public func addToNewFolder(_ tab: Tab) {
        guard let spaceID = tab.spaceID else { return }
        let folder = session.makeFolder(in: spaceID, pinned: tab.isPinned)
        session.moveTab(tab.id, toFolder: folder.id)
        renamingFolderID = folder.id
    }

    /// Keeps the old name when the new one is empty.
    public func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { session.updateFolder(id) { $0.name = trimmed } }
        endRenamingFolder(id)
    }

    /// Does not interrupt renaming another folder that may have started meanwhile.
    public func endRenamingFolder(_ id: UUID) {
        if renamingFolderID == id { renamingFolderID = nil }
    }

    // MARK: Split view

    /// The split view the page area shows: the selected tab's, if it is in one.
    private var splitOnScreen: [UUID]? {
        guard let selected = selectedTab, let spaceID = selected.spaceID, let ids = session.splitTabIDs[spaceID], ids.contains(selected.id) else { return nil }
        return ids
    }

    /// The page area's panes, left to right: the selected tab's split view, or the selected tab alone. The window shows the pages of `shownTabIDs` among them.
    var paneTabs: [Tab] {
        guard let selected = selectedTab else { return [] }
        guard let ids = splitOnScreen else { return [selected] }
        return ids.compactMap { id in session.tabs.first { $0.id == id } }
    }

    /// Whether `tab` is a pane of the split view the page area shows.
    func isInSplitViewOnScreen(_ tab: Tab) -> Bool {
        splitOnScreen?.contains(tab.id) == true
    }

    /// Whether `tab` can open as a pane: it belongs to the selected tab's space, the page area does not show it yet, and the panes it joins have room.
    public func canOpenInSplitView(_ tab: Tab) -> Bool {
        let panes = panesJoined(by: tab)
        return !panes.isEmpty && !panes.contains(tab.id) && panes.count < BrowserSession.maximumPanes
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
        guard (2...BrowserSession.maximumPanes).contains(ids.count) else { return }
        session.setSplitView(ids, ofSpace: spaceID)
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
        let neighborID = session.leaveSplitView(tab)
        if selectedTabID == tab.id, let neighborID { selectedTabID = neighborID }
    }

    /// The panes `tab` joins, left to right: those on screen, which are a split view or the selected tab alone. The selected tab shown alone joins its space's split view instead or, without one, the tab selected before it. Empty when `tab` is in another space or has no tab to join.
    private func panesJoined(by tab: Tab) -> [UUID] {
        guard let selected = selectedTab, let spaceID = tab.spaceID, selected.spaceID == spaceID else { return [] }
        let onScreen = paneTabs.map(\.id)
        guard onScreen == [tab.id] else { return onScreen }
        if let split = session.splitTabIDs[spaceID] { return split }
        return recentTabs.first { $0.id != tab.id && $0.spaceID == tab.spaceID }.map { [$0.id] } ?? []
    }
}

/// A main window's space and selected tab. The session keeps the record of the last main window that closed, opens the next main window from it, and saves the front main window's.
struct WindowRecord {
    var currentSpaceID: UUID
    var selectedTabID: UUID?
}
