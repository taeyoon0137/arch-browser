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

    /// Creates a database at `path` in write-ahead log mode whose changes are all still in its `-wal` file, as in a browser that holds the database open: `statements` run in a database that is copied with its log before it closes, since closing moves the log into the database.
    @discardableResult
    func databaseWithLog(_ path: String, _ statements: [String]) throws -> URL {
        let open = try write(Data(), to: "open-\(UUID().uuidString)/database")
        let file = url.appendingPathComponent(path)
        var database: OpaquePointer?
        defer {
            sqlite3_close(database)
            try? FileManager.default.removeItem(at: open.deletingLastPathComponent())
        }
        guard sqlite3_open(open.path, &database) == SQLITE_OK else { throw SQLiteError(database) }
        for statement in ["PRAGMA journal_mode = WAL"] + statements {
            guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw SQLiteError(database) }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal"] {
            try FileManager.default.copyItem(atPath: open.path + suffix, toPath: file.path + suffix)
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

/// A sidebar file's items, spaces, and profile references.
enum SidebarItems {
    static let defaultProfile: [String: Any] = ["default": true]
    static func customProfile(_ folder: String) -> [String: Any] {
        ["custom": ["_0": ["directoryBasename": folder, "machineID": "machine"]]]
    }

    static func container(_ id: String, _ children: [String]) -> [String: Any] {
        ["id": id, "parentID": NSNull(), "childrenIds": children, "data": ["itemContainer": ["containerType": ["spaceItems": ["_0": "space"]]]]]
    }

    static func tab(_ id: String, _ address: String, savedTitle: String, title: String? = nil) -> [String: Any] {
        ["id": id, "title": title ?? NSNull(), "childrenIds": [String](), "data": ["tab": ["savedURL": address, "savedTitle": savedTitle]]]
    }

    static func item(_ id: String, _ kind: String, title: String? = nil, _ children: [String]) -> [String: Any] {
        ["id": id, "title": title ?? NSNull(), "childrenIds": children, "data": [kind: [String: Any]()]]
    }

    static func space(_ id: String, title: String?, profile: [String: Any], pinned: String, unpinned: String, theme: [String: Double]? = nil) -> [String: Any] {
        var space: [String: Any] = ["id": id, "containerIDs": ["unpinned", unpinned, "pinned", pinned], "profile": profile]
        space["title"] = title
        space["customInfo"] = theme.map { ["windowTheme": ["primaryColorPalette": ["midTone": $0.merging(["alpha": 1]) { first, _ in first }]]] }
        return space
    }

    /// An array that alternates each object's ID with the object, as the file stores `items` and `spaces`.
    static func flat(_ objects: [[String: Any]]) -> [Any] {
        objects.flatMap { [$0["id"]!, $0] }
    }

    static func file(version: Int = 1, containers: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "sidebar": ["containers": containers], "sidebarSyncState": ["containers": [[String: Any]]()]])
    }
}

/// Chromium-format databases: the `urls` table of History and the `keywords` table of Web Data.
enum ChromiumDatabases {
    static let urlsTable = "CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER)"

    static let keywordsTable = """
        CREATE TABLE keywords (id INTEGER PRIMARY KEY, short_name VARCHAR NOT NULL, keyword VARCHAR NOT NULL, url VARCHAR NOT NULL,
            safe_for_autoreplace INTEGER, prepopulate_id INTEGER DEFAULT 0, created_by_policy INTEGER DEFAULT 0, sync_guid VARCHAR,
            is_active INTEGER DEFAULT 0, starter_pack_id INTEGER DEFAULT 0)
        """

    /// Inserts a `keywords` row; the defaults describe an active shortcut the user created.
    static func keyword(_ name: String, _ keyword: String, _ template: String, guid: String = "", safe: Int = 0, prepopulateID: Int = 0,
                        starterPackID: Int = 0, policy: Int = 0, active: Int = 1) -> String {
        "INSERT INTO keywords (short_name, keyword, url, sync_guid, safe_for_autoreplace, prepopulate_id, starter_pack_id, created_by_policy, is_active) "
            + "VALUES ('\(name)', '\(keyword)', '\(template)', '\(guid)', \(safe), \(prepopulateID), \(starterPackID), \(policy), \(active))"
    }
}

/// The tables of a `history_items` database.
enum WebKitDatabases {
    static let historyTables = [
        "CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, visit_count INTEGER NOT NULL)",
        """
        CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL, visit_time REAL NOT NULL, title TEXT NULL,
            load_successful BOOLEAN NOT NULL DEFAULT 1, redirect_source INTEGER NULL, redirect_destination INTEGER NULL)
        """,
    ]
}
