// Owns the engine application, one profile, and one browser for the window. Also owns sidebar state: spaces, favorites, and tabs.
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
        didSet { if let tab = selectedTab, tab.spaceID != currentSpaceID { currentSpaceID = tab.spaceID } }
    }
    @Published public var isSidebarVisible = true
    /// `nil` when the command palette is hidden.
    @Published public var commandPaletteMode: CommandPaletteMode?

    public static let searchURL = URL(string: "https://www.google.com/search")!
    public static let newTabURL = URL(string: "https://www.google.com")!

    private let store: SessionStore
    private var cancellables: Set<AnyCancellable> = []
    private var tabObservers: [UUID: AnyCancellable] = [:]

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
        application.run()
        browser = application.createBrowser(EngineBrowserCreateParams(initialBounds: .zero), context: context, delegate: self, window: nil)
        restoreTabs(snapshot)
        observeChanges()
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
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self] _ in self?.scheduleSave() }
        tabs.append(tab)
        if select || selectedTabID == nil { selectedTabID = tab.id }
        return tab
    }

    public func closeTab(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        tabObservers[tab.id] = nil
        browser.closeWebContents(tab.webContents)
        if selectedTabID == tab.id {
            let siblings = tabs.filter { $0.spaceID == tab.spaceID }
            selectedTabID = (siblings.first { !$0.isPinned } ?? siblings.first)?.id
        }
    }

    public func closeSelectedTab() {
        selectedTab.map(closeTab)
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

    public func showCommandPalette(_ mode: CommandPaletteMode) { commandPaletteMode = mode }
    public func dismissCommandPalette() { commandPaletteMode = nil }

    public func submitCommandPalette(_ input: String) {
        defer { commandPaletteMode = nil }
        guard let mode = commandPaletteMode, let url = Self.destination(forInput: input) else { return }
        switch mode {
        case .editCurrent where selectedTab != nil: navigate(to: input)
        case .editCurrent, .newTab: openTab(url: url)
        }
    }

    public func goBack() { selectedTab?.webContents.navigationController.goBack() }
    public func goForward() { selectedTab?.webContents.navigationController.goForward() }
    public func reload() { selectedTab?.webContents.navigationController.reload() }
    public func focusCommandBar() { showCommandPalette(selectedTab == nil ? .newTab : .editCurrent) }
    public func toggleSidebar() { isSidebarVisible.toggle() }

    // MARK: Persistence

    private func restoreTabs(_ snapshot: SessionSnapshot?) {
        guard let snapshot else { return }
        for record in snapshot.tabs where spaces.contains(where: { $0.id == record.spaceID }) {
            openTab(url: record.url, in: record.spaceID, pinned: record.isPinned, select: false)
        }
        if let index = snapshot.selectedTabIndex, tabs.indices.contains(index), tabs[index].spaceID == currentSpaceID {
            selectedTabID = tabs[index].id
        } else {
            selectedTabID = tabs.first { $0.spaceID == currentSpaceID }?.id
        }
    }

    private func observeChanges() {
        Publishers.Merge4($tabs.map { _ in () }, $spaces.map { _ in () }, $favorites.map { _ in () }, $currentSpaceID.map { _ in () })
            .merge(with: $selectedTabID.map { _ in () })
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
                        tabs: tabs.map { SessionSnapshot.TabRecord(spaceID: $0.spaceID, url: $0.url, title: $0.title, isPinned: $0.isPinned) },
                        selectedTabIndex: tabs.firstIndex { $0.id == selectedTabID })
    }
}

public enum CommandPaletteMode {
    case editCurrent
    case newTab
}

extension BrowserSession: EngineBrowserDelegate {
    public func browser(_ browser: any EngineBrowser, didCreateNewWebContents webContents: any EngineWebContents, isActive: Bool) {
        _ = adopt(webContents, spaceID: currentSpaceID, pinned: false, select: isActive)
    }
}
