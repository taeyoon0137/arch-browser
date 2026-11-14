// Unloading (`docs/bookmarks.md`, Unloading; bookmark rules 4 and 5): what each way of closing does to each kind of tab, the stand-in a pinned tab takes when it closes and the one any tab takes when it unloads on its own, the tab a window selects after a close or an unload, which tabs that no window shows unload, the hours setting, the reports that keep a tab loaded, the leave-page answer of an automatic unload, and Delete Tab's record. Tabs run on `PageStub` and `UnloadedWebContents`, without a session or an engine, so the session's side of each close, which keeps a pinned tab at its place in its list without a closed record or a Tab Close Log entry, is regression check 69.
import AppKit
import ARCHEngine
import Foundation
import JavaScriptCore
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
    private let reasons: [TabCloseReason] = [.user, .page, .crash, .archive, .download, .webExtension, .persona, .sync]

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

    @Test func closingAPinnedTabUnloadsItExceptForPersonaAndSyncDeletions() {
        let (tab, _) = pinnedTabThatLeftHome()
        for reason in reasons {
            #expect(TabCloseAction.of(tab, reason: reason) == (reason == .persona || reason == .sync ? .close(remember: true) : .unload), "\(reason)")
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

    @Test func closingALiveFolderItemsTabDismissesItUnlessItOnlyPointedAtAFileItsPageCrashedOrItsPersonaGoes() {
        let (tab, _) = tab(at: home, title: "Post", pinned: true)
        tab.folderID = folderID
        tab.liveItemID = "post"
        for reason in reasons {
            let expected: TabCloseAction = switch reason {
            case .user, .page, .webExtension: .dismiss
            case .persona, .sync: .close(remember: false)
            case .crash, .download, .archive: .unload
            }
            #expect(TabCloseAction.of(tab, reason: reason) == expected, "\(reason)")
        }
        // Close and an extension's `tabs.remove` dismiss the item, and no action leaves a closed record for it.
        #expect(TabCloseAction.of(tab, reason: .user) == .dismiss && TabCloseAction.of(tab, reason: .webExtension) == .dismiss)
        for action in [TabCloseAction.dismiss, .close(remember: false), .unload] {
            #expect(action.closedRecord(of: tab) == nil)
        }
        // Even a record that the closed list took would carry no item.
        #expect(TabCloseAction.close(remember: true).closedRecord(of: tab)?.closed.liveItemID == nil)
    }

    // MARK: The pinned tab's side of Close

    /// `Tab.unloadToSavedPage()`, which the session's Close on a pinned tab calls once the tab's windows have selected other tabs.
    @Test func unloadingToTheSavedPageLeavesThePinnedTabAStandInWithoutState() {
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

    // MARK: The selection after a close

    /// The tab a window picks among `tabs` after `tab` closes or unloads, with `shownElsewhere` shown by another window.
    private func selection(after tab: Tab, among tabs: [Tab], opener: Tab? = nil, splitNeighbor: Tab? = nil, shownElsewhere: [Tab] = []) -> Tab? {
        BrowserSession.tabToSelect(after: tab, opener: opener, splitNeighbor: splitNeighbor, among: tabs, spaceID: spaceID,
                                   isShownInAnotherWindow: { tab in shownElsewhere.contains { $0 === tab } })
    }

    /// A pinned tab of the space without its page, as Close leaves it, at `url`.
    private func unloadedPinnedTab(at url: URL) -> Tab {
        let (tab, _) = tab(at: url, title: "", pinned: true)
        _ = tab.unloadToSavedPage()
        return tab
    }

    @Test func twoPinnedTabsWhoseSavedPagesAreFilesDoNotSelectEachOther() {
        // Unloading the first after its download selects nothing, rather than the second, whose load would download its file and unload it in turn, back to the first.
        let first = tab(at: URL(string: "https://site.example/a.dmg")!, title: "", pinned: true).tab
        let second = unloadedPinnedTab(at: URL(string: "https://site.example/b.dmg")!)
        #expect(selection(after: first, among: [first, second]) == nil)
        #expect(selection(after: second, among: [first, second]) === first)
    }

    @Test func closingInASpaceOfPinnedTabsSelectsOnlyOneThatHasItsPage() {
        let selected = tab(at: home, title: "Home", pinned: true).tab
        let unloaded = unloadedPinnedTab(at: elsewhere)
        let loaded = tab(at: elsewhere, title: "Other", pinned: true).tab
        #expect(selection(after: selected, among: [selected, unloaded]) == nil)
        #expect(selection(after: selected, among: [selected, unloaded, loaded]) === loaded)
        #expect(selection(after: selected, among: [selected, unloaded, loaded], shownElsewhere: [loaded]) == nil)
    }

    @Test func anOpenTabWithoutItsPageStaysAChoiceBeforePinnedTabs() {
        let selected = tab(at: home, title: "Home", pinned: true).tab
        let pinned = tab(at: elsewhere, title: "Other", pinned: true).tab
        let restored = Tab(id: UUID(), webContents: UnloadedWebContents(url: elsewhere, title: "Other", engine: .webKit, state: nil), spaceID: spaceID, isPinned: false, personaID: personaID)
        let otherSpace = Tab(id: UUID(), webContents: PageStub(engine: .webKit, url: elsewhere), spaceID: UUID(), isPinned: false, personaID: personaID)
        #expect(selection(after: selected, among: [otherSpace, selected, pinned, restored]) === restored)
        #expect(selection(after: selected, among: [otherSpace, selected, pinned]) === pinned)
    }

    @Test func theOpenerAndThenTheSplitNeighborComeFirst() {
        let popup = tab(at: elsewhere, title: "Sign In", pinned: false).tab
        let opener = tab(at: home, title: "Home", pinned: true).tab
        let neighbor = tab(at: elsewhere, title: "Other", pinned: false).tab
        let open = tab(at: elsewhere, title: "Other", pinned: false).tab
        let tabs = [popup, open, neighbor, opener]
        #expect(selection(after: popup, among: tabs, opener: opener, splitNeighbor: neighbor) === opener)
        #expect(selection(after: popup, among: tabs, opener: opener, splitNeighbor: neighbor, shownElsewhere: [opener]) === neighbor)
        #expect(selection(after: popup, among: tabs, splitNeighbor: neighbor) === neighbor)
        #expect(selection(after: popup, among: tabs) === open)
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

    @Test func theUnloadSettingReadsItsHoursAndDefaultsToTwelve() throws {
        #expect(TabUnloading.unloadAfterHoursKey == "ARCHUnloadAfterHours")
        // A domain of the test's own, emptied when it starts and when it ends. macOS keeps an empty file for a removed domain, so the name stays the same on every run in a checkout.
        let name = "test.arch.tab-unloading.\(checkoutID)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(TabUnloading.unloadAfterHours(in: defaults) == 12)
        defaults.set(5, forKey: TabUnloading.unloadAfterHoursKey)
        #expect(TabUnloading.unloadAfterHours(in: defaults) == 5)
        defaults.set(0, forKey: TabUnloading.unloadAfterHoursKey)
        #expect(TabUnloading.unloadAfterHours(in: defaults) == 0)
        defaults.set(-3, forKey: TabUnloading.unloadAfterHoursKey)
        #expect(TabUnloading.unloadAfterHours(in: defaults) == 0)
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

    @Test func backgroundDraftAndMediaSurviveTimedArchivingAndImmediateRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        func openBackgroundPage() -> (Tab, PageStub) {
            let page = PageStub(engine: .webKit, url: home)
            let tab = session.adopt(page, spaceID: space.id, personaID: space.resolvedPersonaID, pinned: false, select: false)
            tab.lastActivatedAt = .distantPast
            return (tab, page)
        }
        let (draft, page) = openBackgroundPage()
        draft.webContents(page, didReceive: inputMessage("\"typed\"", mainFrame: false)) { _ in }
        let (capture, cameraPage) = openBackgroundPage()
        cameraPage.isCapturingMedia = true
        capture.webContentsDidChangeMediaCapture(cameraPage)
        let (radio, audioPage) = openBackgroundPage()
        audioPage.isAudible = true
        radio.webContentsDidChangeAudibleState(audioPage)
        let (movie, videoPage) = openBackgroundPage()
        videoPage.isInPictureInPicture = true
        let (idle, _) = openBackgroundPage()
        let (unloaded, _) = openBackgroundPage()
        _ = unloaded.unloadKeepingPage()

        // A quit before the timer runs must preserve the active pages in the restored sidebar.
        try session.saveNow().get()
        let restored = try BrowserSession(testRegistry: registry, directory: directory)
        let active = Set([draft.id, capture.id, radio.id, movie.id])
        #expect(Set(restored.tabs.map(\.id)) == active)
        session.archiveInactiveTabs()
        #expect(Set(session.tabs.map(\.id)) == active)
        #expect(!session.tabs.contains { $0 === idle || $0 === unloaded })
        #expect(draft.hasTypedInput && capture.isCapturingMedia)
        #expect(draft.lastActivatedAt > .distantPast && capture.lastActivatedAt > .distantPast)

        // Once the activity ends, these same tabs become eligible after the next idle period.
        draft.webContents(page, didReceive: inputMessage("\"start\"")) { _ in }
        cameraPage.isCapturingMedia = false
        capture.webContentsDidChangeMediaCapture(cameraPage)
        audioPage.isAudible = false
        radio.webContentsDidChangeAudibleState(audioPage)
        videoPage.isInPictureInPicture = false
        session.tabs.forEach { $0.lastActivatedAt = .distantPast }
        session.archiveInactiveTabs()
        #expect(session.tabs.isEmpty)
    }

    @Test func theInputScriptRunsFirstInEveryFrameInAWorldOfItsOwn() {
        let script = TabUnloading.inputScript
        #expect(script.world == "arch.unloading")
        #expect(script.injectionTime == .documentStart && !script.mainFrameOnly)
        let plugin = EnginePageScript(world: "ARCHPlugin.sample", source: "() => {}", injectionTime: .documentEnd, mainFrameOnly: true)
        #expect(TabUnloading.pageScripts(withPluginScripts: [plugin]) == [script, plugin])
        #expect(TabUnloading.pageScripts(withPluginScripts: []) == [script])
    }

    @Test func restoredFramesReportDraftsInEitherOrderAndAnUntouchedPageDoesNotInheritOne() throws {
        let js = try #require(JSContext())
        // Each install gets the page script's own Window and event handlers, sharing only the tab's two messages.
        js.evaluateScript("""
        let protectedTab = false;
        function frame(isMain) {
          const window = {};
          window.top = isMain ? window : {};
          const events = {};
          const addEventListener = (name, handler) => { events[name] = handler; };
          (\(TabUnloading.inputScript.source))({send: message => { protectedTab = message === 'typed'; }});
          return (name, trusted = true) => events[name]?.({ isTrusted: trusted, persisted: true });
        }
        const parent = frame(true), child = frame(false);
        child('input');
        """)
        func protected(after events: String) -> Bool {
            js.evaluateScript(events + "; protectedTab").toBool()
        }
        #expect(protected(after: "parent('pagehide', false)"))
        #expect(!protected(after: "parent('pagehide'); const other = frame(true)"))
        #expect(protected(after: "other('pagehide'); child('pageshow'); parent('pageshow')"))
        #expect(protected(after: "parent('pagehide'); other('pageshow'); other('pagehide'); parent('pageshow'); child('pageshow')"))
        #expect(!protected(after: "parent('pagehide'); other('pageshow')"))
        #expect(!protected(after: "child('pageshow', false); other('input', false)"))
        #expect(js.exception == nil)
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

/// A part of the defaults name that stays the same on every run in a checkout and differs between checkouts, so that runs in two checkouts at the same time keep apart, while SwiftPM runs one command at a time in a checkout's build folder: a hash of this file's path.
private let checkoutID = String(#filePath.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 36)
