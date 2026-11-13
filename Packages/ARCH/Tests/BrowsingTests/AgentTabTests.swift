// Agent tabs in the browser (docs/agents.md, In the browser ▸ Agent folders; Rules): a tab is an agent's while an agent folder holds it; `session.json` leaves agent folders and their tabs out, so that an unkept agent tab is gone after a relaunch, and never writes a folder's `agentSessionID`; an agent tab records no visits, and closing one adds it to neither the closed list nor the tab close log, nor counts for ⌘Z; an agent folder goes once its last tab has left it; Keep Tabs makes the folder and its tabs the user's; and an agent tab denies permission requests without asking (P8), dismisses alerts (P10), refuses downloads (P6) and other apps (P11), and asks the agent monitor about each navigation (P16).
import AppKit
import Agent
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct AgentTabTests {
    private let space = Space(name: "Personal", personaID: Persona.defaultID)
    private let owner = UUID()

    /// The session's folders, which the tabs read their owner from as the session's tabs do.
    private final class Folders {
        var folders: [TabFolder] = []
    }

    private func tab(in folder: TabFolder?, folders: Folders, url: URL? = URL(string: "https://example.org/start")) -> (Tab, PageDouble) {
        let page = PageDouble(url: url)
        let tab = Tab(id: UUID(), webContents: page, spaceID: space.id, isPinned: false, personaID: Persona.defaultID)
        tab.folderID = folder?.id
        tab.agentOwnerOfFolder = { [folders] id in folders.folders.first { $0.id == id }?.agentSessionID }
        return (tab, page)
    }

    @Test func agentFoldersAndTheirTabsStayOutOfSessionJSONAndAreGoneAfterARelaunch() throws {
        let folders = Folders()
        let agentFolder = TabFolder(spaceID: space.id, name: "claude \u{00B7} Terminal", isPinned: false, agentSessionID: owner)
        let userFolder = TabFolder(spaceID: space.id, name: "Reading", isPinned: false)
        folders.folders = [userFolder, agentFolder]
        let (agentTab, _) = tab(in: agentFolder, folders: folders)
        let (userTab, _) = tab(in: userFolder, folders: folders)
        let (looseTab, _) = tab(in: nil, folders: folders)
        #expect(agentTab.agentOwnerID == owner && userTab.agentOwnerID == nil && looseTab.agentOwnerID == nil)

        let kept = SessionSnapshot.keptSidebar(tabs: [agentTab, userTab, looseTab], folders: folders.folders)
        #expect(kept.tabs.map(\.id) == [userTab.id, looseTab.id])
        #expect(kept.folders.map(\.id) == [userFolder.id])

        // The saved file has neither, and a relaunch reopens only the user's tabs.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchAgentTabTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        store.saveNow(SessionSnapshot(version: SessionSnapshot.currentVersion, personas: [Persona(id: Persona.defaultID, name: "Default")], spaces: [space], currentSpaceID: space.id, favorites: [],
                                      tabs: kept.tabs.map { SessionSnapshot.TabRecord($0, spaceID: space.id, lastActivatedAt: Date()) }, folders: kept.folders))
        let file = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!file.contains(agentTab.id.uuidString) && !file.contains(agentFolder.id.uuidString) && !file.contains("claude"))
        let reopened = try #require(store.load())
        #expect(reopened.tabs.map(\.id) == [userTab.id, looseTab.id])
        #expect(reopened.folders?.map(\.id) == [userFolder.id])

        // A folder's agent is never encoded, so a folder that comes back from a file is the user's.
        let decoded = try JSONDecoder().decode(TabFolder.self, from: JSONEncoder().encode(agentFolder))
        #expect(decoded.id == agentFolder.id && decoded.agentSessionID == nil)
        #expect(!String(decoding: try JSONEncoder().encode(agentFolder), as: UTF8.self).contains("agentSessionID"))
    }

    @Test func keepTabsMakesTheFolderAndItsTabsTheUsers() {
        let folders = Folders()
        var agentFolder = TabFolder(spaceID: space.id, name: "claude \u{00B7} Terminal", isPinned: false, agentSessionID: owner)
        folders.folders = [agentFolder]
        let (agentTab, page) = tab(in: agentFolder, folders: folders)
        var visits: [URL] = []
        agentTab.recordVisit = { url, _ in visits.append(url) }
        page.load(URL(string: "https://example.org/agent-page")!, in: agentTab)
        #expect(visits.isEmpty)

        agentFolder.agentSessionID = nil
        folders.folders = [agentFolder]
        #expect(agentTab.agentOwnerID == nil)
        #expect(SessionSnapshot.keptSidebar(tabs: [agentTab], folders: folders.folders).tabs.map(\.id) == [agentTab.id])
        page.load(URL(string: "https://example.org/kept-page")!, in: agentTab)
        #expect(visits == [URL(string: "https://example.org/kept-page")!])
        #expect(BrowserSession.closeKeeps(agentTab, remember: true) == (closedList: true, closeLog: true))
    }

    @Test func anAgentTabRecordsNoVisitsAndClosesWithoutARecord() {
        let folders = Folders()
        let agentFolder = TabFolder(spaceID: space.id, name: "agent", isPinned: false, agentSessionID: owner)
        folders.folders = [agentFolder]
        let (agentTab, agentPage) = tab(in: agentFolder, folders: folders)
        let (userTab, userPage) = tab(in: nil, folders: folders)
        var visits: [URL] = []
        agentTab.recordVisit = { url, _ in visits.append(url) }
        userTab.recordVisit = { url, _ in visits.append(url) }
        agentPage.load(URL(string: "https://example.org/agent")!, in: agentTab)
        userPage.load(URL(string: "https://example.org/user")!, in: userTab)
        #expect(visits == [URL(string: "https://example.org/user")!])

        // Closing keeps nothing of an agent tab: no closed-list record for ⇧⌘T and no tab close log entry, whatever the caller asks. `requestCloseTab` counts a close for ⌘Z only when the closed list keeps it, so ⌘Z after an agent tab closes reopens no older tab in its place.
        #expect(BrowserSession.closeKeeps(agentTab, remember: true) == (closedList: false, closeLog: false))
        #expect(BrowserSession.closeKeeps(agentTab, remember: false) == (closedList: false, closeLog: false))
        #expect(BrowserSession.closeKeeps(userTab, remember: true) == (closedList: true, closeLog: true))
        #expect(BrowserSession.closeKeeps(userTab, remember: false) == (closedList: false, closeLog: true))
        let favoritesTab = Tab(id: UUID(), webContents: PageDouble(url: nil), spaceID: nil, isPinned: false, personaID: Persona.defaultID)
        #expect(BrowserSession.closeKeeps(favoritesTab, remember: true) == (closedList: false, closeLog: true))
    }

    @Test func anAgentFolderGoesOnceItsLastTabLeavesIt() {
        let folders = Folders()
        let agentFolder = TabFolder(spaceID: space.id, name: "claude \u{00B7} Terminal", isPinned: false, agentSessionID: owner)
        let userFolder = TabFolder(spaceID: space.id, name: "Reading", isPinned: false)
        folders.folders = [agentFolder, userFolder]
        let (first, _) = tab(in: agentFolder, folders: folders)
        let (second, _) = tab(in: agentFolder, folders: folders)
        #expect(BrowserSession.emptyAgentFolderIDs(in: folders.folders, tabs: [first, second]).isEmpty)
        // The user drags one tab out, then moves the other into a folder of theirs: the agent folder is empty then, and an empty folder of the user's stays.
        first.folderID = nil
        #expect(BrowserSession.emptyAgentFolderIDs(in: folders.folders, tabs: [first, second]).isEmpty)
        second.folderID = userFolder.id
        #expect(first.agentOwnerID == nil && second.agentOwnerID == nil)
        #expect(BrowserSession.emptyAgentFolderIDs(in: folders.folders, tabs: [first, second]) == [agentFolder.id])
        #expect(BrowserSession.emptyAgentFolderIDs(in: folders.folders, tabs: []) == [agentFolder.id])
    }

    @Test func anAgentTabAppliesItsRulesAndReportsThem() {
        let folders = Folders()
        let agentFolder = TabFolder(spaceID: space.id, name: "agent", isPinned: false, agentSessionID: owner)
        folders.folders = [agentFolder]
        let (agentTab, page) = tab(in: agentFolder, folders: folders)
        let monitor = MonitorDouble()
        agentTab.agentMonitor = monitor
        var asked = 0
        agentTab.requestPermission = { _, completion in
            asked += 1
            completion(true)
        }
        var sheets = 0
        agentTab.presentAlert = { _, _, completion in
            sheets += 1
            completion(.alertFirstButtonReturn)
        }

        // P8: denied without asking.
        var granted: Bool?
        agentTab.webContents(page, requestPermission: EnginePermissionRequest(origin: URL(string: "https://example.org")!, types: [.camera]), completion: { granted = $0 })
        #expect(granted == false && asked == 0)
        // P10: an alert is dismissed without a sheet; P9: a confirm waits for the user in a sheet.
        var dismissed = false
        agentTab.webContents(page, runJavaScriptAlert: "Hello", completion: { dismissed = true })
        #expect(dismissed && sheets == 0)
        var confirmed: Bool?
        agentTab.webContents(page, runJavaScriptConfirm: "Sure?", completion: { confirmed = $0 })
        #expect(confirmed == true && sheets == 1)
        // P6 and P11: a download the user has not allowed stops and waits for a card, as a link to another app does; one the user allowed goes ahead.
        #expect(!agentTab.webContents(page, shouldDownload: URL(string: "https://example.org/file.zip")!, hasPage: true))
        agentTab.webContents(page, openExternally: URL(string: "mailto:someone@example.org")!, isUserInitiated: true)
        monitor.allowedDownloads = [URL(string: "https://example.org/allowed.zip")!]
        #expect(agentTab.webContents(page, shouldDownload: URL(string: "https://example.org/allowed.zip")!, hasPage: true))
        // P16: the monitor decides each navigation.
        monitor.allows = false
        #expect(agentTab.webContents(page, decidePolicyFor: EngineNavigationAction(url: URL(string: "https://excluded.example/")!, disposition: .currentTab, isUserInitiated: false)) == .cancel)
        monitor.allows = true
        #expect(agentTab.webContents(page, decidePolicyFor: EngineNavigationAction(url: URL(string: "https://example.org/next")!, disposition: .currentTab, isUserInitiated: true)) == .allow)
        #expect(monitor.asked == [URL(string: "https://excluded.example/")!, URL(string: "https://example.org/next")!])
        #expect(monitor.reports == [.permissionDenied([.camera]), .alertDismissed(message: "Hello"), .dialogWaiting(.confirm, message: "Sure?"),
                                    .downloadAsked(URL(string: "https://example.org/file.zip")!), .externalAppAsked(URL(string: "mailto:someone@example.org")!),
                                    .downloadStarted(URL(string: "https://example.org/allowed.zip")!)])
        #expect(monitor.owners == Set([owner]))

        // The user's own tab asks, shows its alerts, and downloads, and the monitor hears nothing of it.
        let (userTab, userPage) = tab(in: nil, folders: folders)
        userTab.agentMonitor = monitor
        userTab.requestPermission = { _, completion in
            asked += 1
            completion(true)
        }
        userTab.webContents(userPage, requestPermission: EnginePermissionRequest(origin: URL(string: "https://example.org")!, types: [.camera]), completion: { granted = $0 })
        #expect(granted == true && asked == 1)
        #expect(userTab.webContents(userPage, shouldDownload: URL(string: "https://example.org/file.zip")!, hasPage: true))
        #expect(monitor.reports.count == 6)
    }
}

/// Records what agent tabs ask and report.
private final class MonitorDouble: AgentTabMonitor {
    var allows = true
    private(set) var asked: [URL] = []
    private(set) var reports: [AgentTabReport] = []
    private(set) var owners: Set<UUID> = []

    func agentTab(_ tab: Tab, owner: UUID, mayLoad url: URL) -> Bool {
        asked.append(url)
        owners.insert(owner)
        return allows
    }

    var allowedDownloads: Set<URL> = []

    func agentTab(_ tab: Tab, owner: UUID, mayDownload url: URL) -> Bool {
        allowedDownloads.contains(url)
    }

    func agentTab(_ tab: Tab, owner: UUID, didReport report: AgentTabReport) {
        reports.append(report)
        owners.insert(owner)
    }

    func agentTabDidClose(_ tab: Tab, owner: UUID) {}
}

/// An engine's page whose address and loading state the test sets, reporting to the tab as an engine does.
private final class PageDouble: EngineWebContents {
    let engineKind = EngineKind.webKit
    private(set) var url: URL?
    private(set) var isLoading = false
    let title = "Page"
    let favicon: NSImage? = nil
    let canGoBack = false
    let canGoForward = false
    let restorableState: Data? = nil
    let isAudible = false
    var zoomFactor = 1.0
    lazy var view = NSView()
    let navigationController: any EngineNavigationController = NavigationDouble()
    let mediaSession: any EngineMediaSession = MediaDouble()
    weak var uiDelegate: (any EngineWebContentsUIDelegate)?
    weak var navigationDelegate: (any EngineWebContentsNavigationDelegate)?
    weak var pageScriptDelegate: (any EnginePageScriptDelegate)?
    let closingStopsDownloads = false
    let devTools: (any EngineDevTools)? = nil

    init(url: URL?) {
        self.url = url
    }

    /// Starts and finishes a load of `address`, as the engine reports one.
    func load(_ address: URL, in tab: Tab) {
        isLoading = true
        tab.webContentsDidChangeLoadingState(self)
        url = address
        tab.webContentsDidChangeURL(self)
        isLoading = false
        tab.webContentsDidChangeLoadingState(self)
    }

    func find(_ text: String, forward: Bool, matchCase: Bool, completion: @escaping (EngineFindResult) -> Void) {}
    func stopFind() {}
    func setPageScripts(_ scripts: [EnginePageScript]) {}
    func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {}
    func postPageScriptMessage(_ json: String, toWorld world: String) {}
    func readableContent(limit: Int, completion: @escaping (Result<EngineReadableContent, Error>) -> Void) {}
    func captureViewport(completion: @escaping (NSImage?) -> Void) {}
    func captureFullPage(completion: @escaping (NSImage?) -> Void) {}
    func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {}
    func exitFullscreen() {}
    func tryToClose(completion: @escaping (Bool) -> Void) {}
}

private final class MediaDouble: EngineMediaSession {
    weak var delegate: (any EngineMediaSessionDelegate)?
    let playbackState = EngineMediaPlaybackState.none
    let position: EngineMediaPosition? = nil
    let metadata: EngineMediaMetadata? = nil
    let canGoToNextTrack = false
    let canGoToPreviousTrack = false
    func play() {}
    func pause() {}
    func nextTrack() {}
    func previousTrack() {}
}

private final class NavigationDouble: EngineNavigationController, EngineBackForwardList {
    var backForwardList: any EngineBackForwardList { self }
    let backList: [any EngineBackForwardListItem] = []
    func load(_ request: URLRequest) {}
    func reload() {}
    func reloadWithoutCache() {}
    func stop() {}
    func goBack() {}
    func goForward() {}
    func go(to item: any EngineBackForwardListItem) {}
}
