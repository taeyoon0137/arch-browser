// A history store in a folder of its own: address suggestions are pages whose address or title holds the text, most visited first, with SQL wildcard characters taken literally, and none for empty text; an import lets reads in between its batches and finishes before the store says its writes are done; removing pages takes only those, and a removal during an import holds for the import's later batches. The pages hold made-up addresses only.
import Foundation
@testable import History
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
        // Empty text never waits on the store's queue, so the visit is written before the folder goes.
        store.finishWrites()
    }

    /// Pages whose addresses all hold `page`, a batch at a time.
    private static func pages(batches: Int) -> [HistoryEntry] {
        (0..<batches * HistoryStore.importBatchSize).map { index in
            HistoryEntry(url: URL(string: "https://page\(index).example/")!, title: "", visitCount: 1, lastVisit: Date(timeIntervalSince1970: 100))
        }
    }

    @Test func readsRunBetweenImportBatches() async throws {
        let folder = try TemporaryFolder()
        let store = HistoryStore(directory: folder.url)
        let batches = 10
        store.importEntries(Self.pages(batches: batches))
        // The read waits for the batch that runs when it arrives, not for the rest of the import. It would see every page only if the store ran all ten batches before taking a read that arrived first.
        let seen = await store.suggestions(for: "page", limit: .max).count
        #expect(seen % HistoryStore.importBatchSize == 0)
        #expect(seen < batches * HistoryStore.importBatchSize)
        store.finishWrites()
        #expect(await store.suggestions(for: "page", limit: .max).count == batches * HistoryStore.importBatchSize)
    }

    @Test func finishingWritesWaitsForEveryImportBatch() async throws {
        let folder = try TemporaryFolder()
        let store = HistoryStore(directory: folder.url)
        store.importEntries(Self.pages(batches: 3))
        store.record(try #require(URL(string: "https://visit.example/")), title: "Visit")
        store.finishWrites()
        // A store opened on the file afterwards finds every page, as the app does at its next launch.
        let reopened = HistoryStore(directory: folder.url)
        #expect(await reopened.suggestions(for: "example", limit: .max).count == 3 * HistoryStore.importBatchSize + 1)
    }

    @Test func removingPagesTakesOnlyThose() async throws {
        let folder = try TemporaryFolder()
        let store = HistoryStore(directory: folder.url)
        let urls = try ["https://a.example/", "https://b.example/", "https://c.example/"].map { try #require(URL(string: $0)) }
        urls.forEach { store.record($0, title: "") }
        store.remove(Set(urls.prefix(2)))
        let remaining = await withCheckedContinuation { continuation in store.entries(since: .distantPast) { continuation.resume(returning: $0) } }
        #expect(remaining.map(\.url) == [urls[2]])
    }

    @Test func clearingHistoryDuringAnImportLeavesNoPages() async throws {
        let folder = try TemporaryFolder()
        let store = HistoryStore(directory: folder.url)
        // The clear arrives while the import writes its first batches, and the batches it has not written then leave out every page.
        store.importEntries(Self.pages(batches: 10))
        store.clear()
        store.finishWrites()
        #expect(await store.suggestions(for: "page", limit: .max).isEmpty)
    }

    @Test func removalsDuringAnImportHoldForItsLaterBatches() async throws {
        let folder = try TemporaryFolder()
        let store = HistoryStore(directory: folder.url)
        let batches = 4
        // Every other page was last visited after the range's start.
        var pages = Self.pages(batches: batches).enumerated().map { index, page in
            index.isMultiple(of: 2) ? page : HistoryEntry(url: page.url, title: page.title, visitCount: page.visitCount, lastVisit: Date(timeIntervalSince1970: 300))
        }
        // A page of a later batch that the user visited too, so the range takes its earlier visit from the import as well.
        let visited = pages[2 * HistoryStore.importBatchSize].url
        store.record(visited, title: "")
        let removed = pages[3 * HistoryStore.importBatchSize + 2].url
        store.importEntries(pages)
        store.removeEntries(since: Date(timeIntervalSince1970: 200))
        store.remove([removed])
        store.finishWrites()
        pages.removeAll { $0.lastVisit >= Date(timeIntervalSince1970: 200) || $0.url == visited || $0.url == removed }
        let remaining = await withCheckedContinuation { continuation in store.entries(since: .distantPast) { continuation.resume(returning: $0) } }
        #expect(Set(remaining.map(\.url)) == Set(pages.map(\.url)))
        #expect(remaining.count == batches * HistoryStore.importBatchSize / 2 - 2)
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
