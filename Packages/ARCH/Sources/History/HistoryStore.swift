// Records page visits in `history.sqlite` and uses them for address suggestions and the History window. The store uses the system SQLite library and runs every query serially on one queue.
import Foundation
import SQLite3

public struct HistoryEntry: Hashable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let title: String
    public let visitCount: Int
    public let lastVisit: Date

    public init(url: URL, title: String, visitCount: Int, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
    }
}

public final class HistoryStore {
    /// The history store in the app's Application Support folder.
    public static let shared = HistoryStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arch"))

    private let queue = DispatchQueue(label: "local.arch.history")
    private var database: OpaquePointer?

    /// Opens or creates `history.sqlite` in `directory`. All store operations are no-ops if the file cannot be opened.
    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            sqlite3_close(handle)
            return
        }
        database = handle
        execute("CREATE TABLE IF NOT EXISTS visits (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', visit_count INTEGER NOT NULL DEFAULT 0, last_visit REAL NOT NULL)")
        execute("CREATE INDEX IF NOT EXISTS visits_by_last_visit ON visits (last_visit)")
    }

    deinit {
        sqlite3_close(database)
    }

    /// Counts one visit and preserves the stored title if the supplied title is empty.
    public func record(_ url: URL, title: String) {
        queue.async {
            self.execute("INSERT INTO visits (url, title, visit_count, last_visit) VALUES (?1, ?2, 1, ?3) ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, last_visit = excluded.last_visit, title = CASE WHEN excluded.title = '' THEN visits.title ELSE excluded.title END",
                         bindings: [.text(url.absoluteString), .text(title), .double(Date().timeIntervalSince1970)])
        }
    }

    /// Returns entries whose URL or title contains `query`, most visited first. Returns no entries for an empty query.
    public func suggestions(for query: String, limit: Int) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return queue.sync {
            entries("SELECT url, title, visit_count, last_visit FROM visits WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\' ORDER BY visit_count DESC, last_visit DESC LIMIT ?2",
                    bindings: [.text("%\(escaped)%"), .integer(limit)])
        }
    }

    /// Returns entries visited at or after `date`, newest first.
    public func entries(since date: Date) -> [HistoryEntry] {
        queue.sync {
            entries("SELECT url, title, visit_count, last_visit FROM visits WHERE last_visit >= ?1 ORDER BY last_visit DESC", bindings: [.double(date.timeIntervalSince1970)])
        }
    }

    public func remove(_ url: URL) {
        queue.async {
            self.execute("DELETE FROM visits WHERE url = ?1", bindings: [.text(url.absoluteString)])
        }
    }

    /// Removes the entries last visited at or after `date`, including their earlier visits.
    public func removeEntries(since date: Date) {
        queue.async {
            self.execute("DELETE FROM visits WHERE last_visit >= ?1", bindings: [.double(date.timeIntervalSince1970)])
        }
    }

    public func clear() {
        queue.async {
            self.execute("DELETE FROM visits")
        }
    }

    // MARK: SQLite

    private enum Binding {
        case text(String)
        case integer(Int)
        case double(Double)
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, bindings: [Binding]) -> OpaquePointer? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
            case .integer(let value): sqlite3_bind_int64(statement, index, Int64(value))
            case .double(let value): sqlite3_bind_double(statement, index, value)
            }
        }
        return statement
    }

    private func execute(_ sql: String, bindings: [Binding] = []) {
        guard let statement = prepare(sql, bindings: bindings) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func entries(_ sql: String, bindings: [Binding]) -> [HistoryEntry] {
        guard let statement = prepare(sql, bindings: bindings) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlText = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: urlText)) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            result.append(HistoryEntry(url: url, title: title, visitCount: Int(sqlite3_column_int64(statement, 2)),
                                       lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
        return result
    }
}
