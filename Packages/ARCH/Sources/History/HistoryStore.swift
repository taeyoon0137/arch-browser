// Records page visits in `history.sqlite`, each Persona's apart, and uses them for address suggestions, the History window, and agents' and plugins' history searches. The store uses the system SQLite library and runs every query serially on one queue.
import Foundation
import os
import SQLite3

/// A page visited in one Persona: its address, its title, and its visit count and latest visit time in that Persona.
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

/// Safe to use from any thread: outside `init` and `deinit`, only blocks on `queue` touch the database. Every visit belongs to one Persona, by its UUID, and every read and removal names the Persona it covers.
public final class HistoryStore: @unchecked Sendable {
    /// The pages an import writes in one transaction.
    static let importBatchSize = 1_000
    /// The schema version that `PRAGMA user_version` records: 1 since visits record their Persona.
    static let schemaVersion: Int32 = 1
    /// Statements that fail go to the system log, since the store's callers go on without their results.
    private static let log = Logger(subsystem: "xyz.taeyoon.arch", category: "History")

    private let queue = DispatchQueue(label: "local.arch.history")
    private var database: OpaquePointer?
    /// Entered for each import until its last batch is in, so that `finishWrites()` can wait for the batches it has not queued yet.
    private let imports = DispatchGroup()
    /// The imports with batches still to write, used only on `queue`.
    private var runningImports: [PendingImport] = []

    /// Opens or creates `history.sqlite` in `directory`. All store operations are no-ops if the file cannot be opened. A file from before visits recorded their Persona gives its pages to `legacyPersona`, the default Persona, which held everything then (`migrate(legacyPersona:)`).
    public init(directory: URL, legacyPersona: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            Self.log.error("history.sqlite did not open: \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory", privacy: .public)")
            sqlite3_close(handle)
            return
        }
        database = handle
        migrate(legacyPersona: legacyPersona)
    }

    deinit {
        sqlite3_close(database)
    }

    /// Creates the table, keyed by address and Persona, or rebuilds one from before visits recorded their Persona, which was keyed by address alone. SQLite cannot change a table's primary key in place, and a page visited in two Personas needs a row in each, so the old rows move to a new table in one transaction with `legacyPersona` filled in. Filling it in, rather than reading a missing Persona as the default one, keeps one row per page and Persona, which the upserts rely on, and keeps every query a plain comparison. A build from before the rebuild records no visits in the rebuilt file, since its upsert names the address alone, and logs the failure.
    private func migrate(legacyPersona: UUID) {
        guard userVersion() < Self.schemaVersion, execute("BEGIN") != nil else { return }
        let create = "CREATE TABLE visits (url TEXT NOT NULL, persona TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', visit_count INTEGER NOT NULL DEFAULT 0, last_visit REAL NOT NULL, PRIMARY KEY (url, persona))"
        let existing = columns(of: "visits")
        if existing.isEmpty {
            guard execute(create) != nil else { return rollBack() }
        } else if !existing.contains("persona") {
            // The old table's index goes with it.
            guard execute("ALTER TABLE visits RENAME TO visits_unscoped") != nil, execute(create) != nil,
                  execute("INSERT INTO visits (url, persona, title, visit_count, last_visit) SELECT url, ?1, title, visit_count, last_visit FROM visits_unscoped", bindings: [.text(legacyPersona.uuidString)]) != nil,
                  execute("DROP TABLE visits_unscoped") != nil else { return rollBack() }
        }
        guard execute("CREATE INDEX IF NOT EXISTS visits_by_persona_last_visit ON visits (persona, last_visit)") != nil,
              execute("PRAGMA user_version = \(Self.schemaVersion)") != nil, execute("COMMIT") != nil else { return rollBack() }
    }

    /// Counts one visit in the Persona of the tab that made it, and preserves the stored title if the supplied title is empty.
    public func record(_ url: URL, title: String, persona: UUID) {
        queue.async {
            self.execute("INSERT INTO visits (url, persona, title, visit_count, last_visit) VALUES (?1, ?4, ?2, 1, ?3) ON CONFLICT(url, persona) DO UPDATE SET visit_count = visit_count + 1, last_visit = excluded.last_visit, title = CASE WHEN excluded.title = '' THEN visits.title ELSE excluded.title END",
                         bindings: [.text(url.absoluteString), .text(title), .double(Date().timeIntervalSince1970), .text(persona.uuidString)])
        }
    }

    /// Adds pages read from another app's history to the Persona that the import goes to. A page already in that Persona keeps its title unless that is empty, and takes the later last visit and the larger visit count, so importing the same file again changes nothing. The pages go in by batches of `importBatchSize`, each committed on its own and queued once the one before has committed, so that visits, suggestions, and the History window's reads that arrive meanwhile wait for one batch at most. A batch that fails rolls back and ends the import. A removal in the Persona asked for during the import also holds for its later batches, which leave out the pages it removed, as if it had run after the import. `completion`, when given, runs on the main queue after the last batch with the number of pages the committed batches added or changed, counting each address once.
    public func importEntries(_ entries: [HistoryEntry], into persona: UUID, completion: ((Int) -> Void)? = nil) {
        imports.enter()
        let pending = PendingImport(entries: entries, persona: persona, completion: completion)
        queue.async {
            self.runningImports.append(pending)
            self.importNextBatch(of: pending)
        }
    }

    /// One import's pages not written yet, its Persona, and the addresses its batches have added or changed, used only on `queue`.
    private final class PendingImport {
        var remaining: ArraySlice<HistoryEntry>
        let persona: UUID
        let completion: ((Int) -> Void)?
        var changedURLs: Set<URL> = []

        init(entries: [HistoryEntry], persona: UUID, completion: ((Int) -> Void)?) {
            remaining = entries[...]
            self.persona = persona
            self.completion = completion
        }
    }

    /// Runs on `queue`: commits the next batch of `pending`, then queues the one after it behind whatever arrived meanwhile, or ends the import after the last batch or a failed one.
    private func importNextBatch(of pending: PendingImport) {
        let batch = pending.remaining.prefix(Self.importBatchSize)
        if let changedURLs = commit(batch, into: pending.persona) {
            pending.changedURLs.formUnion(changedURLs)
            pending.remaining = pending.remaining.dropFirst(batch.count)
            if !pending.remaining.isEmpty {
                queue.async { self.importNextBatch(of: pending) }
                return
            }
        }
        runningImports.removeAll { $0 === pending }
        let count = pending.changedURLs.count
        imports.leave()
        if let completion = pending.completion { DispatchQueue.main.async { completion(count) } }
    }

    /// Writes `batch` to the Persona in one transaction and returns the addresses it added or changed, or `nil` when a statement failed and the transaction rolled back.
    private func commit(_ batch: ArraySlice<HistoryEntry>, into persona: UUID) -> [URL]? {
        guard execute("BEGIN") != nil else { return nil }
        var changedURLs: [URL] = []
        for entry in batch {
            // The update applies only when it changes the page, so that a page the import leaves as it was does not count.
            guard let changes = execute("INSERT INTO visits (url, persona, title, visit_count, last_visit) VALUES (?1, ?5, ?2, ?3, ?4) ON CONFLICT(url, persona) DO UPDATE SET visit_count = MAX(visits.visit_count, excluded.visit_count), last_visit = MAX(visits.last_visit, excluded.last_visit), title = CASE WHEN visits.title = '' THEN excluded.title ELSE visits.title END WHERE excluded.visit_count > visits.visit_count OR excluded.last_visit > visits.last_visit OR (visits.title = '' AND excluded.title <> '')",
                                        bindings: [.text(entry.url.absoluteString), .text(entry.title), .integer(entry.visitCount), .double(entry.lastVisit.timeIntervalSince1970), .text(persona.uuidString)]) else {
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

    /// Returns the Persona's entries whose URL or title contains `query`, most visited first. Returns no entries for an empty query. The query scans the Persona's rows and can wait for an import batch on the store's queue, so the caller suspends instead of blocking its thread.
    public func suggestions(for query: String, limit: Int, in persona: UUID) async -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return await pages(in: persona, matching: trimmed, limit: limit)
    }

    /// Returns the Persona's entries whose URL or title contains `query`, ignoring the spaces at either end, or all of them for an empty query, most visited first, at most `limit` of those whose address `isIncluded` accepts, which runs on the store's queue. A plugin's history search reads them. Like `suggestions(for:limit:in:)`, the query scans the Persona's rows and can wait for an import batch, so the caller suspends.
    public func pages(in persona: UUID, matching query: String, limit: Int, where isIncluded: @escaping @Sendable (URL) -> Bool = { _ in true }) async -> [HistoryEntry] {
        let pattern = Self.containing(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.entries("SELECT url, title, visit_count, last_visit FROM visits WHERE persona = ?1 AND (url LIKE ?2 ESCAPE '\\' OR title LIKE ?2 ESCAPE '\\') ORDER BY visit_count DESC, last_visit DESC",
                                                            bindings: [.text(persona.uuidString), .text(pattern)], limit: limit, where: isIncluded))
            }
        }
    }

    /// The `LIKE` pattern of text that contains `text`, with SQL's wildcard characters in it taken literally.
    private static func containing(_ text: String) -> String {
        "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    /// Passes the Persona's entries visited at or after `date`, newest first, to `completion` on the main queue. The read sees the changes asked for before it, waits for one import batch at most, and completes in the order of the calls.
    public func entries(since date: Date, in persona: UUID, completion: @escaping ([HistoryEntry]) -> Void) {
        queue.async {
            let entries = self.entries("SELECT url, title, visit_count, last_visit FROM visits WHERE persona = ?1 AND last_visit >= ?2 ORDER BY last_visit DESC",
                                       bindings: [.text(persona.uuidString), .double(date.timeIntervalSince1970)])
            DispatchQueue.main.async { completion(entries) }
        }
    }

    /// Removes the Persona's pages at `urls` in one transaction. Other Personas keep their visits of them.
    public func remove(_ urls: some Sequence<URL>, in persona: UUID) {
        let addresses = Set(urls.map(\.absoluteString))
        queue.async {
            guard self.execute("BEGIN") != nil else { return }
            for address in addresses {
                guard self.execute("DELETE FROM visits WHERE url = ?1 AND persona = ?2", bindings: [.text(address), .text(persona.uuidString)]) != nil else { return self.rollBack() }
            }
            guard self.execute("COMMIT") != nil else { return self.rollBack() }
            self.removeFromRunningImports(into: persona) { addresses.contains($0.url.absoluteString) }
        }
    }

    /// Removes the entries last visited at or after `date`, including their earlier visits, in the Persona, or in every Persona for nil.
    public func removeEntries(since date: Date, in persona: UUID?) {
        queue.async {
            let since = Binding.double(date.timeIntervalSince1970)
            // A running import's later batches leave out the pages removed now in its Persona, also their visits from before `date`.
            var removed: [UUID: Set<String>] = [:]
            for pending in self.runningImports where persona == nil || pending.persona == persona {
                removed[pending.persona] = Set(self.entries("SELECT url, title, visit_count, last_visit FROM visits WHERE persona = ?1 AND last_visit >= ?2",
                                                            bindings: [.text(pending.persona.uuidString), since]).map(\.url.absoluteString))
            }
            if let persona {
                guard self.execute("DELETE FROM visits WHERE persona = ?1 AND last_visit >= ?2", bindings: [.text(persona.uuidString), since]) != nil else { return }
            } else {
                guard self.execute("DELETE FROM visits WHERE last_visit >= ?1", bindings: [since]) != nil else { return }
            }
            for pending in self.runningImports {
                guard let urls = removed[pending.persona] else { continue }
                pending.remaining.removeAll { $0.lastVisit >= date || urls.contains($0.url.absoluteString) }
            }
        }
    }

    /// Moves the Persona's visits into `target`, as Merge Persona Into… does before it removes the Persona: a page in both keeps the target's title unless that is empty, the sum of their visit counts, and the later last visit. It runs in one transaction on the store's queue, ahead of the removal of the source's data that follows.
    public func moveVisits(from source: UUID, to target: UUID) {
        guard source != target else { return }
        queue.async {
            guard self.execute("BEGIN") != nil else { return }
            guard self.execute("INSERT INTO visits (url, persona, title, visit_count, last_visit) SELECT url, ?2, title, visit_count, last_visit FROM visits WHERE persona = ?1 AND true ON CONFLICT(url, persona) DO UPDATE SET visit_count = visits.visit_count + excluded.visit_count, last_visit = MAX(visits.last_visit, excluded.last_visit), title = CASE WHEN visits.title = '' THEN excluded.title ELSE visits.title END",
                                  bindings: [.text(source.uuidString), .text(target.uuidString)]) != nil,
                  self.execute("DELETE FROM visits WHERE persona = ?1", bindings: [.text(source.uuidString)]) != nil,
                  self.execute("COMMIT") != nil else { return self.rollBack() }
        }
    }

    /// Removes the Persona's stored visits and pending import entries, or every Persona's for nil, as when the user clears all history or the session removes a deleted Persona's data.
    public func clear(persona: UUID?) {
        queue.async {
            if let persona {
                guard self.execute("DELETE FROM visits WHERE persona = ?1", bindings: [.text(persona.uuidString)]) != nil else { return }
            } else {
                guard self.execute("DELETE FROM visits") != nil else { return }
            }
            self.removeFromRunningImports(into: persona) { _ in true }
        }
    }

    /// Runs on `queue` after a removal: takes the pages `shouldRemove` accepts out of the batches that running imports into the Persona, or into any Persona for nil, have not written yet.
    private func removeFromRunningImports(into persona: UUID?, where shouldRemove: (HistoryEntry) -> Bool) {
        for pending in runningImports where persona == nil || pending.persona == persona { pending.remaining.removeAll(where: shouldRemove) }
    }

    // MARK: SQLite

    /// A value that `prepare(_:bindings:)` binds to a statement's parameter.
    private enum Binding {
        case text(String)
        case integer(Int)
        case double(Double)
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Prepares a SQLite statement and binds each supplied value.
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

    /// The file's `PRAGMA user_version`: 0 for a new file and for one from before visits recorded their Persona.
    private func userVersion() -> Int32 {
        guard let statement = prepare("PRAGMA user_version", bindings: []) else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    /// The names of the table's columns; none for a table that does not exist.
    private func columns(of table: String) -> [String] {
        guard let statement = prepare("PRAGMA table_info(\(table))", bindings: []) else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.append(String(cString: name)) }
        }
        return names
    }

    /// Reads history rows of `url, title, visit_count, last_visit` from a query, up to `limit` of those whose address `isIncluded` accepts, after which it reads no further rows, keeping rows obtained before a read error.
    private func entries(_ sql: String, bindings: [Binding], limit: Int = .max, where isIncluded: (URL) -> Bool = { _ in true }) -> [HistoryEntry] {
        guard limit > 0, let statement = prepare(sql, bindings: bindings) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [HistoryEntry] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let urlText = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: urlText)), isIncluded(url) {
                let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                result.append(HistoryEntry(url: url, title: title, visitCount: Int(sqlite3_column_int64(statement, 2)),
                                           lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
                if result.count == limit { return result }
            }
            step = sqlite3_step(statement)
        }
        // A read that fails partway returns the rows before the failure.
        if step != SQLITE_DONE { logError() }
        return result
    }
}
