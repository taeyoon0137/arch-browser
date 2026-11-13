// Unloading (`docs/bookmarks.md`, Unloading; bookmark rules 4 and 5): what each way of closing does to each kind of tab, the stand-in a pinned tab takes when it closes and the one any tab takes when it unloads on its own, which tabs that no window shows unload, the reports that keep a tab loaded, the leave-page answer of an automatic unload, and Delete Tab's record. Tabs run on `PageStub` and `UnloadedWebContents`, without a session or an engine.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct TabUnloadingTests {
    private let spaceID = UUID()
    private let personaID = UUID()
    private let folderID = UUID()
    private let home = URL(string: "https://site.example/home")!
    private let elsewhere = URL(string: "https://other.example/page")!
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Every reason a tab closes for: ⌘W and the row's button, the page's `window.close()`, a crashed page, archiving, a tab that only pointed at a file, an extension's `tabs.remove`, and Delete Persona.
    private let reasons: [TabCloseReason] = [.user, .page, .crash, .archive, .download, .webExtension, .persona]

    /// A tab of the space, or a favorite's tab without `inSpace`, on a page in `engine` that shows `url` with `title`.
    private func tab(at url: URL, title: String, pinned: Bool, inSpace: Bool = true, engine: EngineKind = .webKit) -> (tab: Tab, page: PageStub) {
        let page = PageStub(engine: engine, url: url)
        let tab = Tab(id: UUID(), webContents: page, spaceID: inSpace ? spaceID : nil, isPinned: pinned, personaID: personaID)
        page.report(url: url, title: title)
        return (tab, page)
    }

    /// A pinned tab with the user's name in a folder, saved at `home`, whose page in `engine` moved to `elsewhere`.
    private func pinnedTabThatLeftHome(engine: EngineKind = .webKit) -> (tab: Tab, page: PageStub) {
        let (tab, page) = tab(at: home, title: "Home", pinned: false, engine: engine)
        tab.isPinned = true
        tab.folderID = folderID
        tab.customTitle = "Mine"
        page.report(url: elsewhere, title: "Other")
        return (tab, page)
    }

    private func candidate(_ kind: UnloadCandidate.Kind, inactiveFor interval: TimeInterval, _ exclusions: Set<UnloadExclusion> = []) -> UnloadCandidate {
        UnloadCandidate(id: UUID(), kind: kind, lastActivatedAt: now.addingTimeInterval(-interval), exclusions: exclusions)
    }

    private func inputMessage(_ value: String, mainFrame: Bool = true, world: String = TabUnloading.inputWorld) -> EnginePageScriptMessage {
        EnginePageScriptMessage(world: world, frameURL: elsewhere, isMainFrame: mainFrame, json: value)
    }

    // MARK: What closing does

    @Test func closingAPinnedTabUnloadsItOnEveryPathButDeletePersona() {
        let (tab, _) = pinnedTabThatLeftHome()
        for reason in reasons {
            #expect(TabCloseAction.of(tab, reason: reason) == (reason == .persona ? .close(remember: true) : .unload), "\(reason)")
        }
        #expect(TabCloseAction.unload.closedRecord(of: tab) == nil)
    }

    @Test func closingAFavoritesTabEndsItWithoutARecord() {
        let (tab, _) = tab(at: home, title: "Home", pinned: false, inSpace: false)
        for reason in reasons {
            #expect(TabCloseAction.of(tab, reason: reason) == .end, "\(reason)")
        }
        #expect(TabCloseAction.end.closedRecord(of: tab) == nil)
    }

    @Test func closingAnyOtherTabJoinsTheClosedListUnlessItOnlyPointedAtAFile() {
        let (tab, page) = tab(at: elsewhere, title: "Other", pinned: false)
        page.restorableState = Data([7])
        for reason in reasons {
            #expect(TabCloseAction.of(tab, reason: reason) == .close(remember: reason != .download), "\(reason)")
        }
        #expect(TabCloseAction.close(remember: false).closedRecord(of: tab) == nil)
        let record = TabCloseAction.close(remember: true).closedRecord(of: tab)
        #expect(record == SessionSnapshot.TabRecord(id: tab.id, spaceID: spaceID, url: elsewhere, title: "Other", isPinned: false, engine: .webKit, personaID: personaID))
    }

    // MARK: Close on a pinned tab

    @Test func closeLeavesAPinnedTabAStandInAtItsSavedPageWithoutState() {
        let (tab, page) = pinnedTabThatLeftHome()
        page.restorableState = Data([1, 2, 3])
        let id = tab.id
        let closed = tab.unloadToSavedPage()
        #expect(closed === page)
        #expect(page.uiDelegate == nil)
        // The same tab keeps its ID, pin, folder, saved page, and name, at its saved page without page state, and loading it again counts as a visit.
        #expect(tab.id == id && tab.isPinned && tab.folderID == folderID && tab.customTitle == "Mine")
        #expect(tab.savedPage == SavedPage(url: home, title: "Home"))
        #expect(!tab.isLoaded)
        #expect(tab.url == home && tab.title == "Home")
        #expect(tab.engineKind == .webKit)
        #expect(tab.webContents.restorableState == nil)
        #expect(tab.recordedURL == nil)
        let record = SessionSnapshot.TabRecord(tab, spaceID: spaceID, lastActivatedAt: now)
        #expect(record.id == id && record.isPinned && record.folderID == folderID && record.url == home && record.state == nil && record.savedPage == tab.savedPage)
        var made: (url: URL?, engine: EngineKind, state: Data?)?
        tab.loadPage { url, engine, state in
            made = (url, engine, state)
            return PageStub(engine: engine, url: url)
        }
        #expect(made?.url == home && made?.engine == .webKit && made?.state == nil)
    }

    @Test func aPinnedTabWithoutASavedPageUnloadsAtItsAddress() {
        let (tab, _) = tab(at: elsewhere, title: "Other", pinned: true)
        tab.savedPage = nil
        _ = tab.unloadToSavedPage()
        #expect(tab.url == elsewhere && tab.title == "Other" && !tab.isLoaded)
    }

    @Test func aDownloadOnlyPinnedTabUnloadsAndDownloadsItsFileWhenOpenedAgain() {
        let file = URL(string: "https://site.example/report.pdf")!
        let record = SessionSnapshot.TabRecord(id: UUID(), spaceID: spaceID, url: file, title: "", isPinned: true, engine: .chromium, personaID: personaID,
                                               savedPage: SavedPage(url: file, title: ""))
        let tab = Tab(id: record.id!, webContents: UnloadedWebContents(record: record, defaultEngine: .webKit), spaceID: spaceID, isPinned: true, personaID: personaID)
        tab.restore(record, folderID: nil)
        var downloads: [Bool] = []
        tab.didOpenOnlyDownload = { downloads.append($0) }
        tab.loadPage { url, engine, _ in PageStub(engine: engine, url: url) }
        // A restored tab does not fetch the file again, and closes as a tab that only pointed at a file.
        #expect(tab.webContents(tab.webContents, shouldDownload: file, hasPage: false) == false)
        #expect(TabCloseAction.of(tab, reason: .download) == .unload)
        _ = tab.unloadToSavedPage()
        #expect(!tab.isRestored && !tab.isLoaded && tab.url == file && tab.isPinned)
        tab.loadPage { url, engine, _ in PageStub(engine: engine, url: url) }
        #expect(tab.webContents(tab.webContents, shouldDownload: file, hasPage: false) == true)
        #expect(downloads == [false, true])
    }

    // MARK: Automatic unloading

    @Test func anAutomaticUnloadKeepsTheAddressTitleIconAndWebKitsPageState() {
        let (tab, page) = pinnedTabThatLeftHome(engine: .webKit)
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        page.favicon = icon
        tab.webContentsDidChangeFavicon(page)
        page.restorableState = Data([4, 5, 6])
        let id = tab.id
        #expect(tab.unloadKeepingPage() === page)
        #expect(!tab.isLoaded && tab.id == id && tab.folderID == folderID)
        #expect(tab.url == elsewhere && tab.title == "Other" && tab.favicon === icon)
        #expect(tab.savedPage == SavedPage(url: home, title: "Home"))
        #expect(tab.webContents.restorableState == Data([4, 5, 6]))
        var made: (url: URL?, engine: EngineKind, state: Data?)?
        tab.loadPage { url, engine, state in
            made = (url, engine, state)
            return PageStub(engine: engine, url: url)
        }
        #expect(made?.url == elsewhere && made?.engine == .webKit && made?.state == Data([4, 5, 6]))
    }

    /// The Chromium adapter keeps no page state, so the tab loads its last address without its back list.
    @Test func anAutomaticUnloadOfAChromiumPageKeepsNoState() {
        for inSpace in [true, false] {
            let (tab, _) = tab(at: elsewhere, title: "Other", pinned: false, inSpace: inSpace, engine: .chromium)
            _ = tab.unloadKeepingPage()
            #expect(!tab.isLoaded && tab.url == elsewhere && tab.title == "Other" && tab.engineKind == .chromium)
            var made: (url: URL?, state: Data?)?
            tab.loadPage { url, engine, state in
                made = (url, state)
                return PageStub(engine: engine, url: url)
            }
            #expect(made?.url == elsewhere && made?.state == nil)
        }
    }

    @Test func theArchiveTimerUnloadsPinnedTabsAndFavoritesAfterTheHours() {
        let pinned = candidate(.pinned, inactiveFor: 13 * 3600)
        let favorite = candidate(.favorite, inactiveFor: 12 * 3600)
        let open = candidate(.open, inactiveFor: 30 * 3600)
        let recent = candidate(.pinned, inactiveFor: 11 * 3600)
        let candidates = [pinned, favorite, open, recent]
        #expect(TabUnloading.tabsToUnload(candidates, now: now, after: 12, pressure: nil) == [pinned.id, favorite.id])
        #expect(TabUnloading.tabsToUnload(candidates, now: now, after: 1, pressure: nil) == [pinned.id, favorite.id, recent.id])
        #expect(TabUnloading.tabsToUnload(candidates, now: now, after: 0, pressure: nil).isEmpty)
    }

    @Test func memoryPressureUnloadsEveryTabThatNoWindowShows() {
        let pinned = candidate(.pinned, inactiveFor: 31 * 60)
        let open = candidate(.open, inactiveFor: 30 * 60)
        let recentOpen = candidate(.open, inactiveFor: 29 * 60)
        let favorite = candidate(.favorite, inactiveFor: 2 * 3600)
        let justLeft = candidate(.pinned, inactiveFor: 0)
        let candidates = [pinned, open, recentOpen, favorite, justLeft]
        #expect(TabUnloading.tabsToUnload(candidates, now: now, after: 12, pressure: .warning) == [pinned.id, open.id, favorite.id])
        #expect(TabUnloading.tabsToUnload(candidates, now: now, after: 12, pressure: .critical) == candidates.map(\.id))
        // With automatic unloading off, memory pressure unloads nothing either.
        #expect(TabUnloading.tabsToUnload(candidates, now: now, after: 0, pressure: .critical).isEmpty)
    }

    @Test(arguments: UnloadExclusion.allCases)
    func anExclusionKeepsATabLoaded(_ exclusion: UnloadExclusion) {
        let kept = candidate(.pinned, inactiveFor: 48 * 3600, [exclusion])
        let other = candidate(.open, inactiveFor: 48 * 3600)
        for pressure in [nil, UnloadPressure.warning, .critical] {
            #expect(!TabUnloading.tabsToUnload([kept, other], now: now, after: 12, pressure: pressure).contains(kept.id))
        }
        #expect(TabUnloading.tabsToUnload([kept, other], now: now, after: 12, pressure: .critical) == [other.id])
    }

    @Test func theUnloadSettingDefaultsToTwelveHours() {
        #expect(TabUnloading.unloadAfterHoursKey == "ARCHUnloadAfterHours")
        #expect(TabUnloading.unloadAfterHoursByDefault == 12)
    }

    // MARK: What keeps a tab loaded

    @Test func aTabFollowsItsPagesCaptureAndAStandInCapturesNothing() {
        let (tab, page) = tab(at: elsewhere, title: "Call", pinned: true)
        page.isCapturingMedia = true
        tab.webContentsDidChangeMediaCapture(page)
        #expect(tab.isCapturingMedia)
        page.isCapturingMedia = false
        tab.webContentsDidChangeMediaCapture(page)
        #expect(!tab.isCapturingMedia)
        page.isCapturingMedia = true
        tab.webContentsDidChangeMediaCapture(page)
        _ = tab.unloadKeepingPage()
        #expect(!tab.isCapturingMedia && !tab.webContents.isCapturingMedia)
    }

    @Test func theInputScriptRunsFirstInEveryFrameInAWorldOfItsOwn() {
        let script = TabUnloading.inputScript
        #expect(script.world == "arch.unloading")
        #expect(script.injectionTime == .documentStart && !script.mainFrameOnly)
        let plugin = EnginePageScript(world: "ARCHPlugin.sample", source: "() => {}", injectionTime: .documentEnd, mainFrameOnly: true)
        #expect(TabUnloading.pageScripts(withPluginScripts: [plugin]) == [script, plugin])
        #expect(TabUnloading.pageScripts(withPluginScripts: []) == [script])
    }

    @Test func theInputScriptsMessagesReadAsEvents() {
        #expect(TabUnloading.InputEvent(inputMessage("\"start\"")) == .start)
        #expect(TabUnloading.InputEvent(inputMessage("\"typed\"")) == .typed)
        #expect(TabUnloading.InputEvent(inputMessage("\"typed\"", mainFrame: false)) == .typed)
        // Only the main frame starts a document over, and other values and worlds are no events.
        #expect(TabUnloading.InputEvent(inputMessage("\"start\"", mainFrame: false)) == nil)
        #expect(TabUnloading.InputEvent(inputMessage("\"other\"")) == nil)
        #expect(TabUnloading.InputEvent(inputMessage("{\"typed\": true}")) == nil)
        #expect(TabUnloading.InputEvent(inputMessage("\"typed\"", world: "ARCHPlugin.sample")) == nil)
    }

    @Test func typedTextTurnsOnWithTypedAndOffWithANewDocument() {
        let (tab, page) = tab(at: elsewhere, title: "Draft", pinned: true)
        var forwarded: [String] = []
        tab.receivePageScriptMessage = { message, reply in
            forwarded.append(message.world)
            reply(nil)
        }
        var replies = 0
        let deliver = { (message: EnginePageScriptMessage, webContents: any EngineWebContents) in
            tab.webContents(webContents, didReceive: message) { _ in replies += 1 }
        }
        deliver(inputMessage("\"start\""), page)
        #expect(!tab.hasTypedInput)
        deliver(inputMessage("\"typed\"", mainFrame: false), page)
        #expect(tab.hasTypedInput)
        // A frame's document starts nothing over; the main frame's next document does.
        deliver(inputMessage("\"start\"", mainFrame: false), page)
        #expect(tab.hasTypedInput)
        deliver(inputMessage("\"start\""), page)
        #expect(!tab.hasTypedInput)
        // A page that no longer reports to the tab changes nothing, and the plugins never see the app's world.
        deliver(inputMessage("\"typed\""), PageStub(engine: .webKit, url: elsewhere))
        #expect(!tab.hasTypedInput)
        deliver(inputMessage("\"typed\""), page)
        deliver(inputMessage("\"hello\"", world: "ARCHPlugin.sample"), page)
        #expect(forwarded == ["ARCHPlugin.sample"])
        #expect(replies == 7)
        // Another web contents starts without typed text.
        #expect(tab.hasTypedInput)
        _ = tab.unloadKeepingPage()
        #expect(!tab.hasTypedInput)
    }

    @Test func anAutomaticUnloadAnswersTheLeavePageQuestionWithStay() {
        let (tab, page) = tab(at: elsewhere, title: "Draft", pinned: true)
        var selections = 0
        tab.requestSelection = { selections += 1 }
        tab.answersBeforeUnloadWithStay = true
        var answer: Bool?
        tab.webContents(page, runBeforeUnloadPanel: "Leave?") { answer = $0 }
        #expect(answer == false)
        #expect(selections == 0)
        // Another web contents ends the automatic unload's question.
        _ = tab.unloadKeepingPage()
        #expect(!tab.answersBeforeUnloadWithStay)
    }

    // MARK: Delete Tab

    @Test func deleteTabsRecordReopensPinnedInItsFolderWithItsSavedPage() {
        let (tab, page) = pinnedTabThatLeftHome()
        page.restorableState = Data([9])
        let record = TabCloseAction.close(remember: true).closedRecord(of: tab)
        #expect(record?.isPinned == true && record?.folderID == folderID && record?.url == elsewhere && record?.customTitle == "Mine")
        #expect(record?.savedPage == SavedPage(url: home, title: "Home"))
        #expect(record?.state == nil && record?.lastActivatedAt == nil)
        guard let record else { return }
        #expect(record.repairingSavedPage() == record)
        // ⌘Z reopens it under its ID, pinned, at its last address, with its saved page and folder.
        let reopenedPage = PageStub(engine: record.engine ?? .webKit, url: record.url)
        let reopened = Tab(id: record.id!, webContents: reopenedPage, spaceID: record.spaceID, isPinned: record.isPinned, personaID: personaID)
        reopened.reopen(record, folderID: record.folderID)
        reopenedPage.report(url: elsewhere, title: "Other")
        #expect(reopened.id == tab.id && reopened.isPinned && reopened.folderID == folderID && reopened.customTitle == "Mine")
        #expect(reopened.savedPage == SavedPage(url: home, title: "Home"))
        #expect(reopened.isOffSavedPage)
    }
}
