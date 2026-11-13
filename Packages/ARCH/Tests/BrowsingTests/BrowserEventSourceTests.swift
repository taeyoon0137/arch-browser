// The browser event source on fake web contents: a new tab but no restored tabs, closes with each reason, `isRestore` and `isFirstLoadAfterOpen`, address changes with the previous address, title changes from each source but none when the shown name stays, selections and space switches with a Persona change but none while windows are restored, a finished download, and `Tab.pendingCause` on the next address change and load.
import AppKit
import ARCHEngine
import Combine
import Events
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct BrowserEventSourceTests {
    private let bus = BrowserEventBus()
    private let source: BrowserEventSource
    private let recorder = EventRecorder()
    private let persona = UUID()
    private let otherPersona = UUID()
    private let space = UUID()
    private let secondSpace = UUID()
    private let otherPersonaSpace = UUID()

    init() {
        source = BrowserEventSource(bus: bus)
        let personas = [space: persona, secondSpace: persona, otherPersonaSpace: otherPersona]
        source.personaOfSpace = { personas[$0] }
        let recorder = recorder
        bus.subscribe(BrowserEventFilter(tabKinds: Set(BrowserTabKind.allCases))) { recorder.events.append($0) }
    }

    private func makeTab(_ url: String? = "https://example.org/a", space: UUID? = nil, pinned: Bool = false, engine: EngineKind = .chromium) -> (Tab, EventTestPage) {
        let page = EventTestPage(engine: engine, url: url.map { URL(string: $0)! })
        return (Tab(id: UUID(), webContents: page, spaceID: space, isPinned: pinned, personaID: persona), page)
    }

    @Test func aNewTabPostsTabOpenedButRestoredAndImportedTabsDoNot() throws {
        let (restored, _) = makeTab(space: space)
        source.follow(tabs: [restored], postingNewTabs: false)
        #expect(recorder.events.isEmpty)
        let (opened, _) = makeTab(space: space)
        let (popup, _) = makeTab("https://example.org/sign-in", space: space)
        popup.opener = opened.webContents
        let (imported, _) = makeTab(space: space, pinned: true)
        imported.isRestored = true
        let (favorite, _) = makeTab(engine: .webKit)
        let (small, _) = makeTab(space: secondSpace)
        small.isInSmallWindow = true
        source.follow(tabs: [restored, opened, imported, favorite, small], postingNewTabs: true)
        source.follow(tabs: [restored, opened, imported, favorite, small, popup], postingNewTabs: true)
        #expect(recorder.payloads == [
            .tabOpened(tab: BrowserTabRef(id: opened.id, personaID: persona, spaceID: space, kind: .open, engine: .chromium, url: URL(string: "https://example.org/a")), openerTabID: nil),
            .tabOpened(tab: BrowserTabRef(id: favorite.id, personaID: persona, spaceID: nil, kind: .favorite, engine: .webKit, url: URL(string: "https://example.org/a")), openerTabID: nil),
            .tabOpened(tab: BrowserTabRef(id: small.id, personaID: persona, spaceID: secondSpace, kind: .smallWindow, engine: .chromium, url: URL(string: "https://example.org/a")), openerTabID: nil),
            .tabOpened(tab: BrowserTabRef(id: popup.id, personaID: persona, spaceID: space, kind: .open, engine: .chromium, url: URL(string: "https://example.org/sign-in")), openerTabID: opened.id),
        ])
        #expect(BrowserEventSource.kind(of: imported) == .pinned)
    }

    @Test func closesPostEachReasonWithTheTabsLastAddress() {
        let (tab, _) = makeTab("https://example.org/last", space: space, pinned: true)
        source.follow(tabs: [tab], postingNewTabs: false)
        let reasons: [TabCloseReason] = [.user, .page, .crash, .archive, .download, .webExtension]
        for reason in reasons { source.tabWillClose(tab, reason: BrowserTabCloseReason(reason)) }
        source.tabWillClose(tab, reason: .spaceDeleted)
        let ref = BrowserTabRef(id: tab.id, personaID: persona, spaceID: space, kind: .pinned, engine: .chromium, url: URL(string: "https://example.org/last"))
        #expect(recorder.payloads == [.user, .page, .crash, .archive, .download, .webExtension, .spaceDeleted].map { .tabClosed(tab: ref, reason: $0) })
    }

    @Test func loadsMarkARestoredTabsFirstLoadAndANewTabsFirstWebLoad() {
        let (restored, restoredPage) = makeTab(space: space)
        restored.isRestored = true
        source.follow(tabs: [restored], postingNewTabs: false)
        restored.webContentsDidFinishLoadingDocument(restoredPage)
        restored.webContentsDidFinishLoadingDocument(restoredPage)
        let (opened, openedPage) = makeTab("about:blank", space: space)
        source.follow(tabs: [restored, opened], postingNewTabs: true)
        opened.webContentsDidFinishLoadingDocument(openedPage)
        openedPage.url = URL(string: "https://example.org/b")
        opened.webContentsDidChangeURL(openedPage)
        opened.webContentsDidFinishLoadingDocument(openedPage)
        opened.webContentsDidFinishLoadingDocument(openedPage)
        // A tab without an address posts no load.
        let (blank, blankPage) = makeTab(nil, space: space)
        source.follow(tabs: [restored, opened, blank], postingNewTabs: false)
        blank.webContentsDidFinishLoadingDocument(blankPage)
        let loads = recorder.events.compactMap { event -> String? in
            guard case .pageLoaded(let tab, let isRestore, let isFirstLoadAfterOpen) = event.payload else { return nil }
            return "\(tab.id == restored.id ? "restored" : "opened") \(tab.url?.absoluteString ?? "") restore:\(isRestore) first:\(isFirstLoadAfterOpen)"
        }
        #expect(loads == [
            "restored https://example.org/a restore:true first:false",
            "restored https://example.org/a restore:false first:false",
            "opened about:blank restore:false first:false",
            "opened https://example.org/b restore:false first:true",
            "opened https://example.org/b restore:false first:false",
        ])
    }

    @Test func addressChangesCarryThePreviousAddressAndRepeatsPostNothing() {
        let (tab, page) = makeTab(space: space)
        source.follow(tabs: [tab], postingNewTabs: false)
        for address in ["https://example.org/b", "https://example.org/b", "https://example.org/b#part"] {
            page.url = URL(string: address)
            tab.webContentsDidChangeURL(page)
        }
        let changes = recorder.events.compactMap { event -> String? in
            guard case .addressChanged(let tab, let previousURL) = event.payload else { return nil }
            return "\(previousURL?.absoluteString ?? "") > \(tab.url?.absoluteString ?? "")"
        }
        #expect(changes == ["https://example.org/a > https://example.org/b", "https://example.org/b > https://example.org/b#part"])
    }

    @Test func titleChangesNameTheirSourceAndNoneWhenTheShownNameStays() {
        let (tab, page) = makeTab(space: space)
        source.follow(tabs: [tab], postingNewTabs: false)
        page.title = "Pricing"
        tab.webContentsDidChangeTitle(page)
        tab.customTitle = "Mine"
        tab.suggestedTitle = SuggestedTitle(title: "Hook", url: URL(string: "https://example.org/a")!)
        page.title = "Pricing 2"
        tab.webContentsDidChangeTitle(page)
        tab.customTitle = nil
        // Another address drops the hook's name.
        page.url = URL(string: "https://example.org/c")
        tab.webContentsDidChangeURL(page)
        // A page without a title shows its host.
        page.title = ""
        tab.webContentsDidChangeTitle(page)
        page.url = URL(string: "https://example.com/")
        tab.webContentsDidChangeURL(page)
        #expect(recorder.events.map(Self.describe) == [
            "titleChanged page", "titleChanged user", "titleChanged user",
            "addressChanged", "titleChanged suggested",
            "titleChanged page", "addressChanged", "titleChanged page",
        ])
        #expect(tab.displayTitle == "example.com")
    }

    @Test func selectionsAndSpaceSwitchesPostWithThePersonaChangeButNotWhileWindowsAreRestored() {
        let (tab, _) = makeTab(space: space)
        let (other, _) = makeTab(space: secondSpace)
        source.follow(tabs: [tab, other], postingNewTabs: false)
        let window = EventTestWindow(spaceID: space)
        source.follow(windows: [window])
        window.selectedTabID = tab.id
        window.selectedTabID = tab.id
        window.selectedTabID = nil
        window.currentSpaceID = secondSpace
        window.currentSpaceID = otherPersonaSpace
        source.restoringWindows {
            window.selectedTabID = other.id
            window.currentSpaceID = space
        }
        window.currentSpaceID = secondSpace
        // A window that closed is no longer followed.
        source.follow(windows: [])
        window.selectedTabID = tab.id
        #expect(recorder.payloads == [
            .tabSelected(tab: BrowserTabRef(id: tab.id, personaID: persona, spaceID: space, kind: .open, engine: .chromium, url: URL(string: "https://example.org/a")), windowID: window.id),
            .spaceSwitched(windowID: window.id, spaceID: secondSpace, personaID: persona, previousSpaceID: space, previousPersonaID: persona),
            .spaceSwitched(windowID: window.id, spaceID: otherPersonaSpace, personaID: otherPersona, previousSpaceID: secondSpace, previousPersonaID: persona),
            .spaceSwitched(windowID: window.id, spaceID: secondSpace, personaID: persona, previousSpaceID: space, previousPersonaID: persona),
        ])
    }

    @Test func aFinishedDownloadPostsItsNameTypeSizeAddressesAndTab() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchEventSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a1b2.pdf")
        try Data("pdf".utf8).write(to: file)
        let (tab, page) = makeTab(space: space)
        source.follow(tabs: [tab], postingNewTabs: false)
        let finished = EventTestDownload(page: page, targetPath: file)
        let failed = EventTestDownload(page: page, targetPath: folder.appendingPathComponent("b.zip"))
        let missing = EventTestDownload(page: nil, targetPath: folder.appendingPathComponent("gone.pdf"))
        let entries = [finished, failed, missing].map { DownloadEntry(item: $0, personaID: persona) }
        source.follow(downloads: entries)
        finished.state = .completed
        failed.state = .failed
        missing.state = .completed
        entries.forEach { $0.refresh() }
        #expect(await eventually { !recorder.events.isEmpty })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.payloads == [.downloadFinished(download: BrowserDownloadRef(id: entries[0].id, personaID: persona, tabID: tab.id, filename: "a1b2.pdf", mediaType: "application/pdf",
                                                                                      byteCount: 3, sourceURL: URL(string: "https://example.org/files/a1b2.pdf"), pageURL: URL(string: "https://example.org/files"),
                                                                                      isNamedByUser: false))])
    }

    @Test func aPendingCauseGoesToTheNextAddressChangeAndLoadOnly() {
        let cause = BrowserEventCause(origin: .agentSession(id: UUID()))
        let (tab, page) = makeTab(space: space)
        source.follow(tabs: [tab], postingNewTabs: false)
        tab.pendingCause = cause
        page.url = URL(string: "https://example.org/b")
        tab.webContentsDidChangeURL(page)
        tab.webContentsDidFinishLoadingDocument(page)
        #expect(tab.pendingCause == nil)
        page.url = URL(string: "https://example.org/c")
        tab.webContentsDidChangeURL(page)
        tab.webContentsDidFinishLoadingDocument(page)
        // A tab that code opens keeps the code's cause for its first load.
        let run = BrowserEventCause(origin: .hookRun(hook: UUID(), run: UUID()))
        let (opened, openedPage) = makeTab(space: space)
        bus.withCause(run) { source.follow(tabs: [tab, opened], postingNewTabs: true) }
        opened.webContentsDidFinishLoadingDocument(openedPage)
        #expect(recorder.events.map(\.cause) == [cause, cause, nil, nil, run, run])
    }

    private static func describe(_ event: BrowserEvent) -> String {
        guard case .titleChanged(_, let source) = event.payload else { return event.kind.rawValue }
        return "titleChanged \(source.rawValue)"
    }
}

/// The events a test's bus delivered, in order.
@MainActor
final class EventRecorder {
    var events: [BrowserEvent] = []
    var payloads: [BrowserEventPayload] { events.map(\.payload) }
}

/// A window whose selection and space the test sets.
final class EventTestWindow: BrowserEventWindow {
    let id = UUID()
    @Published var selectedTabID: UUID?
    @Published var currentSpaceID: UUID

    init(spaceID: UUID) {
        currentSpaceID = spaceID
    }

    var selectedTabIDs: AnyPublisher<UUID?, Never> { $selectedTabID.eraseToAnyPublisher() }
    var currentSpaceIDs: AnyPublisher<UUID, Never> { $currentSpaceID.eraseToAnyPublisher() }
}

/// A download whose state the test sets, started by `page`.
final class EventTestDownload: EngineDownloadItem {
    let sourceURL = URL(string: "https://example.org/files/a1b2.pdf")!
    let pageURL: URL? = URL(string: "https://example.org/files")
    weak var webContents: (any EngineWebContents)?
    let targetPath: URL?
    var state = EngineDownloadState.inProgress
    let completedBytes: Int64 = 3
    let totalBytes: Int64 = 3

    init(page: (any EngineWebContents)?, targetPath: URL) {
        webContents = page
        self.targetPath = targetPath
    }

    func pause() {}
    func resume() {}
    func cancel() {}
    func remove() {}
}

/// A page whose address, title, and engine the test sets; the tab reads them when the test reports a change.
final class EventTestPage: EngineWebContents {
    var engineKind: EngineKind
    var url: URL?
    var title = ""
    init(engine: EngineKind, url: URL?) {
        engineKind = engine
        self.url = url
    }

    let favicon: NSImage? = nil
    let isLoading = false
    let canGoBack = false
    let canGoForward = false
    let restorableState: Data? = nil
    let isAudible = false
    var zoomFactor = 1.0
    lazy var view = NSView()
    let navigationController: any EngineNavigationController = EventTestNavigation()
    let mediaSession: any EngineMediaSession = EventTestMedia()
    weak var uiDelegate: (any EngineWebContentsUIDelegate)?
    weak var navigationDelegate: (any EngineWebContentsNavigationDelegate)?
    weak var pageScriptDelegate: (any EnginePageScriptDelegate)?
    let closingStopsDownloads = false
    let devTools: (any EngineDevTools)? = nil

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

private final class EventTestMedia: EngineMediaSession {
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

private final class EventTestNavigation: EngineNavigationController, EngineBackForwardList {
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

/// Waits up to two seconds for the condition, and reports whether it held.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
