// Records page visits in `history.sqlite` and uses them for address suggestions and the History window. The store uses the system SQLite library and runs every query serially on one queue.
import Foundation
import os
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

/// Safe to use from any thread: outside `init` and `deinit`, only blocks on `queue` touch the database.
public final class HistoryStore: @unchecked Sendable {
    /// The pages an import writes in one transaction.
    static let importBatchSize = 1_000
    /// Statements that fail go to the system log, since the store's callers go on without their results.
    private static let log = Logger(subsystem: "xyz.taeyoon.arch", category: "History")

    private let queue = DispatchQueue(label: "local.arch.history")
    private var database: OpaquePointer?
    /// Entered for each import until its last batch is in, so that `finishWrites()` can wait for the batches it has not queued yet.
    private let imports = DispatchGroup()

    /// Opens or creates `history.sqlite` in `directory`. All store operations are no-ops if the file cannot be opened.
    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            Self.log.error("history.sqlite did not open: \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory", privacy: .public)")
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

    /// Adds pages read from another app's history. A page already in the store keeps its title unless that is empty, and takes the later last visit and the larger visit count, so importing the same file again changes nothing. The pages go in by batches of `importBatchSize`, each committed on its own and queued once the one before has committed, so that visits, suggestions, and the History window's reads that arrive meanwhile wait for one batch at most. A batch that fails rolls back and ends the import. `completion`, when given, runs on the main queue after the last batch with the number of pages the committed batches added or changed, counting each address once.
    public func importEntries(_ entries: [HistoryEntry], completion: ((Int) -> Void)? = nil) {
        imports.enter()
        let pending = PendingImport(entries: entries, completion: completion)
        queue.async { self.importNextBatch(of: pending) }
    }

    /// One import's pages and the addresses its batches have added or changed, used only on `queue`.
    private final class PendingImport {
        let entries: [HistoryEntry]
        let completion: ((Int) -> Void)?
        var nextIndex = 0
        var changedURLs: Set<URL> = []

        init(entries: [HistoryEntry], completion: ((Int) -> Void)?) {
            self.entries = entries
            self.completion = completion
        }
    }

    /// Runs on `queue`: commits the next batch of `pending`, then queues the one after it behind whatever arrived meanwhile, or ends the import after the last batch or a failed one.
    private func importNextBatch(of pending: PendingImport) {
        let end = min(pending.nextIndex + Self.importBatchSize, pending.entries.count)
        if let changedURLs = commit(pending.entries[pending.nextIndex..<end]) {
            pending.changedURLs.formUnion(changedURLs)
            pending.nextIndex = end
            if end < pending.entries.count {
                queue.async { self.importNextBatch(of: pending) }
                return
            }
        }
        let count = pending.changedURLs.count
        imports.leave()
        if let completion = pending.completion { DispatchQueue.main.async { completion(count) } }
    }

    /// Writes `batch` in one transaction and returns the addresses it added or changed, or `nil` when a statement failed and the transaction rolled back.
    private func commit(_ batch: ArraySlice<HistoryEntry>) -> [URL]? {
        guard execute("BEGIN") != nil else { return nil }
        var changedURLs: [URL] = []
        for entry in batch {
            // The update applies only when it changes the page, so that a page the import leaves as it was does not count.
            guard let changes = execute("INSERT INTO visits (url, title, visit_count, last_visit) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(url) DO UPDATE SET visit_count = MAX(visits.visit_count, excluded.visit_count), last_visit = MAX(visits.last_visit, excluded.last_visit), title = CASE WHEN visits.title = '' THEN excluded.title ELSE visits.title END WHERE excluded.visit_count > visits.visit_count OR excluded.last_visit > visits.last_visit OR (visits.title = '' AND excluded.title <> '')",
                                        bindings: [.text(entry.url.absoluteString), .text(entry.title), .integer(entry.visitCount), .double(entry.lastVisit.timeIntervalSince1970)]) else {
                rollBack()
                return nil
            }
            if changes > 0 { changedURLs.append(entry.url) }
        }
        guard execute("COMMIT") != nil else {
            rollBack()
            return nil
        }
        return changedURLs
    }

    /// Blocks until the imports and the changes asked for so far are in the database, including import batches not queued yet, as the app does before it quits.
    public func finishWrites() {
        imports.wait()
        queue.sync {}
    }

    /// Returns entries whose URL or title contains `query`, most visited first. Returns no entries for an empty query. The query scans every row and can wait for an import batch on the store's queue, so the caller suspends instead of blocking its thread.
    public func suggestions(for query: String, limit: Int) async -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.entries("SELECT url, title, visit_count, last_visit FROM visits WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\' ORDER BY visit_count DESC, last_visit DESC LIMIT ?2",
                                                            bindings: [.text("%\(escaped)%"), .integer(limit)]))
            }
        }
    }

    /// Passes the entries visited at or after `date`, newest first, to `completion` on the main queue. The read sees the changes asked for before it, waits for one import batch at most, and completes in the order of the calls.
    public func entries(since date: Date, completion: @escaping ([HistoryEntry]) -> Void) {
        queue.async {
            let entries = self.entries("SELECT url, title, visit_count, last_visit FROM visits WHERE last_visit >= ?1 ORDER BY last_visit DESC", bindings: [.double(date.timeIntervalSince1970)])
            DispatchQueue.main.async { completion(entries) }
        }
    }

    /// Removes the pages at `urls` in one transaction.
    public func remove(_ urls: some Sequence<URL>) {
        let addresses = urls.map(\.absoluteString)
        queue.async {
            guard self.execute("BEGIN") != nil else { return }
            for address in addresses {
                guard self.execute("DELETE FROM visits WHERE url = ?1", bindings: [.text(address)]) != nil else { return self.rollBack() }
            }
            if self.execute("COMMIT") == nil { self.rollBack() }
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
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            logError()
            return nil
        }
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

    /// Runs a statement that returns no rows and returns how many rows it changed, or `nil` when it failed.
    @discardableResult
    private func execute(_ sql: String, bindings: [Binding] = []) -> Int? {
        guard let statement = prepare(sql, bindings: bindings) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logError()
            return nil
        }
        return Int(sqlite3_changes(database))
    }

    /// Ends the transaction a statement failed in, unless the failure ended it already.
    private func rollBack() {
        if let database, sqlite3_get_autocommit(database) == 0 { execute("ROLLBACK") }
    }

    /// Records the database's last error, with its extended result code.
    private func logError() {
        guard let database else { return }
        Self.log.error("history.sqlite: \(String(cString: sqlite3_errmsg(database)), privacy: .public) (\(sqlite3_extended_errcode(database)))")
    }

    private func entries(_ sql: String, bindings: [Binding]) -> [HistoryEntry] {
        guard let statement = prepare(sql, bindings: bindings) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [HistoryEntry] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let urlText = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: urlText)) {
                let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                result.append(HistoryEntry(url: url, title: title, visitCount: Int(sqlite3_column_int64(statement, 2)),
                                           lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
            }
            step = sqlite3_step(statement)
        }
        // A read that fails partway returns the rows before the failure.
        if step != SQLITE_DONE { logError() }
        return result
    }
}
