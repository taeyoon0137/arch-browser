// A plugin's storage in one Persona, kept in `storage.json` in the plugin's folder: a JSON object of the plugin's keys and values, and of its setting values under keys with a reserved prefix. The file is read when the storage is created and written atomically once changes settle, and at quit. Each instance of the plugin reaches it through a view of its own that stops writing when the instance stops.
import AppKit

@MainActor
final class PluginStorageFile: PluginStorage {
    /// 5 MB, counted as the UTF-8 bytes of each key plus the JSON of its value, for the plugin's keys and its settings together.
    static let quota = 5_000_000
    /// The start of the keys under which the plugin's setting values live, which the plugin's own keys cannot use.
    static let settingKeyPrefix = "arch.setting:"

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
        for (key, value) in PluginFile.read([String: PluginValue].self, at: fileURL) ?? [:] {
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
        Self.isReserved(key) ? nil : entries[key]?.value
    }

    func setValue(_ value: PluginValue?, forKey key: String) throws {
        guard !Self.isReserved(key) else { throw PluginError.reservedKey(key) }
        try store(value, forKey: key)
    }

    func allKeys() -> [String] {
        entries.keys.filter { !Self.isReserved($0) }.sorted()
    }

    /// The value of the setting `key`, which Settings stored.
    func settingValue(forKey key: String) -> PluginValue? {
        entries[Self.settingKeyPrefix + key]?.value
    }

    /// nil removes the value, so the setting reads as its default. Throws like `setValue(_:forKey:)`.
    func setSettingValue(_ value: PluginValue?, forKey key: String) throws {
        try store(value, forKey: Self.settingKeyPrefix + key)
    }

    /// Writes the changes that have not reached the file yet, if any.
    func saveChanges() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        // Every entry encodes, since `size(of:forKey:)` checked each value where the file holds it.
        guard let data = try? Self.encoder.encode(entries.mapValues(\.value)) else { return }
        PluginFile.write(data, to: fileURL)
    }

    /// Drops the changes that have not reached the file, for a plugin whose data goes, so that none writes the file again.
    func discardChanges() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    /// Only a write that grows the storage can exceed the quota.
    private func store(_ value: PluginValue?, forKey key: String) throws {
        let oldSize = entries[key]?.size ?? 0
        let newSize = try value.map { try Self.size(of: $0, forKey: key) } ?? 0
        if newSize > oldSize, size - oldSize + newSize > Self.quota { throw PluginError.quotaExceeded }
        entries[key] = value.map { Entry(value: $0, size: newSize) }
        size += newSize - oldSize
        scheduleSave()
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

    private static func isReserved(_ key: String) -> Bool {
        key.hasPrefix(settingKeyPrefix)
    }

    /// Encodes the value inside an array, one level down as in the file's object, so that it throws for a value nested too deep for the file, and leaves out the brackets.
    private static func size(of value: PluginValue, forKey key: String) throws -> Int {
        try key.utf8.count + encoder.encode([value]).count - 2
    }
}

/// One plugin instance's view of its plugin's storage, which the plugin's instances share. Once the instance stops, it only reads, and writes throw `PluginError.stopped`.
@MainActor
final class ScopedPluginStorage: PluginStorage {
    let file: PluginStorageFile
    private var hasEnded = false

    init(file: PluginStorageFile) {
        self.file = file
    }

    /// Called when the instance stops.
    func end() {
        hasEnded = true
    }

    func value(forKey key: String) -> PluginValue? {
        file.value(forKey: key)
    }

    func setValue(_ value: PluginValue?, forKey key: String) throws {
        guard !hasEnded else { throw PluginError.stopped }
        try file.setValue(value, forKey: key)
    }

    func allKeys() -> [String] {
        file.allKeys()
    }
}
