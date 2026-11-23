// Reads the pages of other browsers' history databases, a Chromium-format History database or a `history_items` database, from copies (see `DatabaseCopy`).
import Foundation
import History
import SQLite3

/// Reads the pages of a browser's history database for the browser import.
enum HistoryDatabase {
    /// Chromium counts time in microseconds since 1601-01-01 UTC.
    private static let secondsFrom1601To1970: Double = 11_644_473_600

    /// Returns the pages a Chromium-format History database lists in its history and that have web addresses, with their titles, visit counts, and last visits.
    static func entries(at url: URL) throws -> [HistoryEntry] {
        try DatabaseCopy.read(url, unreadable: .unreadableHistory(url)) { database in
            var entries: [HistoryEntry] = []
            // Hidden rows are pages the browser leaves out of its own history list, such as those loaded in frames.
            try DatabaseCopy.forEachRow(in: database, "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > 0", unreadable: .unreadableHistory(url)) { row in
                guard let pageURL = DatabaseCopy.text(row, 0).flatMap(ImportedFile.webURL) else { return }
                let lastVisit = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 3)) / 1_000_000 - secondsFrom1601To1970)
                entries.append(HistoryEntry(url: pageURL, title: DatabaseCopy.text(row, 1) ?? "", visitCount: max(Int(sqlite3_column_int64(row, 2)), 1), lastVisit: lastVisit))
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
        return try DatabaseCopy.read(url, unreadable: .unreadableHistory(url)) { database in
            var entries: [HistoryEntry] = []
            try DatabaseCopy.forEachRow(in: database, query, unreadable: .unreadableHistory(url)) { row in
                guard let pageURL = DatabaseCopy.text(row, 0).flatMap(ImportedFile.webURL) else { return }
                let lastVisit = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 2))
                entries.append(HistoryEntry(url: pageURL, title: DatabaseCopy.text(row, 3) ?? "", visitCount: max(Int(sqlite3_column_int64(row, 1)), 1), lastVisit: lastVisit))
            }
            return entries
        }
    }
}
