// Live folders were removed on November 23 by the user's decision (`docs/bookmarks.md`, Live sources). A saved live folder loads as an ordinary folder (`SessionSnapshot.dropLiveItemTabs()`), and what live folders kept outside `session.json` goes once the session has saved without them: `live-folders.json`, its set-aside copy, and the private feed addresses' Keychain items.
import Foundation
import Security

/// Names and deletes what removed live folders left outside `session.json`: their files in Application Support and their Keychain items.
enum RemovedLiveFolders {
    /// The files that kept each live folder's fetched items and read state, in the app's Application Support folder.
    static let fileNames = ["live-folders.json", "live-folders.unreadable.json"]
    /// The Keychain service of the private feed addresses' generic password items, one per folder.
    static let keychainService = "xyz.taeyoon.arch.live-folders"

    /// Whether `directory` still holds one of the files.
    static func hasStoredFiles(in directory: URL) -> Bool {
        fileNames.contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Deletes the files in `directory`.
    static func removeFiles(in directory: URL) {
        for name in fileNames { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }

    /// Deletes every private feed address from the login keychain. On macOS one call deletes every item that matches the service. A failure leaves the items, which nothing reads any more.
    static func removeKeychainItems() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
