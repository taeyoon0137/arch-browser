// Address suggestions from a history store in a folder of its own: pages whose address or title holds the text, most visited first, with SQL wildcard characters taken literally, and none for empty text. The pages hold made-up addresses only.
import Foundation
import History
import Testing

@Suite struct HistoryStoreTests {
    @Test func suggestionsMatchAddressOrTitleMostVisitedFirst() async throws {
        let folder = try TemporaryFolder()
        let store = HistoryStore(directory: folder.url)
        let mail = try #require(URL(string: "https://mail.example/"))
        let digest = try #require(URL(string: "https://news.example/"))
        for _ in 0..<3 { store.record(mail, title: "Inbox") }
        for _ in 0..<2 { store.record(digest, title: "Daily Mail Digest") }
        store.record(try #require(URL(string: "https://weather.example/")), title: "Weather")
        // The reads wait on the store's queue behind the recorded visits.
        #expect(await store.suggestions(for: "mail", limit: 10).map(\.url) == [mail, digest])
        #expect(await store.suggestions(for: " MAIL ", limit: 10).map(\.url) == [mail, digest])
        #expect(await store.suggestions(for: "mail", limit: 1).map(\.url) == [mail])
    }

    @Test func wildcardCharactersMatchThemselves() async throws {
        let folder = try TemporaryFolder()
        let store = HistoryStore(directory: folder.url)
        let percent = try #require(URL(string: "https://a.example/?off=100%25"))
        let underscore = try #require(URL(string: "https://b.example/"))
        store.record(percent, title: "Sale")
        store.record(try #require(URL(string: "https://c.example/1000")), title: "Thousand")
        store.record(underscore, title: "plan_b")
        store.record(try #require(URL(string: "https://d.example/")), title: "planxb")
        #expect(await store.suggestions(for: "100%", limit: 10).map(\.url) == [percent])
        #expect(await store.suggestions(for: "plan_b", limit: 10).map(\.url) == [underscore])
    }

    @Test func emptyTextHasNoSuggestions() async throws {
        let folder = try TemporaryFolder()
        let store = HistoryStore(directory: folder.url)
        store.record(try #require(URL(string: "https://a.example/")), title: "A")
        #expect(await store.suggestions(for: "", limit: 10).isEmpty)
        #expect(await store.suggestions(for: " \n", limit: 10).isEmpty)
    }
}

/// A folder of its own for one test's database, removed when the test ends.
private final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
