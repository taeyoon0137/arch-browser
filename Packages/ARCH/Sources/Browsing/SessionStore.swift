// Saves and restores sidebar state (spaces, favorites and their tabs, tabs, tab folders, closed tabs, split views, and selection) in the JSON file `session.json`. The session supplies the app's Application Support folder.
import ARCHEngine
import Foundation

struct SessionSnapshot: Codable {
    /// Version 2 adds each tab's engine, version 3 its restorable page state, version 4 each space's home page, version 5 the favorites' tabs, version 6 tab folders, version 7 each space's split view, and version 8 each tab's ID. Files without a version are version 1.
    static let currentVersion = 8

    struct TabRecord: Codable {
        /// The tab's ID. `nil` in files before version 8; `normalized()` gives every record one.
        var id: UUID?
        var spaceID: UUID
        var url: URL?
        var title: String
        /// The user's tab name. `nil` when the tab shows its page's title or the file predates tab renaming.
        var customTitle: String?
        var isPinned: Bool
        /// The folder that held the tab. `nil` outside folders and in files before version 6.
        var folderID: UUID?
        /// `nil` in closed-tab records and in files written before activation tracking.
        var lastActivatedAt: Date?
        /// `nil` in version 1 files; such a tab opens in the default engine.
        var engine: EngineKind?
        /// The engine's restorable page state, such as WebKit's back-forward list. `nil` for engines that keep none, in closed-tab records, and in files before version 3.
        var state: Data?
    }

    /// A favorite's tab, which opens where it was when the favorite is next opened.
    struct FavoriteTabRecord: Codable {
        /// The tab's ID, as in a tab record.
        var id: UUID?
        var favoriteID: UUID
        var url: URL?
        var engine: EngineKind
        /// The engine's restorable page state, as in a tab record.
        var state: Data?
    }

    var version: Int?

    var spaces: [Space]
    var currentSpaceID: UUID
    var favorites: [Favorite]
    var tabs: [TabRecord]
    /// Every space's folders, in sidebar order within each space's pinned and open tabs. Optional so files before version 6 still decode.
    var folders: [TabFolder]?
    var selectedTabIndex: Int?
    /// Recently closed tabs, oldest first. Optional so older files without this field still decode.
    var closedTabs: [TabRecord]?
    /// Each space's split view as indexes into `tabs`, left to right; the tabs' space is the split view's. `nil` in files before version 7.
    var splitViews: [[Int]]?
    /// The favorites' tabs, in favorite order. `nil` in files before version 5.
    var favoriteTabs: [FavoriteTabRecord]?
    /// The favorite whose tab was selected. `nil` when a space's tab was selected and in files before version 5.
    var selectedFavoriteID: UUID?

    /// Fills in what older files lack and repairs what a file got wrong. The only migration point: `SessionStore.load()` returns every snapshot through it.
    func normalized() -> SessionSnapshot {
        // Every tab record, whether open, a favorite's, or closed, has an ID of its own. Records from files before version 8 have none, and a record that repeats an earlier record's ID gets a new one, so open tabs keep theirs first.
        var usedIDs: Set<UUID> = []
        func withUniqueIDs<Record>(_ records: [Record], at id: WritableKeyPath<Record, UUID?>) -> [Record] {
            records.map { record in
                if let kept = record[keyPath: id], usedIDs.insert(kept).inserted { return record }
                var record = record
                record[keyPath: id] = UUID()
                return record
            }
        }
        var snapshot = self
        snapshot.tabs = withUniqueIDs(tabs, at: \.id)
        snapshot.favoriteTabs = favoriteTabs.map { withUniqueIDs($0, at: \.id) }
        snapshot.closedTabs = closedTabs.map { withUniqueIDs($0, at: \.id) }
        return snapshot
    }
}

final class SessionStore {
    let fileURL: URL
    private var pendingSave: DispatchWorkItem?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("session.json")
    }

    /// The saved session, or nil when there is none or it cannot be read. A file from a newer build first leaves a copy, `session-v<version>.json`, which keeps that build's fields once this build saves without them. A file that does not decode moves to `session.unreadable.json`, so the fresh session never overwrites it. Either copy replaces an older one.
    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let directory = fileURL.deletingLastPathComponent()
        if let version = try? JSONDecoder().decode(SavedVersion.self, from: data).version, version > SessionSnapshot.currentVersion {
            try? data.write(to: directory.appendingPathComponent("session-v\(version).json"), options: .atomic)
        }
        guard let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else {
            _ = try? FileManager.default.replaceItemAt(directory.appendingPathComponent("session.unreadable.json"), withItemAt: fileURL)
            return nil
        }
        return snapshot.normalized()
    }

    /// The version a file was written with, read on its own so that a newer file is copied even when the rest does not decode.
    private struct SavedVersion: Decodable {
        var version: Int?
    }

    /// Combines rapid changes, such as tab updates, into one file write. Runs the `snapshot` closure when writing, not when scheduling.
    func scheduleSave(_ snapshot: @escaping () -> SessionSnapshot) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [fileURL] in
            guard let data = try? JSONEncoder().encode(snapshot()) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow(_ snapshot: SessionSnapshot) {
        pendingSave?.cancel()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
