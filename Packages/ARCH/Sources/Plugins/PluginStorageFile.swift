// A plugin's storage in one Persona, kept in `storage.json` in the plugin's folder: a JSON object of the plugin's keys and values. The file is read when the storage is created and written atomically once changes settle, and at quit.
import AppKit

@MainActor
final class PluginStorageFile: PluginStorage {
    /// 5 MB, counted as the UTF-8 bytes of each key plus the JSON of its value.
    static let quota = 5_000_000

    private static let encoder = JSONEncoder()

    private let fileURL: URL
    private var entries: [String: Entry] = [:]
    /// The sum of the entries' sizes.
    private var size = 0
    private var pendingSave: DispatchWorkItem?

    private struct Entry {
        var value: PluginValue
        /// What the entry counts against the quota.
        var size: Int
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        for (key, value) in Self.values(at: fileURL) {
            // Values read from the file always encode again.
            let entry = Entry(value: value, size: (try? Self.size(of: value, forKey: key)) ?? 0)
            entries[key] = entry
            size += entry.size
        }
        // A change made just before quitting still reaches the file.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveChanges() }
        }
    }

    func value(forKey key: String) -> PluginValue? {
        entries[key]?.value
    }

    /// Only a write that grows the storage can exceed the quota.
    func setValue(_ value: PluginValue?, forKey key: String) throws {
        let oldSize = entries[key]?.size ?? 0
        let newSize = try value.map { try Self.size(of: $0, forKey: key) } ?? 0
        if newSize > oldSize, size - oldSize + newSize > Self.quota { throw PluginError.quotaExceeded }
        entries[key] = value.map { Entry(value: $0, size: newSize) }
        size += newSize - oldSize
        scheduleSave()
    }

    func allKeys() -> [String] {
        entries.keys.sorted()
    }

    /// Writes the changes that have not reached the file yet, if any.
    func saveChanges() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        // Every entry encodes, since `size(of:forKey:)` checked each value where the file holds it.
        guard let data = try? Self.encoder.encode(entries.mapValues(\.value)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Combines rapid changes into one file write, like the app's other stores.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveChanges() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The values in the file. A missing file has none. A file that does not decode has none either and moves to `storage.unreadable.json` beside it, replacing an older one, so the first change does not overwrite it.
    private static func values(at fileURL: URL) -> [String: PluginValue] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        if let values = try? JSONDecoder().decode([String: PluginValue].self, from: data) { return values }
        _ = try? FileManager.default.replaceItemAt(fileURL.deletingLastPathComponent().appendingPathComponent("storage.unreadable.json"), withItemAt: fileURL)
        return [:]
    }

    /// Encodes the value inside an array, one level down as in the file's object, so that it throws for a value nested too deep for the file, and leaves out the brackets.
    private static func size(of value: PluginValue, forKey key: String) throws -> Int {
        try key.utf8.count + encoder.encode([value]).count - 2
    }
}
