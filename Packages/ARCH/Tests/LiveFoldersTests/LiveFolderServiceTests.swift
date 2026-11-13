// The service with fetchers that stand in for the network and `gh`: registering, the first fetch, private feeds, starting over, the queue's limits, and failures (docs/bookmarks.md, Live folders ▸ Refreshing).
import Foundation
import Testing
@testable import LiveFolders

/// Answers each fetch with the items it is given, after `delay`, and records the addresses and how many fetches of each kind ran at once.
private final class StubFetchers: LiveFolderFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var feedItems: [LiveItem]
    private var failure: LiveFolderError?
    private let delay: Duration
    private var running = (feeds: 0, gitHub: 0)
    private var peak = (feeds: 0, gitHub: 0)
    private var fetched: [URL] = []

    /// The most fetches of each kind that ran at once.
    var peaks: (feeds: Int, gitHub: Int) {
        locked { peak }
    }

    /// The feed addresses fetched, in order.
    var addresses: [URL] {
        locked { fetched }
    }

    init(items: [LiveItem] = [item("a"), item("b")], delay: Duration = .zero) {
        feedItems = items
        self.delay = delay
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
            running.feeds += 1
            peak.feeds = max(peak.feeds, running.feeds)
            return (feedItems, self.failure)
        }
        try? await Task.sleep(for: delay)
        locked { running.feeds -= 1 }
        if let failure { throw failure }
        return .fetched(Feed(title: "Stub", items: items, interval: nil), FeedValidators(entityTag: "\"1\""))
    }

    func searchGitHub(_ search: GitHubSearch, limit: Int) async throws -> [LiveItem] {
        let items = locked {
            running.gitHub += 1
            peak.gitHub = max(peak.gitHub, running.gitHub)
            return Array(feedItems.prefix(limit))
        }
        try? await Task.sleep(for: delay)
        locked { running.gitHub -= 1 }
        return items
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private let feedConfiguration = LiveFolderConfiguration(source: .feed(address: URL(string: "https://blog.example.org/feed.xml")!, isPrivate: false), itemLimit: 10)

@MainActor
private func service(_ fetchers: StubFetchers, addresses: InMemoryLiveFolderKeychain = InMemoryLiveFolderKeychain()) throws -> LiveFolderService {
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
