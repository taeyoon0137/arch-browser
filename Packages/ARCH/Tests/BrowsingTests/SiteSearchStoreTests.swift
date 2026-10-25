// Site search shortcuts that an import adds, a `site-search.json` that does not decode, and the palette's destination for a keyword whose template makes no web address, each test in a temporary folder of its own.
import Foundation
import Testing
@testable import Browsing

@Suite struct SiteSearchStoreTests {
    private static let defaultKeywords = SiteSearchStore.defaultShortcuts.map(\.keyword)
    private static let docs = SiteSearchShortcut(keyword: "docs", name: "Docs", template: "https://docs.example/search?q=%s")

    @Test func addingSkipsKeywordsInUseAndShortcutsThatCannotBeSaved() throws {
        let folder = try TemporaryFolder()
        let store = SiteSearchStore(directory: folder.url)
        let added = store.add([
            SiteSearchShortcut(keyword: "YT", name: "Videos", template: "https://videos.example/?q=%s"),
            Self.docs,
            SiteSearchShortcut(keyword: "docs", name: "Other Docs", template: "https://other.example/?q=%s"),
            SiteSearchShortcut(keyword: "two words", name: "Words", template: "https://words.example/?q=%s"),
            SiteSearchShortcut(keyword: "plain", name: "Plain", template: "https://plain.example/"),
            SiteSearchShortcut(keyword: "files", name: "Files", template: "file:///tmp/%s"),
            SiteSearchShortcut(keyword: "unnamed", name: " ", template: "https://unnamed.example/?q=%s"),
        ])
        #expect(added == 1)
        #expect(store.shortcuts.map(\.keyword) == Self.defaultKeywords + ["docs"])
        #expect(store.shortcuts.last?.template == Self.docs.template)
        #expect(SiteSearchStore(directory: folder.url).shortcuts.map(\.keyword) == Self.defaultKeywords + ["docs"])
    }

    @Test func anUndecodableFileMovesAsideAtTheFirstWrite() throws {
        let folder = try TemporaryFolder()
        try folder.write("{", to: "site-search.json")
        let store = SiteSearchStore(directory: folder.url)
        #expect(store.shortcuts.map(\.keyword) == Self.defaultKeywords)
        #expect(folder.contents("site-search.json") == "{")
        #expect(folder.contents("site-search.unreadable.json") == nil)

        #expect(store.add([Self.docs]) == 1)
        #expect(folder.contents("site-search.unreadable.json") == "{")
        #expect(SiteSearchStore(directory: folder.url).shortcuts.map(\.keyword) == Self.defaultKeywords + ["docs"])
        store.remove(Self.docs)
        #expect(folder.contents("site-search.unreadable.json") == "{")
        #expect(SiteSearchStore(directory: folder.url).shortcuts.map(\.keyword) == Self.defaultKeywords)
    }

    @Test func aKeywordWhoseTemplateMakesNoWebAddressSearchesTheWeb() throws {
        let folder = try TemporaryFolder()
        // Settings saves no such template, but the file can be edited by hand.
        try folder.write(#"{ "shortcuts": [{ "keyword": "docs", "name": "Docs", "url": "https://docs.example/search?q=%s" }, { "keyword": "bad", "name": "Bad", "url": "files %s" }] }"#, to: "site-search.json")
        let store = SiteSearchStore(directory: folder.url)
        #expect(BrowserSession.destination(forInput: "docs cats", siteSearch: store) == URL(string: "https://docs.example/search?q=cats"))
        let search = try #require(BrowserSession.destination(forInput: "bad cats", siteSearch: store))
        #expect(search.host == BrowserSession.searchURL.host)
        #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value == "bad cats")
    }
}

/// A folder of its own for one test's files, removed when the test ends.
private final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSiteSearchStoreTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: url.appendingPathComponent(name))
    }

    func contents(_ name: String) -> String? {
        (try? Data(contentsOf: url.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }
}
