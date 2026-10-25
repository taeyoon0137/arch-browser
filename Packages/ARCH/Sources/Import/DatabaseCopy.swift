// Reads other browsers' SQLite databases from copies, so that SQLite never opens or writes the browsers' own files: the copy step, the loop over a query's rows, and the deletion of copies an earlier import left behind. `HistoryDatabase` and `SearchKeywords` read their tables through it.
import Foundation
import SQLite3

enum DatabaseCopy {
    /// Starts the name of each temporary folder that holds a copy.
    private static let folderPrefix = "ArchImport-"

    /// Runs `body` on a copy of the database at `url` in a new temporary folder, which only the user can open, and deletes the copy afterward. The owning browser may hold the file open and locked, so the copy takes the journal or write-ahead log beside it to have the last committed changes. A symbolic link is followed, since copying it would copy the link: the copy takes the target's contents and the files beside the target, where SQLite keeps them. Throws `unreadable` when SQLite cannot open the copy.
    static func read<Value>(_ url: URL, unreadable: ImportError, _ body: (OpaquePointer?) throws -> Value) throws -> Value {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("\(folderPrefix)\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let source = url.resolvingSymlinksInPath()
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try files.copyItem(at: source, to: copy)
        for suffix in ["-journal", "-wal"] where files.fileExists(atPath: source.path + suffix) {
            try? files.copyItem(at: URL(fileURLWithPath: source.path + suffix).resolvingSymlinksInPath(), to: URL(fileURLWithPath: copy.path + suffix))
        }

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        // Read-write, so that SQLite can apply the copied write-ahead log.
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw unreadable }
        return try body(database)
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
