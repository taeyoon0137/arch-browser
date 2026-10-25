// Reads other browsers' SQLite databases from copies: the pages of a Chromium-format History database or of a `history_items` database, and through `withCopy` any other database, such as a Chromium-format `Web Data`.
import Foundation
import History
import SQLite3

enum HistoryDatabase {
    /// Chromium counts time in microseconds since 1601-01-01 UTC.
    private static let secondsFrom1601To1970: Double = 11_644_473_600
    /// Starts the name of each temporary folder that holds a copy.
    private static let copyFolderPrefix = "ArchImport-"

    /// Returns the pages a Chromium-format History database lists in its history and that have web addresses, with their titles, visit counts, and last visits.
    static func entries(at url: URL) throws -> [HistoryEntry] {
        try withCopy(of: url, unreadable: .unreadableHistory(url)) { database in
            var entries: [HistoryEntry] = []
            // Hidden rows are pages the browser leaves out of its own history list, such as those loaded in frames.
            try forEachRow(in: database, "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > 0", unreadable: .unreadableHistory(url)) { row in
                guard let pageURL = text(row, 0).flatMap(ImportedFile.webURL) else { return }
                let lastVisit = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 3)) / 1_000_000 - secondsFrom1601To1970)
                entries.append(HistoryEntry(url: pageURL, title: text(row, 1) ?? "", visitCount: max(Int(sqlite3_column_int64(row, 2)), 1), lastVisit: lastVisit))
            }
            return entries
        }
    }

    /// Returns the pages of a database with `history_items` and their `history_visits`, timed in seconds since 2001-01-01 UTC. Only visits that loaded and did not redirect elsewhere count: a page needs one, the latest is its last visit, and the latest with a title gives its title. The visit count is the page's own.
    static func historyItemEntries(at url: URL) throws -> [HistoryEntry] {
        let query = """
            SELECT item.url, item.visit_count, MAX(visit.visit_time),
                (SELECT titled.title FROM history_visits titled
                 WHERE titled.history_item = item.id AND titled.load_successful = 1 AND titled.redirect_destination IS NULL AND titled.title <> ''
                 ORDER BY titled.visit_time DESC LIMIT 1)
            FROM history_items item JOIN history_visits visit ON visit.history_item = item.id
            WHERE visit.load_successful = 1 AND visit.redirect_destination IS NULL
            GROUP BY item.id
            """
        return try withCopy(of: url, unreadable: .unreadableHistory(url)) { database in
            var entries: [HistoryEntry] = []
            try forEachRow(in: database, query, unreadable: .unreadableHistory(url)) { row in
                guard let pageURL = text(row, 0).flatMap(ImportedFile.webURL) else { return }
                let lastVisit = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 2))
                entries.append(HistoryEntry(url: pageURL, title: text(row, 3) ?? "", visitCount: max(Int(sqlite3_column_int64(row, 1)), 1), lastVisit: lastVisit))
            }
            return entries
        }
    }

    /// Runs `body` on a copy of the database at `url` in a new temporary folder, which only the user can open, and deletes the copy afterward. The owning browser may hold the file open and locked, so the copy takes the journal or write-ahead log beside it to have the last committed changes. Throws `unreadable` when SQLite cannot open the copy.
    static func withCopy<Value>(of url: URL, unreadable: ImportError, _ body: (OpaquePointer?) throws -> Value) throws -> Value {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("\(copyFolderPrefix)\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try files.copyItem(at: url, to: copy)
        for suffix in ["-journal", "-wal"] where files.fileExists(atPath: url.path + suffix) {
            try? files.copyItem(atPath: url.path + suffix, toPath: copy.path + suffix)
        }

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        // Read-write, so that SQLite can apply the copied write-ahead log.
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw unreadable }
        return try body(database)
    }

    /// Passes each row of `query` to `body`. Throws `unreadable` when the query does not compile, as when the database lacks its table or columns.
    static func forEachRow(in database: OpaquePointer?, _ query: String, unreadable: ImportError, _ body: (OpaquePointer?) -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw unreadable }
        while sqlite3_step(statement) == SQLITE_ROW {
            body(statement)
        }
    }

    /// The text in `column` of the current row, or nil for NULL.
    static func text(_ row: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    /// Deletes the copies that an earlier import left behind when Arch quit while reading them. The import controller calls it before reading, when no read uses a copy, since imports run one at a time.
    static func removeLeftoverCopies() {
        let files = FileManager.default
        let items = (try? files.contentsOfDirectory(at: files.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(copyFolderPrefix) {
            try? files.removeItem(at: item)
        }
    }
}
