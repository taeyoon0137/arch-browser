// Saves and restores sidebar state (spaces, favorites and their tabs, tabs, tab folders, closed tabs, and selection) in the JSON file `session.json`. The session supplies the app's Application Support folder.
import ARCHEngine
import Foundation

struct SessionSnapshot: Codable {
    /// Version 2 adds each tab's engine, version 3 its restorable page state, version 4 each space's home page, version 5 the favorites' tabs, and version 6 tab folders. Files without a version are version 1.
    static let currentVersion = 6

    struct TabRecord: Codable {
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
    /// The favorites' tabs, in favorite order. `nil` in files before version 5.
    var favoriteTabs: [FavoriteTabRecord]?
    /// The favorite whose tab was selected. `nil` when a space's tab was selected and in files before version 5.
    var selectedFavoriteID: UUID?
}

final class SessionStore {
    let fileURL: URL
    private var pendingSave: DispatchWorkItem?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("session.json")
    }

    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
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
