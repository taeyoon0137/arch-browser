// Agent tabs in the browser (docs/agents.md, In the browser ▸ Agent folders; Rules): a tab is an agent's while an agent folder holds it; `session.json` leaves agent folders and their tabs out, so that an unkept agent tab is gone after a relaunch, and never writes a folder's `agentSessionID`; an agent tab records no visits, and closing one adds it to neither the closed list nor the tab close log, nor counts for ⌘Z; an agent folder goes once its last tab has left it; Keep Tabs makes the folder and its tabs the user's; and an agent tab denies permission requests without asking (P8), dismisses alerts (P10), refuses downloads (P6) and other apps (P11), hands every file chooser to the agents' service before any panel and ends it with no file when its page moves on, its engine changes, its tab closes, or Arch quits (P7), and asks the agent monitor about each navigation (P16).
import AppKit
import Combine
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
        let store = SessionStore(directory: directory, seal: .fixture)
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
        #expect(TabCloseAction.of(agentTab, reason: .user).closedRecord(of: agentTab)?.id == agentTab.id)
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

        let reasons: [TabCloseReason] = [.user, .page, .crash, .archive, .download, .webExtension, .persona]
        for reason in reasons {
            let action = TabCloseAction.of(agentTab, reason: reason)
            #expect(action == .forget)
            #expect(action.closedRecord(of: agentTab) == nil)
        }
        #expect(TabCloseAction.of(userTab, reason: .user).closedRecord(of: userTab)?.id == userTab.id)
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
        var tree = FolderTree(folders: folders.folders, tabs: [first, second])
        tree.moveTabOut(first)
        #expect(BrowserSession.emptyAgentFolderIDs(in: folders.folders, tabs: [first, second]).isEmpty)
        second.folderID = userFolder.id
        #expect(first.agentOwnerID == nil && second.agentOwnerID == nil)
        #expect(BrowserSession.emptyAgentFolderIDs(in: folders.folders, tabs: [first, second]) == [agentFolder.id])
        #expect(BrowserSession.emptyAgentFolderIDs(in: folders.folders, tabs: []) == [agentFolder.id])
        var child = userFolder
        child.parentID = agentFolder.id
        #expect(BrowserSession.emptyAgentFolderIDs(in: [agentFolder, child], tabs: []).isEmpty)
    }

    @Test func userTabChoicesBelongToTheirPersonaAndReportWhetherTheDocumentIsLoaded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchTabRequest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let host = BrowserAgentHost(session: session)
        let home = try #require(session.spaces.first)
        let work = session.addPersona(named: "Work")
        let otherSpace = try #require(session.spaces(in: work.id).first)
        let url = try #require(URL(string: "https://fixture.invalid/report"))
        let ordinary = session.openTab(url: url, in: home.id, select: false)
        let pinned = session.openTab(url: url, in: home.id, pinned: true, select: false)
        let elsewhere = session.openTab(url: url, in: otherSpace.id, select: false)
        _ = try #require(host.openAgentTab(at: url, engine: .webKit, for: AgentTabOwner(id: owner, spaceID: home.id, folderName: "Task")))
        #expect(session.closeTab(pinned))

        let homeChoices = host.userTabs(in: home.resolvedPersonaID)
        #expect(Set(homeChoices.map(\.id)) == [ordinary.id, pinned.id])
        #expect(homeChoices.filter(\.isLoaded).map(\.id) == [ordinary.id])
        #expect(host.userTabs(in: work.id).map(\.id) == [elsewhere.id])
    }

    @Test func userTabEventsNameTheDocumentThatCommittedOrClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSourceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let host = BrowserAgentHost(session: session)
        let space = try #require(session.spaces.first)
        let address = URL(string: "https://example.org/source")!
        let source = session.openTab(url: address, in: space.id, pinned: true, select: false, engine: .webKit)
        let other = session.openTab(url: address, in: space.id, select: false, engine: .webKit)
        var ended: [UUID: [UUID]] = [:]
        host.userDocumentDidEnd = { tab, document in ended[tab, default: []].append(document) }

        var addresses: [UUID] = []
        host.userTabAddressDidChange = { addresses.append($0) }
        let page = try #require(source.webContents as? PageDouble)
        let initial = source.documentID
        let changed = address.appendingPathComponent("next")
        page.load(changed, in: source)
        source.webContentsDidChangeURL(page)
        page.load(address, in: source)
        #expect(addresses == [source.id, source.id] && source.documentID == initial && ended.isEmpty)
        source.webContents(source.webContents, didCommitDocumentAt: address)
        let reloaded = source.documentID
        #expect(reloaded != initial && ended[source.id] == [initial])
        let closed = other.documentID
        #expect(session.closeTab(other))
        #expect(ended[other.id] == [closed] && ended[source.id] == [initial])
        #expect(session.closeTab(source))
        #expect(!source.isLoaded && ended[source.id] == [initial, reloaded])
    }

    /// P7 through the session: an agent tab's chooser queues no panel among the tab's prompts and reaches the agents' service first through `BrowserAgentHost`, with who asks as Arch's panel names it. The service's denial, a new document, quitting, a change of engine, the tab's close, and a session without the service's callback give the page no file, and the user's own tab still queues Arch's panel.
    @Test func anAgentTabsFileChooserReachesTheServiceBeforeAnyPanelAndEndsWithItsPage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchAgentChooserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let host = BrowserAgentHost(session: session)
        let space = try #require(session.spaces.first)
        let info = try #require(host.openAgentTab(at: URL(string: "https://example.org/upload")!, engine: .webKit, for: AgentTabOwner(id: owner, spaceID: space.id, folderName: "Task")))
        let tab = try #require(session.tabs.first { $0.id == info.id })
        let request = EngineFileChooserRequest(mode: .openFiles, acceptedTypes: [".pdf"], origin: URL(string: "https://upload.example/frame"), pageOrigin: URL(string: "https://example.org/upload"))
        var replies: [[URL]?] = []

        // Without the service's callback, the page gets no file.
        tab.webContents(tab.webContents, runFileChooser: request) { replies.append($0) }
        #expect(replies == [nil] && !session.prompts.hasPrompt(for: tab.id))
        // The service gets the chooser before any panel, with who asks as Arch's panel names it, and nothing waits among the tab's prompts.
        var handed: [(owner: UUID, tab: UUID, chooser: AgentFileChooser)] = []
        host.agentTabChoosesFiles = { handed.append(($0, $1, $2)) }
        tab.webContents(tab.webContents, runFileChooser: request) { replies.append($0) }
        let first = try #require(handed.last)
        #expect(first.owner == owner && first.tab == tab.id && first.chooser.request == request)
        #expect(first.chooser.asker == "\u{201C}upload.example\u{201D} in \u{201C}example.org\u{201D}")
        #expect(replies == [nil] && !session.prompts.hasPrompt(for: tab.id) && !first.chooser.hasEnded)
        first.chooser.deny()
        #expect(replies == [nil, nil])
        // A new document ends a waiting chooser with no file, and so does quitting.
        tab.webContents(tab.webContents, runFileChooser: request) { replies.append($0) }
        let waiting = try #require(handed.last?.chooser)
        tab.webContents(tab.webContents, didCommitDocumentAt: URL(string: "https://example.org/next"))
        #expect(waiting.hasEnded && replies == [nil, nil, nil])
        tab.webContents(tab.webContents, runFileChooser: request) { replies.append($0) }
        let quitting = try #require(handed.last?.chooser)
        session.isQuitting = true
        #expect(quitting.hasEnded && replies == [nil, nil, nil, nil])
        session.isQuitting = false
        // A change of the tab's engine ends one.
        registry.register(SessionTestEngine(kind: .chromium))
        _ = session.runtime(for: .chromium, in: space.resolvedPersonaID)
        tab.webContents(tab.webContents, runFileChooser: request) { replies.append($0) }
        let switching = try #require(handed.last?.chooser)
        session.switchEngine(of: tab, to: .chromium)
        #expect(tab.engineKind == .chromium && switching.hasEnded && replies == [nil, nil, nil, nil, nil])
        // The tab's close ends one, and its late answer reaches no page.
        tab.webContents(tab.webContents, runFileChooser: request) { replies.append($0) }
        let closing = try #require(handed.last?.chooser)
        host.closeAgentTab(tab.id)
        #expect(closing.hasEnded && replies == [nil, nil, nil, nil, nil, nil])
        closing.deny()
        #expect(replies.count == 6 && handed.count == 5)
        // The user's own tab queues Arch's panel among its prompts and asks no service.
        let userTab = session.openTab(url: URL(string: "https://example.org/mine")!, in: space.id, select: false)
        userTab.webContents(userTab.webContents, runFileChooser: request) { _ in }
        #expect(session.prompts.hasPrompt(for: userTab.id) && handed.count == 5)
        session.prompts.dismiss(tabID: userTab.id)
    }

    @Test func sessionProtectsAgentTabsUntilTakeoverOrClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchAgentSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let host = BrowserAgentHost(session: session)
        let persona = session.addPersona(named: "Temporary")
        let space = try #require(session.spaces(in: persona.id).first)
        let ownership = AgentTabOwner(id: owner, spaceID: space.id, folderName: "Task")
        let address = URL(string: "https://example.org/task")!
        var events: [UUID: [AgentTabReport]] = [:]
        host.agentTabDidReport = { _, tab, report in events[tab, default: []].append(report) }
        func open() throws -> Tab {
            let info = try #require(host.openAgentTab(at: address, engine: .webKit, for: ownership))
            return try #require(session.tabs.first { $0.id == info.id })
        }

        var ownersAtPublication: [UUID?] = []
        let observer = session.$tabs.dropFirst().sink { tabs in
            ownersAtPublication.append(contentsOf: tabs.map(\.agentOwnerID))
        }
        let agent = try open()
        observer.cancel()
        #expect(ownersAtPublication == [owner])
        let folderID = try #require(agent.folderID)
        #expect(session.unloadCandidate(agent)?.exclusions.contains(.agent) == true)
        #expect(!session.canMoveFolder(folderID, toSpace: session.spaces[0].id))
        let copy = try #require(session.duplicateTab(agent))
        #expect(copy.folderID == nil && copy.agentOwnerID == nil)
        session.moveTab(copy.id, toFolder: folderID)
        session.moveTab(copy.id, to: agent)
        #expect(copy.folderID == nil)
        // The copy only pointed at a download. Its log entry belongs to it, and no closed record is kept.
        session.closeTab(copy, reason: .download)
        #expect(session.closeLog.entries.map(\.reason) == [.download])
        #expect(session.closeTab(agent))
        #expect(!session.hasClosedTabs && session.undoableCloseCount == 0)
        #expect(session.closeLog.entries.map(\.reason) == [.download])
        #expect(events[agent.id] == [.closed])
        #expect(!session.folders.contains { $0.id == folderID })

        let moved = try open()
        let oldFolder = moved.folderID
        session.moveOutOfFolder(moved)
        #expect(moved.agentOwnerID == nil && !session.folders.contains { $0.id == oldFolder })
        #expect(session.unloadCandidate(moved)?.exclusions.contains(.agent) == false)
        // A takeover followed immediately by a user close delivers one takeover event.
        session.requestCloseTab(moved)
        #expect(session.hasClosedTabs && session.undoableCloseCount == 1)

        let pinned = try open()
        session.togglePinned(pinned)
        #expect(pinned.agentOwnerID == nil && pinned.folderID == nil && pinned.isPinned)
        let kept = try open()
        let keptFolder = try #require(kept.folderID)
        session.keepTabs(ofFolder: keptFolder)
        #expect(kept.agentOwnerID == nil && kept.folderID == keptFolder)
        let released = try open()
        let deletedFolder = try #require(released.folderID)
        session.deleteFolder(deletedFolder)
        #expect(released.agentOwnerID == nil && released.folderID == nil)
        let deleted = try open()
        session.requestCloseTab(deleted)
        #expect(session.undoableCloseCount == 0)
        #expect(events[deleted.id] == [.closed])

        let temporary = try open()
        let silent = try open()
        host.closeAgentTab(silent.id)
        #expect(events[silent.id] == nil)
        session.deletePersona(persona.id)
        #expect(events[temporary.id] == [.closed])
        #expect(session.tabs.isEmpty && session.folders.isEmpty)
        #expect(session.closeLog.entries.filter { $0.reason == .persona }.count == 3)
        session.saveNow()
        let restored = try #require(SessionStore(directory: directory, seal: .fixture).load())
        #expect(Set(restored.closedTabs?.compactMap(\.id) ?? []) == [moved.id, pinned.id, kept.id, released.id])

        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        for tab in [moved, pinned, kept, released] {
            #expect(events[tab.id] == [.takenOver])
        }
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
        var cards = 0
        agentTab.presentPrompt = { _, completion in
            cards += 1
            completion(.answered(PromptAnswer(buttonID: "ok")))
        }

        // P8: denied without asking, through the session's denial that leaves the profile's kept answers as they were.
        var denied = 0
        agentTab.denyPermission = { _, completion in
            denied += 1
            completion(false)
        }
        var granted: Bool?
        agentTab.webContents(page, requestPermission: EnginePermissionRequest(origin: URL(string: "https://example.org")!, types: [.camera]), completion: { granted = $0 })
        #expect(granted == false && asked == 0 && denied == 1)
        // An agent tab never asks to be shown, as an opener's focus() on its popup would.
        var activations = 0
        agentTab.requestActivation = { activations += 1 }
        agentTab.webContentsDidRequestActivation(page)
        #expect(activations == 0)
        // P10: an alert is dismissed without a card; P9: a confirm waits for the user on a card.
        var dismissed = false
        // Each report names the frame's origin, by which the tool host keeps another site's text from the agent.
        let frame = URL(string: "https://widgets.example.net")!
        agentTab.webContents(page, runJavaScriptAlert: "Hello", frameOrigin: frame, completion: { dismissed = true })
        #expect(dismissed && cards == 0)
        var confirmed: Bool?
        agentTab.webContents(page, runJavaScriptConfirm: "Sure?", frameOrigin: nil, completion: { confirmed = $0 })
        #expect(confirmed == true && cards == 1)
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
        // A server redirect is asked about as a hop of the tab's navigation (P13), and a window the page opens elsewhere as a popup, never as a hop.
        #expect(agentTab.webContents(page, decidePolicyFor: EngineNavigationAction(url: URL(string: "https://example.org/hop")!, disposition: .currentTab, isUserInitiated: false, isRedirect: true)) == .allow)
        _ = agentTab.webContents(page, decidePolicyFor: EngineNavigationAction(url: URL(string: "https://example.org/window")!, disposition: .newWindow, isUserInitiated: false, isRedirect: true))
        #expect(monitor.asked == ["https://excluded.example/", "https://example.org/next", "https://example.org/hop", "https://example.org/window"].map { URL(string: $0)! })
        #expect(monitor.kinds == [.navigation, .navigation, .redirect, .popup])
        #expect(monitor.reports == [.permissionDenied([.camera]), .alertDismissed(message: "Hello", frame: frame), .dialogWaiting(.confirm, message: "Sure?"),
                                    .downloadAsked(URL(string: "https://example.org/file.zip")!), .externalAppAsked(URL(string: "mailto:someone@example.org")!),
                                    .downloadStarted(URL(string: "https://example.org/allowed.zip")!)])
        #expect(monitor.owners == Set([owner]))
        // P7: the tab hands every chooser to the session, which asks the agents' service first for an agent tab (`BrowserSession.chooseFiles(inAgentTab:owner:request:completion:)`); without the session's callback the page gets no file.
        var queued = 0
        let chooser = EngineFileChooserRequest(mode: .openFile, acceptedTypes: ["image/*"])
        var chosen: [URL]?? = .none
        agentTab.webContents(page, runFileChooser: chooser) { chosen = .some($0) }
        #expect(chosen == .some(nil) && monitor.choosers.isEmpty)

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
        userTab.chooseFiles = { _, completion in
            queued += 1
            completion([URL(fileURLWithPath: "/tmp/picked.png")])
        }
        userTab.webContents(userPage, runFileChooser: chooser) { chosen = .some($0) }
        #expect(chosen == .some([URL(fileURLWithPath: "/tmp/picked.png")]) && queued == 1)
        #expect(monitor.reports.count == 6)
    }
}

/// Records what agent tabs ask and report.
private final class MonitorDouble: AgentTabMonitor {
    var allows = true
    private(set) var asked: [URL] = []
    private(set) var kinds: [AgentLoadKind] = []
    private(set) var reports: [AgentTabReport] = []
    private(set) var owners: Set<UUID> = []

    func agentTab(_ tab: Tab, owner: UUID, mayLoad url: URL, kind: AgentLoadKind) -> Bool {
        asked.append(url)
        kinds.append(kind)
        owners.insert(owner)
        return allows
    }

    var allowedDownloads: Set<URL> = []

    func agentTab(_ tab: Tab, owner: UUID, mayDownload url: URL) -> Bool {
        allowedDownloads.contains(url)
    }

    private(set) var choosers: [AgentFileChooser] = []

    func agentTab(_ tab: Tab, owner: UUID, choosesFiles chooser: AgentFileChooser) {
        choosers.append(chooser)
        owners.insert(owner)
    }

    func agentTab(_ tab: Tab, owner: UUID, didReport report: AgentTabReport) {
        reports.append(report)
        owners.insert(owner)
    }

    func userDocumentDidEnd(in tabID: UUID, document: UUID) {}
    func userTabAddressDidChange(_ tabID: UUID) {}

    func agentTabDidClose(_ tab: Tab, owner: UUID) {}
}

/// An engine's page whose address and loading state the test sets, reporting to the tab as an engine does.
final class PageDouble: EngineWebContents {
    let engineKind: EngineKind
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
    let isCapturingMedia = false
    let isInPictureInPicture = false
    let closingStopsDownloads = false
    let devTools: (any EngineDevTools)? = nil

    init(url: URL?, engine: EngineKind = .webKit) {
        self.engineKind = engine
        self.url = url
    }

    /// Starts and finishes a load of `address`, as the engine reports one.
    @MainActor func load(_ address: URL, in tab: Tab) {
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
    func tryToClose(completion: @escaping (Bool) -> Void) { completion(true) }
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

/// The session's in-memory engine. Each call for a profile gets its own context, and pages report only the initial address.
final class SessionTestEngine: Engine, EngineApplication {
    let kind: EngineKind
    var unavailableStorageID: UUID?
    init(kind: EngineKind = .webKit) { self.kind = kind }
    var engineKind: EngineKind { kind }
    let capabilities: Set<EngineCapability> = []
    let extensionRuntimeVersion: String? = nil
    weak var delegate: (any EngineApplicationDelegate)?
    func makeApplication(configuration: EngineApplicationConfiguration) throws -> any EngineApplication { self }
    func removeStoredData(forStorage identifier: UUID, configuration: EngineApplicationConfiguration, completion: @escaping (Bool) -> Void) { completion(true) }
    func createBrowserContext(storageIdentifier: UUID?, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void) {
        if let unavailableStorageID, unavailableStorageID == storageIdentifier {
            completion(.failure(CocoaError(.fileReadUnknown)))
        } else {
            completion(.success(Context()))
        }
    }
    var readCookies: (@escaping ([EngineCookie]) -> Void) -> Void = { $0([]) }
    func createBrowser(context: any EngineBrowserContext) -> any EngineBrowser { Browser(kind: kind, readCookies: readCookies) }

    private final class Context: EngineBrowserContext {
        let downloads: any EngineDownloads = Downloads()
        let extensions: (any EngineExtensions)? = nil
        var preferences = EnginePreferences()
    }

    private final class Downloads: EngineDownloads {
        weak var delegate: (any EngineDownloadsDelegate)?
        let items: [any EngineDownloadItem] = []
    }

    private final class Browser: EngineBrowser {
        let kind: EngineKind
        let readCookies: (@escaping ([EngineCookie]) -> Void) -> Void
        init(kind: EngineKind, readCookies: @escaping (@escaping ([EngineCookie]) -> Void) -> Void) {
            self.kind = kind
            self.readCookies = readCookies
        }
        var cookiesDidChange: (() -> Void)?
        func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents { PageDouble(url: configuration.initialURL, engine: kind) }
        func takeOwnership(of webContents: any EngineWebContents) {}
        func closeWebContents(_ webContents: any EngineWebContents) {}
        func closeAllWebContents() {}
        func allCookies(completion: @escaping ([EngineCookie]) -> Void) { readCookies(completion) }
        func setCookies(_ cookies: [EngineCookie], completion: @escaping () -> Void) { completion() }
        func removeCookies(where shouldRemove: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void) { completion() }
        func removeSiteData(for origins: [URL], completion: @escaping () -> Void) { completion() }
    }
}
