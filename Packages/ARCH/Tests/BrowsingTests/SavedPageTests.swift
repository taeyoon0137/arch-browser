// Saved pages (`docs/bookmarks.md`, Saved pages; bookmark rules 2 and 3): a tab saves its page as it becomes pinned and forgets it as it is unpinned, takes the first address its page reports when it had none, compares addresses as rule 3 says, keeps its saved page in its records, and returns to it, replaces it, or edits it; a favorite takes its tab's page or an edited name and address, but not another favorite's address; an imported pinned tab is saved at its address, which keeps it out of the next import. Tabs run on `PageStub` and `UnloadedWebContents`, without a session or an engine.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct SavedPageTests {
    private let spaceID = UUID()
    private let personaID = UUID()
    private let home = URL(string: "https://site.example/home")!
    private let elsewhere = URL(string: "https://other.example/page")!

    /// A tab on a page that shows `url` with `title`.
    private func tab(at url: URL?, title: String = "", pinned: Bool) -> (tab: Tab, page: PageStub) {
        let page = PageStub(engine: .webKit, url: url)
        let tab = Tab(id: UUID(), webContents: page, spaceID: spaceID, isPinned: pinned, personaID: personaID)
        page.report(url: url, title: title)
        return (tab, page)
    }

    /// A pinned tab saved at `home` whose page has moved to `elsewhere`.
    private func pinnedTabThatLeftHome() -> (tab: Tab, page: PageStub) {
        let (tab, page) = tab(at: home, title: "Home", pinned: false)
        tab.isPinned = true
        page.report(url: elsewhere, title: "Other")
        return (tab, page)
    }

    /// The pinned tab as relaunching restores it from a record saved at `home` that was last at `elsewhere`, without its page.
    private func restoredPinnedTab() -> (tab: Tab, record: SessionSnapshot.TabRecord) {
        let record = SessionSnapshot.TabRecord(id: UUID(), spaceID: spaceID, url: elsewhere, title: "Other", isPinned: true, engine: .webKit, state: Data([1, 2]), personaID: personaID,
                                               savedPage: SavedPage(url: home, title: "Home"))
        let tab = Tab(id: record.id!, webContents: UnloadedWebContents(record: record, defaultEngine: .chromium), spaceID: spaceID, isPinned: true, personaID: personaID)
        tab.restore(record, folderID: nil)
        return (tab, record)
    }

    @Test func pinningSavesThePageAndUnpinningForgetsIt() {
        let (tab, page) = tab(at: home, title: "Home", pinned: false)
        #expect(tab.savedPage == nil)
        tab.isPinned = true
        #expect(tab.savedPage == SavedPage(url: home, title: "Home"))
        // Following a link or pinning again, as a drop among the pinned tabs does, keeps it.
        page.report(url: elsewhere, title: "Other")
        tab.isPinned = true
        #expect(tab.savedPage == SavedPage(url: home, title: "Home"))
        tab.isPinned = false
        #expect(tab.savedPage == nil)
        page.report(url: home, title: "Home")
        #expect(tab.savedPage == nil)
    }

    @Test func aPinnedTabWithoutAnAddressTakesTheFirstOneReported() {
        let (tab, page) = tab(at: nil, pinned: false)
        tab.isPinned = true
        #expect(tab.savedPage == nil)
        page.report(url: home)
        #expect(tab.savedPage == SavedPage(url: home, title: ""))
        // The empty title takes the first title the page shows at the saved address, and only there.
        page.report(url: elsewhere, title: "Other")
        #expect(tab.savedPage == SavedPage(url: home, title: ""))
        page.report(url: URL(string: "https://site.example/home/")!, title: "Home")
        #expect(tab.savedPage == SavedPage(url: home, title: "Home"))
        page.report(url: home, title: "Home, Renamed")
        #expect(tab.savedPage == SavedPage(url: home, title: "Home"))
        // A tab made pinned without a saved page, as one reopened from a record without an address, takes it the same way, and then the title its page shows there.
        let (reopened, reopenedPage) = self.tab(at: nil, pinned: true)
        reopenedPage.report(url: elsewhere, title: "Other")
        #expect(reopened.savedPage == SavedPage(url: elsewhere, title: "Other"))
        // The title the tab still shows from the page before is not the new page's.
        let (late, latePage) = self.tab(at: nil, title: "Previous", pinned: true)
        latePage.report(url: elsewhere)
        #expect(late.savedPage == SavedPage(url: elsewhere, title: ""))
    }

    @Test func aTabMadePinnedOnAPageThatHasItsAddressTakesItsSavedPageFromItsRecord() {
        // A WebKit page reports the address it opens at before its tab exists, so the tab learns no address to save from its page. A reopened tab therefore takes its saved page from its record, which `normalized()` fills for closed records of files before version 13 as well.
        let page = PageStub(engine: .webKit, url: home)
        let reopened = Tab(id: UUID(), webContents: page, spaceID: spaceID, isPinned: true, personaID: personaID)
        #expect(reopened.url == home)
        #expect(reopened.savedPage == nil)
        let record = SessionSnapshot.TabRecord(id: reopened.id, spaceID: spaceID, url: home, title: "Home", isPinned: true).repairingSavedPage()
        #expect(record.savedPage == SavedPage(url: home, title: "Home"))
    }

    @Test(arguments: [
        ("https://example.org/docs", "https://example.org/docs#part"),
        ("https://example.org/docs", "http://example.org/docs"),
        ("https://example.org/docs", "https://EXAMPLE.org/docs"),
        ("https://example.org/docs", "https://www.example.org/docs"),
        ("https://example.org/docs", "https://example.org/docs/"),
        ("https://example.org", "http://www.example.org/#top"),
        ("https://example.org/docs?page=2", "https://example.org/docs/?page=2"),
        ("file:///Users/me/notes.html", "file:///Users/me/notes.html#end"),
    ])
    func theseAddressesShowTheSamePage(_ first: String, _ second: String) throws {
        let first = try #require(URL(string: first)), second = try #require(URL(string: second))
        #expect(first.isSamePage(as: second))
        #expect(second.isSamePage(as: first))
        #expect(first.isSameSite(as: second))
    }

    @Test(arguments: [
        ("https://example.org/docs", "https://example.org/docs?page=2", true),
        ("https://example.org/docs?page=1", "https://example.org/docs?page=2", true),
        ("https://example.org/docs", "https://example.org/other", true),
        ("https://example.org/docs", "https://example.org/docs/more", true),
        ("https://example.org/docs", "https://example.org:8443/docs", true),
        ("https://example.org/docs", "https://docs.example.org/docs", false),
        ("https://example.org/docs", "https://other.example/docs", false),
        ("https://example.org/docs", "file:///docs", false),
        ("file:///Users/me/a.html", "file:///Users/me/b.html", true),
    ])
    func theseAddressesShowAnotherPage(_ first: String, _ second: String, onTheSameSite: Bool) throws {
        let first = try #require(URL(string: first)), second = try #require(URL(string: second))
        #expect(!first.isSamePage(as: second))
        #expect(!second.isSamePage(as: first))
        #expect(first.isSameSite(as: second) == onTheSameSite)
        #expect(second.isSameSite(as: first) == onTheSameSite)
    }

    @Test func aTabIsOffItsSavedPageAndSiteAsItsAddressMoves() {
        let (tab, page) = tab(at: home, title: "Home", pinned: false)
        tab.isPinned = true
        #expect(!tab.isOffSavedPage && !tab.isOffSavedSite)
        page.report(url: URL(string: "http://www.Site.example/home/#comments")!)
        #expect(!tab.isOffSavedPage && !tab.isOffSavedSite)
        page.report(url: URL(string: "https://site.example/account?tab=1")!)
        #expect(tab.isOffSavedPage && !tab.isOffSavedSite)
        page.report(url: elsewhere)
        #expect(tab.isOffSavedPage && tab.isOffSavedSite)
        // An unpinned tab has no saved page to be off.
        tab.isPinned = false
        #expect(!tab.isOffSavedPage && !tab.isOffSavedSite)
    }

    @Test func goBackLoadsTheSavedPage() {
        let (tab, page) = pinnedTabThatLeftHome()
        #expect(tab.isOffSavedPage)
        tab.goBack(toSavedPage: home)
        #expect(page.loadedURLs == [home])
    }

    @Test func goBackOnATabWithoutItsPageMovesItsStandInWithoutLoading() {
        let (tab, record) = restoredPinnedTab()
        #expect(tab.savedPage == record.savedPage)
        #expect(tab.isOffSavedPage && tab.isOffSavedSite)
        tab.goBack(toSavedPage: home)
        #expect(!tab.isLoaded)
        #expect(tab.url == home)
        #expect(tab.webContents.restorableState == nil)
        #expect(!tab.isOffSavedPage)
        #expect(tab.savedPage == record.savedPage)
    }

    @Test func useCurrentPageTakesTheTabsAddressAndTitle() {
        let (tab, _) = pinnedTabThatLeftHome()
        tab.useCurrentPageAsSavedPage()
        #expect(tab.savedPage == SavedPage(url: elsewhere, title: "Other"))
        #expect(!tab.isOffSavedPage)
        // An unpinned tab has no saved page to replace.
        let (open, _) = self.tab(at: elsewhere, title: "Other", pinned: false)
        open.useCurrentPageAsSavedPage()
        #expect(open.savedPage == nil)
    }

    @Test func editSavedAddressTakesAnAddressAndRefusesOtherText() throws {
        let (tab, page) = pinnedTabThatLeftHome()
        for text in ["", "   ", "two words", "nodot"] {
            #expect(!tab.setSavedAddress(fromInput: text))
            #expect(tab.savedPage == SavedPage(url: home, title: "Home"))
        }
        // The same page keeps its title; another page's title stays empty until the page shows one there.
        #expect(tab.setSavedAddress(fromInput: " site.example/home/#top "))
        #expect(tab.savedPage == SavedPage(url: try #require(URL(string: "https://site.example/home/#top")), title: "Home"))
        #expect(tab.setSavedAddress(fromInput: "https://news.example/today"))
        #expect(tab.savedPage == SavedPage(url: try #require(URL(string: "https://news.example/today")), title: ""))
        // A tab with its page stays where it is.
        #expect(page.loadedURLs.isEmpty)
        #expect(tab.url == elsewhere)
        // An unpinned tab has no saved address to edit.
        let (open, _) = self.tab(at: elsewhere, pinned: false)
        #expect(!open.setSavedAddress(fromInput: "example.org"))
        #expect(open.savedPage == nil)
    }

    @Test func editSavedAddressMovesTheStandInOfATabWithoutItsPage() throws {
        let (tab, _) = restoredPinnedTab()
        #expect(tab.setSavedAddress(fromInput: "news.example/today"))
        let address = try #require(URL(string: "https://news.example/today"))
        #expect(tab.savedPage == SavedPage(url: address, title: ""))
        #expect(!tab.isLoaded)
        #expect(tab.url == address)
    }

    @Test func aFavoriteCannotTakeTheAddressOfAnotherFavoriteOfItsPersona() throws {
        let other = UUID()
        let first = Favorite(url: try #require(URL(string: "https://a.example")), title: "A", personaID: personaID)
        let second = Favorite(url: try #require(URL(string: "https://b.example")), title: "B", personaID: personaID)
        let otherPersonas = Favorite(url: try #require(URL(string: "https://c.example")), title: "C", personaID: other)
        let favorites = [first, second, otherPersonas]
        #expect(!BrowserSession.canUse(second.url, asAddressOf: first, among: favorites))
        #expect(BrowserSession.canUse(first.url, asAddressOf: first, among: favorites))
        #expect(BrowserSession.canUse(otherPersonas.url, asAddressOf: first, among: favorites))
        #expect(BrowserSession.canUse(elsewhere, asAddressOf: first, among: favorites))
        #expect(BrowserSession.canUse(first.url, asAddressOf: otherPersonas, among: favorites))
    }

    @Test func aFavoriteTakesItsTabsPageUnlessAnotherFavoriteOfItsPersonaHasIt() throws {
        let favorite = Favorite(url: home, title: "Home", personaID: personaID)
        let other = Favorite(url: try #require(URL(string: "https://b.example")), title: "B", personaID: personaID)
        let favorites = [favorite, other]
        let (tab, page) = self.tab(at: elsewhere, title: "Other", pinned: false)
        let moved = try #require(favorite.usingCurrentPage(of: tab, among: favorites))
        #expect(moved.id == favorite.id)
        #expect(moved.url == elsewhere && moved.title == "Other")
        // A page without a title gives its host.
        page.report(url: URL(string: "https://news.example/today"))
        #expect(favorite.usingCurrentPage(of: tab, among: favorites)?.title == "news.example")
        page.report(url: other.url, title: "B")
        #expect(favorite.usingCurrentPage(of: tab, among: favorites) == nil)
        page.report(url: nil)
        #expect(favorite.usingCurrentPage(of: tab, among: favorites) == nil)
    }

    @Test func editFavoriteTakesANameAndAnAddressAndRefusesAnotherFavoritesAddress() throws {
        let favorite = Favorite(url: home, title: "Home", personaID: personaID)
        let other = Favorite(url: try #require(URL(string: "https://b.example")), title: "B", personaID: personaID)
        let favorites = [favorite, other]
        let edited = try #require(favorite.edited(name: " Start ", address: "news.example/today", among: favorites))
        #expect(edited.id == favorite.id)
        #expect(edited.title == "Start" && edited.url == URL(string: "https://news.example/today"))
        // An empty name keeps the old one.
        #expect(favorite.edited(name: "  ", address: "https://news.example", among: favorites)?.title == "Home")
        // Text that is no address and another favorite's address change nothing.
        for address in ["", "two words", "nodot", "https://b.example"] {
            #expect(favorite.edited(name: "Start", address: address, among: favorites) == nil)
        }
    }

    @Test func importedPinnedTabsAreSavedAtTheirAddressesAndKeepThemOutOfTheNextImport() throws {
        let row = SidebarImport(profile: SidebarImport.Profile(source: "test.browser", folder: "Default"), profileName: "Profile", favorites: [], spaces: [
            SidebarImport.SourceSpace(origin: .space("personal"), name: "Personal", tint: nil, pinnedItems: [SidebarImport.Item(sourceID: "home", url: home, title: "Home", customTitle: "Start")], folders: []),
        ])
        var sidebar = SidebarImport.Sidebar(personas: [Persona(id: Persona.defaultID, name: "Default")], spaces: [Space(id: spaceID, name: "Personal", personaID: Persona.defaultID)],
                                            folders: [], favorites: [], tabs: [])
        let pinned = try #require(SidebarImport.Plan(row, to: .persona(Persona.defaultID), entry: nil, in: sidebar).pinnedTabs.first)
        // The session opens it pinned at its address, on a page that already has it.
        let page = PageStub(engine: .webKit, url: pinned.url)
        let tab = Tab(id: pinned.id, webContents: page, spaceID: pinned.spaceID, isPinned: true, personaID: Persona.defaultID)
        tab.takeImport(pinned)
        #expect(tab.savedPage == SavedPage(url: home, title: "Home"))
        #expect(tab.customTitle == "Start")
        #expect(tab.isRestored && tab.recordedURL == home)
        // After its page went to another site, its saved page still counts as pinned, also without the record of the first import.
        page.report(url: elsewhere, title: "Other")
        let state = try #require(SidebarImport.Sidebar.TabState(tab))
        #expect(state.url == elsewhere && state.savedURL == home)
        sidebar.tabs = [state]
        #expect(SidebarImport.Plan(row, to: .persona(Persona.defaultID), entry: nil, in: sidebar).pinnedTabs.isEmpty)
    }

    @Test func recordsAndTheClosedListKeepTheSavedPage() {
        let (tab, _) = pinnedTabThatLeftHome()
        let record = SessionSnapshot.TabRecord(tab, spaceID: spaceID, lastActivatedAt: Date())
        #expect(record.url == elsewhere)
        #expect(record.savedPage == SavedPage(url: home, title: "Home"))
        #expect(record.closed.savedPage == record.savedPage)
        // A tab restored or reopened from the record returns with it.
        let restored = Tab(id: UUID(), webContents: UnloadedWebContents(record: record, defaultEngine: .webKit), spaceID: spaceID, isPinned: true, personaID: personaID)
        restored.restore(record, folderID: nil)
        #expect(restored.savedPage == record.savedPage)
        // An open tab's record has none.
        let (open, _) = self.tab(at: home, pinned: false)
        #expect(SessionSnapshot.TabRecord(open, spaceID: spaceID, lastActivatedAt: Date()).savedPage == nil)
    }

    @Test func normalizingRepairsSavedPagesByPinnedState() {
        let saved = SavedPage(url: home, title: "Home")
        func record(pinned: Bool, savedPage: SavedPage?) -> SessionSnapshot.TabRecord {
            SessionSnapshot.TabRecord(id: UUID(), spaceID: spaceID, url: elsewhere, title: "Other", isPinned: pinned, savedPage: savedPage)
        }
        let open = [record(pinned: true, savedPage: saved), record(pinned: true, savedPage: nil), record(pinned: false, savedPage: saved)]
        let closed = [record(pinned: true, savedPage: saved), record(pinned: true, savedPage: nil), record(pinned: false, savedPage: saved)]
        let snapshot = SessionSnapshot(spaces: [Space(id: spaceID, name: "Personal")], currentSpaceID: spaceID, favorites: [], tabs: open, closedTabs: closed).normalized()
        #expect(snapshot.tabs.map(\.savedPage) == [saved, SavedPage(url: elsewhere, title: "Other"), nil])
        #expect(snapshot.closedTabs?.map(\.savedPage) == [saved, SavedPage(url: elsewhere, title: "Other"), nil])
    }
}
