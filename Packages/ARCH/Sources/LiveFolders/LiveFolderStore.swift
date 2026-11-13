// `live-folders.json` (docs/bookmarks.md, Live folders ▸ Storage; live folder rule 1): what each live folder fetched and what the user did with its items. It changes with every fetch and stays on each Mac, while the folder's configuration lives in `session.json`.
import Foundation

/// One live folder's fetched items, read state, dismissed items, and fetch state.
public struct LiveFolderState: Codable, Equatable, Sendable {
    /// The source these items came from. A folder whose configuration names another source starts over (Interface ▸ Edit Live Folder…).
    public var source: LiveFolderSource?
    /// The item limit the items and validators are for. A folder whose configuration names another limit keeps the items within it and refreshes without validators.
    public var itemLimit: Int?
    /// When the last attempt that ended started.
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    /// Failures in a row, not counting those while the Mac was offline.
    public var failureCount = 0
    /// The last failure's message, cleared by a success.
    public var lastError: String?
    /// The earliest next attempt that `Retry-After` or GitHub's rate limit named.
    public var earliestNextAttempt: Date?
    public var validators = FeedValidators()
    /// The interval the feed asks for.
    public var feedInterval: TimeInterval?
    public var feedTitle: String?
    /// The source's items in its order, up to the folder's limit.
    public var items: [LiveItem] = []
    public var firstSuccess: Date?
    /// When a window last showed each listed item's tab or stopped showing it, or the user marked it read.
    public var viewedAt: [String: Date] = [:]
    /// Items whose tabs the user closed; they stay out of the folder while the source lists them.
    public var dismissed: Set<String> = []

    public init(source: LiveFolderSource? = nil, itemLimit: Int? = nil) {
        self.source = source
        self.itemLimit = itemLimit
    }

    /// Records a fetch's items. Items seen at the folder's first success count as viewed then, and `viewedAt` and the dismissed items lose entries for items the source no longer lists (Read and unread).
    public mutating func recordSuccess(items: [LiveItem], validators: FeedValidators = FeedValidators(), feedTitle: String? = nil, feedInterval: TimeInterval? = nil, at date: Date) {
        if firstSuccess == nil {
            firstSuccess = date
            for item in items { viewedAt[item.id] = date }
        }
        self.items = items
        let listed = Set(items.map(\.id))
        viewedAt = viewedAt.filter { listed.contains($0.key) }
        dismissed.formIntersection(listed)
        self.validators = validators
        self.feedTitle = feedTitle
        self.feedInterval = feedInterval
        recordAnswer(at: date)
    }

    /// Records a 304, which keeps the items.
    public mutating func recordNotModified(at date: Date) {
        recordAnswer(at: date)
    }

    /// Records a failure: its message, a count toward the backoff unless the Mac was offline, and the time the source asked to wait for (live folder rule 6).
    public mutating func recordFailure(_ error: LiveFolderError, at date: Date) {
        lastError = error.message
        if !error.isOffline { failureCount += 1 }
        earliestNextAttempt = error.retryDate.flatMap { $0 > date ? $0 : nil }
    }

    private mutating func recordAnswer(at date: Date) {
        lastSuccess = date
        failureCount = 0
        lastError = nil
        earliestNextAttempt = nil
    }
}

@MainActor
public final class LiveFolderStore {
    public static let fileName = "live-folders.json"

    private struct File: Codable {
        var version = 1
        /// By folder ID.
        var folders: [String: LiveFolderState]
    }

    public let fileURL: URL
    public private(set) var folders: [UUID: LiveFolderState] = [:]
    /// Whether the file did not decode at launch and moved to `live-folders.unreadable.json`; its folders then fetch again.
    public private(set) var replacedUnreadableFile = false
    private var pendingSave: DispatchWorkItem?
    /// Writes the encoded files in order, away from the main thread.
    private let writeQueue = DispatchQueue(label: "xyz.taeyoon.arch.live-folders.store", qos: .utility)

    /// `fileURL` is `live-folders.json` in the app's Application Support folder; tests pass one in a temporary folder.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            if let file = try? JSONDecoder().decode(File.self, from: data) {
                for (key, state) in file.folders {
                    if let id = UUID(uuidString: key) { folders[id] = state }
                }
            } else {
                let unreadable = fileURL.deletingPathExtension().appendingPathExtension("unreadable").appendingPathExtension("json")
                try? FileManager.default.removeItem(at: unreadable)
                try? FileManager.default.moveItem(at: fileURL, to: unreadable)
                replacedUnreadableFile = true
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// The folder's state, empty before its first refresh.
    public subscript(folder: UUID) -> LiveFolderState {
        folders[folder] ?? LiveFolderState()
    }

    /// Changes one folder's state and saves half a second after the last change.
    public func update(_ folder: UUID, _ change: (inout LiveFolderState) -> Void) {
        var state = self[folder]
        change(&state)
        guard folders[folder] != state else { return }
        folders[folder] = state
        scheduleSave()
    }

    public func remove(_ folder: UUID) {
        guard folders.removeValue(forKey: folder) != nil else { return }
        scheduleSave()
    }

    /// Drops the entries of folders that are not live folders in `session.json` (Storage).
    public func removeFolders(notIn kept: Set<UUID>) {
        let removed = folders.keys.filter { !kept.contains($0) }
        guard !removed.isEmpty else { return }
        for folder in removed { folders[folder] = nil }
        scheduleSave()
    }

    /// Combines rapid changes, such as a read state per shown tab, into one write.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save(waiting: false) }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes the file now and returns once it is on disk, as quitting needs.
    public func saveNow() {
        save(waiting: true)
    }

    private func save(waiting: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        let file = File(folders: Dictionary(uniqueKeysWithValues: folders.map { ($0.key.uuidString, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(file) else { return }
        let fileURL = fileURL
        let write: @Sendable () -> Void = {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
        if waiting {
            writeQueue.sync(execute: write)
        } else {
            writeQueue.async(execute: write)
        }
    }
}
