// Chromium-format profiles: the profiles that a user data folder's `Local State` lists, and the files in each profile folder that the browser import reads. Each read returns nil for a missing file and throws for one that is blocked or does not parse (see `FileAccess`).
import Foundation
import History

/// One profile that a Chromium-format user data folder lists, as the file header describes.
struct ChromiumProfile: Equatable {
    /// The profile's folder in the user data folder, such as `Default` or `Profile 2`.
    let folder: URL
    /// The name the browser shows for the profile.
    let name: String
    /// Whether `Local State` names the profile as the one used last, or the profile is `Default` and `Local State` names none, as Chromium then opens `Default`.
    let isLastUsed: Bool

    static func localStateFile(in userData: URL) -> URL {
        userData.appendingPathComponent("Local State")
    }

    /// The profiles `Local State` lists under `profile.info_cache`, in the order of `profile.profiles_order` and then by folder. Without a `Local State`, or with one that lists no profiles, the `Default` profile stands alone as the last used, named after its folder. Throws `ImportError.unreadableFile` for a `Local State` that does not parse or lacks `profile.info_cache`, which Chromium writes for each profile it creates, so that a changed format reports the file rather than hiding the profiles.
    static func profiles(in userData: URL) throws -> [ChromiumProfile] {
        let localState = try FileAccess.parse(localStateFile(in: userData)) { data -> (profile: [String: Any], cache: [String: Any])? in
            guard let profile = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["profile"] as? [String: Any],
                  let cache = profile["info_cache"] as? [String: Any] else { return nil }
            return (profile, cache)
        }
        guard case let (profile, cache)? = localState, !cache.isEmpty else {
            return [ChromiumProfile(folder: userData.appendingPathComponent("Default"), name: "Default", isLastUsed: true)]
        }
        let order = (profile["profiles_order"] as? [String] ?? []).filter { cache[$0] != nil }
        let lastUsed = (profile["last_used"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Default"
        return (order + cache.keys.filter { !order.contains($0) }.sorted()).map { folderName in
            let name = ((cache[folderName] as? [String: Any])?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ChromiumProfile(folder: userData.appendingPathComponent(folderName), name: name.isEmpty ? folderName : name, isLastUsed: folderName == lastUsed)
        }
    }

    /// The profile's bookmarks: `Bookmarks`, then the bookmarks saved to the signed-in account without sync in `AccountBookmarks`, merged so that an address in both comes once. Returns nil without either file. Throws `ImportError.encryptedBookmarks` when the profile keeps them only in the copies encrypted with the browser's key.
    func bookmarks() throws -> BookmarkTree? {
        let trees = try ["Bookmarks", "AccountBookmarks"].compactMap { name in
            try FileAccess.parse(folder.appendingPathComponent(name), with: BookmarkFile.chromiumTree(from:))
        }
        guard !trees.isEmpty else {
            let isEncrypted = ["EncryptedBookmarks2", "EncryptedAccountBookmarks2"].contains { FileAccess(folder.appendingPathComponent($0)) != .missing }
            if isEncrypted { throw ImportError.encryptedBookmarks }
            return nil
        }
        return BookmarkTree.merging(trees)
    }

    /// The pages of the profile's `History` database.
    func history() throws -> [HistoryEntry]? {
        try FileAccess.read(folder.appendingPathComponent("History"), with: HistoryDatabase.entries(at:))
    }

    /// The search shortcuts in the profile's `Web Data` database, with the default engine that its `Preferences` names. A `Preferences` file that is missing or does not parse names none.
    func searchKeywords() throws -> SearchKeywords? {
        let preferences = (try? Data(contentsOf: folder.appendingPathComponent("Preferences"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return try FileAccess.read(folder.appendingPathComponent("Web Data")) { try SearchKeywords.read(at: $0, preferences: preferences) }
    }
}
