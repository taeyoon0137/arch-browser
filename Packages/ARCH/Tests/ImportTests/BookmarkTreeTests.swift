// Bookmark trees from Chromium-format JSON and WebKit-format property lists: the path rule that splits them into bar bookmarks and folders, and the file import's flattened favorites.
import Foundation
import Testing
@testable import Import

@Suite struct BookmarkTreeTests {
    /// A bar with nested and empty folders, a folder named like one in another root, and addresses that are not web pages.
    private let chromiumFile = ChromiumBookmarks.file(
        bar: [
            ChromiumBookmarks.url("a", "A", "https://a.example/"),
            ChromiumBookmarks.folder("work", "Work", [
                ChromiumBookmarks.url("b", "B", "https://b.example/"),
                ChromiumBookmarks.folder("docs", "Docs", [ChromiumBookmarks.url("c", "C", "https://c.example/")]),
            ]),
            ChromiumBookmarks.url("script", "Script", "javascript:void(0)"),
            ChromiumBookmarks.folder("bar-recipes", "Recipes", [ChromiumBookmarks.url("g", "G", "https://g.example/")]),
            ChromiumBookmarks.folder("empty", "Empty", []),
            ChromiumBookmarks.url("h", " ", "https://h.example/page"),
        ],
        other: [
            ChromiumBookmarks.url("d", "D", "https://d.example/"),
            ChromiumBookmarks.folder("other-recipes", "Recipes", [ChromiumBookmarks.url("e", "E", "https://e.example/")]),
            ChromiumBookmarks.url("file", "File", "file:///tmp/page.html"),
        ],
        synced: [
            ChromiumBookmarks.url("f", "F", "https://f.example/"),
            ChromiumBookmarks.url("internal", "Internal", "about:settings"),
        ]
    )

    @Test func chromiumFoldersBecomeFoldersNamedByTheirPaths() throws {
        let tree = try #require(BookmarkFile.chromiumTree(from: JSONSerialization.data(withJSONObject: chromiumFile)))
        let (barItems, folders) = tree.split()
        #expect(barItems.map(\.title) == ["A", "h.example"])
        #expect(barItems.map(\.sourceID) == ["a", "h"])
        #expect(folders.map(\.name) == ["Work", "Work \u{25B8} Docs", "Recipes", "Other Bookmarks", "Other Bookmarks \u{25B8} Recipes", "Mobile Bookmarks"])
        #expect(folders.map(\.sourceID) == ["work", "docs", "bar-recipes", "other", "other-recipes", "synced"])
        #expect(folders.map { $0.items.map(\.title) } == [["B"], ["C"], ["G"], ["D"], ["E"], ["F"]])
    }

    @Test func theFileImportFlattensChromiumBookmarksInFileOrder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.writeJSON(chromiumFile, to: "Bookmarks")
        let favorites = try ImportedFile.read(file).favorites
        #expect(favorites.map(\.title) == ["A", "B", "C", "G", "h.example", "D", "E", "F"])
        #expect(favorites.map(\.url.absoluteString) == ["https://a.example/", "https://b.example/", "https://c.example/", "https://g.example/",
                                                        "https://h.example/page", "https://d.example/", "https://e.example/", "https://f.example/"])
    }

    /// The top level holds the history entry, the Favorites bar, the bookmarks menu, the reading list, a folder, and a bookmark, in that order.
    private let webKitFile: [String: Any] = [
        "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "top", "Title": "",
        "Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "WebBookmarkUUID": "history", "Title": "History"],
            WebKitBookmarks.list("bar", "BookmarksBar", [WebKitBookmarks.leaf("a", "A", "https://a.example/"), WebKitBookmarks.list("x", "X", [WebKitBookmarks.leaf("b", "B", "https://b.example/")])]),
            WebKitBookmarks.list("menu", "BookmarksMenu", [WebKitBookmarks.leaf("c", "C", "https://c.example/")]),
            WebKitBookmarks.list("reading", "com.apple.ReadingList", [WebKitBookmarks.leaf("r", "R", "https://r.example/")]),
            WebKitBookmarks.list("y", "Y", [WebKitBookmarks.leaf("d", "D", "https://d.example/")]),
            WebKitBookmarks.leaf("e", "E", "https://e.example/"),
        ],
    ]

    @Test func webKitBarMenuAndTopLevelSplitAndTheReadingListStaysOut() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: webKitFile, format: .binary, options: 0)
        let (barItems, folders) = try #require(BookmarkFile.webKitTree(from: data)).split()
        #expect(barItems.map(\.title) == ["A"])
        #expect(folders.map(\.name) == ["Bookmarks", "X", "Bookmarks Menu", "Bookmarks \u{25B8} Y"])
        #expect(folders.map(\.sourceID) == ["top", "x", "menu", "y"])
        #expect(folders.map { $0.items.map(\.title) } == [["E"], ["B"], ["C"], ["D"]])
    }

    @Test func theFileImportFlattensWebKitBookmarksInFileOrder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.write(PropertyListSerialization.data(fromPropertyList: webKitFile, format: .xml, options: 0), to: "Bookmarks.plist")
        #expect(try ImportedFile.read(file).favorites.map(\.title) == ["A", "B", "C", "D", "E"])
    }
}
