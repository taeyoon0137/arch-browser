// A history store in a folder of its own: address suggestions are pages of one Persona whose address or title holds the text, most visited first, with SQL wildcard characters taken literally, and none for empty text; each Persona's visits, removals, clears, and imports stay apart; a file from before visits recorded their Persona gives its pages to the default Persona; an import lets reads in between its batches and finishes before the store says its writes are done; removing pages takes only those, and a removal during an import holds for the import's later batches. The pages hold made-up addresses only.
import Foundation
@testable import History
import SQLite3
import Testing

@Suite struct HistoryStoreTests {
    private static let persona = UUID()
    private static let other = UUID()

    private static func store(in folder: TemporaryFolder) -> HistoryStore {
        HistoryStore(directory: folder.url, legacyPersona: persona)
    }

    private static func entries(of store: HistoryStore, in persona: UUID = persona) async -> [HistoryEntry] {
        await withCheckedContinuation { continuation in store.entries(since: .distantPast, in: persona) { continuation.resume(returning: $0) } }
    }

    @Test func suggestionsMatchAddressOrTitleMostVisitedFirst() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        let mail = try #require(URL(string: "https://mail.example/"))
        let digest = try #require(URL(string: "https://news.example/"))
        for _ in 0..<3 { store.record(mail, title: "Inbox", persona: Self.persona) }
        for _ in 0..<2 { store.record(digest, title: "Daily Mail Digest", persona: Self.persona) }
        store.record(try #require(URL(string: "https://weather.example/")), title: "Weather", persona: Self.persona)
        // The reads wait on the store's queue behind the recorded visits.
        #expect(await store.suggestions(for: "mail", limit: 10, in: Self.persona).map(\.url) == [mail, digest])
        #expect(await store.suggestions(for: " MAIL ", limit: 10, in: Self.persona).map(\.url) == [mail, digest])
        #expect(await store.suggestions(for: "mail", limit: 1, in: Self.persona).map(\.url) == [mail])
    }

    @Test func wildcardCharactersMatchThemselves() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        let percent = try #require(URL(string: "https://a.example/?off=100%25"))
        let underscore = try #require(URL(string: "https://b.example/"))
        store.record(percent, title: "Sale", persona: Self.persona)
        store.record(try #require(URL(string: "https://c.example/1000")), title: "Thousand", persona: Self.persona)
        store.record(underscore, title: "plan_b", persona: Self.persona)
        store.record(try #require(URL(string: "https://d.example/")), title: "planxb", persona: Self.persona)
        #expect(await store.suggestions(for: "100%", limit: 10, in: Self.persona).map(\.url) == [percent])
        #expect(await store.suggestions(for: "plan_b", limit: 10, in: Self.persona).map(\.url) == [underscore])
    }

    @Test func emptyTextHasNoSuggestions() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        store.record(try #require(URL(string: "https://a.example/")), title: "A", persona: Self.persona)
        #expect(await store.suggestions(for: "", limit: 10, in: Self.persona).isEmpty)
        #expect(await store.suggestions(for: " \n", limit: 10, in: Self.persona).isEmpty)
        // Empty text never waits on the store's queue, so the visit is written before the folder goes.
        store.finishWrites()
    }

    /// A page visited in two Personas keeps a row in each, with each Persona's own count, title, and last visit, and every read, removal, and clear covers only the Persona it names.
    /// Merge Persona Into… moves the source's visits into the target: a page in both adds up its visits and keeps the later visit and the target's title, and the source keeps none.
    @Test func movingVisitsJoinsThemToTheTargetPersona() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        let shared = try #require(URL(string: "https://shared.example/"))
        let only = try #require(URL(string: "https://only.example/"))
        for _ in 0..<2 { store.record(shared, title: "Shared in source", persona: Self.other) }
        store.record(only, title: "Only in source", persona: Self.other)
        store.record(shared, title: "Shared in target", persona: Self.persona)
        store.moveVisits(from: Self.other, to: Self.persona)

        #expect(await Self.entries(of: store, in: Self.other).isEmpty)
        let target = await Self.entries(of: store)
        #expect(Set(target.map(\.url)) == [shared, only])
        #expect(target.first { $0.url == shared }?.visitCount == 3)
        #expect(target.first { $0.url == shared }?.title == "Shared in target")
        #expect(target.first { $0.url == only }?.title == "Only in source")
    }

    @Test func eachPersonaKeepsItsOwnVisits() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        let shared = try #require(URL(string: "https://shared.example/"))
        let work = try #require(URL(string: "https://work.example/"))
        for _ in 0..<3 { store.record(shared, title: "Shared at home", persona: Self.persona) }
        store.record(shared, title: "Shared at work", persona: Self.other)
        store.record(work, title: "Work", persona: Self.other)

        #expect(await store.suggestions(for: "shared", limit: 10, in: Self.persona).map(\.title) == ["Shared at home"])
        #expect(await store.suggestions(for: "work", limit: 10, in: Self.persona).isEmpty)
        let otherEntries = await Self.entries(of: store, in: Self.other)
        #expect(Set(otherEntries.map(\.url)) == [shared, work])
        #expect(otherEntries.first { $0.url == shared }?.visitCount == 1)
        #expect(await store.pages(in: UUID(), matching: "", limit: 10).isEmpty)

        store.remove([shared], in: Self.other)
        #expect(await Self.entries(of: store).map(\.url) == [shared])
        #expect(await Self.entries(of: store, in: Self.other).map(\.url) == [work])

        store.record(shared, title: "", persona: Self.other)
        store.removeEntries(since: .distantPast, in: Self.persona)
        #expect(await Self.entries(of: store).isEmpty)
        #expect(Set(await Self.entries(of: store, in: Self.other).map(\.url)) == [shared, work])

        store.record(shared, title: "", persona: Self.persona)
        store.clear(persona: Self.other)
        #expect(await Self.entries(of: store).map(\.url) == [shared])
        #expect(await Self.entries(of: store, in: Self.other).isEmpty)

        store.record(work, title: "", persona: Self.other)
        store.clear(persona: nil)
        #expect(await Self.entries(of: store).isEmpty)
        #expect(await Self.entries(of: store, in: Self.other).isEmpty)
    }

    /// A plugin's search: empty text gives every page of the Persona, most visited first, and the check and the limit apply to the pages the check accepts.
    @Test func pagesGiveAllForEmptyTextUnderTheCheckAndLimit() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        let urls = try ["https://a.example/", "https://private.example/", "https://b.example/", "https://c.example/"].map { try #require(URL(string: $0)) }
        for (index, url) in urls.enumerated() {
            for _ in 0..<(urls.count - index) { store.record(url, title: "", persona: Self.persona) }
        }
        #expect(await store.pages(in: Self.persona, matching: " ", limit: 10).map(\.url) == urls)
        #expect(await store.pages(in: Self.persona, matching: "", limit: 2) { $0.host != "private.example" }.map(\.url) == [urls[0], urls[2]])
        #expect(await store.pages(in: Self.persona, matching: "", limit: 0).isEmpty)
    }

    /// A file from before visits recorded their Persona, keyed by address alone, gives every page to the default Persona with its title, count, and last visit, and takes visits of the same page in another Persona afterwards.
    @Test func anOlderFileGivesItsPagesToTheDefaultPersona() async throws {
        let folder = try TemporaryFolder()
        var handle: OpaquePointer?
        #expect(sqlite3_open(folder.url.appendingPathComponent("history.sqlite").path, &handle) == SQLITE_OK)
        for sql in ["CREATE TABLE visits (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', visit_count INTEGER NOT NULL DEFAULT 0, last_visit REAL NOT NULL)",
                    "CREATE INDEX visits_by_last_visit ON visits (last_visit)",
                    "INSERT INTO visits VALUES ('https://old.example/', 'Old', 7, 100), ('https://older.example/', '', 2, 50)"] {
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(handle)

        let store = Self.store(in: folder)
        let old = try #require(URL(string: "https://old.example/"))
        #expect(await Self.entries(of: store) == [HistoryEntry(url: old, title: "Old", visitCount: 7, lastVisit: Date(timeIntervalSince1970: 100)),
                                                    HistoryEntry(url: try #require(URL(string: "https://older.example/")), title: "", visitCount: 2, lastVisit: Date(timeIntervalSince1970: 50))])
        store.record(old, title: "Old", persona: Self.other)
        store.record(old, title: "Old", persona: Self.persona)
        #expect(await Self.entries(of: store, in: Self.other).map(\.visitCount) == [1])
        #expect(await store.suggestions(for: "old.example", limit: 10, in: Self.persona).map(\.visitCount) == [8])
        store.finishWrites()

        // Opening the migrated file again keeps the pages where they went, whatever Persona the store is told older pages go to.
        let reopened = HistoryStore(directory: folder.url, legacyPersona: Self.other)
        #expect(await Self.entries(of: reopened).count == 2)
        #expect(await Self.entries(of: reopened, in: Self.other).count == 1)
    }

    /// Pages whose addresses all hold `page`, a batch at a time.
    private static func pages(batches: Int) -> [HistoryEntry] {
        (0..<batches * HistoryStore.importBatchSize).map { index in
            HistoryEntry(url: URL(string: "https://page\(index).example/")!, title: "", visitCount: 1, lastVisit: Date(timeIntervalSince1970: 100))
        }
    }

    @Test func readsRunBetweenImportBatches() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        let batches = 10
        store.importEntries(Self.pages(batches: batches), into: Self.persona)
        // The read waits for the batch that runs when it arrives, not for the rest of the import. It would see every page only if the store ran all ten batches before taking a read that arrived first.
        let seen = await store.suggestions(for: "page", limit: .max, in: Self.persona).count
        #expect(seen % HistoryStore.importBatchSize == 0)
        #expect(seen < batches * HistoryStore.importBatchSize)
        store.finishWrites()
        #expect(await store.suggestions(for: "page", limit: .max, in: Self.persona).count == batches * HistoryStore.importBatchSize)
        #expect(await store.suggestions(for: "page", limit: .max, in: Self.other).isEmpty)
    }

    @Test func finishingWritesWaitsForEveryImportBatch() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        store.importEntries(Self.pages(batches: 3), into: Self.persona)
        store.record(try #require(URL(string: "https://visit.example/")), title: "Visit", persona: Self.persona)
        store.finishWrites()
        // A store opened on the file afterwards finds every page, as the app does at its next launch.
        let reopened = Self.store(in: folder)
        #expect(await reopened.suggestions(for: "example", limit: .max, in: Self.persona).count == 3 * HistoryStore.importBatchSize + 1)
    }

    @Test func removingPagesTakesOnlyThose() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        let urls = try ["https://a.example/", "https://b.example/", "https://c.example/"].map { try #require(URL(string: $0)) }
        urls.forEach { store.record($0, title: "", persona: Self.persona) }
        store.remove(Set(urls.prefix(2)), in: Self.persona)
        #expect(await Self.entries(of: store).map(\.url) == [urls[2]])
    }

    @Test func clearingHistoryDuringAnImportLeavesNoPages() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        // The clear arrives while the import writes its first batches, and the batches it has not written then leave out every page.
        store.importEntries(Self.pages(batches: 10), into: Self.persona)
        store.clear(persona: Self.persona)
        store.finishWrites()
        #expect(await store.suggestions(for: "page", limit: .max, in: Self.persona).isEmpty)
    }

    /// A clear of one Persona during imports into two leaves out the pages of its own import only.
    @Test func clearingOnePersonaDuringImportsKeepsTheOtherImport() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        store.importEntries(Self.pages(batches: 5), into: Self.persona)
        store.importEntries(Self.pages(batches: 5), into: Self.other)
        store.clear(persona: Self.persona)
        store.finishWrites()
        #expect(await store.suggestions(for: "page", limit: .max, in: Self.persona).isEmpty)
        #expect(await store.suggestions(for: "page", limit: .max, in: Self.other).count == 5 * HistoryStore.importBatchSize)
    }

    @Test func removalsDuringAnImportHoldForItsLaterBatches() async throws {
        let folder = try TemporaryFolder()
        let store = Self.store(in: folder)
        let batches = 4
        // Every other page was last visited after the range's start.
        var pages = Self.pages(batches: batches).enumerated().map { index, page in
            index.isMultiple(of: 2) ? page : HistoryEntry(url: page.url, title: page.title, visitCount: page.visitCount, lastVisit: Date(timeIntervalSince1970: 300))
        }
        // A page of a later batch that the user visited too, so the range takes its earlier visit from the import as well.
        let visited = pages[2 * HistoryStore.importBatchSize].url
        store.record(visited, title: "", persona: Self.persona)
        let removed = pages[3 * HistoryStore.importBatchSize + 2].url
        store.importEntries(pages, into: Self.persona)
        store.removeEntries(since: Date(timeIntervalSince1970: 200), in: Self.persona)
        store.remove([removed], in: Self.persona)
        store.finishWrites()
        pages.removeAll { $0.lastVisit >= Date(timeIntervalSince1970: 200) || $0.url == visited || $0.url == removed }
        let remaining = await Self.entries(of: store)
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
