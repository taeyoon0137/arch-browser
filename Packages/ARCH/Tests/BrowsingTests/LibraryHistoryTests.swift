// The library groups and pages one Persona's history, searches the store, and keeps removals within that Persona.
import ARCHEngine
import Foundation
import History
import Testing
@testable import Browsing

@MainActor @Suite struct LibraryHistoryTests {
    @Test func groupingUsesCalendarDaysAcrossTheEndOfDaylightSavingTime() throws {
        let calendar = try Self.calendar()
        let now = try Self.date("2026-11-02T12:00:00-08:00")
        let today = Self.entry("today", at: now)
        let yesterdayLate = Self.entry("yesterday-late", at: try Self.date("2026-11-01T23:30:00-08:00"))
        let yesterdayEarly = Self.entry("yesterday-early", at: try Self.date("2026-11-01T00:30:00-07:00"))
        let older = Self.entry("older", at: try Self.date("2026-10-31T23:30:00-07:00"))

        let days = LibraryHistoryDay.group([today, yesterdayLate, yesterdayEarly, older], calendar: calendar)

        try #require(days.count == 3)
        #expect(days.map(\.entries) == [[today], [yesterdayLate, yesterdayEarly], [older]])
        #expect(days.map(\.date) == [today, yesterdayEarly, older].map { calendar.startOfDay(for: $0.lastVisit) })
        #expect(days[0].title(relativeTo: now, calendar: calendar) == localized("Today"))
        #expect(days[1].title(relativeTo: now, calendar: calendar) == localized("Yesterday"))
        #expect(days[2].title(relativeTo: now, calendar: calendar) == days[2].date.formatted(date: .abbreviated, time: .omitted))
        #expect(LibraryHistoryDay.group([], calendar: calendar).isEmpty)
    }

    @Test func clearRangesUseAnHourOrLocalMidnightRatherThanTwentyFourHours() throws {
        let calendar = try Self.calendar()
        let now = try Self.date("2026-11-01T12:00:00-08:00")
        let midnight = try Self.date("2026-11-01T00:00:00-07:00")

        #expect(LibraryHistoryClearRange.lastHour.start(now: now, calendar: calendar) == now.addingTimeInterval(-3600))
        #expect(LibraryHistoryClearRange.today.start(now: now, calendar: calendar) == midnight)
        #expect(now.timeIntervalSince(midnight) == 13 * 3600)
        #expect(LibraryHistoryClearRange.all.start(now: now, calendar: calendar) == nil)
    }

    @Test func pagesLoadOnlyWhenRequestedAndKeepTheNewestFirstOrder() async throws {
        let folder = try HistoryTestFolder()
        let persona = UUID()
        let store = HistoryStore(directory: folder.url, legacyPersona: persona)
        let expected = (0..<5).map { Self.entry("page-\($0)", at: Date(timeIntervalSince1970: Double(100 - $0))) }
        await Self.seed(expected.reversed(), in: store, persona: persona)
        await Self.seed([Self.entry("other-persona", at: Date(timeIntervalSince1970: 200))], in: store, persona: UUID())
        let model = LibraryHistoryModel(store: store, persona: persona, pageSize: 2)

        #expect(model.entries.isEmpty)
        await model.loadNextPage()
        #expect(model.entries == Array(expected.prefix(2)))
        #expect(model.hasMore)
        await model.loadNextPage()
        #expect(model.entries == Array(expected.prefix(4)))
        await model.loadNextPage()
        #expect(model.entries == expected)
        #expect(!model.hasMore)
        await model.loadNextPage()
        #expect(model.entries == expected)
        #expect(!model.isLoading)
    }

    @Test func searchFindsTitlesAndAddressesBeyondTheLoadedPage() async throws {
        let folder = try HistoryTestFolder()
        let persona = UUID()
        let store = HistoryStore(directory: folder.url, legacyPersona: persona)
        let recent = Self.entry("recent", title: "Recent page", at: Date(timeIntervalSince1970: 300))
        let titleMatch = Self.entry("older", title: "A Saved Recipe", at: Date(timeIntervalSince1970: 200))
        let addressMatch = Self.entry("recipe-archive", title: "Archive", at: Date(timeIntervalSince1970: 100))
        await Self.seed([recent, titleMatch, addressMatch], in: store, persona: persona)
        let model = LibraryHistoryModel(store: store, persona: persona, pageSize: 1)
        await model.loadNextPage()
        #expect(model.entries == [recent])

        model.query = "  RECIPE  "
        try #require(await Self.wait { !model.isLoading && model.entries == [titleMatch] })
        await model.loadNextPage()
        #expect(model.entries == [titleMatch, addressMatch])
        await model.loadNextPage()
        #expect(!model.hasMore)

        model.query = "missing page"
        try #require(await Self.wait { !model.isLoading && !model.hasMore })
        #expect(model.entries.isEmpty)
        model.query = " \n"
        try #require(await Self.wait { !model.isLoading && model.entries == [recent] })
    }

    @Test func aLaterQueryReplacesPendingReloads() async throws {
        let folder = try HistoryTestFolder()
        let persona = UUID()
        let store = HistoryStore(directory: folder.url, legacyPersona: persona)
        let mail = Self.entry("mail", title: "Inbox", at: Date(timeIntervalSince1970: 200))
        let weather = Self.entry("weather", title: "Forecast", at: Date(timeIntervalSince1970: 100))
        await Self.seed([mail, weather], in: store, persona: persona)
        let model = LibraryHistoryModel(store: store, persona: persona, pageSize: 1)

        model.query = "mail"
        model.query = "missing"
        model.query = "forecast"
        try #require(await Self.wait { !model.isLoading && model.entries == [weather] })
        await model.loadNextPage()
        #expect(model.entries == [weather])
        #expect(!model.hasMore)
    }

    @Test func aPageAlreadyBeingReadCannotRepopulateANewerSearch() async throws {
        let folder = try HistoryTestFolder()
        let persona = UUID()
        let store = HistoryStore(directory: folder.url, legacyPersona: persona)
        let mail = Self.entry("mail", title: "Inbox", at: Date(timeIntervalSince1970: 200))
        let weather = Self.entry("weather", title: "Forecast", at: Date(timeIntervalSince1970: 100))
        await Self.seed([mail, weather], in: store, persona: persona)
        let reachedStore = DispatchSemaphore(value: 0)
        let releaseStore = DispatchSemaphore(value: 0)
        defer { releaseStore.signal() }
        // Hold the store's queue so the first page is still in flight when the search changes.
        let blocker = Task {
            await store.pages(in: persona, matching: "", limit: 1) { _ in
                reachedStore.signal()
                releaseStore.wait()
                return true
            }
        }
        var reached = false
        try #require(await Self.wait {
            reached = reached || reachedStore.wait(timeout: .now()) == .success
            return reached
        })
        let model = LibraryHistoryModel(store: store, persona: persona, pageSize: 1)
        let firstPage = Task { await model.loadNextPage() }
        try #require(await Self.wait { model.isLoading })

        model.query = "forecast"
        releaseStore.signal()
        _ = await blocker.value
        await firstPage.value
        try #require(await Self.wait { !model.isLoading && model.entries == [weather] })
        await model.loadNextPage()
        #expect(model.entries == [weather])
        #expect(!model.hasMore)
    }

    @Test func libraryChoicePersistsAndOnlyDownloadsClearsUnseenBadges() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: LibraryTab.defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: LibraryTab.defaultsKey) }
            else { defaults.removeObject(forKey: LibraryTab.defaultsKey) }
        }
        // This synchronous main-actor test restores the preference before another window can read it.
        defaults.removeObject(forKey: LibraryTab.defaultsKey)
        let folder = try HistoryTestFolder()
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: folder.url)
        let space = try #require(session.spaces.first)
        let record = SessionSnapshot.WindowRecord(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true)
        let first = BrowserWindowModel(session: session, record: record, kind: .main)
        #expect(first.nsWindow == nil && session.windows.isEmpty)
        #expect(first.libraryTab == .downloads)
        first.libraryTab = .history
        let second = BrowserWindowModel(session: session, record: record, kind: .main)
        #expect(second.libraryTab == .history)

        let downloads = try #require(session.runtime(for: .webKit, in: Persona.defaultID)).context.downloads
        let item = LibraryTestDownload()
        session.downloads(downloads, didCreate: item)
        item.state = .completed
        session.downloads(downloads, didUpdate: item)
        let entry = try #require(session.downloads.first)
        #expect(session.unseenDownloadIDs == [entry.id])
        first.isLibraryVisible = true
        #expect(session.unseenDownloadIDs == [entry.id])
        first.isLibraryVisible = false
        first.isLibraryVisible = true
        #expect(session.unseenDownloadIDs == [entry.id])

        first.libraryTab = .downloads
        #expect(session.unseenDownloadIDs.isEmpty)
        #expect(second.libraryTab == .history)
        let third = BrowserWindowModel(session: session, record: record, kind: .main)
        #expect(third.libraryTab == .downloads)
        #expect(third.nsWindow == nil && session.windows.isEmpty)
    }

    @Test func liveVisitsAndRemovalsRefreshTheCurrentPersona() async throws {
        let folder = try HistoryTestFolder()
        let persona = UUID()
        let store = HistoryStore(directory: folder.url, legacyPersona: persona)
        let older = Self.entry("older", at: Date(timeIntervalSince1970: 100))
        await Self.seed([older], in: store, persona: persona)
        let model = LibraryHistoryModel(store: store, persona: persona)
        await model.loadNextPage()
        #expect(model.entries == [older])

        let url = Self.entry("live", at: Date()).url
        store.record(url, title: "Live page", persona: persona)
        try #require(await Self.wait { !model.isLoading && model.entries.map(\.url) == [url, older.url] })
        store.remove([url], in: persona)
        try #require(await Self.wait { !model.isLoading && model.entries == [older] })
        store.clear(persona: nil)
        try #require(await Self.wait { !model.isLoading && !model.hasMore && model.entries.isEmpty })
    }

    @Test func changesFromOtherPersonasAndStoresDoNotResetLoadedPages() async throws {
        let folder = try HistoryTestFolder()
        let otherFolder = try HistoryTestFolder()
        let persona = UUID()
        let store = HistoryStore(directory: folder.url, legacyPersona: persona)
        let otherStore = HistoryStore(directory: otherFolder.url, legacyPersona: persona)
        let entries = [Self.entry("newer", at: Date(timeIntervalSince1970: 200)), Self.entry("older", at: Date(timeIntervalSince1970: 100))]
        await Self.seed(entries, in: store, persona: persona)
        let model = LibraryHistoryModel(store: store, persona: persona, pageSize: 1)
        await model.loadNextPage()
        await model.loadNextPage()

        // Import completion follows the store's change notification on the main queue.
        await Self.seed([Self.entry("other-persona", at: Date())], in: store, persona: UUID())
        await Self.seed([Self.entry("other-store", at: Date())], in: otherStore, persona: persona)
        #expect(model.entries == entries)
        #expect(!model.isLoading)
    }

    @Test func deletingARowLeavesTheOtherPersonasVisit() async throws {
        let folder = try HistoryTestFolder()
        let persona = UUID()
        let other = UUID()
        let store = HistoryStore(directory: folder.url, legacyPersona: persona)
        let row = Self.entry("shared", at: Date(timeIntervalSince1970: 100))
        await Self.seed([row], in: store, persona: persona)
        await Self.seed([row], in: store, persona: other)
        let model = LibraryHistoryModel(store: store, persona: persona)
        await model.loadNextPage()

        model.delete(row)
        #expect(await store.entries(in: persona, limit: 10).isEmpty)
        #expect(await store.entries(in: other, limit: 10) == [row])
        try #require(await Self.wait { !model.isLoading && !model.hasMore && model.entries.isEmpty })
    }

    @Test(arguments: [LibraryHistoryClearRange.lastHour, .today, .all])
    func clearingRemovesTheBoundaryAndLaterVisitsOnlyInItsPersona(_ range: LibraryHistoryClearRange) async throws {
        let folder = try HistoryTestFolder()
        let persona = UUID()
        let other = UUID()
        let store = HistoryStore(directory: folder.url, legacyPersona: persona)
        let calendar = try Self.calendar()
        let now = try Self.date("2026-11-01T12:00:00-08:00")
        let boundary = range.start(now: now, calendar: calendar) ?? now.addingTimeInterval(-86400)
        let old = Self.entry("before", at: boundary.addingTimeInterval(-1))
        let atBoundary = Self.entry("boundary", at: boundary)
        let recent = Self.entry("recent", at: now)
        let entries = [recent, atBoundary, old]
        await Self.seed(entries, in: store, persona: persona)
        await Self.seed(entries, in: store, persona: other)
        let model = LibraryHistoryModel(store: store, persona: persona)

        model.clear(range, now: now, calendar: calendar)
        let expected = range == .all ? [] : [old]
        #expect(await store.entries(in: persona, limit: 10) == expected)
        #expect(await store.entries(in: other, limit: 10) == entries)
        try #require(await Self.wait { !model.isLoading && !model.hasMore && model.entries == expected })
    }

    private static func entry(_ path: String, title: String = "", at date: Date) -> HistoryEntry {
        HistoryEntry(url: URL(string: "https://history.example/\(path)")!, title: title, visitCount: 1, lastVisit: date)
    }

    private static func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private static func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return calendar
    }

    private static func seed(_ entries: some Sequence<HistoryEntry>, in store: HistoryStore, persona: UUID) async {
        await withCheckedContinuation { continuation in
            store.importEntries(Array(entries), into: persona) { _ in continuation.resume() }
        }
    }

    private static func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}

private final class HistoryTestFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchLibraryHistoryTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class LibraryTestDownload: EngineDownloadItem {
    let sourceURL = URL(string: "https://history.example/file")!
    let pageURL: URL? = nil
    let webContents: (any EngineWebContents)? = nil
    let targetPath: URL? = nil
    var state: EngineDownloadState = .inProgress
    let completedBytes: Int64 = 0
    let totalBytes: Int64 = 0
    func pause() {}
    func resume() {}
    func cancel() {}
    func remove() {}
}
