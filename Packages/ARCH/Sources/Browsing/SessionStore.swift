// Saves and restores sidebar state (spaces, favorites, tabs, closed tabs, and selection) in the JSON file `session.json`. The session supplies the app's Application Support folder.
import ARCHEngine
import Foundation

struct SessionSnapshot: Codable {
    /// Version 2 adds each tab's engine. Files without a version are version 1.
    static let currentVersion = 2

    struct TabRecord: Codable {
        var spaceID: UUID
        var url: URL?
        var title: String
        var isPinned: Bool
        /// `nil` in closed-tab records and in files written before activation tracking.
        var lastActivatedAt: Date?
        /// `nil` in version 1 files; such a tab opens in the default engine.
        var engine: EngineKind?
    }

    var version: Int?

    var spaces: [Space]
    var currentSpaceID: UUID
    var favorites: [Favorite]
    var tabs: [TabRecord]
    var selectedTabIndex: Int?
    /// Recently closed tabs, oldest first. Optional so older files without this field still decode.
    var closedTabs: [TabRecord]?
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
