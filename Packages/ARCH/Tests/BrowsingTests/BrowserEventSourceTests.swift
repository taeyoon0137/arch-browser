// The browser event source uses fake web contents. It reports a new tab but no restored tabs. It reports an agent folder's tab as `agent` with its owner. A name from code follows the suggested name rules and carries its cause, even while a WebKit navigation waits to commit. The hook host's tabs use their committed addresses. The source reports closes with each reason, `isRestore`, and `isFirstLoadAfterOpen`. Address changes include the previous address and report only addresses the tab commits. Title changes come from the input that supplies the shown name. An unchanged name posts no title change. An address the tab leaves before committing keeps the hook's name and posts no title change. A commit reports the document's address and ends an earlier name. The source reports selections and space switches with a Persona change, but none while restoring windows. It reports a finished download. `Tab.pendingCause` applies to the next address change and load. A load that ends without one drops it.
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
            .tabOpened(tab: BrowserTabRef(id: opened.id, personaID: persona, spaceID: space, kind: .open, engine: .chromium, url: URL(string: "https://example.org/a"), documentID: opened.documentID), openerTabID: nil),
            .tabOpened(tab: BrowserTabRef(id: favorite.id, personaID: persona, spaceID: nil, kind: .favorite, engine: .webKit, url: URL(string: "https://example.org/a"), documentID: favorite.documentID), openerTabID: nil),
            .tabOpened(tab: BrowserTabRef(id: small.id, personaID: persona, spaceID: secondSpace, kind: .smallWindow, engine: .chromium, url: URL(string: "https://example.org/a"), documentID: small.documentID), openerTabID: nil),
            .tabOpened(tab: BrowserTabRef(id: popup.id, personaID: persona, spaceID: space, kind: .open, engine: .chromium, url: URL(string: "https://example.org/sign-in"), documentID: popup.documentID), openerTabID: opened.id),
        ])
        #expect(BrowserEventSource.kind(of: imported) == .pinned)
    }

    /// An agent folder's tab posts as `agent` with its folder's owner. Only a filter that names the kind receives it. Once the tab leaves the folder, it posts as the user's.
    @Test func anAgentFoldersTabPostsAsAnAgentTabUntilItLeavesTheFolder() {
        let agentFolder = UUID()
        let owner = UUID()
        let (tab, _) = makeTab(space: space)
        tab.folderID = agentFolder
        tab.agentOwnerOfFolder = { $0 == agentFolder ? owner : nil }
        let userEvents = EventRecorder()
        bus.subscribe(BrowserEventFilter()) { userEvents.events.append($0) }
        source.follow(tabs: [tab], postingNewTabs: true)
        source.tabWillClose(tab, reason: .agent)
        let ref = BrowserTabRef(id: tab.id, personaID: persona, spaceID: space, kind: .agent, engine: .chromium, url: URL(string: "https://example.org/a"), documentID: tab.documentID,
                                agentOwnerID: owner)
        #expect(recorder.payloads == [.tabOpened(tab: ref, openerTabID: nil), .tabClosed(tab: ref, reason: .agent)])
        #expect(userEvents.events.isEmpty)
        tab.folderID = nil
        #expect(BrowserEventSource.kind(of: tab) == .open)
    }

    @Test func closesPostEachReasonWithTheTabsLastAddress() {
        let (tab, _) = makeTab("https://example.org/last", space: space, pinned: true)
        source.follow(tabs: [tab], postingNewTabs: false)
        let reasons: [TabCloseReason] = [.user, .page, .crash, .archive, .download, .webExtension, .plugin, .persona, .sync]
        for reason in reasons { source.tabWillClose(tab, reason: BrowserTabCloseReason(reason)) }
        let ref = BrowserTabRef(id: tab.id, personaID: persona, spaceID: space, kind: .pinned, engine: .chromium, url: URL(string: "https://example.org/last"), documentID: tab.documentID)
        #expect(recorder.payloads == [.user, .page, .crash, .archive, .download, .webExtension, .plugin, .spaceDeleted, .sync].map { .tabClosed(tab: ref, reason: $0) })
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

    @Test func aReloadSignalsDocumentReplacementAtCommitBeforeItsLoadEvent() {
        let (tab, page) = makeTab(space: space)
        let original = tab.documentID
        var replacements: [UUID] = []
        source.documentDidChange = { id, _, documentID in
            #expect(id == tab.id)
            replacements.append(documentID)
        }
        source.follow(tabs: [tab], postingNewTabs: false)
        tab.webContents(page, didCommitDocumentAt: tab.committedURL)
        #expect(replacements == [tab.documentID] && original != tab.documentID)
        #expect(recorder.events.isEmpty)
        tab.webContentsDidFinishLoadingDocument(page)
        #expect(recorder.events.last?.tab?.documentID == tab.documentID)
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

    /// Plugins and hook scripts rename tabs under this rule (`SessionPluginBrowserHost`). The title change carries the caller's cause.
    @Test func aNameFromCodeFollowsTheSuggestedNameRulesAndNamesItsCause() {
        let (tab, _) = makeTab(space: space)
        source.follow(tabs: [tab], postingNewTabs: false)
        let document = URL(string: "https://example.org/a#top")!
        let cause = BrowserEventCause(origin: .hookRun(hook: UUID(), run: UUID()), hookChain: [UUID()])
        // A test changes nothing.
        #expect(BrowserHooks.suggest("Named", for: document, to: tab, applying: false))
        #expect(tab.suggestedTitle == nil && recorder.events.isEmpty)
        #expect(bus.withCause(cause) { BrowserHooks.suggest("  Named  \nmore", for: document, to: tab, applying: true) })
        #expect(tab.suggestedTitle == SuggestedTitle(title: "Named", url: document) && tab.displayTitle == "Named")
        guard case .titleChanged(_, .suggested)? = recorder.events.last?.payload else {
            Issue.record("The name posted no title change.")
            return
        }
        #expect(recorder.events.last?.cause == cause)
        // The name belongs to the document the tab shows.
        #expect(!BrowserHooks.suggest("Other", for: URL(string: "https://example.org/b")!, to: tab, applying: true))
        #expect(BrowserHooks.suggest(nil, for: document, to: tab, applying: true))
        #expect(tab.suggestedTitle == nil)
        // A name the user turned down stays turned down. The user's own name wins.
        let refusal = SuggestedTitle(title: nil, url: document)
        tab.suggestedTitle = refusal
        #expect(!BrowserHooks.suggest("Again", for: document, to: tab, applying: true))
        #expect(BrowserHooks.suggest(nil, for: document, to: tab, applying: true))
        #expect(tab.suggestedTitle == refusal)
        tab.customTitle = "Mine"
        #expect(!BrowserHooks.suggest("Again", for: document, to: tab, applying: true))
        #expect(!BrowserHooks.suggest(nil, for: document, to: tab, applying: true))
    }

    /// A name from code may arrive while a WebKit navigation waits to commit. It posts its title change once the address settles. It keeps the cause of the code that gave it, so a hook does not run again for its own rename.
    @Test func aNameFromCodeWhileTheAddressWaitsPostsWithItsCauseOnceTheAddressSettles() {
        let named = URL(string: "https://example.org/pricing")!
        let (tab, page) = makeTab(named.absoluteString, space: space, engine: .webKit)
        source.follow(tabs: [tab], postingNewTabs: false)
        let cause = BrowserEventCause(origin: .hookRun(hook: UUID(), run: UUID()), hookChain: [UUID()])
        load(tab, page) {
            page.url = URL(string: "https://example.org/pricing.pdf")
            tab.webContentsDidChangeURL(page)
            #expect(bus.withCause(cause) { BrowserHooks.suggest("Plans", for: named, to: tab, applying: true) })
            #expect(recorder.events.isEmpty)
            // The navigation becomes a download. The tab shows its committed address again.
            page.isLoading = false
            page.url = named
            tab.webContentsDidChangeURL(page)
        }
        #expect(recorder.events.map(Self.describeAddress) == ["titleChanged suggested https://example.org/pricing"])
        #expect(recorder.events.first?.cause == cause)
        // The user's own name after it carries no cause.
        tab.customTitle = "Mine"
        #expect(recorder.events.count == 2 && recorder.events.last?.cause == nil)
    }

    /// The hook registry's tabs give each run tab its document and site checks. They therefore name the tab's committed address, not one a WebKit navigation shows before committing.
    @Test func theHookHostDescribesATabByItsCommittedAddress() {
        let (tab, page) = makeTab("https://example.org/a", space: space, engine: .webKit)
        page.isLoading = true
        page.url = URL(string: "https://example.net/b")
        tab.webContentsDidChangeURL(page)
        #expect(tab.url == URL(string: "https://example.net/b") && tab.committedURL == URL(string: "https://example.org/a"))
        #expect(BrowserHookHost.ref(tab) == BrowserTabRef(id: tab.id, personaID: persona, spaceID: space, kind: .open, engine: .webKit, url: URL(string: "https://example.org/a"), documentID: tab.documentID))
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
        // A hook names the tab. The user turns the name down.
        tab.suggestedTitle = SuggestedTitle(title: "Hook 2", url: URL(string: "https://example.com/")!)
        tab.suggestedTitle = SuggestedTitle(title: nil, url: URL(string: "https://example.com/")!)
        #expect(recorder.events.map(Self.describe) == [
            "titleChanged page", "titleChanged user", "titleChanged user",
            "addressChanged", "titleChanged page",
            "titleChanged page", "addressChanged", "titleChanged page",
            "titleChanged suggested", "titleChanged user",
        ])
        #expect(tab.displayTitle == "example.com")
    }

    @Test func anAddressThatChangesWhileThePageLoadsPostsOnceItCommits() {
        let (tab, page) = makeTab(space: space, engine: .webKit)
        source.follow(tabs: [tab], postingNewTabs: false)
        // WebKit reports a navigation's address before it commits. It reports the earlier address once the navigation becomes a download.
        load(tab, page) {
            page.url = URL(string: "https://example.org/file.dmg")
            tab.webContentsDidChangeURL(page)
            page.isLoading = false
            page.url = URL(string: "https://example.org/a")
            tab.webContentsDidChangeURL(page)
        }
        // A navigation that redirects and commits posts its last address once its document loads, before the load, as Chromium reports it.
        load(tab, page) {
            page.url = URL(string: "https://example.org/b")
            tab.webContentsDidChangeURL(page)
            page.url = URL(string: "https://example.org/c")
            tab.webContentsDidChangeURL(page)
            tab.webContentsDidFinishLoadingDocument(page)
        }
        // WebKit ends a load just before its document's load.
        load(tab, page) {
            page.url = URL(string: "https://example.org/d")
            tab.webContentsDidChangeURL(page)
        }
        tab.webContentsDidFinishLoadingDocument(page)
        #expect(recorder.events.map(Self.describeAddress) == [
            "addressChanged https://example.org/a > https://example.org/c", "pageLoaded https://example.org/c",
            "addressChanged https://example.org/c > https://example.org/d", "pageLoaded https://example.org/d",
        ])
    }

    @Test func anAddressTheTabLeavesBeforeItCommitsKeepsAHooksNameAndPostsNoTitleChange() {
        let named = URL(string: "https://example.org/pricing")!
        let (tab, page) = makeTab(named.absoluteString, space: space, engine: .webKit)
        tab.suggestedTitle = SuggestedTitle(title: "Plans", url: named)
        // A page without a title shows its host.
        let (untitled, untitledPage) = makeTab(space: space, engine: .webKit)
        source.follow(tabs: [tab, untitled], postingNewTabs: false)
        // WebKit reports a navigation's address before it commits. It reports the earlier address once the navigation becomes a download or the user stops it.
        for target in ["https://example.org/pricing.pdf", "https://example.net/"] {
            load(tab, page) {
                page.url = URL(string: target)
                tab.webContentsDidChangeURL(page)
                page.isLoading = false
                page.url = named
                tab.webContentsDidChangeURL(page)
            }
        }
        load(untitled, untitledPage) {
            untitledPage.url = URL(string: "https://example.net/file.zip")
            untitled.webContentsDidChangeURL(untitledPage)
            untitledPage.isLoading = false
            untitledPage.url = URL(string: "https://example.org/a")
            untitled.webContentsDidChangeURL(untitledPage)
        }
        #expect(recorder.events.isEmpty)
        #expect(tab.suggestedTitle == SuggestedTitle(title: "Plans", url: named) && tab.displayTitle == "Plans" && tab.committedURL == named)
        // A navigation that commits drops the name once its document loads. The page's earlier title then posts with the address, after it.
        load(tab, page) {
            page.url = URL(string: "https://example.net/")
            tab.webContentsDidChangeURL(page)
            page.title = "Example"
            tab.webContentsDidChangeTitle(page)
            tab.webContentsDidFinishLoadingDocument(page)
        }
        #expect(recorder.events.map(Self.describeAddress) == [
            "addressChanged https://example.org/pricing > https://example.net/", "titleChanged page https://example.net/", "pageLoaded https://example.net/",
        ])
        #expect(tab.suggestedTitle == nil && tab.displayTitle == "Example")
    }

    /// A document that commits while its load runs counts from the commit. Chromium reports the commit before the address. The address then posts with the new document. A hook's name for the earlier document goes long before the load ends.
    @Test func aDocumentThatCommitsDuringItsLoadPostsItsAddressAndDropsTheEarlierName() {
        let named = URL(string: "https://example.org/a")!
        let (tab, page) = makeTab(named.absoluteString, space: space)
        tab.suggestedTitle = SuggestedTitle(title: "Seoul Weather", url: named)
        source.follow(tabs: [tab], postingNewTabs: false)
        load(tab, page) {
            tab.webContents(page, didCommitDocumentAt: URL(string: "https://example.net/b"))
            #expect(tab.suggestedTitle == nil && tab.committedURL == URL(string: "https://example.net/b"))
            #expect(recorder.events.map(Self.describeAddress) == ["addressChanged https://example.org/a > https://example.net/b"])
            #expect(recorder.events.first?.tab?.documentID == tab.documentID)
            page.url = URL(string: "https://example.net/b")
            tab.webContentsDidChangeURL(page)
            tab.webContentsDidFinishLoadingDocument(page)
        }
        #expect(recorder.events.map(Self.describeAddress) == [
            "addressChanged https://example.org/a > https://example.net/b", "titleChanged page https://example.net/b", "pageLoaded https://example.net/b",
        ])
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
        // The source stops following a window when it closes.
        source.follow(windows: [])
        window.selectedTabID = tab.id
        #expect(recorder.payloads == [
            .tabSelected(tab: BrowserTabRef(id: tab.id, personaID: persona, spaceID: space, kind: .open, engine: .chromium, url: URL(string: "https://example.org/a"), documentID: tab.documentID), windowID: window.id),
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
                                                                                      isNamedByUser: false, tabKind: .open))])
    }

    @Test(arguments: [false, true])
    func anAgentDownloadStaysPrivateAfterTakeoverOrClose(closed: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (tab, page) = makeTab(space: space)
        tab.folderID = UUID()
        let owner = UUID()
        tab.agentOwnerOfFolder = { _ in owner }
        source.follow(tabs: [tab], postingNewTabs: false)
        let userEvents = EventRecorder()
        bus.subscribe(.everything) { userEvents.events.append($0) }
        let item = EventTestDownload(page: page, targetPath: file)
        let entry = DownloadEntry(item: item, personaID: persona)
        source.follow(downloads: [entry])

        tab.folderID = nil
        if closed {
            source.follow(tabs: [], postingNewTabs: false)
            item.webContents = nil
        }
        item.state = .completed
        entry.refresh()

        #expect(await eventually { !recorder.events.isEmpty })
        let event = try #require(recorder.events.last)
        guard case .downloadFinished(let download) = event.payload else {
            Issue.record("Expected a finished download")
            return
        }
        #expect(download.tabKind == .agent)
        #expect(download.tabID == (closed ? nil : tab.id))
        #expect(userEvents.events.isEmpty)
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

    @Test func aLoadThatEndsWithoutADocumentDropsThePendingCause() async {
        let cause = BrowserEventCause(origin: .agentSession(id: UUID()))
        let (tab, page) = makeTab(space: space)
        source.follow(tabs: [tab], postingNewTabs: false)
        tab.pendingCause = cause
        load(tab, page) {
            page.url = URL(string: "https://example.org/file.dmg")
            tab.webContentsDidChangeURL(page)
            page.isLoading = false
            page.url = URL(string: "https://example.org/a")
            tab.webContentsDidChangeURL(page)
        }
        #expect(await eventually { tab.pendingCause == nil })
        // The user's next navigation carries no cause.
        page.url = URL(string: "https://example.org/b")
        tab.webContentsDidChangeURL(page)
        tab.webContentsDidFinishLoadingDocument(page)
        // A document that loads just after its load ends, as on WebKit, still takes the cause.
        tab.pendingCause = cause
        load(tab, page) {
            page.url = URL(string: "https://example.org/c")
            tab.webContentsDidChangeURL(page)
        }
        tab.webContentsDidFinishLoadingDocument(page)
        #expect(tab.pendingCause == nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.events.map { "\($0.kind.rawValue) \($0.cause == cause)" } == ["addressChanged false", "pageLoaded false", "addressChanged true", "pageLoaded true"])
    }

    /// Runs `body` while the page loads, and ends the load after it.
    private func load(_ tab: Tab, _ page: EventTestPage, _ body: () -> Void) {
        page.isLoading = true
        tab.webContentsDidChangeLoadingState(page)
        body()
        page.isLoading = false
        tab.webContentsDidChangeLoadingState(page)
    }

    private static func describeAddress(_ event: BrowserEvent) -> String {
        switch event.payload {
        case .addressChanged(let tab, let previousURL): return "addressChanged \(previousURL?.absoluteString ?? "") > \(tab.url?.absoluteString ?? "")"
        case .pageLoaded(let tab, _, _): return "pageLoaded \(tab.url?.absoluteString ?? "")"
        case .titleChanged(let tab, let source): return "titleChanged \(source.rawValue) \(tab.url?.absoluteString ?? "")"
        default: return event.kind.rawValue
        }
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

/// A page whose address, title, and engine the test sets. The tab reads them when the test reports a change.
final class EventTestPage: EngineWebContents {
    var engineKind: EngineKind
    var url: URL?
    var title = ""
    init(engine: EngineKind, url: URL?) {
        engineKind = engine
        self.url = url
    }

    let favicon: NSImage? = nil
    var isLoading = false
    let canGoBack = false
    let canGoForward = false
    let restorableState: Data? = nil
    let isAudible = false
    let isCapturingMedia = false
    let isInPictureInPicture = false
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
    func executeJavaScriptWithoutUserGesture(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {}
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
