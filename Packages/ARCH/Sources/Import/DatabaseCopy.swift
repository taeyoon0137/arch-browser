// Reads other browsers' SQLite databases from copies, so that SQLite never opens or writes the browsers' own files: the copy step, the loop over a query's rows, and the deletion of copies an earlier import left behind. `HistoryDatabase` and `SearchKeywords` read their tables through it.
import Foundation
import SQLite3

/// Reads another browser's SQLite database through a copy, as the file header describes.
enum DatabaseCopy {
    /// Starts the name of each temporary folder that holds a copy.
    private static let folderPrefix = "ArchImport-"
    /// How many times `copyDatabase` copies a database's files before it gives up on one that the browser keeps writing.
    private static let copyAttempts = 3

    /// Runs `body` on a copy of the database at `url` in a new temporary folder, which only the user can open, and deletes the copy afterward. A symbolic link is followed, since copying it would copy the link: the copy takes the target's contents and the files beside the target, where SQLite keeps them. Throws `unreadable` when the browser kept writing to the files while they were copied (see `copyDatabase`) or SQLite cannot open the copy.
    static func read<Value>(_ url: URL, unreadable: ImportError, _ body: (OpaquePointer?) throws -> Value) throws -> Value {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("\(folderPrefix)\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        guard try copyDatabase(at: url.resolvingSymlinksInPath(), to: copy) else { throw unreadable }

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        // Read-write, so that SQLite can apply the copied write-ahead log.
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw unreadable }
        return try body(database)
    }

    /// Copies the database at `source` to `copy` with the journal or write-ahead log beside it, since the owning browser may hold the database open and locked with its last committed changes still in those files. The files are copied one after another, so a write in between could pair the database with a log of another moment: while any of the files changed during a copy, they are copied again. Returns false when they still changed after `copyAttempts` copies. `copyFile` copies one file.
    ///
    /// Throws the copy's error for a log that stays as it was but does not copy, as when macOS lets Arch read only the database the user chose: the copy would lack the changes the log holds.
    static func copyDatabase(at source: URL, to copy: URL, copyFile: (URL, URL) throws -> Void = FileManager.default.copyItem(at:to:)) throws -> Bool {
        let logs = ["-journal", "-wal"].map { (source: URL(fileURLWithPath: source.path + $0).resolvingSymlinksInPath(), copy: URL(fileURLWithPath: copy.path + $0)) }
        let sources = [source] + logs.map(\.source)
        for _ in 0..<copyAttempts {
            let states = sources.map(fileState)
            for file in [copy] + logs.map(\.copy) { try? FileManager.default.removeItem(at: file) }
            try copyFile(source, copy)
            var logError: (any Error)?
            for log in logs where FileManager.default.fileExists(atPath: log.source.path) {
                do {
                    try copyFile(log.source, log.copy)
                } catch {
                    logError = error
                }
            }
            // A log can disappear or change while it is copied, as when a transaction ends; the states then differ, and the files are copied again.
            guard sources.map(fileState) == states else { continue }
            if let logError { throw logError }
            return true
        }
        return false
    }

    /// The size and the time of the last change of the file at `url`, both of which a write changes, or nil when the file does not exist.
    private static func fileState(_ url: URL) -> [Int]? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return [Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
    }

    /// Passes each row of `query` to `body`. Throws `unreadable` when the query does not compile, as when the database lacks its table or columns, or when a step fails before the last row, as in a damaged copy, so that part of the rows never passes for all of them.
    static func forEachRow(in database: OpaquePointer?, _ query: String, unreadable: ImportError, _ body: (OpaquePointer?) -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw unreadable }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            body(statement)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw unreadable }
    }

    /// The text in `column` of the current row, or nil for NULL.
    static func text(_ row: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    /// Deletes the copies that an earlier import left behind when Arch quit while reading them. The import controller calls it before reading, when no read uses a copy, since imports run one at a time.
    static func removeLeftovers() {
        let files = FileManager.default
        let items = (try? files.contentsOfDirectory(at: files.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(folderPrefix) {
            try? files.removeItem(at: item)
        }
    }
}
