// Keeps the live folders up to date (docs/bookmarks.md, Live folders ▸ Refreshing): the store, the check every 5 minutes through `NSBackgroundActivityScheduler`, the queue that runs at most four feed fetches and one `gh` process at once, and each folder's current fetch. The session registers its live folders, passes the triggers, and plans and applies each result that `didChange` reports.
import Foundation

/// What fetches a folder's items. Tests replace it.
public protocol LiveFolderFetching: Sendable {
    func fetchFeed(_ address: URL, validators: FeedValidators) async throws -> FeedFetchResult
    func searchGitHub(_ search: GitHubSearch, limit: Int) async throws -> GitHubSearchResult
}

/// Feeds through `FeedFetcher` and GitHub through `GitHubCLI`.
public struct LiveFolderFetchers: LiveFolderFetching {
    public let feeds: FeedFetcher
    public let gitHub: GitHubCLI

    public init(feeds: FeedFetcher = FeedFetcher(), gitHub: GitHubCLI = .shared) {
        self.feeds = feeds
        self.gitHub = gitHub
    }

    public func fetchFeed(_ address: URL, validators: FeedValidators) async throws -> FeedFetchResult {
        try await feeds.fetch(address, validators: validators)
    }

    public func searchGitHub(_ search: GitHubSearch, limit: Int) async throws -> GitHubSearchResult {
        try await gitHub.search(search, limit: limit)
    }
}

@MainActor
public final class LiveFolderService {
    public static let feedFetchLimit = 4
    public static let gitHubProcessLimit = 1

    public let store: LiveFolderStore
    /// Private feed addresses (live folder rule 8), read here; `setPrivateAddress(_:for:folderName:)` writes them.
    public let addresses: any LiveFolderAddressStore
    /// Called when a folder starts waiting for a free slot, starts a refresh, or ends one. The folder's items and read state are in `store`; `isRefreshing(_:)` tells whether it waits or refreshes.
    public var didChange: ((UUID) -> Void)?
    public private(set) var folders: [UUID: LiveFolderConfiguration] = [:]

    private let fetchers: any LiveFolderFetching
    private let isLowPowerMode: () -> Bool
    private let now: () -> Date
    /// Folders waiting for a free slot, in the order they became due.
    private var waiting: [UUID] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var scheduler: NSBackgroundActivityScheduler?
    /// The Keychain work asked for last. Each piece waits for the one before, so a cleanup never removes an address written while it ran (Storage).
    private var addressWork: Task<Void, Never>?
    /// Folders whose address `setPrivateAddress` wrote and that no `register(_:)` has listed as private feeds since; cleanups keep their items.
    private var unregisteredAddresses: Set<UUID> = []
    /// Whether registering keeps the store entries and Keychain items of folders that no register of this run listed, removing only those of folders that a register listed and a later one leaves out or lists as no private feed's.
    private let keepsUnknownFolders: Bool

    /// With `keepsUnknownFolders`, as while the session has set aside a file that did not decode, the folders of that file keep their read state and private addresses for a repaired file to bring back.
    public init(store: LiveFolderStore, addresses: any LiveFolderAddressStore = LiveFolderKeychain(), fetchers: any LiveFolderFetching = LiveFolderFetchers(),
                isLowPowerMode: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }, now: @escaping () -> Date = Date.init, keepsUnknownFolders: Bool = false) {
        self.store = store
        self.addresses = addresses
        self.fetchers = fetchers
        self.isLowPowerMode = isLowPowerMode
        self.now = now
        self.keepsUnknownFolders = keepsUnknownFolders
    }

    /// Replaces the live folders, at launch and after each change. A folder that is new, or whose source changed, starts over and refreshes. One whose item limit changed keeps the items within the new limit and refreshes without its validators, so a 304 cannot keep the old number of items; after a raise, that refresh counts the older items it adds as read. The others refresh when due. The store's entries for other folders go, and so do the Keychain items of folders that are not private feeds' (Storage), apart from addresses that `setPrivateAddress(_:for:folderName:)` wrote for folders not registered yet; with `keepsUnknownFolders`, only those of the folders that the last register listed.
    public func register(_ folders: [UUID: LiveFolderConfiguration]) {
        let previous = self.folders
        let gone = Set(previous.keys).subtracting(folders.keys)
        for folder in gone {
            cancel(folder)
            // A registered folder that goes takes its address along, also one written for it since.
            unregisteredAddresses.remove(folder)
        }
        self.folders = folders
        unregisteredAddresses.subtract(Self.privateFeeds(in: folders))
        store.removeFolders(notIn: keepsUnknownFolders ? Set(store.folders.keys).subtracting(gone) : Set(folders.keys))
        let candidates = keepsUnknownFolders ? gone.union(Self.privateFeeds(in: previous)) : nil
        afterEarlierAddressWork { [weak self] in await self?.removeUnusedAddresses(among: candidates) }
        for (folder, configuration) in folders {
            let state = store[folder]
            if state.source != configuration.source {
                startOver(folder, configuration)
            } else if state.itemLimit != configuration.itemLimit {
                cancel(folder)
                store.update(folder) { state in
                    if let previous = state.itemLimit, configuration.itemLimit > previous { state.itemLimitRose = true }
                    state.items = Array(state.items.prefix(configuration.itemLimit))
                    state.validators = FeedValidators()
                    state.itemLimit = configuration.itemLimit
                }
                enqueue(folder)
            }
        }
        refreshDueFolders(.timer)
        // A fetch cancelled above can leave a free slot to a waiting folder.
        startWaitingFolders()
    }

    /// Writes a private feed's whole address to `addresses` (live folder rule 8) before its folder is registered; registering keeps it from then on, and a later register without the folder removes it. A registered private feed whose address changed, as when Edit Live Folder… changes only the query that its source leaves out, starts over and refreshes.
    public func setPrivateAddress(_ address: URL, for folder: UUID, folderName: String) async throws {
        unregisteredAddresses.insert(folder)
        let addresses = addresses
        let changed: Bool
        do {
            changed = try await afterEarlierAddressWork {
                let previous = try? await addresses.address(for: folder)
                try await addresses.setAddress(address, for: folder, folderName: folderName)
                return previous != address
            }.value
        } catch {
            unregisteredAddresses.remove(folder)
            throw error
        }
        guard changed, let configuration = folders[folder], case .feed(_, isPrivate: true) = configuration.source else { return }
        startOver(folder, configuration)
    }

    /// Refresh Now.
    public func refresh(_ folder: UUID) {
        trigger(.refreshNow, folders: [folder])
    }

    /// Arch became active: GitHub folders refresh when due or after the activation gap.
    public func applicationDidBecomeActive() {
        refreshDueFolders(.activation)
    }

    /// A window showed a space with these live folders.
    public func windowDidShowFolders(_ folders: some Sequence<UUID>) {
        trigger(.activation, folders: folders)
    }

    public func isRefreshing(_ folder: UUID) -> Bool {
        running[folder] != nil || waiting.contains(folder)
    }

    /// The timer's next attempt for the folder, for the tooltip of a folder whose refresh failed.
    public func nextAttempt(for folder: UUID) -> Date? {
        folders[folder].map { LiveFolderSchedule.nextAttempt(configuration: $0, state: store[folder], lowPowerMode: isLowPowerMode()) }
    }

    /// Starts the check every 5 minutes.
    public func start() {
        guard scheduler == nil else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "xyz.taeyoon.arch.live-folders.refresh")
        scheduler.repeats = true
        scheduler.interval = LiveFolderSchedule.checkInterval
        scheduler.tolerance = 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                self?.refreshDueFolders(.timer)
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    /// At quit: stops the checks, cancels running fetches, which ends the `gh` process group, and writes the store. A cancelled fetch records no attempt, so its folder is due at the next launch.
    public func stop() {
        scheduler?.invalidate()
        scheduler = nil
        waiting = []
        for task in running.values { task.cancel() }
        running = [:]
        store.saveNow()
    }

    // MARK: Queue

    private func trigger(_ trigger: LiveFolderTrigger, folders ids: some Sequence<UUID>) {
        let lowPower = isLowPowerMode()
        for folder in ids {
            guard let configuration = folders[folder],
                  LiveFolderSchedule.shouldRefresh(trigger, configuration: configuration, state: store[folder], now: now(), lowPowerMode: lowPower) else { continue }
            enqueue(folder)
        }
    }

    private func refreshDueFolders(_ trigger: LiveFolderTrigger) {
        self.trigger(trigger, folders: folders.keys.sorted { $0.uuidString < $1.uuidString })
    }

    private func enqueue(_ folder: UUID) {
        guard running[folder] == nil, !waiting.contains(folder) else { return }
        waiting.append(folder)
        startWaitingFolders()
        // A folder that starts reports it in `start(_:_:)`; one left waiting reports here, so that its row shows the refresh at once.
        if waiting.contains(folder) { didChange?(folder) }
    }

    /// Starts waiting folders while their kind has a free slot.
    private func startWaitingFolders() {
        var feeds = running.keys.filter { folders[$0]?.source.isGitHub == false }.count
        var gitHub = running.count - feeds
        for folder in waiting {
            guard let configuration = folders[folder] else { continue }
            if configuration.source.isGitHub {
                guard gitHub < Self.gitHubProcessLimit else { continue }
                gitHub += 1
            } else {
                guard feeds < Self.feedFetchLimit else { continue }
                feeds += 1
            }
            waiting.removeAll { $0 == folder }
            start(folder, configuration)
        }
        waiting.removeAll { folders[$0] == nil }
    }

    /// Cancels the folder's fetch, forgets its items, read state, and fetch state, and refreshes it.
    private func startOver(_ folder: UUID, _ configuration: LiveFolderConfiguration) {
        cancel(folder)
        store.update(folder) { $0 = LiveFolderState(source: configuration.source, itemLimit: configuration.itemLimit) }
        enqueue(folder)
    }

    private func start(_ folder: UUID, _ configuration: LiveFolderConfiguration) {
        let validators = store[folder].validators
        let started = now()
        let fetchers = fetchers, addresses = addresses
        running[folder] = Task { [weak self] in
            let outcome: Result<Fetched, LiveFolderError>
            do {
                outcome = .success(try await Self.fetch(configuration, folder: folder, validators: validators, fetchers: fetchers, addresses: addresses))
            } catch let error as LiveFolderError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.network(error.localizedDescription))
            }
            // Cancelled: the folder went, its source, address, or item limit changed, or Arch is quitting; a newer task may run for the folder.
            guard !Task.isCancelled else { return }
            self?.finish(folder, configuration, started: started, outcome)
        }
        didChange?(folder)
    }

    private enum Fetched {
        case items([LiveItem], FeedValidators, title: String?, interval: TimeInterval?, isComplete: Bool)
        case notModified
    }

    private nonisolated static func fetch(_ configuration: LiveFolderConfiguration, folder: UUID, validators: FeedValidators, fetchers: any LiveFolderFetching, addresses: any LiveFolderAddressStore) async throws -> Fetched {
        switch configuration.source {
        case .feed(let address, let isPrivate):
            var whole = address
            if isPrivate {
                do {
                    guard let stored = try await addresses.address(for: folder) else { throw LiveFolderError.privateAddressMissing }
                    whole = stored
                } catch let error as LiveFolderError {
                    throw error
                } catch {
                    throw LiveFolderError.keychain(error.localizedDescription)
                }
            }
            switch try await fetchers.fetchFeed(whole, validators: validators) {
            case .notModified: return .notModified
            case .fetched(let feed, let sent): return .items(Array(feed.items.prefix(configuration.itemLimit)), sent, title: feed.title, interval: feed.interval, isComplete: true)
            }
        case .gitHub(let search):
            let result = try await fetchers.searchGitHub(search, limit: configuration.itemLimit)
            return .items(result.items, FeedValidators(), title: nil, interval: nil, isComplete: result.isComplete)
        }
    }

    /// Records the attempt, with the time it started, and its outcome, unless the folder went or its source changed meanwhile.
    private func finish(_ folder: UUID, _ configuration: LiveFolderConfiguration, started: Date, _ outcome: Result<Fetched, LiveFolderError>) {
        running[folder] = nil
        if folders[folder]?.source == configuration.source {
            let date = now()
            store.update(folder) { state in
                state.lastAttempt = started
                switch outcome {
                case .success(.items(let items, let validators, let title, let interval, let isComplete)):
                    state.recordSuccess(items: items, validators: validators, feedTitle: title, feedInterval: interval, isComplete: isComplete, at: date)
                case .success(.notModified):
                    state.recordNotModified(at: date)
                case .failure(let error):
                    state.recordFailure(error, at: date)
                }
            }
            didChange?(folder)
        }
        startWaitingFolders()
    }

    // MARK: Keychain

    /// Removes the Keychain items of folders that are not private feeds' among the folders registered when it runs, apart from addresses written for folders not registered yet; with `candidates`, only those of these folders.
    private func removeUnusedAddresses(among candidates: Set<UUID>?) async {
        let kept = Self.privateFeeds(in: folders).union(unregisteredAddresses)
        guard let candidates else {
            try? await addresses.removeAddresses(except: kept)
            return
        }
        for folder in candidates.subtracting(kept) { try? await addresses.removeAddress(for: folder) }
    }

    /// Runs Keychain work once the work asked for before it has ended.
    @discardableResult
    private func afterEarlierAddressWork<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) -> Task<T, any Error> {
        let previous = addressWork
        let task = Task { @MainActor in
            await previous?.value
            return try await work()
        }
        addressWork = Task { _ = try? await task.value }
        return task
    }

    private static func privateFeeds(in folders: [UUID: LiveFolderConfiguration]) -> Set<UUID> {
        Set(folders.compactMap { id, configuration -> UUID? in
            guard case .feed(_, isPrivate: true) = configuration.source else { return nil }
            return id
        })
    }

    private func cancel(_ folder: UUID) {
        waiting.removeAll { $0 == folder }
        running.removeValue(forKey: folder)?.cancel()
    }
}
