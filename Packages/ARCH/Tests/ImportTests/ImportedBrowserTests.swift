// What the browser import reads from sources defined over temporary folders: the rows of a Chromium-format browser with a sidebar file, with items that cannot be read, and the one row of a WebKit-format browser. The files hold made-up addresses and names only.
import Browsing
import Foundation
import Testing
@testable import Import

@Suite struct ImportedBrowserTests {
    private static func chromium(_ folder: TemporaryFolder, sidebarFile: Bool = true) -> BrowserSource {
        BrowserSource(name: "Test Browser", bundleIdentifier: "test.browser",
                      layout: .chromium(userData: folder.url.appendingPathComponent("User Data"), sidebarFile: sidebarFile ? folder.url.appendingPathComponent("Sidebar.json") : nil),
                      privacySetting: .fullDiskAccess)
    }

    private static func url(_ host: String) -> URL {
        URL(string: "https://\(host)/")!
    }

    /// A sidebar file with two spaces of the default profile, one of them with nothing pinned, a space of a profile folder that `Local State` does not list, and the default profile's favorites.
    private static func writeSidebarFile(in folder: TemporaryFolder) throws {
        let items = SidebarItems.flat([
            SidebarItems.container("pinned-home", ["one"]),
            SidebarItems.tab("one", "https://one.example/", savedTitle: "One"),
            SidebarItems.container("pinned-empty", []),
            SidebarItems.container("pinned-elsewhere", ["nine"]),
            SidebarItems.tab("nine", "https://nine.example/", savedTitle: "Nine"),
            SidebarItems.container("unpinned", []),
            SidebarItems.container("favorites-default", ["favorite"]),
            SidebarItems.tab("favorite", "https://favorite.example/", savedTitle: "Favorite"),
        ])
        let spaces = SidebarItems.flat([
            SidebarItems.space("home", title: "Home", profile: SidebarItems.defaultProfile, pinned: "pinned-home", unpinned: "unpinned"),
            SidebarItems.space("empty", title: "Empty", profile: SidebarItems.defaultProfile, pinned: "pinned-empty", unpinned: "unpinned"),
            SidebarItems.space("elsewhere", title: "Elsewhere", profile: SidebarItems.customProfile("Profile 9"), pinned: "pinned-elsewhere", unpinned: "unpinned"),
        ])
        let topApps: [Any] = [SidebarItems.defaultProfile, "favorites-default"]
        try folder.write(SidebarItems.file(containers: [["items": items, "spaces": spaces, "topAppsContainerIDs": topApps]]), to: "Sidebar.json")
    }

    @Test func chromiumProfilesBringTheirSidebarItemsBookmarksHistoryAndShortcuts() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.writeJSON(["profile": [
            "info_cache": ["Default": ["name": "Personal"], "Profile 2": ["name": "Work"], "Profile 3": ["name": "Empty"]],
            "profiles_order": ["Default", "Profile 2", "Profile 3"],
            "last_used": "Profile 2",
        ]], to: "User Data/Local State")
        try Self.writeSidebarFile(in: folder)
        // The default profile's engines are all built in, so it has no shortcuts to bring.
        try folder.database("User Data/Default/Web Data", [
            ChromiumDatabases.keywordsTable, ChromiumDatabases.keyword("Built In", "builtin.example", "https://builtin.example/?q={searchTerms}", safe: 1, prepopulateID: 1),
        ])
        try folder.writeJSON(ChromiumBookmarks.file(bar: [ChromiumBookmarks.url("a", "A", "https://a.example/"), ChromiumBookmarks.folder("work", "Work", [ChromiumBookmarks.url("b", "B", "https://b.example/")])],
                                                    other: [ChromiumBookmarks.url("c", "C", "https://c.example/")]), to: "User Data/Profile 2/Bookmarks")
        try folder.database("User Data/Profile 2/History", [
            ChromiumDatabases.urlsTable,
            "INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES ('https://a.example/', 'A', 2, 0, 12622780800000000, 0)",
        ])
        try folder.database("User Data/Profile 2/Web Data", [
            ChromiumDatabases.keywordsTable,
            ChromiumDatabases.keyword("Engine", "engine.example", "https://engine.example/?q={searchTerms}", guid: "engine", safe: 1, prepopulateID: 3),
            ChromiumDatabases.keyword("Docs", "d", "https://docs.example/?q={searchTerms}"),
        ])
        try folder.writeJSON(["default_search_provider": ["guid": "engine"]], to: "User Data/Profile 2/Preferences")
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("User Data/Profile 3"), withIntermediateDirectories: true)

        let browser = ImportedBrowser.read(Self.chromium(folder))
        #expect(!browser.isBlockedByPrivacy)
        #expect(browser.defaultEngine == .bing)
        // The profile without anything to bring is left out, and the folder that only the sidebar file names comes last.
        let profiles = try browser.profiles.get()
        #expect(profiles.map(\.id.folder) == ["Default", "Profile 2", "Profile 9"])
        #expect(profiles.map(\.id.source) == ["test.browser", "test.browser", "test.browser"])
        #expect(profiles.map(\.name) == ["Personal", "Work", "Profile 9"])
        #expect(profiles.map(\.isFirst) == [true, false, false])

        let personal = profiles[0]
        #expect(try personal.favorites?.get().map(\.url) == [Self.url("favorite.example")])
        // The space with nothing pinned would not be made, so it is not counted.
        #expect(try personal.spaces?.get().map(\.name) == ["Home"])
        #expect(personal.pinnedTabCount(of: .spaces) == 1)
        #expect(personal.bookmarkFolders == nil)
        #expect(personal.history == nil)
        #expect(personal.searchKeywords == nil)

        let work = profiles[1]
        #expect(try work.favorites?.get().map(\.url) == [Self.url("a.example")])
        #expect(work.spaces == nil)
        #expect(try work.bookmarkFolders?.get().map(\.name) == ["Work", "Other Bookmarks"])
        #expect(work.pinnedTabCount(of: .bookmarkFolders) == 2)
        #expect(try work.count(of: .history)?.get() == 1)
        #expect(try work.searchKeywords?.get().shortcuts.map(\.keyword) == ["d"])
        let row = work.sidebarImport(of: [.favorites, .bookmarkFolders], browserName: "Test Browser")
        #expect(row.profileName == "Work")
        #expect(row.favorites.map(\.url) == [Self.url("a.example")])
        #expect(row.spaces.map(\.origin) == [.bookmarks])
        #expect(row.spaces.map(\.name) == ["Test Browser"])
        #expect(row.spaces.first?.folders.map(\.name) == ["Work", "Other Bookmarks"])
        #expect(work.sidebarImport(of: [.history, .searchShortcuts], browserName: "Test Browser").spaces.isEmpty)

        #expect(try profiles[2].spaces?.get().map(\.name) == ["Elsewhere"])
        #expect(profiles[2].favorites == nil)
    }

    @Test func itemsThatCannotBeReadAreReportedWithoutHidingTheOthers() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.writeJSON(["profile": ["info_cache": ["Default": ["name": "Personal"]]]], to: "User Data/Local State")
        let sidebarFile = try folder.write(Data("{".utf8), to: "Sidebar.json")
        let bookmarksFile = try folder.write(Data("[]".utf8), to: "User Data/Default/Bookmarks")
        try folder.database("User Data/Default/History", [
            ChromiumDatabases.urlsTable,
            "INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES ('https://a.example/', 'A', 1, 0, 12622780800000000, 0)",
        ])

        let browser = ImportedBrowser.read(Self.chromium(folder))
        let profile = try #require(try browser.profiles.get().first)
        // The favorites come from both files, so either one that cannot be read keeps all of them out.
        #expect(throws: ImportError.unreadableFile(sidebarFile)) { try profile.favorites?.get() }
        #expect(throws: ImportError.unreadableFile(sidebarFile)) { try profile.spaces?.get() }
        #expect(throws: ImportError.unreadableFile(bookmarksFile)) { try profile.bookmarkFolders?.get() }
        #expect(try profile.count(of: .history)?.get() == 1)
        // The favorites and spaces share the sidebar file's failure, which the profile reports once.
        #expect(profile.errors.map(\.localizedDescription) == [ImportError.unreadableFile(sidebarFile), ImportError.unreadableFile(bookmarksFile)].map(\.localizedDescription))
        #expect(profile.pinnedTabCount(of: .spaces) == 0)
        #expect(!browser.isBlockedByPrivacy)

        let localState = try folder.write(Data("{".utf8), to: "User Data/Local State")
        #expect(throws: ImportError.unreadableFile(localState)) { try ImportedBrowser.read(Self.chromium(folder)).profiles.get() }
    }

    @Test func aWebKitFormatBrowserHasOneRowNamedAfterIt() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bookmarks: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [
            WebKitBookmarks.list("bar", "BookmarksBar", [WebKitBookmarks.leaf("a", "A", "https://a.example/")]),
            WebKitBookmarks.list("trips", "Trips", [WebKitBookmarks.leaf("t", "T", "https://t.example/")]),
            WebKitBookmarks.list("reading", "com.apple.ReadingList", [WebKitBookmarks.leaf("r", "R", "https://r.example/")]),
        ]]
        let bookmarksFile = try folder.write(PropertyListSerialization.data(fromPropertyList: bookmarks, format: .binary, options: 0), to: "Bookmarks.plist")
        let historyFile = try folder.database("History.db", WebKitDatabases.historyTables + [
            "INSERT INTO history_items (id, url, visit_count) VALUES (1, 'https://a.example/', 3)",
            "INSERT INTO history_visits (history_item, visit_time, title, load_successful) VALUES (1, 100, 'A', 1)",
        ])
        let source = BrowserSource(name: "Test Browser", bundleIdentifier: "test.webkit", layout: .webKit(bookmarks: bookmarksFile, history: historyFile), privacySetting: .fullDiskAccess)

        let browser = ImportedBrowser.read(source)
        let profiles = try browser.profiles.get()
        #expect(profiles.map(\.name) == ["Test Browser"])
        #expect(profiles.map(\.isFirst) == [true])
        #expect(profiles.map(\.id) == [SidebarImport.Profile(source: "test.webkit", folder: "Default")])
        #expect(try profiles[0].favorites?.get().map(\.url) == [Self.url("a.example")])
        #expect(try profiles[0].bookmarkFolders?.get().map(\.name) == ["Bookmarks / Trips"])
        #expect(try profiles[0].count(of: .history)?.get() == 1)
        #expect(profiles[0].searchKeywords == nil)
        #expect(browser.defaultEngine == nil)
    }
}
