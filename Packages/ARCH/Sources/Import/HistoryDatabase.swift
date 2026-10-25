// Reads the pages of a Chromium-format History database, the SQLite file in a Chromium-based browser's profile folder.
import Foundation
import History
import SQLite3

enum HistoryDatabase {
    /// Chromium counts time in microseconds since 1601-01-01 UTC.
    private static let secondsFrom1601To1970: Double = 11_644_473_600
    /// Starts the name of each temporary folder that holds a copy.
    private static let copyFolderPrefix = "ArchImport-"

    /// Returns the pages the browser lists in its history and that have web addresses, with their titles, visit counts, and last visits. The browser may hold the file open and locked, so the reader opens a copy in a temporary folder, with the journal or write-ahead log beside it so the copy has the last committed changes.
    static func entries(at url: URL) throws -> [HistoryEntry] {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("\(copyFolderPrefix)\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("History")
        try files.copyItem(at: url, to: copy)
        for suffix in ["-journal", "-wal"] where files.fileExists(atPath: url.path + suffix) {
            try? files.copyItem(atPath: url.path + suffix, toPath: copy.path + suffix)
        }

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        // Hidden rows are pages the browser leaves out of its own history list, such as those loaded in frames.
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > 0", -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.unreadableHistory(url)
        }
        defer { sqlite3_finalize(statement) }
        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let address = sqlite3_column_text(statement, 0), let pageURL = ImportedFile.webURL(String(cString: address)) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let lastVisit = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1_000_000 - secondsFrom1601To1970)
            entries.append(HistoryEntry(url: pageURL, title: title, visitCount: max(Int(sqlite3_column_int64(statement, 2)), 1), lastVisit: lastVisit))
        }
        return entries
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
