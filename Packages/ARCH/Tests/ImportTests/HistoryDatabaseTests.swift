// History from synthetic SQLite databases: a `history_items` database and a Chromium-format History database, both read from copies, including one behind a symbolic link, one damaged partway through, and one written to while it is copied.
import Foundation
import History
import Testing
@testable import Import

@Suite struct HistoryDatabaseTests {
    @Test func historyItemsCountOnlyVisitsThatLoadedWithoutRedirecting() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.database("History.db", WebKitDatabases.historyTables + [
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
            ChromiumDatabases.urlsTable,
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
            ChromiumDatabases.urlsTable,
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
            ChromiumDatabases.urlsTable,
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

    @Test func aDatabaseWrittenToWhileItIsCopiedIsCopiedAgain() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = try folder.databaseWithLog("Default/History", [
            ChromiumDatabases.urlsTable,
            "INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES ('https://a.example/', 'A', 1, 0, 1, 0)",
        ])
        let log = URL(fileURLWithPath: source.path + "-wal")
        let copy = folder.url.appendingPathComponent("Copy/History")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copies as the import does and, as a browser might, writes to the log right after the database is copied in each attempt listed in `writes`.
        func copyDatabase(writingIn writes: Set<Int>) throws -> (isCopied: Bool, copiedFiles: [String]) {
            var copiedFiles: [String] = []
            var attempt = 0
            let isCopied = try DatabaseCopy.copyDatabase(at: source, to: copy) { from, to in
                try FileManager.default.copyItem(at: from, to: to)
                copiedFiles.append(from.lastPathComponent)
                guard from == source else { return }
                attempt += 1
                guard writes.contains(attempt) else { return }
                let handle = try FileHandle(forWritingTo: log)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0]))
                try handle.close()
            }
            return (isCopied, copiedFiles)
        }

        // A write during the first copy makes a second one, which matches the files.
        let once = try copyDatabase(writingIn: [1])
        #expect(once.isCopied)
        #expect(once.copiedFiles == ["History", "History-wal", "History", "History-wal"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy.path + "-wal")) == Data(contentsOf: log))
        // A browser that writes during every copy leaves the database unread.
        let always = try copyDatabase(writingIn: [1, 2, 3])
        #expect(!always.isCopied)
        #expect(always.copiedFiles.count == 6)
    }
}
