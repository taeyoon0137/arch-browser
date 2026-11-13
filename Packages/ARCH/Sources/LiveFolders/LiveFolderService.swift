// Keeps the live folders up to date (docs/bookmarks.md, Live folders ▸ Refreshing): the store, the check every 5 minutes through `NSBackgroundActivityScheduler`, the queue that runs at most four feed fetches and one `gh` process at once, and each folder's current fetch. The session registers its live folders, passes the triggers, and plans and applies each result that `didChange` reports.
import Foundation

/// What fetches a folder's items. Tests replace it.
public protocol LiveFolderFetching: Sendable {
    func fetchFeed(_ address: URL, validators: FeedValidators) async throws -> FeedFetchResult
    func searchGitHub(_ search: GitHubSearch, limit: Int) async throws -> [LiveItem]
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

    public func searchGitHub(_ search: GitHubSearch, limit: Int) async throws -> [LiveItem] {
        try await gitHub.search(search, limit: limit)
    }
}

@MainActor
public final class LiveFolderService {
    public static let feedFetchLimit = 4
    public static let gitHubProcessLimit = 1

    public let store: LiveFolderStore
    /// Private feed addresses (live folder rule 8).
    public let addresses: any LiveFolderAddressStore
    /// Called when a folder starts or ends a refresh. The folder's items and read state are in `store`; `isRefreshing(_:)` tells which.
    public var didChange: ((UUID) -> Void)?
    public private(set) var folders: [UUID: LiveFolderConfiguration] = [:]

    private let fetchers: any LiveFolderFetching
    private let isLowPowerMode: () -> Bool
    private let now: () -> Date
    /// Folders waiting for a free slot, in the order they became due.
    private var waiting: [UUID] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var scheduler: NSBackgroundActivityScheduler?

    public init(store: LiveFolderStore, addresses: any LiveFolderAddressStore = LiveFolderKeychain(), fetchers: any LiveFolderFetching = LiveFolderFetchers(),
                isLowPowerMode: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.addresses = addresses
        self.fetchers = fetchers
        self.isLowPowerMode = isLowPowerMode
        self.now = now
    }

    /// Replaces the live folders, at launch and after each change. A folder that is new, or whose source changed, starts over and refreshes; the others refresh when due. The store's entries for other folders go, and so do the Keychain items of folders that are not private feeds' (Storage), so a new private feed's address goes into `addresses` before its folder is registered.
    public func register(_ folders: [UUID: LiveFolderConfiguration]) {
        for folder in self.folders.keys where folders[folder] == nil { cancel(folder) }
        self.folders = folders
        store.removeFolders(notIn: Set(folders.keys))
        Task { [weak self] in await self?.removeUnusedAddresses() }
        for (folder, configuration) in folders where store[folder].source != configuration.source {
            cancel(folder)
            store.update(folder) { $0 = LiveFolderState(source: configuration.source) }
            enqueue(folder)
        }
        refreshDueFolders(.timer)
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

    /// At quit: stops the checks, cancels running fetches, which ends the `gh` process group, and writes the store.
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

    private func start(_ folder: UUID, _ configuration: LiveFolderConfiguration) {
        let validators = store[folder].validators
        store.update(folder) { $0.lastAttempt = now() }
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
            // Cancelled: the folder went, its source changed, or Arch is quitting; a newer task may run for the folder.
            guard !Task.isCancelled else { return }
            self?.finish(folder, configuration, outcome)
        }
        didChange?(folder)
    }

    private enum Fetched {
        case items([LiveItem], FeedValidators, title: String?, interval: TimeInterval?)
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
            case .fetched(let feed, let sent): return .items(Array(feed.items.prefix(configuration.itemLimit)), sent, title: feed.title, interval: feed.interval)
            }
        case .gitHub(let search):
            return .items(try await fetchers.searchGitHub(search, limit: configuration.itemLimit), FeedValidators(), title: nil, interval: nil)
        }
    }

    /// Records the outcome, unless the folder went or its source changed meanwhile.
    private func finish(_ folder: UUID, _ configuration: LiveFolderConfiguration, _ outcome: Result<Fetched, LiveFolderError>) {
        running[folder] = nil
        if folders[folder]?.source == configuration.source {
            let date = now()
            store.update(folder) { state in
                switch outcome {
                case .success(.items(let items, let validators, let title, let interval)):
                    state.recordSuccess(items: items, validators: validators, feedTitle: title, feedInterval: interval, at: date)
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

    /// Removes the Keychain items of folders that are not private feeds' among the folders registered when it runs.
    private func removeUnusedAddresses() async {
        let privateFeeds = Set(folders.compactMap { id, configuration -> UUID? in
            guard case .feed(_, isPrivate: true) = configuration.source else { return nil }
            return id
        })
        try? await addresses.removeAddresses(except: privateFeeds)
    }

    private func cancel(_ folder: UUID) {
        waiting.removeAll { $0 == folder }
        running.removeValue(forKey: folder)?.cancel()
    }
}
