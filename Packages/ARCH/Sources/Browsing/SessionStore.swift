// Saves and restores sidebar state (spaces, favorites, tabs, and selection) in one JSON file, `session.json`. The session supplies the directory: the app's Application Support folder.
import Foundation

struct SessionSnapshot: Codable {
    struct TabRecord: Codable {
        var spaceID: UUID
        var url: URL?
        var title: String
        var isPinned: Bool
    }

    var spaces: [Space]
    var currentSpaceID: UUID
    var favorites: [Favorite]
    var tabs: [TabRecord]
    var selectedTabIndex: Int?
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

    /// Combines rapid changes, such as a burst of tab updates, into one file write. Runs the `snapshot` closure when writing, not when scheduling the save.
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
