// Paged reads keep newest-first order through tied dates, search before limiting, and use the same Persona-scoped deletion paths as the full history list.
import Foundation
@testable import History
import Testing

@Suite struct HistoryPagingTests {
    private static let persona = UUID()
    private static let other = UUID()

    private static func page(_ name: String, title: String = "", time: TimeInterval, visits: Int = 1) -> HistoryEntry {
        HistoryEntry(url: URL(string: "https://history.example/\(name)")!, title: title, visitCount: visits, lastVisit: Date(timeIntervalSince1970: time))
    }

    @Test func pagingKeepsTiedDatesInOrderWithoutSkippingPages() async throws {
        let folder = try HistoryPagingFolder()
        let store = HistoryStore(directory: folder.url, legacyPersona: Self.persona)
        let pages = [Self.page("new", time: 300), Self.page("a", time: 200), Self.page("b", time: 200),
                     Self.page("c", time: 200), Self.page("old", time: 100, visits: 20)]
        store.importEntries(Array(pages.reversed()), into: Self.persona)
        store.importEntries([Self.page("other", time: 400)], into: Self.other)
        store.finishWrites()

        let first = await store.entries(in: Self.persona, limit: 2)
        let second = await store.entries(in: Self.persona, limit: 2, before: first.last)
        let third = await store.entries(in: Self.persona, limit: 2, before: second.last)
        #expect(first + second + third == pages)
        #expect(await store.entries(in: Self.persona, limit: 2, before: third.last).isEmpty)
        #expect(await store.entries(in: Self.persona, limit: 0).isEmpty)
        #expect(await store.entries(in: Self.persona, limit: -1).isEmpty)
    }

    @Test func cursorSurvivesDeletionAndNewerInsertions() async throws {
        let folder = try HistoryPagingFolder()
        let store = HistoryStore(directory: folder.url, legacyPersona: Self.persona)
        let pages = [Self.page("a", time: 200), Self.page("b", time: 200), Self.page("c", time: 200), Self.page("old", time: 100)]
        store.importEntries(pages, into: Self.persona)
        store.finishWrites()
        let first = await store.entries(in: Self.persona, limit: 2)
        store.remove([pages[1].url], in: Self.persona)
        let newest = Self.page("new", time: 300)
        store.importEntries([newest], into: Self.persona)
        store.finishWrites()

        #expect(await store.entries(in: Self.persona, limit: 2, before: first.last) == Array(pages.suffix(2)))
        #expect(await store.entries(in: Self.persona, limit: 1) == [newest])
    }

    @Test func searchFiltersTitleAndAddressBeforePagingAndTreatsWildcardsLiterally() async throws {
        let folder = try HistoryPagingFolder()
        let store = HistoryStore(directory: folder.url, legacyPersona: Self.persona)
        let pages = [Self.page("irrelevant", title: "Unrelated", time: 600), Self.page("one", title: "Reading Notes", time: 500),
                     Self.page("reading", time: 400), Self.page("three", title: "READING", time: 300),
                     Self.page("literal", title: "plan_100%\\done", time: 200), Self.page("korean", title: "방문 기록", time: 100)]
        store.importEntries(pages, into: Self.persona)
        store.importEntries([Self.page("private-reading", title: "Reading", time: 700)], into: Self.other)
        store.finishWrites()

        let first = await store.entries(in: Self.persona, matching: "  ReAdInG \n", limit: 2)
        #expect(first == Array(pages[1...2]))
        #expect(await store.entries(in: Self.persona, matching: "reading", limit: 2, before: first.last) == [pages[3]])
        #expect(await store.entries(in: Self.persona, matching: "plan_100%\\", limit: 10) == [pages[4]])
        #expect(await store.entries(in: Self.persona, matching: "방문", limit: 10) == [pages[5]])
        #expect(await store.entries(in: Self.persona, matching: " \n", limit: 10) == pages)
        #expect(await store.entries(in: Self.persona, matching: "missing", limit: 10).isEmpty)
    }

    @Test func rangeRemovalIncludesItsBoundaryAndPreservesOtherPersonas() async throws {
        let folder = try HistoryPagingFolder()
        let store = HistoryStore(directory: folder.url, legacyPersona: Self.persona)
        let pages = [Self.page("after", time: 301), Self.page("boundary", time: 300, visits: 9), Self.page("before", time: 299)]
        store.importEntries(pages, into: Self.persona)
        store.importEntries(pages, into: Self.other)
        store.finishWrites()
        store.removeEntries(since: Date(timeIntervalSince1970: 300), in: Self.persona)

        #expect(await store.entries(in: Self.persona, limit: 10) == [pages[2]])
        #expect(await store.entries(in: Self.other, limit: 10) == pages)
        store.clear(persona: Self.persona)
        #expect(await store.entries(in: Self.persona, limit: 10).isEmpty)
        #expect(await store.entries(in: Self.other, limit: 10) == pages)
        store.removeEntries(since: Date(timeIntervalSince1970: 300), in: nil)
        #expect(await store.entries(in: Self.other, limit: 10) == [pages[2]])
    }

    @Test @MainActor func writesNotifyTheAffectedPersonasOnTheMainThread() async throws {
        let folder = try HistoryPagingFolder()
        let store = HistoryStore(directory: folder.url, legacyPersona: Self.persona)
        let changes = HistoryChanges()
        let observer = NotificationCenter.default.addObserver(forName: HistoryStore.didChange, object: nil, queue: nil) { notification in
            guard let changedStore = notification.object as? HistoryStore, changedStore === store else { return }
            #expect(Thread.isMainThread)
            MainActor.assumeIsolated { changes.personas.append(notification.userInfo?["persona"] as? UUID) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let page = Self.page("page", time: 100)
        store.record(page.url, title: "Page", persona: Self.persona)
        store.importEntries([page], into: Self.other)
        store.finishWrites()
        store.remove([page.url], in: Self.persona)
        store.removeEntries(since: Date(timeIntervalSince1970: 200), in: Self.other)
        store.moveVisits(from: Self.other, to: Self.persona)
        store.clear(persona: nil)
        // This callback follows every queued notification on the main queue.
        await withCheckedContinuation { continuation in
            store.entries(since: .distantPast, in: Self.persona) { _ in continuation.resume() }
        }
        #expect(changes.personas == [Self.persona, Self.other, Self.persona, Self.other, Self.other, Self.persona, nil])
    }
}

@MainActor private final class HistoryChanges {
    var personas: [UUID?] = []
}

private final class HistoryPagingFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchHistoryPagingTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
