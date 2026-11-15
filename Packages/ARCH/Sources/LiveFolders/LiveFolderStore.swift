// `live-folders.json` (docs/bookmarks.md, Live folders ▸ Storage; live folder rule 1): what each live folder fetched and what the user did with its items. It changes with every fetch and stays on each Mac, while the folder's configuration lives in `session.json`.
import Foundation

/// One live folder's fetched items, read state, dismissed items, and fetch state.
public struct LiveFolderState: Codable, Equatable, Sendable {
    /// The source these items came from. A folder whose configuration names another source starts over (Interface ▸ Edit Live Folder…).
    public var source: LiveFolderSource?
    /// The item limit the items and validators are for. A folder whose configuration names another limit keeps the items within it and refreshes without validators.
    public var itemLimit: Int?
    /// Set when the item limit rose, until the next success, which counts as viewed the items it lists after the last of the earlier items: older items that the lower limit left out (Read and unread).
    public var itemLimitRose: Bool?
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

    /// Records a fetch's items. Items seen at the folder's first success count as viewed then, as do the older items that a raised item limit adds. `viewedAt` and the dismissed items lose entries for items the source no longer lists, unless the answer is not complete, as when GitHub withholds results whose items may return (Read and unread).
    public mutating func recordSuccess(items: [LiveItem], validators: FeedValidators = FeedValidators(), feedTitle: String? = nil, feedInterval: TimeInterval? = nil,
                                       isComplete: Bool = true, at date: Date) {
        if firstSuccess == nil {
            firstSuccess = date
            for item in items { viewedAt[item.id] = date }
        } else if itemLimitRose == true {
            let earlier = Set(self.items.map(\.id))
            if let last = items.lastIndex(where: { earlier.contains($0.id) }) {
                for item in items[(last + 1)...] { viewedAt[item.id] = date }
            }
        }
        itemLimitRose = nil
        self.items = items
        if isComplete {
            let listed = Set(items.map(\.id))
            viewedAt = viewedAt.filter { listed.contains($0.key) }
            dismissed.formIntersection(listed)
        }
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
        var folders: [String: Entry]
    }

    /// A folder's state or, when this build cannot decode it, as with a source that a later build adds, its JSON as the file has it, which saving writes back.
    private enum Entry: Codable {
        case state(LiveFolderState)
        case unreadable(JSONValue)

        init(from decoder: any Decoder) throws {
            if let state = try? LiveFolderState(from: decoder) {
                self = .state(state)
            } else {
                self = .unreadable(try JSONValue(from: decoder))
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .state(let state): try state.encode(to: encoder)
            case .unreadable(let value): try value.encode(to: encoder)
            }
        }
    }

    /// A JSON value as it was read: whole numbers stay whole.
    private enum JSONValue: Codable {
        case null, bool(Bool), integer(Int64), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }

    public let fileURL: URL
    public private(set) var folders: [UUID: LiveFolderState] = [:]
    /// The entries that this build cannot decode, which the file keeps as they were until their folders go.
    private var unreadableEntries: [UUID: JSONValue] = [:]
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
                for (key, entry) in file.folders {
                    guard let id = UUID(uuidString: key) else { continue }
                    switch entry {
                    case .state(let state): folders[id] = state
                    case .unreadable(let value): unreadableEntries[id] = value
                    }
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

    /// The folders with an entry, also one that this build cannot decode.
    public var folderIDs: Set<UUID> { Set(folders.keys).union(unreadableEntries.keys) }

    /// The folder's state, empty before its first refresh and for an entry that this build cannot decode.
    public subscript(folder: UUID) -> LiveFolderState {
        folders[folder] ?? LiveFolderState()
    }

    /// Changes one folder's state and saves half a second after the last change. The new state replaces an entry that this build cannot decode.
    public func update(_ folder: UUID, _ change: (inout LiveFolderState) -> Void) {
        var state = self[folder]
        change(&state)
        guard folders[folder] != state else { return }
        folders[folder] = state
        unreadableEntries[folder] = nil
        scheduleSave()
    }

    public func remove(_ folder: UUID) {
        let removedState = folders.removeValue(forKey: folder) != nil
        let removedEntry = unreadableEntries.removeValue(forKey: folder) != nil
        guard removedState || removedEntry else { return }
        scheduleSave()
    }

    /// Drops the entries of folders that are not live folders in `session.json` (Storage), also those that this build cannot decode.
    public func removeFolders(notIn kept: Set<UUID>) {
        let removed = folderIDs.subtracting(kept)
        guard !removed.isEmpty else { return }
        for folder in removed {
            folders[folder] = nil
            unreadableEntries[folder] = nil
        }
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
        var entries = unreadableEntries.mapValues(Entry.unreadable)
        for (folder, state) in folders { entries[folder] = .state(state) }
        let file = File(folders: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) }))
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
