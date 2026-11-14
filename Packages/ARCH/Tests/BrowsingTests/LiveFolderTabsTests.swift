// Live folders in the sidebar (`docs/bookmarks.md`, Live folders: Items as tabs, Read and unread, and Interface; live folder rules 1, 4, 5, and 8): plans applied to item tabs on `PageStub` and stand-ins, their icons, titles, and restore state, dismissed items, item tabs leaving their folders, the read state that windows set, Convert to Folder and Delete Folder, the folder tree's refusals, and a private feed's address kept only in the Keychain store. Tabs run without a session or an engine, and the service runs with fetchers that never reach the network, so the session's calls, the rows, and the menus are regression check 72.
import AppKit
import ARCHEngine
import Foundation
import LiveFolders
import Testing
@testable import Browsing

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LiveFolderTabsTests {
    private let spaceID = UUID()
    private let personaID = UUID()
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let feed = LiveFolderConfiguration(source: .feed(address: URL(string: "https://blog.example.org/feed.xml")!, isPrivate: false))

    private func liveFolder(_ name: String = "News", in parent: TabFolder? = nil) -> TabFolder {
        var folder = TabFolder(spaceID: spaceID, name: name, isPinned: true)
        folder.parentID = parent?.id
        folder.live = feed
        return folder
    }

    private func item(_ id: String, title: String? = nil, date: Date? = nil, gitHub: GitHubItem? = nil) -> LiveItem {
        LiveItem(id: id, url: URL(string: "https://blog.example.org/\(id)")!, title: title ?? "Item \(id)", date: date, gitHub: gitHub)
    }

    /// An item's new tab as a plan makes it, without the session's callbacks.
    private func itemTab(_ item: LiveItem, in folder: TabFolder) -> Tab {
        let tab = Tab(id: UUID(), webContents: LiveFolderTabs.standIn(for: item, engine: .webKit, icon: nil), spaceID: folder.spaceID, isPinned: true, personaID: personaID)
        LiveFolderTabs.prepare(tab, as: item, inFolder: folder.id)
        return tab
    }

    /// An item's tab whose page a window loaded, showing `title` at the item's address.
    private func loadedItemTab(_ item: LiveItem, in folder: TabFolder, title: String = "Page") -> (tab: Tab, page: PageStub) {
        let tab = itemTab(item, in: folder)
        var made: PageStub?
        tab.loadPage { url, engine, _ in
            let page = PageStub(engine: engine, url: url)
            made = page
            return page
        }
        let page = made!
        page.report(url: item.url, title: title)
        return (tab, page)
    }

    private func store() throws -> LiveFolderStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchLiveFolderTabsTests-\(UUID().uuidString)", isDirectory: true)
        return LiveFolderStore(fileURL: folder.appendingPathComponent(LiveFolderStore.fileName))
    }

    /// `tabs` after a plan of `items` for `folder`, as the session applies one.
    private func applying(_ items: [LiveItem], to tabs: [Tab], in folder: TabFolder, dismissed: Set<String> = [], shown: Set<UUID> = []) -> (tabs: [Tab], removed: [Tab]) {
        let plan = LiveFolderReconciler.plan(items: items, tabs: LiveFolderTabs.reconcilerTabs(LiveFolderTabs.itemTabs(inFolder: folder.id, among: tabs)) { shown.contains($0.id) }, dismissed: dismissed)
        return LiveFolderTabs.applying(plan, toFolder: folder.id, in: tabs) { itemTab($0, in: folder) }
    }

    // MARK: Plans

    @Test func aPlanAddsStandInsInTheSourcesOrderKeepsTabsWithPagesOrShownAndRemovesTheRest() {
        let news = liveFolder()
        let outside = Tab(id: UUID(), webContents: PageStub(engine: .webKit, url: URL(string: "https://other.example/")), spaceID: spaceID, isPinned: true, personaID: personaID)
        let b = itemTab(item("b"), in: news)
        let gone = itemTab(item("gone"), in: news)
        let read = loadedItemTab(item("read"), in: news).tab
        let shown = itemTab(item("shown"), in: news)
        let after = Tab(id: UUID(), webContents: PageStub(engine: .webKit, url: nil), spaceID: spaceID, isPinned: false, personaID: personaID)

        let result = applying([item("a"), item("b", title: "B, retitled")], to: [outside, b, gone, read, shown, after], in: news, shown: [shown.id])
        #expect(result.removed.map(\.id) == [gone.id])
        // The folder's tabs take the source's order where its first tab was, then the tabs kept for items it no longer lists; other tabs keep their places.
        #expect(result.tabs.count == 6)
        #expect(result.tabs.first === outside && result.tabs.last === after)
        let added = result.tabs[1]
        #expect(result.tabs.dropFirst(2).prefix(3).map(\.id) == [b.id, read.id, shown.id])
        #expect(added.liveItemID == "a" && added.folderID == news.id && added.isPinned && !added.isLoaded && !added.isRestored)
        #expect(added.savedPage == SavedPage(url: item("a").url, title: "Item a"))
        #expect(added.url == item("a").url)
        #expect(added.displayTitle == "Item a")
        #expect(b.savedPage?.title == "B, retitled")
        #expect(b.displayTitle == "B, retitled")
        // A tab whose item is gone keeps its page without the item or a dot, and the item that came after the first fetch is unread.
        var state = LiveFolderState(items: [item("b")])
        state.recordSuccess(items: [item("a"), item("b", title: "B, retitled")], at: start)
        LiveFolderTabs.update(LiveFolderTabs.itemTabs(inFolder: news.id, among: result.tabs), from: state)
        #expect(read.liveItem == nil && !read.isUnread)
        #expect(added.liveItem == item("a") && added.isUnread)
    }

    @Test func anItemWhoseAddressChangedMovesItsTabsSavedPageAndStandIn() {
        let news = liveFolder()
        let tab = itemTab(item("a"), in: news)
        var moved = item("a")
        moved.url = URL(string: "https://blog.example.org/a-moved")!
        LiveFolderTabs.update([tab], from: LiveFolderState(items: [moved]))
        #expect(tab.savedPage == SavedPage(url: moved.url, title: "Item a"))
        #expect(tab.url == moved.url)
        #expect(!tab.isLoaded)
    }

    @Test func itemStandInsRequestNoSiteIconAtAPlanARelaunchOrAnUnload() {
        let news = liveFolder()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let standIn = LiveFolderTabs.standIn(for: item("a"), engine: .chromium, icon: icon)
        #expect(!standIn.requestsSiteIcon)
        #expect(standIn.favicon === icon)
        // A load on it, as Go Back to Saved Page makes, keeps the folder's icon and requests none.
        standIn.navigationController.load(URLRequest(url: URL(string: "https://blog.example.org/elsewhere")!))
        standIn.loadSiteIcon()
        #expect(standIn.favicon === icon)
        // At a relaunch, an item's record gives a stand-in that requests no icon; any other record's requests one.
        var record = SessionSnapshot.TabRecord(id: UUID(), spaceID: spaceID, url: item("a").url, title: "Item a", isPinned: true, folderID: news.id, liveItemID: "a")
        #expect(!UnloadedWebContents(record: record, defaultEngine: .webKit).requestsSiteIcon)
        record.liveItemID = nil
        #expect(UnloadedWebContents(record: record, defaultEngine: .webKit).requestsSiteIcon)
        // Unloading an item's tab, by hand or automatically, keeps it from requesting one.
        let (tab, _) = loadedItemTab(item("b"), in: news)
        _ = tab.unloadKeepingPage()
        #expect((tab.webContents as? UnloadedWebContents)?.requestsSiteIcon == false)
        let (other, _) = loadedItemTab(item("c"), in: news)
        _ = other.unloadToSavedPage()
        #expect((other.webContents as? UnloadedWebContents)?.requestsSiteIcon == false)
    }

    @Test func restoredItemTabsAreNotRestoredTabsAndShowTheirItemsTitle() {
        let news = liveFolder()
        let item = item("a", title: "The Post")
        let record = SessionSnapshot.TabRecord(id: UUID(), spaceID: spaceID, url: item.url, title: "Old page title", isPinned: true, folderID: news.id, savedPage: SavedPage(url: item.url, title: item.title), liveItemID: item.id)
        let tab = Tab(id: record.id!, webContents: UnloadedWebContents(record: record, defaultEngine: .webKit), spaceID: spaceID, isPinned: true, personaID: personaID)
        tab.restore(record, folderID: news.id)
        // Opening an item is the user's new choice: its first load is a visit, and a file it points at downloads.
        #expect(tab.liveItemID == item.id && !tab.isRestored && tab.recordedURL == nil)
        #expect(tab.displayTitle == "The Post")
        // A record whose folder is gone restores as an ordinary pinned tab.
        let ordinary = Tab(id: UUID(), webContents: UnloadedWebContents(record: record, defaultEngine: .webKit), spaceID: spaceID, isPinned: true, personaID: personaID)
        ordinary.restore(record, folderID: nil)
        #expect(ordinary.liveItemID == nil && ordinary.isRestored)
    }

    @Test func anItemTabShowsItsItemsTitleOnTheSavedPageAndThePagesTitleElsewhere() {
        let (tab, page) = loadedItemTab(item("a", title: "The Post"), in: liveFolder(), title: "Blog — The Post")
        #expect(tab.displayTitle == "The Post")
        page.report(url: URL(string: "https://blog.example.org/a#comments")!, title: "Blog — The Post")
        #expect(tab.displayTitle == "The Post")
        page.report(url: URL(string: "https://blog.example.org/about")!, title: "About")
        #expect(tab.displayTitle == "About")
        // No hook names an item's tab; the user's name wins.
        tab.suggestedTitle = SuggestedTitle(title: "Hook", url: URL(string: "https://blog.example.org/about")!)
        #expect(tab.displayTitle == "About")
        tab.customTitle = "Mine"
        #expect(tab.displayTitle == "Mine")
    }

    // MARK: Dismissing and leaving

    @Test func aDismissedItemStaysOutOfThePlansUntilShowDismissedItems() throws {
        let news = liveFolder()
        let store = try store()
        let items = [item("a"), item("b")]
        store.update(news.id) { $0.recordSuccess(items: items, at: start) }
        let a = itemTab(items[0], in: news)
        let b = itemTab(items[1], in: news)
        // Close on an item's tab dismisses it (`TabCloseAction.dismiss`): the session removes the tab and records the item.
        #expect(TabCloseAction.of(a, reason: .user) == .dismiss)
        store.update(news.id) { $0.dismiss("a") }
        var tabs = applying(items, to: [b], in: news, dismissed: store[news.id].dismissed).tabs
        #expect(tabs.map(\.liveItemID) == ["b"])
        store.update(news.id) { $0.restoreDismissed() }
        tabs = applying(items, to: tabs, in: news, dismissed: store[news.id].dismissed).tabs
        #expect(tabs.map(\.liveItemID) == ["a", "b"])
    }

    @Test func aDownloadOnlyItemTabUnloadsAndStaysInItsFolder() {
        let news = liveFolder()
        let (tab, page) = loadedItemTab(item("report.pdf"), in: news)
        #expect(TabCloseAction.of(tab, reason: .download) == .unload)
        let closed = tab.unloadToSavedPage()
        #expect(closed === page)
        #expect(!tab.isLoaded && tab.folderID == news.id && tab.liveItemID == "report.pdf" && tab.url == item("report.pdf").url)
        // The next plan keeps the tab rather than replacing it.
        let result = applying([item("report.pdf")], to: [tab], in: news)
        #expect(result.tabs.map(\.id) == [tab.id] && result.removed.isEmpty)
    }

    @Test func anItemTabMovedWithinThePinnedTabsKeepsItsSavedPageAndItsFolderGetsANewTabMarkedRead() throws {
        let news = liveFolder()
        let store = try store()
        store.update(news.id) { $0.recordSuccess(items: [item("a")], at: start) }
        let items = [item("a"), item("b")]
        store.update(news.id) { $0.recordSuccess(items: items, at: start.addingTimeInterval(60)) }
        let a = itemTab(items[0], in: news)
        let b = itemTab(items[1], in: news)
        LiveFolderTabs.update([a, b], from: store[news.id])
        #expect(b.isUnread)
        // A drag among the pinned tabs outside folders, as `moveTab(_:to:)` makes it.
        let left = LiveFolderTabs.itemTabsLeaving([a, b]) { b.folderID = nil }
        #expect(left.map(\.tab.id) == [b.id] && left.map(\.folderID) == [news.id])
        #expect(LiveFolderTabs.takeOut(left, in: store, at: start.addingTimeInterval(120)) == [news.id])
        #expect(b.liveItemID == nil && b.isPinned && !b.isUnread)
        #expect(b.savedPage == SavedPage(url: items[1].url, title: "Item b"))
        let result = applying(items, to: [a, b], in: news)
        let added = try #require(result.tabs.first { $0.liveItemID == "b" })
        #expect(added !== b && added.folderID == news.id)
        LiveFolderTabs.update(LiveFolderTabs.itemTabs(inFolder: news.id, among: result.tabs), from: store[news.id])
        #expect(!added.isUnread)
    }

    @Test func unpinningAnItemTabClearsItsSavedPageAndItsFolderGetsANewTab() throws {
        let news = liveFolder()
        let a = itemTab(item("a"), in: news)
        // Unpin Tab, as `togglePinned(_:)` makes it.
        let left = LiveFolderTabs.itemTabsLeaving([a]) {
            a.folderID = nil
            a.isPinned = false
        }
        _ = LiveFolderTabs.takeOut(left, in: try store(), at: start)
        #expect(a.liveItemID == nil && !a.isPinned && a.savedPage == nil)
        #expect(applying([item("a")], to: [a], in: news).tabs.compactMap(\.liveItemID) == ["a"])
        // A move that keeps the tab in its folder takes nothing out.
        let b = itemTab(item("b"), in: news)
        #expect(LiveFolderTabs.itemTabsLeaving([b]) { b.spaceID = UUID() }.isEmpty)
    }

    // MARK: Read and unread

    @Test func aWindowShowingAnItemTabAndThenAnotherMarksTheItemViewedBothTimes() throws {
        let issues = liveFolder("Issues")
        let store = try store()
        let first = start.addingTimeInterval(-3_600)
        let pull = GitHubItem(kind: .pullRequest, state: .open, repository: "owner/repo", number: 1, author: "someone")
        store.update(issues.id) { $0.recordSuccess(items: [item("1", date: first, gitHub: pull)], at: start) }
        let tab = itemTab(item("1", date: first, gitHub: pull), in: issues)
        // The pull request changes after the first fetch: it is unread.
        let changed = start.addingTimeInterval(60)
        store.update(issues.id) { $0.recordSuccess(items: [item("1", date: changed, gitHub: pull)], at: changed) }
        LiveFolderTabs.update([tab], from: store[issues.id])
        #expect(tab.isUnread)
        // A window shows the tab, and the user approves it while looking, which changes it again.
        let shown = start.addingTimeInterval(120)
        #expect(LiveFolderTabs.markViewed([tab], in: store, at: shown) == [issues.id])
        #expect(store[issues.id].viewedAt["1"] == shown)
        store.update(issues.id) { $0.recordSuccess(items: [item("1", date: shown.addingTimeInterval(30), gitHub: pull)], at: shown.addingTimeInterval(40)) }
        // The window shows another tab: the item counts as viewed then, so the approval stays read.
        let hidden = shown.addingTimeInterval(50)
        LiveFolderTabs.markViewed([tab], in: store, at: hidden, sparingMarkedUnread: true)
        #expect(store[issues.id].viewedAt["1"] == hidden)
        LiveFolderTabs.update([tab], from: store[issues.id])
        #expect(!tab.isUnread)
        // Mark as Unread while a window shows the tab lasts when the window stops showing it, and until a window shows it again.
        store.update(issues.id) { $0.markUnread("1") }
        #expect(LiveFolderTabs.markViewed([tab], in: store, at: hidden.addingTimeInterval(10), sparingMarkedUnread: true).isEmpty)
        LiveFolderTabs.update([tab], from: store[issues.id])
        #expect(tab.isUnread)
        LiveFolderTabs.markViewed([tab], in: store, at: hidden.addingTimeInterval(20))
        LiveFolderTabs.update([tab], from: store[issues.id])
        #expect(!tab.isUnread)
        // An ordinary tab marks nothing.
        let ordinary = Tab(id: UUID(), webContents: PageStub(engine: .webKit, url: nil), spaceID: spaceID, isPinned: true, personaID: personaID)
        #expect(LiveFolderTabs.markViewed([ordinary], in: store, at: hidden).isEmpty)
    }

    // MARK: Converting and deleting

    @Test func convertToFolderKeepsOrdinaryPinnedTabsAndRegisteringForgetsTheEntryAndThePrivateAddress() async throws {
        let (source, keychainAddress) = try LiveFolderSource.makeFeed(address: URL(string: "http://feeds.example.org/private.xml?token=secret#top")!)
        var folder = TabFolder(spaceID: spaceID, name: "Private", isPinned: true)
        folder.live = LiveFolderConfiguration(source: source)
        let address = try #require(keychainAddress)
        // `session.json` keeps the address without its query (live folder rule 8).
        let record = SessionSnapshot.TabRecord(id: UUID(), spaceID: spaceID, url: nil, title: "", isPinned: true, folderID: folder.id)
        let snapshot = SessionSnapshot(spaces: [Space(id: spaceID, name: "Personal")], currentSpaceID: spaceID, favorites: [], tabs: [record], folders: [folder])
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!encoded.contains("secret") && !encoded.contains("token"))
        #expect(encoded.contains(#""isPrivate":true"#))
        // The Keychain store keeps the whole address while the folder is a private feed's live folder.
        let keychain = InMemoryLiveFolderKeychain()
        let service = LiveFolderService(store: try store(), addresses: keychain, fetchers: OfflineFetchers(), isLowPowerMode: { false })
        try await service.setPrivateAddress(address, for: folder.id, folderName: folder.name)
        service.register(LiveFolderTabs.configurations(in: [folder]))
        #expect(try await keychain.address(for: folder.id) == URL(string: "https://feeds.example.org/private.xml?token=secret"))
        #expect(keychain.label(for: folder.id) == "Arch Live Folder: Private")
        #expect(service.store.folders[folder.id] != nil)

        let tab = itemTab(item("a"), in: folder)
        LiveFolderTabs.itemTabs(inFolder: folder.id, among: [tab]).forEach(LiveFolderTabs.takeOut)
        folder.live = nil
        #expect(tab.liveItemID == nil && tab.isPinned && tab.folderID == folder.id && tab.savedPage == SavedPage(url: item("a").url, title: "Item a"))
        service.register(LiveFolderTabs.configurations(in: [folder]))
        #expect(service.store.folders[folder.id] == nil)
        #expect(await waitUntil { keychain.folders.isEmpty })
        service.stop()
    }

    @Test func deletingALiveFolderOrItsPersonaLeavesNoClosedRecordsForItemTabs() {
        let work = TabFolder(spaceID: spaceID, name: "Work", isPinned: true)
        let news = liveFolder(in: work)
        let (tab, _) = loadedItemTab(item("a"), in: news)
        #expect(TabCloseAction.of(tab, reason: .persona) == .close(remember: false))
        #expect(TabCloseAction.close(remember: false).closedRecord(of: tab) == nil)
        // Delete Folder: each item tab is an ordinary pinned tab where the folder was until its page agrees to close, without a closed record.
        LiveFolderTabs.takeOut(tab)
        var tree = FolderTree(folders: [work, news], tabs: [tab])
        tree.deleteFolder(news.id)
        #expect(tree.folders.map(\.id) == [work.id])
        #expect(tab.folderID == work.id && tab.isPinned && tab.liveItemID == nil && tab.savedPage?.url == item("a").url)
        #expect(TabCloseAction.of(tab, reason: .user) == .unload)
    }

    // MARK: The folder tree

    @Test func dropsAndMovesIntoALiveFolderAreRefused() throws {
        let work = TabFolder(spaceID: spaceID, name: "Work", isPinned: true)
        let news = liveFolder(in: work)
        let other = TabFolder(spaceID: spaceID, name: "Other", isPinned: true)
        let entry = itemTab(item("a"), in: news)
        let ordinary = Tab(id: UUID(), webContents: PageStub(engine: .webKit, url: nil), spaceID: spaceID, isPinned: true, personaID: personaID)
        let tree = FolderTree(folders: [work, news, other], tabs: [entry, ordinary])
        #expect(tree.isLive(news.id) && !tree.isLive(work.id) && !tree.isLive(nil))
        #expect(!tree.canMoveTab(ordinary, into: news.id) && tree.canMoveTab(ordinary, into: work.id))
        #expect(!tree.canAddFolder(inside: news.id) && tree.canAddFolder(inside: work.id))
        #expect(!tree.canMoveFolder(other.id, into: news.id) && tree.canMoveFolder(other.id, into: work.id))
        #expect(tree.dropTarget(for: other.id, at: .onFolder(news.id)) == nil)
        #expect(tree.dropTarget(for: other.id, at: .onTab(entry.id)) == nil)
        // Move to Folder lists Work, which holds the live folder, without the live folder.
        let targets = tree.moveTargets(forTab: ordinary, pinned: true)
        #expect(targets.map(\.folder.id) == [work.id, other.id])
        #expect(targets.first?.inside.isEmpty == true)
        #expect(tree.moveTargets(forFolder: other.id).map(\.folder.id) == [work.id])
        // The live folder itself moves among ordinary folders.
        #expect(tree.canMoveFolder(news.id, into: other.id))
    }
}

extension LiveFolderState {
    /// A state that fetched `items` once.
    init(items: [LiveItem]) {
        self.init()
        recordSuccess(items: items, at: Date(timeIntervalSinceReferenceDate: 0))
    }
}

/// Fetchers that answer every fetch as offline, so that tests never reach the network or `gh`.
private struct OfflineFetchers: LiveFolderFetching {
    func fetchFeed(_ address: URL, validators: FeedValidators) async throws -> FeedFetchResult {
        throw LiveFolderError.offline
    }

    func searchGitHub(_ search: GitHubSearch, limit: Int) async throws -> GitHubSearchResult {
        throw LiveFolderError.offline
    }
}

/// Waits up to `limit` for `condition`, checking every 10 milliseconds.
private func waitUntil(_ limit: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
