// Synthetic browser files for the Import tests, each test in a temporary folder of its own. The files hold made-up addresses and names only.
import Foundation
import SQLite3

/// A temporary folder for one test's files. `remove()` deletes it.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `data` at `path` below the folder, creating the folders on the way.
    @discardableResult
    func write(_ data: Data, to path: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    @discardableResult
    func writeJSON(_ object: Any, to path: String) throws -> URL {
        try write(JSONSerialization.data(withJSONObject: object), to: path)
    }

    /// Creates a SQLite database at `path` and runs `statements` in it.
    @discardableResult
    func database(_ path: String, _ statements: [String]) throws -> URL {
        let file = try write(Data(), to: path)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open(file.path, &database) == SQLITE_OK else { throw SQLiteError(database) }
        for statement in statements {
            guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw SQLiteError(database) }
        }
        return file
    }
}

struct SQLiteError: Error, CustomStringConvertible {
    let description: String

    init(_ database: OpaquePointer?) {
        description = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite could not open the database"
    }
}

/// Chromium-format bookmark nodes.
enum ChromiumBookmarks {
    static func url(_ guid: String, _ name: String, _ address: String) -> [String: Any] {
        ["type": "url", "guid": guid, "name": name, "url": address]
    }

    static func folder(_ guid: String, _ name: String, _ children: [[String: Any]]) -> [String: Any] {
        ["type": "folder", "guid": guid, "name": name, "children": children]
    }

    /// A Bookmarks file with the three roots.
    static func file(bar: [[String: Any]], other: [[String: Any]] = [], synced: [[String: Any]] = [], prefix: String = "") -> [String: Any] {
        [
            "version": 1,
            "roots": [
                "bookmark_bar": folder("\(prefix)bar", "Bar", bar),
                "other": folder("\(prefix)other", "Other", other),
                "synced": folder("\(prefix)synced", "Mobile", synced),
            ],
        ]
    }
}

/// WebKit-format bookmark entries.
enum WebKitBookmarks {
    static func leaf(_ uuid: String, _ title: String, _ address: String) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeLeaf", "WebBookmarkUUID": uuid, "URLString": address, "URIDictionary": ["title": title]]
    }

    static func list(_ uuid: String, _ title: String, _ children: [[String: Any]]) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": uuid, "Title": title, "Children": children]
    }
}
