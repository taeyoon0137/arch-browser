// History from synthetic SQLite databases: a `history_items` database and a Chromium-format History database, both read from copies, including one behind a symbolic link and one damaged partway through.
import Foundation
import History
import Testing
@testable import Import

@Suite struct HistoryDatabaseTests {
    /// The Chromium-format `urls` table.
    private static let urlsTable = "CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER)"

    @Test func historyItemsCountOnlyVisitsThatLoadedWithoutRedirecting() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.database("History.db", [
            "CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, visit_count INTEGER NOT NULL)",
            """
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL, visit_time REAL NOT NULL, title TEXT NULL,
                load_successful BOOLEAN NOT NULL DEFAULT 1, redirect_source INTEGER NULL, redirect_destination INTEGER NULL)
            """,
            "INSERT INTO history_items (id, url, visit_count) VALUES (1, 'https://a.example/', 5), (2, 'https://b.example/', 2), (3, 'file:///tmp/page.html', 1), (4, 'https://c.example/', 0)",
            """
            INSERT INTO history_visits (history_item, visit_time, title, load_successful, redirect_destination) VALUES
                (1, 100, 'Old Title', 1, NULL), (1, 200, 'New Title', 1, NULL), (1, 300, NULL, 1, NULL), (1, 400, 'Failed', 0, NULL), (1, 500, 'Redirected', 1, 9),
                (2, 600, 'Failed', 0, NULL), (2, 700, 'Redirected', 1, 9),
                (3, 800, 'File', 1, NULL),
                (4, 900, '', 1, NULL)
            """,
        ])
        let entries = try HistoryDatabase.historyItemEntries(at: file).sorted { $0.lastVisit < $1.lastVisit }
        #expect(entries.map(\.url.absoluteString) == ["https://a.example/", "https://c.example/"])
        #expect(entries.map(\.title) == ["New Title", ""])
        #expect(entries.map(\.visitCount) == [5, 1])
        #expect(entries.map(\.lastVisit) == [Date(timeIntervalSinceReferenceDate: 300), Date(timeIntervalSinceReferenceDate: 900)])
    }

    @Test func chromiumHistoryLeavesHiddenPagesOut() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        // Chromium times visits in microseconds since 1601; this one is 2001-01-01, the reference date.
        let referenceDate = 12_622_780_800_000_000
        let file = try folder.database("History", [
            Self.urlsTable,
            "INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES ('https://a.example/', 'A', 3, 0, \(referenceDate), 0), ('https://frame.example/', 'Frame', 1, 0, \(referenceDate), 1)",
        ])
        let entries = try HistoryDatabase.entries(at: file)
        #expect(entries.map(\.url.absoluteString) == ["https://a.example/"])
        #expect(entries.map(\.lastVisit) == [Date(timeIntervalSinceReferenceDate: 0)])
    }

    @Test func aDatabaseWithoutTheHistoryTablesCannotBeRead() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.database("History.db", ["CREATE TABLE other (id INTEGER)"])
        #expect(throws: ImportError.unreadableHistory(file)) { try HistoryDatabase.historyItemEntries(at: file) }
    }

    @Test func aDatabaseBehindALinkIsReadFromItsTargetWithoutChangingIt() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let target = try folder.databaseWithLog("Elsewhere/History", [
            Self.urlsTable,
            "INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES ('https://a.example/', 'A', 1, 0, 1, 0)",
        ])
        let link = folder.url.appendingPathComponent("Default/History")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        func targetFiles() throws -> [String: Data] {
            let names = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
            return try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: target.deletingLastPathComponent().appendingPathComponent($0))) })
        }
        let before = try targetFiles()
        #expect(before.keys.sorted() == ["History", "History-wal"])

        // The page is only in the log, so reading it shows that the log beside the target came along.
        #expect(try HistoryDatabase.entries(at: link).map(\.url.absoluteString) == ["https://a.example/"])
        #expect(try targetFiles() == before)
    }

    @Test func aDatabaseDamagedPartwayThroughCannotBeRead() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let pageSize = 4_096
        let file = try folder.database("History", [
            "PRAGMA page_size = \(pageSize)",
            Self.urlsTable,
            """
            WITH RECURSIVE page(number) AS (SELECT 1 UNION ALL SELECT number + 1 FROM page WHERE number < 200)
            INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden)
            SELECT 'https://page' || number || '.example/', printf('%.200c', 'T'), 1, 0, 1, 0 FROM page
            """,
        ])
        // The last page holds the last rows of the table, so the read fails only after the rows before it.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: try handle.seekToEnd() - UInt64(pageSize))
        try handle.write(contentsOf: Data(repeating: 0xFF, count: pageSize))
        try handle.close()
        #expect(throws: ImportError.unreadableHistory(file)) { try HistoryDatabase.entries(at: file) }
    }
}
