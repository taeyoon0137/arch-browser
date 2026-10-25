// Reads one file that Import accepts: exported bookmarks as an HTML bookmark file, Chromium-format Bookmarks JSON, or a WebKit-format Bookmarks.plist, or a Chromium-format History database. The contents decide the format, since a History database has no extension.
import Browsing
import Foundation
import History

/// The favorites and history pages one file holds.
struct ImportedFile {
    var favorites: [Favorite] = []
    var history: [HistoryEntry] = []

    /// Reads `url` on the calling thread. Throws when the file cannot be read or is in none of the formats.
    static func read(_ url: URL) throws -> ImportedFile {
        let handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: 16) ?? Data()
        try? handle.close()
        if header.starts(with: Data("SQLite format 3\0".utf8)) {
            return ImportedFile(history: try HistoryDatabase.entries(at: url))
        }
        let data = try Data(contentsOf: url)
        let start = String(decoding: data.prefix(1_024), as: UTF8.self)
        let favorites: [Favorite]?
        if header.starts(with: Data("bplist".utf8)) || start.contains("<plist") {
            favorites = BookmarkFile.webKitTree(from: data)?.allItems.map(\.favorite)
        } else if start.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).hasPrefix("{") {
            favorites = BookmarkFile.chromiumTree(from: data)?.allItems.map(\.favorite)
        } else if start.range(of: "NETSCAPE-Bookmark-file", options: .caseInsensitive) != nil || ["html", "htm"].contains(url.pathExtension.lowercased()) {
            favorites = BookmarkFile.netscapeFavorites(from: data)
        } else {
            favorites = nil
        }
        guard let favorites else { throw ImportError.unrecognizedFormat(url) }
        return ImportedFile(favorites: favorites)
    }

    /// Only web pages come in. Script bookmarklets, files, and another app's internal pages would not open in Arch as they did there.
    static func webURL(_ address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// Why a file gave nothing to import.
enum ImportError: LocalizedError, Equatable {
    /// The file is in none of the formats Import reads.
    case unrecognizedFormat(URL)
    /// SQLite could not open the copy of the database, or the copy lacks the history table or its columns.
    case unreadableHistory(URL)
    /// The file does not parse, or the database copy lacks the expected table or columns.
    case unreadableFile(URL)
    /// macOS privacy protection keeps Arch from reading the file (`EPERM`). A privacy setting in System Settings opens it.
    case blockedByPrivacy(URL)
    /// The file's owner or permissions keep Arch from reading it (`EACCES`), which no privacy setting changes.
    case notPermitted(URL)
    /// The profile keeps its bookmarks only in files encrypted with the browser's own key.
    case encryptedBookmarks

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat(let url):
            return "\u{201C}\(url.lastPathComponent)\u{201D} is not a bookmarks file or a History database that Arch can read."
        case .unreadableHistory(let url):
            return "\u{201C}\(url.lastPathComponent)\u{201D} could not be read as a History database."
        case .unreadableFile(let url):
            return "\u{201C}\(url.lastPathComponent)\u{201D} could not be read."
        case .blockedByPrivacy(let url):
            return "macOS privacy protection keeps Arch from reading \u{201C}\(url.lastPathComponent)\u{201D}."
        case .notPermitted(let url):
            return "Arch does not have permission to read \u{201C}\(url.lastPathComponent)\u{201D}."
        case .encryptedBookmarks:
            return "The bookmarks are encrypted with the browser's own key."
        }
    }
}
