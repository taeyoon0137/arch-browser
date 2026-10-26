// The JSON files in a Persona's plugin folder, `plugins.json` and each plugin's `storage.json`: read whole, written atomically, and kept aside when they do not read or decode.
import Foundation

enum PluginFile {
    /// The value in the file, or nil for a missing file. A file that does not read, as for its permissions, or does not decode moves to `unreadableURL(of:)`, replacing an older one, so that the next write does not overwrite it, and reads as nil too.
    static func read<Value: Decodable>(_ type: Value.Type, at url: URL) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(type, from: data) { return value }
        _ = try? FileManager.default.replaceItemAt(unreadableURL(of: url), withItemAt: url)
        return nil
    }

    /// `<name>.unreadable.json` beside the file at `url`, where `read(_:at:)` keeps it when it does not read or decode.
    static func unreadableURL(of url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("unreadable.json")
    }

    /// Writes the data atomically, creating the file's folder first. Throws the file system's error, as on a full disk, and the file then stays as it was.
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
