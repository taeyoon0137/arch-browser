// The browsers File ▸ Import from Browser… reads, where each keeps its data, and the checks that find them. As `AGENTS.md` allows, only this file names browser products in code: other code and the tests read names, identifiers, and locations from these definitions.
import Foundation

/// A browser Arch imports from, with the places and formats of its data, and the folders where native app vendors install host manifests for other browsers.
public struct BrowserSource: Hashable, Identifiable, Sendable {
    /// The name the import sheet shows.
    let name: String
    /// Identifies the source in the import record and gives the sheet the app's icon.
    let bundleIdentifier: String
    let layout: Layout
    /// The setting that lets Arch read the browser's files when macOS privacy protection blocks them.
    let privacySetting: PrivacySetting

    public var id: String { bundleIdentifier }

    /// The folders where native app vendors install host manifests for other browsers, in the order that `NativeMessagingHostLinks` reads them, which the app shell passes to the session (`docs/import-browsers.md`, Native messaging hosts). The system folders come first, since root owns them and they are no app's data; the user folders follow, the protected one of an installed browser first. The import does not use them.
    public static let nativeMessagingHostFolders: [URL] = {
        let system = URL(fileURLWithPath: "/Library", isDirectory: true)
        let support = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Application Support", isDirectory: true)
        return [
            system.appendingPathComponent("Google/Chrome/NativeMessagingHosts", isDirectory: true),
            system.appendingPathComponent("Application Support/Chromium/NativeMessagingHosts", isDirectory: true),
            system.appendingPathComponent("Microsoft/Edge/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("Chromium/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("Vivaldi/NativeMessagingHosts", isDirectory: true),
        ]
    }()

    /// Where a browser keeps the data Arch reads, by format.
    enum Layout: Hashable, Sendable {
        /// Chromium-format profiles in a user data folder, and for a browser with spaces, its sidebar file.
        case chromium(userData: URL, sidebarFile: URL?)
        /// WebKit-format bookmarks and a `history_items` database.
        case webKit(bookmarks: URL, history: URL)
    }

    /// The file that shows the browser keeps data on this Mac: the sidebar file, `Local State`, or the bookmarks.
    var keyFile: URL {
        switch layout {
        case .chromium(let userData, let sidebarFile): return sidebarFile ?? ChromiumProfile.localStateFile(in: userData)
        case .webKit(let bookmarks, _): return bookmarks
        }
    }

    /// The browsers the import looks for, in the order the sheet lists them.
    static let all: [BrowserSource] = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let support = library.appendingPathComponent("Application Support")
        return [
            // macOS protects Chrome's folder as another app's data. Check 1 under Checks with the app in `docs/import-browsers.md` confirms which setting opens it; until then the sheet names Full Disk Access.
            BrowserSource(name: "Chrome", bundleIdentifier: "com.google.Chrome",
                          layout: .chromium(userData: support.appendingPathComponent("Google/Chrome"), sidebarFile: nil), privacySetting: .fullDiskAccess),
            // Not checked: Dia's bundle identifier and data location are assumed (see Dia in `docs/import-browsers.md`).
            BrowserSource(name: "Dia", bundleIdentifier: "company.thebrowser.dia",
                          layout: .chromium(userData: support.appendingPathComponent("Dia/User Data"), sidebarFile: nil), privacySetting: .fullDiskAccess),
            BrowserSource(name: "Arc", bundleIdentifier: "company.thebrowser.Browser",
                          layout: .chromium(userData: support.appendingPathComponent("Arc/User Data"), sidebarFile: support.appendingPathComponent("Arc/StorableSidebar.json")),
                          privacySetting: .fullDiskAccess),
            BrowserSource(name: "Safari", bundleIdentifier: "com.apple.Safari",
                          layout: .webKit(bookmarks: library.appendingPathComponent("Safari/Bookmarks.plist"), history: library.appendingPathComponent("Safari/History.db")),
                          privacySetting: .fullDiskAccess),
        ]
    }()

    /// The sources among `sources` that keep data on this Mac, each with its key file's access. A source without its data folder lacks the key file as well, so one check covers both.
    static func detected(among sources: [BrowserSource] = all) -> [(source: BrowserSource, access: FileAccess)] {
        sources.compactMap { source in
            let access = FileAccess(source.keyFile)
            return access == .missing ? nil : (source, access)
        }
    }
}

/// A setting in System Settings ▸ Privacy & Security.
struct PrivacySetting: Hashable, Sendable {
    let name: String
    /// Opens the setting's pane. The anchor is undocumented (see Open decisions in `docs/import-browsers.md`); without it, System Settings opens at Privacy & Security.
    let paneURL: URL

    static let fullDiskAccess = PrivacySetting(name: "Full Disk Access", paneURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
}

/// Whether Arch can read a file, from `access(2)`. It opens nothing, so checking a file that macOS protects shows no prompt.
enum FileAccess: Equatable {
    case readable
    case missing
    /// macOS privacy protection blocks the file (`EPERM`). The source's privacy setting opens it.
    case blockedByPrivacy
    /// The file's owner or permissions block it (`EACCES`), which no privacy setting changes.
    case notPermitted

    init(_ url: URL) {
        guard access(url.path, R_OK) != 0 else {
            self = .readable
            return
        }
        switch errno {
        case EPERM: self = .blockedByPrivacy
        case EACCES: self = .notPermitted
        default: self = .missing
        }
    }

    /// Runs `read` on `url` once the check passes. Returns nil for a missing file, and throws `ImportError.blockedByPrivacy` or `.notPermitted` for a blocked one. A read that fails with `EPERM` counts as blocked too, since macOS may decide only when the file opens.
    static func read<Value>(_ url: URL, with read: (URL) throws -> Value) throws -> Value? {
        switch FileAccess(url) {
        case .missing:
            return nil
        case .blockedByPrivacy:
            throw ImportError.blockedByPrivacy(url)
        case .notPermitted:
            throw ImportError.notPermitted(url)
        case .readable:
            do {
                return try read(url)
            } catch let error where isPrivacyDenial(error) {
                throw ImportError.blockedByPrivacy(url)
            }
        }
    }

    /// Reads `url` and parses it with `parse`, as `read(_:with:)` does. Throws `ImportError.unreadableFile` when `parse` returns nil.
    static func parse<Value>(_ url: URL, with parse: (Data) -> Value?) throws -> Value? {
        try read(url) { url in
            guard let value = parse(try Data(contentsOf: url)) else { throw ImportError.unreadableFile(url) }
            return value
        }
    }

    /// Whether `error` or an error under it is the POSIX error `EPERM`, which Foundation wraps in Cocoa errors such as `NSFileReadNoPermissionError`.
    private static func isPrivacyDenial(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
