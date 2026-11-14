// The service with fetchers that stand in for the network and `gh`: registering, the first fetch, private feeds, starting over, item limits, the queue's limits, cancelled fetches, and failures (docs/bookmarks.md, Live folders ▸ Refreshing).
import Foundation
import Testing
@testable import LiveFolders

/// Answers each fetch with the items it is given, after `delay`, and records the addresses, validators, and searches, and how many fetches of each kind ran at once.
private final class StubFetchers: LiveFolderFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var feedItems: [LiveItem]
    private var failure: LiveFolderError?
    private let delay: Duration
    /// Answers 304 to a feed request with validators, as a feed that did not change does.
    private let answersNotModified: Bool
    private var running = (feeds: 0, gitHub: 0)
    private var peak = (feeds: 0, gitHub: 0)
    private var fetched: [URL] = []
    private var sent: [FeedValidators] = []
    private var searched: [GitHubSearch] = []

    /// The most fetches of each kind that ran at once.
    var peaks: (feeds: Int, gitHub: Int) {
        locked { peak }
    }

    /// The feed addresses fetched, in order.
    var addresses: [URL] {
        locked { fetched }
    }

    /// The validators each feed request sent, in order.
    var validators: [FeedValidators] {
        locked { sent }
    }

    /// The searches started, in order.
    var searches: [GitHubSearch] {
        locked { searched }
    }

    init(items: [LiveItem] = [item("a"), item("b")], delay: Duration = .zero, answersNotModified: Bool = false) {
        feedItems = items
        self.delay = delay
        self.answersNotModified = answersNotModified
    }

    func answer(items: [LiveItem]? = nil, failure: LiveFolderError? = nil) {
        locked {
            if let items { feedItems = items }
            self.failure = failure
        }
    }

    func fetchFeed(_ address: URL, validators: FeedValidators) async throws -> FeedFetchResult {
        let (items, failure) = locked {
            fetched.append(address)
            sent.append(validators)
            running.feeds += 1
            peak.feeds = max(peak.feeds, running.feeds)
            return (feedItems, self.failure)
        }
        try? await Task.sleep(for: delay)
        locked { running.feeds -= 1 }
        if let failure { throw failure }
        if answersNotModified, validators.entityTag != nil { return .notModified }
        return .fetched(Feed(title: "Stub", items: items, interval: nil), FeedValidators(entityTag: "\"1\""))
    }

    func searchGitHub(_ search: GitHubSearch, limit: Int) async throws -> GitHubSearchResult {
        let items = locked {
            searched.append(search)
            running.gitHub += 1
            peak.gitHub = max(peak.gitHub, running.gitHub)
            return Array(feedItems.prefix(limit))
        }
        try? await Task.sleep(for: delay)
        locked { running.gitHub -= 1 }
        return GitHubSearchResult(items: items)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Holds the first removal until `open()`, as the hop to the Keychain's queue can hold a cleanup after it chose what to keep, and passes the rest to an in-memory store.
private final class GatedKeychain: LiveFolderAddressStore, @unchecked Sendable {
    let stored = InMemoryLiveFolderKeychain()
    private let lock = NSLock()
    private var removals = 0
    private var finished = 0
    private var isOpen = false
    private var gate: CheckedContinuation<Void, Never>?

    /// The removals that started.
    var startedRemovals: Int {
        lock.withLock { removals }
    }

    /// The removals that ended.
    var finishedRemovals: Int {
        lock.withLock { finished }
    }

    func open() {
        let gate = lock.withLock {
            isOpen = true
            defer { self.gate = nil }
            return self.gate
        }
        gate?.resume()
    }

    func address(for folder: UUID) async throws -> URL? {
        try await stored.address(for: folder)
    }

    func setAddress(_ address: URL, for folder: UUID, folderName: String) async throws {
        try await stored.setAddress(address, for: folder, folderName: folderName)
    }

    func removeAddress(for folder: UUID) async throws {
        try await stored.removeAddress(for: folder)
    }

    func removeAddresses(except kept: Set<UUID>) async throws {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock {
                removals += 1
                if !isOpen { gate = continuation }
                return isOpen
            }
            if passes { continuation.resume() }
        }
        try await stored.removeAddresses(except: kept)
        lock.withLock { finished += 1 }
    }
}

private let feedConfiguration = LiveFolderConfiguration(source: .feed(address: URL(string: "https://blog.example.org/feed.xml")!, isPrivate: false), itemLimit: 10)

@MainActor
private func service(_ fetchers: StubFetchers, addresses: any LiveFolderAddressStore = InMemoryLiveFolderKeychain()) throws -> LiveFolderService {
    let store = LiveFolderStore(fileURL: try temporaryDirectory().appendingPathComponent(LiveFolderStore.fileName))
    return LiveFolderService(store: store, addresses: addresses, fetchers: fetchers, isLowPowerMode: { false })
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LiveFolderServiceTests {
    @Test func aNewFolderRefreshesAndItsFirstItemsAreRead() async throws {
        let fetchers = StubFetchers(items: (1...12).map { item("\($0)") })
        let service = try service(fetchers)
        let folder = UUID()
        var changes: [UUID] = []
        service.didChange = { changes.append($0) }
        service.register([folder: feedConfiguration])
        #expect(await waitUntil { service.store[folder].lastSuccess != nil })
        let state = service.store[folder]
        #expect(state.items.count == 10)
        #expect(state.feedTitle == "Stub")
        #expect(state.validators.entityTag == "\"1\"")
        #expect(state.unreadItemIDs.isEmpty)
        #expect(!service.isRefreshing(folder))
        #expect(changes == [folder, folder])
        // Not due again yet.
        service.register([folder: feedConfiguration])
        #expect(!service.isRefreshing(folder))
        #expect(fetchers.addresses.count == 1)
    }

    @Test func aPrivateFeedFetchesItsAddressFromTheKeychain() async throws {
        let fetchers = StubFetchers()
        let keychain = InMemoryLiveFolderKeychain()
        let folder = UUID(), stale = UUID()
        let whole = URL(string: "https://tracker.example.org/feed.atom?token=abc123")!
        let made = try LiveFolderSource.makeFeed(address: whole)
        try await keychain.setAddress(try #require(made.keychainAddress), for: folder, folderName: "Tracker")
        try await keychain.setAddress(whole, for: stale, folderName: "Gone")
        let service = try service(fetchers, addresses: keychain)
        service.register([folder: LiveFolderConfiguration(source: made.source)])
        #expect(await waitUntil { service.store[folder].lastSuccess != nil })
        #expect(fetchers.addresses == [whole])
        // The Keychain items of folders that are no private feeds' go.
        #expect(await waitUntil { keychain.folders == [folder] })
    }

    @Test func aPrivateFeedWithoutItsKeychainItemFails() async throws {
        let service = try service(StubFetchers())
        let folder = UUID()
        service.register([folder: LiveFolderConfiguration(source: .feed(address: URL(string: "https://tracker.example.org/feed.atom")!, isPrivate: true))])
        #expect(await waitUntil { service.store[folder].lastError != nil })
        #expect(service.store[folder].lastError == LiveFolderError.privateAddressMissing.message)
        #expect(service.store[folder].failureCount == 1)
    }

    @Test func aChangedSourceStartsOverAndARemovedFolderLeavesNothing() async throws {
        let fetchers = StubFetchers()
        let service = try service(fetchers)
        let folder = UUID()
        service.register([folder: feedConfiguration])
        #expect(await waitUntil { service.store[folder].lastSuccess != nil })
        service.store.update(folder) { $0.dismiss("a") }
        fetchers.answer(items: [item("x"), item("y")])
        let gitHub = LiveFolderConfiguration(source: .gitHub(search: GitHubSearch(kind: .assignedIssues)))
        service.register([folder: gitHub])
        #expect(service.store[folder].items.isEmpty)
        #expect(service.store[folder].dismissed.isEmpty)
        #expect(await waitUntil { service.store[folder].lastSuccess != nil })
        #expect(service.store[folder].items.map(\.id) == ["x", "y"])
        #expect(service.store[folder].source == gitHub.source)
        service.register([:])
        #expect(service.store.folders.isEmpty)
    }

    @Test func aPrivateFeedWhoseAddressChangedStartsOver() async throws {
        let fetchers = StubFetchers()
        let service = try service(fetchers)
        let folder = UUID()
        let first = URL(string: "https://tracker.example.org/feed.php?cat=1&key=abc123")!
        let second = URL(string: "https://tracker.example.org/feed.php?cat=2&key=abc123")!
        let made = try LiveFolderSource.makeFeed(address: first)
        // Only the query changes, which the source leaves out.
        #expect(try LiveFolderSource.makeFeed(address: second).source == made.source)
        try await service.setPrivateAddress(try #require(made.keychainAddress), for: folder, folderName: "Tracker")
        service.register([folder: LiveFolderConfiguration(source: made.source)])
        #expect(await waitUntil { service.store[folder].lastSuccess != nil })
        service.store.update(folder) { $0.dismiss("a") }
        fetchers.answer(items: [item("x")])
        try await service.setPrivateAddress(first, for: folder, folderName: "Tracker")
        #expect(service.store[folder].dismissed == ["a"])
        try await service.setPrivateAddress(second, for: folder, folderName: "Tracker")
        #expect(service.store[folder].items.isEmpty)
        #expect(service.store[folder].dismissed.isEmpty)
        #expect(service.store[folder].validators == FeedValidators())
        #expect(await waitUntil { service.store[folder].lastSuccess != nil })
        #expect(service.store[folder].items.map(\.id) == ["x"])
        #expect(fetchers.addresses == [first, second])
    }

    @Test func anAddressWrittenBeforeItsFolderIsRegisteredSurvivesOtherRegisters() async throws {
        let fetchers = StubFetchers()
        let keychain = InMemoryLiveFolderKeychain()
        let service = try service(fetchers, addresses: keychain)
        let other = UUID(), folder = UUID(), stale = UUID()
        let whole = URL(string: "https://tracker.example.org/feed.atom?token=abc123")!
        try await keychain.setAddress(whole, for: stale, folderName: "Gone")
        try await service.setPrivateAddress(whole, for: folder, folderName: "Tracker")
        // Another window registers before the new folder's does.
        service.register([other: feedConfiguration])
        #expect(await waitUntil { !keychain.folders.contains(stale) })
        #expect(keychain.folders == [folder])
        service.register([other: feedConfiguration, folder: LiveFolderConfiguration(source: try LiveFolderSource.makeFeed(address: whole).source)])
        #expect(await waitUntil { service.store[folder].lastSuccess != nil })
        #expect(fetchers.addresses.contains(whole))
        // Once registered, the address goes with its folder.
        service.register([other: feedConfiguration])
        #expect(await waitUntil { keychain.folders.isEmpty })
    }

    @Test func aRegisteredPrivateFeedThatGoesTakesAnAddressWrittenSinceAlong() async throws {
        let keychain = InMemoryLiveFolderKeychain()
        let service = try service(StubFetchers(), addresses: keychain)
        let folder = UUID()
        let first = URL(string: "https://tracker.example.org/feed.php?cat=1&key=abc123")!
        let second = URL(string: "https://tracker.example.org/feed.php?cat=2&key=abc123")!
        try await service.setPrivateAddress(first, for: folder, folderName: "Tracker")
        service.register([folder: LiveFolderConfiguration(source: try LiveFolderSource.makeFeed(address: first).source)])
        #expect(await waitUntil { service.store[folder].lastSuccess != nil })
        // Edit Live Folder… changes only the query, which leaves the configuration as it was, and Delete Folder follows.
        try await service.setPrivateAddress(second, for: folder, folderName: "Tracker")
        #expect(keychain.folders == [folder])
        service.register([:])
        #expect(await waitUntil { keychain.folders.isEmpty })
    }

    @Test func aCleanupThatChoseWhatToKeepBeforeAWriteLeavesTheWrittenAddress() async throws {
        let keychain = GatedKeychain()
        let service = try service(StubFetchers(), addresses: keychain)
        let folder = UUID()
        let whole = URL(string: "https://tracker.example.org/feed.atom?token=abc123")!
        service.register([UUID(): feedConfiguration])
        #expect(await waitUntil { keychain.startedRemovals == 1 })
        let write = Task { try await service.setPrivateAddress(whole, for: folder, folderName: "Tracker") }
        // Time for a write that does not wait for the cleanup to pass it.
        try? await Task.sleep(for: .milliseconds(200))
        keychain.open()
        try await write.value
        #expect(await waitUntil { keychain.finishedRemovals == 1 })
        #expect(keychain.stored.folders == [folder])
    }

    @Test func aChangedItemLimitKeepsTheItemsWithinItAndRefreshesWithoutValidators() async throws {
        let fetchers = StubFetchers(items: (1...30).map { item("\($0)") }, answersNotModified: true)
        let service = try service(fetchers)
        let folder = UUID()
        let source = feedConfiguration.source
        service.register([folder: LiveFolderConfiguration(source: source, itemLimit: 10)])
        #expect(await waitUntil { service.store[folder].lastSuccess != nil })
        #expect(service.store[folder].items.count == 10)
        // Raised: the next request sends no validators, which would bring a 304 and keep 10 items. The older items it adds count as read; a newer one does not.
        fetchers.answer(items: [item("new")] + (1...30).map { item("\($0)") })
        service.register([folder: LiveFolderConfiguration(source: source, itemLimit: 25)])
        #expect(service.isRefreshing(folder))
        #expect(await waitUntil { service.store[folder].items.count == 25 })
        #expect(fetchers.validators.map(\.entityTag) == [nil, nil])
        #expect(service.store[folder].unreadItemIDs == ["new"])
        #expect(service.store[folder].itemLimitRose == nil)
        // Lowered: the first items stay at once.
        service.register([folder: LiveFolderConfiguration(source: source, itemLimit: 10)])
        #expect(service.store[folder].items.map(\.id) == ["new"] + (1...9).map { "\($0)" })
        #expect(await waitUntil { !service.isRefreshing(folder) })
        #expect(service.store[folder].items.count == 10)
    }

    @Test func removingARunningFolderStartsTheOneWaitingForItsSlot() async throws {
        let fetchers = StubFetchers(delay: .milliseconds(500))
        let service = try service(fetchers)
        let pulls = UUID(), issues = UUID()
        let configurations = [pulls: LiveFolderConfiguration(source: .gitHub(search: GitHubSearch(kind: .myPullRequests))),
                              issues: LiveFolderConfiguration(source: .gitHub(search: GitHubSearch(kind: .assignedIssues)))]
        service.register(configurations)
        #expect(await waitUntil { fetchers.searches.count == 1 })
        // One `gh` runs while the other folder waits; the running one's folder goes.
        let waiting = fetchers.searches[0].kind == .myPullRequests ? issues : pulls
        #expect(service.isRefreshing(waiting))
        service.register([waiting: try #require(configurations[waiting])])
        #expect(await waitUntil { service.store[waiting].lastSuccess != nil })
        #expect(!service.isRefreshing(waiting))
    }

    @Test func aFetchThatQuittingCancelsRecordsNoAttempt() async throws {
        let fetchers = StubFetchers(delay: .seconds(5))
        let service = try service(fetchers)
        let folder = UUID()
        service.register([folder: feedConfiguration])
        #expect(await waitUntil { fetchers.addresses.count == 1 })
        service.stop()
        #expect(!service.isRefreshing(folder))
        #expect(service.store[folder].lastAttempt == nil)
        // Due at once at the next launch.
        #expect(service.nextAttempt(for: folder) == .distantPast)
    }

    @Test func runsAtMostFourFeedsAndOneGhProcessAtOnce() async throws {
        let fetchers = StubFetchers(delay: .milliseconds(150))
        let service = try service(fetchers)
        var folders: [UUID: LiveFolderConfiguration] = [:]
        for _ in 0..<6 { folders[UUID()] = feedConfiguration }
        for _ in 0..<3 { folders[UUID()] = LiveFolderConfiguration(source: .gitHub(search: GitHubSearch(kind: .myPullRequests))) }
        service.register(folders)
        #expect(await waitUntil { folders.keys.allSatisfy { service.store[$0].lastSuccess != nil } })
        #expect(fetchers.peaks.feeds == LiveFolderService.feedFetchLimit)
        #expect(fetchers.peaks.gitHub == LiveFolderService.gitHubProcessLimit)
    }

    @Test func failuresAreRecordedAndRefreshNowTriesAgain() async throws {
        let fetchers = StubFetchers()
        fetchers.answer(failure: .httpStatus(500, retryAfter: nil))
        let service = try service(fetchers)
        let folder = UUID()
        service.register([folder: feedConfiguration])
        #expect(await waitUntil { service.store[folder].failureCount == 1 })
        #expect(service.store[folder].items.isEmpty)
        #expect(service.nextAttempt(for: folder).map { $0.timeIntervalSinceNow > 59 * 60 } == true)
        fetchers.answer(failure: nil)
        service.refresh(folder)
        #expect(await waitUntil { service.store[folder].lastSuccess != nil })
        #expect(service.store[folder].failureCount == 0)
        #expect(service.store[folder].lastError == nil)
    }
}
