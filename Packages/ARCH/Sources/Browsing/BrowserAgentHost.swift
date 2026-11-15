// The browser side of the agents' service (docs/agents.md, Parts and modules): the session's Personas, spaces, and tabs in sidebar order, the Agents Persona, which it adds on demand and keeps agent-only, the front main window for the grant sheet, the search engine's results address for the sessions' site scope, and the agent tabs: it opens, navigates, reads, and closes them, runs the agents' page script in them and captures them, giving a tab that no window shows a viewport first, gives the tool host their trusted input, passes on what happens in them, asks the service about each of their navigations and downloads, and hands it their file choosers. It offers the user's own tabs for `request_tab`, shows tabs, opens links in other apps once the user allowed them, and opens the agent panel in a window.
import Agent
import AppKit
import ARCHEngine
import Combine
import Foundation

@MainActor public final class BrowserAgentHost: AgentBrowserHost {
    static let agentsPersonaName = "Agents"

    private unowned let session: BrowserSession
    public var personasDidChange: (() -> Void)?
    public var userDocumentDidEnd: ((_ tabID: UUID, _ documentID: UUID) -> Void)?
    public var userTabAddressDidChange: ((_ tabID: UUID) -> Void)?
    public var agentTabDidReport: ((_ ownerID: UUID, _ tabID: UUID, _ report: AgentTabReport) -> Void)?
    public var agentTabMayLoad: ((_ ownerID: UUID, _ tabID: UUID, _ url: URL, _ kind: AgentLoadKind) -> Bool)?
    public var agentTabMayDownload: ((_ ownerID: UUID, _ tabID: UUID, _ url: URL) -> Bool)?
    public var agentTabChoosesFiles: ((_ ownerID: UUID, _ tabID: UUID, _ chooser: AgentFileChooser) -> Void)?
    public var agentPanel: AgentPanelModel?
    /// The addresses of the downloads each owner's tabs started once the user allowed them, which `list_downloads` follows in the session's downloads.
    private var downloadsByOwner: [UUID: [URL]] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// The agent tabs this host follows, each with its owner, until it closes or the user takes it over.
    private var followed: [UUID: (owner: UUID, observer: AnyCancellable)] = [:]
    /// The tab `closeAgentTab(_:)` is closing, whose close the agent asked for and so hears nothing of.
    private var closingTabID: UUID?

    public init(session: BrowserSession) {
        self.session = session
        // On the next turn, once the session has finished a change that touches both lists, as deleting a Persona does.
        session.$personas.combineLatest(session.$spaces)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.personasDidChange?() } }
            .store(in: &cancellables)
        session.agentMonitor = self
    }

    public var personas: [AgentPersonaInfo] {
        session.personas.map { AgentPersonaInfo(id: $0.id, name: $0.name) }
    }

    public func spaces(in personaID: UUID) -> [AgentSpaceInfo] {
        session.spaces(in: personaID).map { AgentSpaceInfo(id: $0.id, name: $0.name) }
    }

    public func tabs(withIDs ids: Set<UUID>) -> [AgentTabInfo] {
        guard !ids.isEmpty else { return [] }
        return session.tabsInSidebarOrder.filter { ids.contains($0.id) }.map(Self.info(of:))
    }

    public func agentTabs(of ownerID: UUID) -> [AgentTabInfo] {
        session.tabsInSidebarOrder.filter { $0.agentOwnerID == ownerID }.map(Self.info(of:))
    }

    /// A tab as the agents' service sees it.
    static func info(of tab: Tab) -> AgentTabInfo {
        AgentTabInfo(id: tab.id, spaceID: tab.spaceID, title: tab.displayTitle, url: tab.url, isLoading: tab.isLoading, canGoBack: tab.canGoBack, canGoForward: tab.canGoForward,
                     engine: tab.engineKind, agentOwnerID: tab.agentOwnerID, documentID: tab.documentID, isLoaded: tab.isLoaded)
    }

    /// The results page of the search engine chosen in Settings ▸ General, which takes the terms in `q`.
    public var searchResultsAddress: AgentSearchResultsAddress? {
        AgentSearchResultsAddress(base: SearchEngine.current.resultsURL)
    }

    /// A Persona of its own named Agents, with one space and storage of its own on both engines (Persona rule 2), so it holds no sign-ins.
    public func makeAgentsPersona() -> UUID {
        session.addPersona(named: Self.agentsPersonaName).id
    }

    public func setAgentOnlyPersona(_ id: UUID?) {
        session.agentOnlyPersonaID = id
    }

    public func windowForSheet() -> NSWindow? {
        session.sidebarTarget().nsWindow
    }

    // MARK: Agent tabs

    public func openAgentTab(at url: URL, engine: EngineKind?, for owner: AgentTabOwner) -> AgentTabInfo? {
        guard let tab = session.openAgentTab(url: url, engine: engine, owner: owner.id, folderName: owner.folderName, in: owner.spaceID) else { return nil }
        follow(tab, owner: owner.id)
        return Self.info(of: tab)
    }

    public func navigate(_ tabID: UUID, _ navigation: AgentNavigation) {
        guard let tab = agentTab(tabID) else { return }
        let controller = tab.webContents.navigationController
        switch navigation {
        case .load(let url): controller.load(URLRequest(url: url))
        case .back: controller.goBack()
        case .forward: controller.goForward()
        case .reload: controller.reload()
        }
    }

    public func closeAgentTab(_ tabID: UUID) {
        guard let tab = agentTab(tabID) else { return }
        closingTabID = tabID
        session.closeAgentTab(tab, reason: .user)
        closingTabID = nil
    }

    public func readableContent(of tabID: UUID, limit: Int, completion: @escaping (Result<EngineReadableContent, any Error>) -> Void) {
        guard let tab = session.allTabs.first(where: { $0.id == tabID }) else { return completion(.failure(EngineReadableContentError.unreadable)) }
        tab.webContents.readableContent(limit: limit, completion: completion)
    }

    public func runPageScript(_ source: String, world: String, in tabID: UUID, completion: @escaping (Result<String?, any Error>) -> Void) {
        guard let tab = session.allTabs.first(where: { $0.id == tabID }) else { return completion(.failure(EngineReadableContentError.unreadable)) }
        giveViewport(to: tab)
        tab.webContents.executeJavaScript(source, inWorld: world, completion: completion)
    }

    public func capture(_ tabID: UUID, fullPage: Bool, completion: @escaping (NSImage?) -> Void) {
        guard let tab = session.allTabs.first(where: { $0.id == tabID }) else { return completion(nil) }
        giveViewport(to: tab)
        if fullPage { tab.webContents.captureFullPage(completion: completion) } else { tab.webContents.captureViewport(completion: completion) }
    }

    /// Only agent tabs, whose pages run the target check (`AgentPageScripts.targetCheck`), act through trusted input.
    public func trustedInput(of tabID: UUID) -> AgentTabInput? {
        guard let tab = agentTab(tabID), let input = tab.webContents.input else { return nil }
        return AgentTabInput(input: input, zoomFactor: tab.webContents.zoomFactor)
    }

    /// A page whose view no window shows and has never been sized lays out in a viewport of nothing, where no element is visible or reachable, so it gets the size of the front window's content first.
    private func giveViewport(to tab: Tab) {
        let view = tab.webContents.view
        guard view.window == nil, view.frame.width < 1 || view.frame.height < 1 else { return }
        let size = session.sidebarTarget().nsWindow?.contentView?.bounds.size ?? NSSize(width: 1280, height: 800)
        view.setFrameSize(NSSize(width: max(size.width, 800), height: max(size.height, 600)))
    }

    public func userTabs(in personaID: UUID) -> [AgentTabInfo] {
        session.tabsInSidebarOrder.filter { $0.agentOwnerID == nil && $0.personaID == personaID }.map(Self.info(of:))
    }

    /// Shows a tab by the rule a step's tab button follows (`BrowserWindowModel.showAgentTab(_:)`): a small window's tab brings its small window forward, since the main window selecting it would close that window and leave the tab out of every list; any other tab is selected in the front main window, which comes forward. A tab that has closed shows nothing.
    public func showTab(_ tabID: UUID) {
        guard let tab = session.allTabs.first(where: { $0.id == tabID }) else { return }
        let window = session.sidebarTarget()
        window.showAgentTab(tabID)
        if !tab.isInSmallWindow { window.nsWindow?.makeKeyAndOrderFront(nil) }
    }

    public func agentDownloads(of ownerID: UUID) -> [AgentDownloadInfo] {
        let addresses = downloadsByOwner[ownerID] ?? []
        return session.downloads.filter { addresses.contains($0.item.sourceURL) }
            .map { AgentDownloadInfo(name: $0.filename, completedBytes: $0.completedBytes, totalBytes: $0.totalBytes, state: $0.state) }
    }

    public func appName(forOpening url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    public func openExternally(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func showAgentPanel(for ownerID: UUID) {
        session.sidebarTarget().showAgentPanel(for: ownerID)
    }

    public func searchHistory(_ query: String, limit: Int) async -> [AgentHistoryPage] {
        await session.history.suggestions(for: query, limit: limit).map { AgentHistoryPage(url: $0.url, title: $0.title) }
    }

    /// An open tab that an agent folder holds.
    private func agentTab(_ id: UUID) -> Tab? {
        session.tabs.first { $0.id == id && $0.agentOwnerID != nil }
    }

    /// Follows an agent tab's folder, so that the owner hears when the user takes the tab over: by moving it out of the folder, deleting the folder, or keeping its tabs. The tab's next documents then run the target check only while an agent folder still holds it.
    private func follow(_ tab: Tab, owner: UUID) {
        let tabID = tab.id
        let observer = tab.$folderID.combineLatest(session.$folders)
            .dropFirst()
            .sink { [weak self] folderID, folders in
                guard folders.first(where: { $0.id == folderID })?.agentSessionID != owner else { return }
                // Published values arrive before storage changes. Deliver the takeover afterwards, even if the user immediately closes their tab.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.followed[tabID]?.owner == owner else { return }
                        self.followed[tabID] = nil
                        if let tab = self.session.allTabs.first(where: { $0.id == tabID }) {
                            let plugins = self.session.plugins(in: tab.personaID).contributions.pageScripts
                            tab.webContents.setPageScripts(TabUnloading.pageScripts(withPluginScripts: plugins, inAgentTab: tab.agentOwnerID != nil))
                        }
                        self.agentTabDidReport?(owner, tabID, .takenOver)
                    }
                }
            }
        followed[tab.id] = (owner, observer)
    }
}

extension BrowserAgentHost: AgentTabMonitor {
    func userDocumentDidEnd(in tabID: UUID, document: UUID) {
        userDocumentDidEnd?(tabID, document)
    }

    func userTabAddressDidChange(_ tabID: UUID) {
        userTabAddressDidChange?(tabID)
    }

    func agentTab(_ tab: Tab, owner: UUID, mayLoad url: URL, kind: AgentLoadKind) -> Bool {
        agentTabMayLoad?(owner, tab.id, url, kind) ?? false
    }

    func agentTab(_ tab: Tab, owner: UUID, mayDownload url: URL) -> Bool {
        guard agentTabMayDownload?(owner, tab.id, url) == true else { return false }
        downloadsByOwner[owner, default: []].append(url)
        return true
    }

    func agentTab(_ tab: Tab, owner: UUID, choosesFiles chooser: AgentFileChooser) {
        guard let agentTabChoosesFiles else { return chooser.deny() }
        agentTabChoosesFiles(owner, tab.id, chooser)
    }

    func agentTab(_ tab: Tab, owner: UUID, didReport report: AgentTabReport) {
        if case .opened(let openedID) = report, let opened = session.tabs.first(where: { $0.id == openedID }) { follow(opened, owner: owner) }
        agentTabDidReport?(owner, tab.id, report)
    }

    func agentTabDidClose(_ tab: Tab, owner: UUID) {
        guard followed.removeValue(forKey: tab.id) != nil, closingTabID != tab.id else { return }
        agentTabDidReport?(owner, tab.id, .closed)
    }
}
