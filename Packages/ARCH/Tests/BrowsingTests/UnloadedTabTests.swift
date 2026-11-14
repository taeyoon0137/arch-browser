// A tab restored from `session.json` has no page until a window first shows it: its stand-in keeps the saved record, which saving writes back unchanged, it answers the tab's readers without a page, and the tab gets its engine's page once, at its saved address, engine, and state.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct UnloadedTabTests {
    private let spaceID = UUID()
    private let personaID = UUID()

    /// A saved record: a pinned WebKit tab with page state in a folder for even numbers, an open Chromium tab without state for odd ones, both with the user's or a hook's name.
    private func record(_ number: Int) -> SessionSnapshot.TabRecord {
        let url = URL(string: "https://site\(number).example/docs/page#part")!
        let isWebKit = number.isMultiple(of: 2)
        return SessionSnapshot.TabRecord(id: UUID(), spaceID: spaceID, url: url, title: "Page \(number)", customTitle: isWebKit ? "Mine \(number)" : nil, isPinned: isWebKit,
                                         folderID: isWebKit ? UUID() : nil, lastActivatedAt: Date(timeIntervalSinceReferenceDate: Double(number) * 60), engine: isWebKit ? .webKit : .chromium,
                                         state: isWebKit ? Data([1, 2, UInt8(number)]) : nil, personaID: personaID, suggestedTitle: isWebKit ? nil : SuggestedTitle(title: "Hook \(number)", url: url))
    }

    /// The tab as `BrowserSession.restoreTabs` makes it from `record`, with the same stand-in and record fields, in a folder that still exists, and without the session's callbacks and the site icon.
    private func restoredTab(_ record: SessionSnapshot.TabRecord) -> Tab {
        let tab = Tab(id: record.id!, webContents: UnloadedWebContents(record: record, defaultEngine: .chromium), spaceID: record.spaceID, isPinned: record.isPinned, personaID: record.personaID!)
        tab.restore(record, folderID: record.folderID)
        return tab
    }

    /// The tab's record as the session's snapshot writes it.
    private func savedRecord(of tab: Tab) -> SessionSnapshot.TabRecord {
        SessionSnapshot.TabRecord(tab, spaceID: tab.spaceID!, lastActivatedAt: tab.lastActivatedAt)
    }

    @Test func relaunchingWithFortySavedTabsCreatesOnlyTheShownTabsPagesAndSavesTheOthersUnchanged() {
        let records = (0..<40).map(record)
        let tabs = records.map(restoredTab)
        #expect(tabs.allSatisfy { !$0.isLoaded })
        #expect(tabs.map(savedRecord) == records)
        // One window shows the third tab. Another selects the first, with the second and third as panes of its split view, and leaves the third to the first window.
        let otherWindow = BrowserWindowModel.panesToShow([tabs[2]], selectedTabID: tabs[2].id, shownTabIDs: [], isShownInAnotherWindow: { _ in false })
        let window = BrowserWindowModel.panesToShow(Array(tabs.prefix(3)), selectedTabID: tabs[0].id, shownTabIDs: [], isShownInAnotherWindow: { $0 === tabs[2] })
        #expect(otherWindow.map(\.id) == [tabs[2].id])
        #expect(window.map(\.id) == [tabs[0].id, tabs[1].id])
        var created: [(url: URL?, engine: EngineKind, state: Data?)] = []
        for tab in otherWindow + window {
            tab.loadPage { url, engine, state in
                created.append((url, engine, state))
                return PageStub(engine: engine, url: url)
            }
        }
        #expect(created.count == 3)
        #expect(tabs.map(\.isLoaded) == [true, true, true] + Array(repeating: false, count: 37))
        #expect(tabs.dropFirst(3).map(savedRecord) == Array(records.dropFirst(3)))
    }

    /// A window keeps showing its selected tab and the panes it shows already, even while another window shows them too.
    @Test func aWindowKeepsItsSelectedTabAndShownPanes() {
        let tabs = (0..<3).map(record).map(restoredTab)
        let shown = BrowserWindowModel.panesToShow(tabs, selectedTabID: tabs[0].id, shownTabIDs: [tabs[1].id], isShownInAnotherWindow: { _ in true })
        #expect(shown.map(\.id) == [tabs[0].id, tabs[1].id])
    }

    /// WebKit reports the address it loaded with a user name and password, which the page's own `location.href` leaves out. The tab shows and saves it without them, and history records it without them.
    @Test func aTabKeepsItsAddressWithoutAUserNameAndPassword() {
        var saved = record(5)
        saved.url = URL(string: "https://alice:SECRETPW@site5.example/docs/page#part")
        let restored = restoredTab(saved)
        #expect(restored.url?.absoluteString == "https://site5.example/docs/page#part")
        #expect(savedRecord(of: restored).url == restored.url)
        let opened = Tab(id: UUID(), webContents: UnloadedWebContents(record: saved, defaultEngine: .webKit), spaceID: spaceID, isPinned: false, personaID: personaID)
        var visits: [URL] = []
        opened.recordVisit = { url, _ in visits.append(url) }
        opened.webContentsDidChangeLoadingState(opened.webContents)
        #expect(visits.map(\.absoluteString) == ["https://site5.example/docs/page#part"])
    }

    /// A record from a file without engines gets a stand-in, and so a page, of the default engine.
    @Test func aRecordWithoutAnEngineGetsTheDefaultEngine() {
        var record = record(3)
        record.engine = nil
        #expect(UnloadedWebContents(record: record, defaultEngine: .webKit).engineKind == .webKit)
        #expect(UnloadedWebContents(record: record, defaultEngine: .chromium).engineKind == .chromium)
    }

    @Test func aTabGetsItsPageOnceAtItsSavedAddressEngineAndState() {
        let record = record(4)
        let tab = restoredTab(record)
        var made: [(url: URL?, engine: EngineKind, state: Data?)] = []
        let make = { (url: URL?, engine: EngineKind, state: Data?) -> any EngineWebContents in
            made.append((url, engine, state))
            return PageStub(engine: engine, url: url)
        }
        tab.loadPage(make)
        let page = tab.webContents
        tab.loadPage(make)
        #expect(made.count == 1)
        #expect(made.first?.url == record.url)
        #expect(made.first?.engine == .webKit)
        #expect(made.first?.state == record.state)
        #expect(tab.isLoaded)
        #expect(tab.webContents === page)
        #expect(page.uiDelegate === tab)
        // The tab keeps its saved title until the page reports its own.
        #expect(tab.title == record.title)
        #expect(tab.url == record.url)
        #expect(tab.isLoading)
    }

    @Test func aLoadBeforeAWindowShowsTheTabReplacesTheSavedPage() {
        let tab = restoredTab(record(6))
        let next = URL(string: "https://other.example/start")!
        tab.webContents.navigationController.load(URLRequest(url: next))
        #expect(!tab.isLoaded)
        #expect(tab.url == next)
        #expect(tab.title.isEmpty)
        #expect(tab.pageTitle == "other.example")
        var made: (url: URL?, state: Data?)?
        tab.loadPage { url, engine, state in
            made = (url, state)
            return PageStub(engine: engine, url: url)
        }
        #expect(made?.url == next)
        #expect(made?.state == nil)
    }

    @Test func aTabWithoutItsPageAnswersItsReadersWithoutOne() {
        let record = record(8)
        let tab = restoredTab(record)
        let page = tab.webContents
        #expect(tab.engineKind == .webKit)
        #expect(!page.isLoading && !page.canGoBack && !page.canGoForward && !page.isAudible && !page.isInPictureInPicture)
        #expect(page.devTools == nil)
        #expect(page.mediaSession.playbackState == .none)
        #expect(page.navigationController.backForwardList.backList.isEmpty)
        // Reloading waits for the page, which loads its saved state once a window shows the tab.
        page.navigationController.reload()
        page.navigationController.goBack()
        #expect(page.url == record.url && page.restorableState == record.state)
        // Closing needs no agreement and stops no download.
        #expect(!page.closingStopsDownloads)
        var agreed: Bool?
        page.tryToClose { agreed = $0 }
        #expect(agreed == true)
        var found: EngineFindResult?
        page.find("page", forward: true, matchCase: false) { found = $0 }
        #expect(found?.numberOfMatches == 0)
        var readFailed = false
        page.readableContent(limit: 100) { result in
            if case .failure(EngineReadableContentError.unreadable) = result { readFailed = true }
        }
        #expect(readFailed)
        var capture: NSImage? = NSImage()
        page.captureViewport { capture = $0 }
        #expect(capture == nil)
    }
}

/// An engine's page as far as the tab tests need one: its engine, address, title, icon, page state, and capture, a load in progress, and the loads asked of it. `report(url:title:)` tells the tab what the page shows, as an engine does.
final class PageStub: EngineWebContents {
    let engineKind: EngineKind
    private(set) var url: URL?
    private(set) var title = ""
    init(engine: EngineKind, url: URL?) {
        engineKind = engine
        self.url = url
    }

    /// The page moves to `url`, then shows `title`, each reported to the tab.
    func report(url: URL?, title: String = "") {
        self.url = url
        uiDelegate?.webContentsDidChangeURL(self)
        self.title = title
        uiDelegate?.webContentsDidChangeTitle(self)
    }

    /// The addresses loaded through the navigation controller, in order.
    var loadedURLs: [URL?] { navigation.loadedURLs }

    /// The page's icon, page state, and capture, which a test sets as an engine's page would have them.
    var favicon: NSImage?
    var restorableState: Data?
    var isCapturingMedia = false
    let isLoading = true
    let canGoBack = false
    let canGoForward = false
    let isAudible = false
    let isInPictureInPicture = false
    var zoomFactor = 1.0
    lazy var view = NSView()
    private let navigation = NavigationStub()
    var navigationController: any EngineNavigationController { navigation }
    let mediaSession: any EngineMediaSession = MediaStub()
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

private final class MediaStub: EngineMediaSession {
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

private final class NavigationStub: EngineNavigationController, EngineBackForwardList {
    private(set) var loadedURLs: [URL?] = []
    var backForwardList: any EngineBackForwardList { self }
    let backList: [any EngineBackForwardListItem] = []
    func load(_ request: URLRequest) { loadedURLs.append(request.url) }
    func reload() {}
    func reloadWithoutCache() {}
    func stop() {}
    func goBack() {}
    func goForward() {}
    func go(to item: any EngineBackForwardListItem) {}
}
