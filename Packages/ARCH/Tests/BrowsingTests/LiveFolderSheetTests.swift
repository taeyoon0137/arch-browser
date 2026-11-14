// The New Live Folder sheet's model (`docs/bookmarks.md`, Live folders ▸ Interface; live folder rules 2, 3, 7, and 8): accepted and refused feed addresses, an address with a query marked for the Keychain, default names, each discovery outcome, `gh`'s states from a stubbed lookup, Add at the limit of 20 live folders, edits that start a folder over or keep its items, and the title with one and two Personas. The lookups never reach the network or `gh`, and the service runs with fetchers that answer offline, so the sheet on a window, its fields, and the session's calls are regression check 72.
import Foundation
import LiveFolders
import Testing
@testable import Browsing

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LiveFolderSheetTests {
    private let space = Space(name: "Research", personaID: Persona.defaultID)
    private let defaultPersona = Persona(id: Persona.defaultID, name: "Default")
    private let blog = URL(string: "https://blog.example.org/")!
    private let blogFeed = URL(string: "https://blog.example.org/feed.xml")!

    private func feed(_ title: String?) -> Feed {
        Feed(title: title, items: [], interval: nil)
    }

    private func newSheet(address: String = "", liveFolderCount: Int = 0, lookups: StubLookups, committed: Committed? = nil) -> LiveFolderSheetModel {
        let model = LiveFolderSheetModel(newIn: space, personas: [defaultPersona], liveFolderCount: liveFolderCount, address: nil, openTerminal: nil,
                                         lookups: lookups.lookups) { committed?.submissions.append($0) }
        model.address = address
        return model
    }

    // MARK: Addresses

    @Test func feedAddressesAreAcceptedOverHTTPSAndRefusedWithoutHTTPOrWithCredentials() throws {
        let typed = try #require(try LiveFolderSheetModel.feedAddress(fromInput: " https://blog.example.org/feed.xml#top "))
        #expect(typed.source == .feed(address: blogFeed, isPrivate: false))
        #expect(typed.keychainAddress == nil && typed.url == blogFeed)
        // Plain HTTP is tried as HTTPS, and text without a scheme counts as HTTPS (live folder rule 2).
        #expect(try LiveFolderSheetModel.feedAddress(fromInput: "http://blog.example.org/feed.xml")?.url == blogFeed)
        #expect(try LiveFolderSheetModel.feedAddress(fromInput: "blog.example.org/feed.xml")?.url == blogFeed)
        #expect(try LiveFolderSheetModel.feedAddress(fromInput: "   ") == nil)

        let lookups = StubLookups()
        let sheet = newSheet(lookups: lookups)
        #expect(sheet.addressError == nil && !sheet.canAdd)
        sheet.address = "ftp://blog.example.org/feed.xml"
        #expect(sheet.addressError == "A feed's address starts with https://." && !sheet.canAdd)
        sheet.address = "https://reader:secret@blog.example.org/feed.xml"
        #expect(sheet.addressError == "A feed's address cannot hold a user name or password." && !sheet.canAdd)
        sheet.address = "blog example"
        #expect(sheet.addressError == "This is not a web address." && !sheet.canAdd)
        sheet.address = "blog.example.org/feed.xml"
        #expect(sheet.addressError == nil && sheet.canAdd)
    }

    @Test func anAddressWithAQueryIsMarkedForTheKeychain() async throws {
        let lookups = StubLookups()
        lookups.outcomes[URL(string: "https://feeds.example.org/private.xml?token=secret")!] = .feed(feed("Private"))
        let committed = Committed()
        let sheet = newSheet(address: "https://feeds.example.org/private.xml?token=secret#top", lookups: lookups, committed: committed)
        #expect(sheet.keepsAddressInKeychain)
        sheet.address = "https://feeds.example.org/public.xml"
        #expect(!sheet.keepsAddressInKeychain)
        sheet.address = "https://feeds.example.org/private.xml?token=secret#top"
        await sheet.add()
        // `session.json` keeps the address without its query; the Keychain gets the whole one without its fragment (live folder rule 8).
        let submission = try #require(committed.submissions.first)
        #expect(submission.configuration.source == .feed(address: URL(string: "https://feeds.example.org/private.xml")!, isPrivate: true))
        #expect(submission.keychainAddress == URL(string: "https://feeds.example.org/private.xml?token=secret"))
        #expect(lookups.discovered == [URL(string: "https://feeds.example.org/private.xml?token=secret")!])
    }

    // MARK: Names

    @Test func aFolderIsNamedByTheUserElseByTheFeedItsLinkOrItsHost() async throws {
        let lookups = StubLookups()
        lookups.outcomes[blogFeed] = .feed(feed("Example Blog"))
        let committed = Committed()
        let sheet = newSheet(address: blogFeed.absoluteString, lookups: lookups, committed: committed)
        #expect(sheet.namePlaceholder == "Feed Title")
        await sheet.add()
        #expect(committed.submissions.last?.name == "Example Blog")

        sheet.name = "  Reading  "
        await sheet.add()
        #expect(committed.submissions.last?.name == "Reading")

        // A feed without a title takes the title its page's link gives, else its host.
        lookups.outcomes[blog] = .links([FeedLink(url: blogFeed, title: "Posts")])
        lookups.outcomes[blogFeed] = .feed(feed(nil))
        sheet.name = ""
        sheet.address = blog.absoluteString
        await sheet.add()
        #expect(committed.submissions.last?.name == "Posts")
        sheet.address = blogFeed.absoluteString
        await sheet.add()
        #expect(committed.submissions.last?.name == "blog.example.org")
    }

    @Test func gitHubSearchesHaveTheirDefaultNames() async throws {
        let lookups = StubLookups()
        lookups.statuses["github.com"] = .signedIn
        let committed = Committed()
        let sheet = newSheet(lookups: lookups, committed: committed)
        sheet.sourceKind = .gitHub
        await sheet.checkGitHub()
        let names: [GitHubSearch.Kind: String] = [.myPullRequests: "Pull Requests", .reviewRequests: "Review Requests", .assignedIssues: "Issues", .search: "GitHub Search"]
        for (kind, name) in names {
            sheet.gitHubKind = kind
            sheet.searchText = kind == .search ? "is:pr is:open review-requested:@me" : ""
            #expect(sheet.namePlaceholder == name)
            await sheet.add()
            #expect(committed.submissions.last?.name == name)
            #expect(committed.submissions.last?.configuration.source == .gitHub(search: GitHubSearch(kind: kind, text: sheet.searchText)))
        }
        // GitHub refreshes every 15 minutes by default (live folder rule 6), and the item limit stays at 25.
        #expect(committed.submissions.last?.configuration.refreshMinutes == 15)
        #expect(committed.submissions.last?.configuration.itemLimit == 25)
        #expect(committed.submissions.last?.keychainAddress == nil)
    }

    // MARK: Discovery

    @Test func aFeedAddressIsUsedDirectly() async throws {
        let lookups = StubLookups()
        lookups.outcomes[blogFeed] = .feed(feed("Example Blog"))
        let committed = Committed()
        let sheet = newSheet(address: blogFeed.absoluteString, lookups: lookups, committed: committed)
        var dismissed = false
        sheet.dismiss = { dismissed = true }
        sheet.itemLimit = 50
        sheet.chosenRefreshMinutes = 60
        await sheet.add()
        let submission = try #require(committed.submissions.first)
        #expect(submission.configuration == LiveFolderConfiguration(source: .feed(address: blogFeed, isPrivate: false), itemLimit: 50, refreshMinutes: 60))
        #expect(lookups.discovered == [blogFeed])
        #expect(dismissed && !sheet.isWorking)
    }

    @Test func aPageWithOneFeedUsesItAtOnce() async throws {
        let lookups = StubLookups()
        let atom = URL(string: "http://blog.example.org/atom.xml")!
        lookups.outcomes[blog] = .links([FeedLink(url: atom, title: "Atom")])
        lookups.outcomes[URL(string: "https://blog.example.org/atom.xml")!] = .feed(feed("Example Blog"))
        let committed = Committed()
        let sheet = newSheet(address: blog.absoluteString, lookups: lookups, committed: committed)
        await sheet.add()
        // The page's feed loads as a feed itself, over HTTPS.
        #expect(lookups.discovered == [blog, URL(string: "https://blog.example.org/atom.xml")!])
        #expect(committed.submissions.first?.configuration.source == .feed(address: URL(string: "https://blog.example.org/atom.xml")!, isPrivate: false))
        #expect(committed.submissions.first?.name == "Example Blog")
    }

    @Test func aPageWithSeveralFeedsListsThemToChooseFrom() async throws {
        let lookups = StubLookups()
        let posts = URL(string: "https://blog.example.org/posts.xml")!, comments = URL(string: "https://blog.example.org/comments.xml?key=reader")!
        lookups.outcomes[blog] = .links([FeedLink(url: posts, title: "Posts"), FeedLink(url: comments, title: "Comments")])
        lookups.outcomes[comments] = .feed(feed("Comments"))
        let committed = Committed()
        let sheet = newSheet(address: blog.absoluteString, lookups: lookups, committed: committed)
        await sheet.add()
        #expect(committed.submissions.isEmpty)
        #expect(sheet.feedLinks.map(\.url) == [posts, comments] && sheet.chosenFeed == posts)
        #expect(sheet.canAdd && !sheet.keepsAddressInKeychain)
        sheet.chosenFeed = comments
        #expect(sheet.keepsAddressInKeychain)
        await sheet.add()
        #expect(lookups.discovered == [blog, comments])
        #expect(committed.submissions.first?.configuration.source == .feed(address: URL(string: "https://blog.example.org/comments.xml")!, isPrivate: true))
        #expect(committed.submissions.first?.keychainAddress == comments)
        // Typing another address puts the list away.
        sheet.address = blogFeed.absoluteString
        #expect(sheet.feedLinks.isEmpty && sheet.chosenFeed == nil)
    }

    @Test func aPageWithoutFeedsAFailedLoadAndABrokenLinkMakeNoFolder() async throws {
        let lookups = StubLookups()
        lookups.outcomes[blog] = .links([])
        let committed = Committed()
        var dismissed = false
        let sheet = newSheet(address: blog.absoluteString, lookups: lookups, committed: committed)
        sheet.dismiss = { dismissed = true }
        await sheet.add()
        #expect(sheet.feedMessage == "No feed found at this address.")

        lookups.failures[blogFeed] = LiveFolderError.httpStatus(404, retryAfter: nil)
        sheet.address = blogFeed.absoluteString
        #expect(sheet.feedMessage == nil)
        await sheet.add()
        #expect(sheet.feedMessage == LiveFolderError.httpStatus(404, retryAfter: nil).message)

        // A link whose address is no feed.
        let other = URL(string: "https://other.example.org/")!
        lookups.outcomes[other] = .links([FeedLink(url: blog, title: nil)])
        sheet.address = other.absoluteString
        await sheet.add()
        #expect(sheet.feedMessage == "No feed found at this address.")
        #expect(committed.submissions.isEmpty && !dismissed)
    }

    // MARK: GitHub

    @Test func gitHubStatesComeFromTheCLIAndAddWaitsUntilItIsSignedIn() async throws {
        let lookups = StubLookups()
        lookups.statuses = ["github.com": .notInstalled, "git.example.com": .signedOut, "git.example.com:8443": .signedIn]
        let sheet = newSheet(lookups: lookups)
        sheet.sourceKind = .gitHub
        #expect(sheet.gitHubState == .checking && !sheet.canAdd)
        await sheet.checkGitHub()
        #expect(sheet.gitHubState == .checked(.notInstalled, host: "github.com"))
        #expect(sheet.gitHubMessage == "Install the GitHub CLI in the built-in terminal, for example with `brew install gh`.")
        #expect(!sheet.canAdd)

        sheet.host = " Git.Example.com "
        #expect(sheet.gitHubState == .checking)
        await sheet.checkGitHub()
        #expect(sheet.gitHubMessage == "Sign in with `gh auth login --hostname git.example.com` in the built-in terminal.")
        #expect(!sheet.canAdd)

        // A pasted address names its host and port.
        sheet.host = "https://git.example.com:8443/"
        await sheet.checkGitHub(again: true)
        #expect(sheet.gitHubState == .checked(.signedIn, host: "git.example.com:8443"))
        #expect(sheet.gitHubMessage == "Signed in to git.example.com:8443.")
        #expect(sheet.isGitHubReady && sheet.canAdd)
        #expect(lookups.checks.map(\.again) == [false, false, true])

        // Search needs its text; a host `gh --hostname` cannot take needs none of `gh`.
        sheet.gitHubKind = .search
        #expect(!sheet.canAdd)
        sheet.searchText = "repo:example/arch is:open"
        #expect(sheet.canAdd)
        sheet.host = "-bad host"
        await sheet.checkGitHub()
        #expect(sheet.gitHubState == .invalidHost && sheet.gitHubMessage == "Enter a GitHub host, such as github.com.")
        #expect(!sheet.canAdd && lookups.checks.count == 3)

        lookups.statuses["github.com"] = .signedOut
        sheet.host = "github.com"
        await sheet.checkGitHub(again: true)
        #expect(sheet.gitHubMessage == "Sign in with `gh auth login` in the built-in terminal.")
    }

    @Test func onlyTheNewestGitHubCheckCounts() async throws {
        let lookups = StubLookups()
        lookups.statuses["github.com"] = .signedIn
        lookups.heldHosts = ["slow.example.com"]
        let sheet = newSheet(lookups: lookups)
        sheet.sourceKind = .gitHub
        sheet.host = "slow.example.com"
        let slow = Task { await sheet.checkGitHub() }
        #expect(await waitUntil { lookups.held.count == 1 })
        sheet.host = "github.com"
        await sheet.checkGitHub()
        #expect(sheet.gitHubState == .checked(.signedIn, host: "github.com"))
        lookups.held.removeFirst().resume(returning: .signedOut)
        await slow.value
        #expect(sheet.gitHubState == .checked(.signedIn, host: "github.com") && sheet.canAdd)
    }

    // MARK: The limit

    @Test func addIsDisabledAtTwentyLiveFolders() async throws {
        let lookups = StubLookups()
        lookups.outcomes[blogFeed] = .feed(feed("Example Blog"))
        let committed = Committed()
        let full = newSheet(address: blogFeed.absoluteString, liveFolderCount: 20, lookups: lookups, committed: committed)
        #expect(full.isAtFolderLimit && !full.canAdd)
        await full.add()
        full.startAdding()
        #expect(committed.submissions.isEmpty && lookups.discovered.isEmpty)
        #expect(LiveFolderSheetModel.folderLimitMessage == "Arch keeps up to 20 live folders.")
        #expect(LiveFolderSheetError.folderLimit.errorDescription == "Arch keeps up to 20 live folders.")

        let room = newSheet(address: blogFeed.absoluteString, liveFolderCount: 19, lookups: lookups, committed: committed)
        #expect(!room.isAtFolderLimit && room.canAdd)
        // Editing a folder makes none, so the limit does not apply.
        var folder = TabFolder(spaceID: space.id, name: "News", isPinned: true)
        folder.live = LiveFolderConfiguration(source: .feed(address: blogFeed, isPrivate: false))
        let edit = editSheet(folder, lookups: lookups)
        #expect(!edit.isAtFolderLimit && edit.canAdd)
    }

    @Test func aFailedCommitStaysInTheSheet() async throws {
        let lookups = StubLookups()
        lookups.outcomes[blogFeed] = .feed(feed("Example Blog"))
        var dismissed = false
        let sheet = LiveFolderSheetModel(newIn: space, personas: [defaultPersona], liveFolderCount: 19, address: blogFeed, openTerminal: nil, lookups: lookups.lookups) { _ in
            throw LiveFolderSheetError.folderLimit
        }
        sheet.dismiss = { dismissed = true }
        #expect(sheet.address == blogFeed.absoluteString)
        await sheet.add()
        #expect(sheet.saveError == "Arch keeps up to 20 live folders." && !dismissed && !sheet.isSaving && !sheet.isWorking)
    }

    // MARK: Editing

    private func editSheet(_ folder: TabFolder, wholeAddress: URL? = nil, keychainReadError: String? = nil, lookups: StubLookups,
                           commit: @escaping (LiveFolderSheetModel.Submission) async throws -> Void = { _ in }) -> LiveFolderSheetModel {
        LiveFolderSheetModel(editing: folder, configuration: folder.live!, in: space, personas: [defaultPersona], wholeAddress: wholeAddress,
                             keychainReadError: keychainReadError, openTerminal: nil, lookups: lookups.lookups, commit: commit)
    }

    private func store() -> LiveFolderStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchLiveFolderSheetTests-\(UUID().uuidString)", isDirectory: true)
        return LiveFolderStore(fileURL: folder.appendingPathComponent(LiveFolderStore.fileName))
    }

    private func items(_ count: Int) -> [LiveItem] {
        (0..<count).map { LiveItem(id: "\($0)", url: URL(string: "https://blog.example.org/\($0)")!, title: "Item \($0)", date: nil) }
    }

    /// Applies an edit as the session does: a private feed's new whole address to the Keychain first, then the folder's change, then registering it.
    private func commitEdit(_ submission: LiveFolderSheetModel.Submission, to folder: inout TabFolder, service: LiveFolderService) async throws {
        if let address = submission.keychainAddress { try await service.setPrivateAddress(address, for: folder.id, folderName: submission.name) }
        submission.apply(to: &folder)
        service.register(LiveFolderTabs.configurations(in: [folder]))
    }

    @Test func anEditOfTheSourceStartsTheFolderOverAndOneOfTheLimitKeepsItsItems() async throws {
        let service = LiveFolderService(store: store(), addresses: InMemoryLiveFolderKeychain(), fetchers: OfflineSheetFetchers(), isLowPowerMode: { false })
        defer { service.stop() }
        var folder = TabFolder(spaceID: space.id, name: "News", isPinned: true)
        folder.live = LiveFolderConfiguration(source: .feed(address: blogFeed, isPrivate: false))
        service.register(LiveFolderTabs.configurations(in: [folder]))
        service.store.update(folder.id) { $0.recordSuccess(items: items(12), at: Date()) }

        // Only the item limit changes: no load, and the items within the new limit stay.
        let lookups = StubLookups()
        var submitted: LiveFolderSheetModel.Submission?
        let limitEdit = editSheet(folder, lookups: lookups) { submitted = $0 }
        #expect(limitEdit.address == blogFeed.absoluteString && limitEdit.name == "News" && limitEdit.title == "Edit Live Folder in Research")
        limitEdit.itemLimit = 10
        limitEdit.name = ""
        await limitEdit.add()
        var submission = try #require(submitted)
        #expect(lookups.discovered.isEmpty && submission.name == "News" && submission.keychainAddress == nil)
        try await commitEdit(submission, to: &folder, service: service)
        #expect(service.store[folder.id].items.map(\.id) == items(10).map(\.id))

        // The address changes: the folder starts over without its items, read state, or dismissed items.
        service.store.update(folder.id) { state in
            state.dismiss("1")
            state.markViewed(["0"], at: Date())
        }
        let other = URL(string: "https://other.example.org/feed.xml")!
        lookups.outcomes[other] = .feed(feed("Other"))
        submitted = nil
        let sourceEdit = editSheet(folder, lookups: lookups) { submitted = $0 }
        sourceEdit.address = other.absoluteString
        await sourceEdit.add()
        submission = try #require(submitted)
        #expect(submission.name == "News" && submission.configuration.source == .feed(address: other, isPrivate: false) && submission.configuration.itemLimit == 10)
        try await commitEdit(submission, to: &folder, service: service)
        let state = service.store[folder.id]
        #expect(state.source == .feed(address: other, isPrivate: false))
        #expect(state.items.isEmpty && state.viewedAt.isEmpty && state.dismissed.isEmpty && state.lastSuccess == nil)
    }

    @Test func anEditOfAPrivateFeedsQueryMovesItIntoTheKeychainAndStartsOver() async throws {
        let keychain = InMemoryLiveFolderKeychain()
        let service = LiveFolderService(store: store(), addresses: keychain, fetchers: OfflineSheetFetchers(), isLowPowerMode: { false })
        defer { service.stop() }
        let old = URL(string: "https://feeds.example.org/private.xml?token=old")!
        let (source, _) = try LiveFolderSource.makeFeed(address: old)
        var folder = TabFolder(spaceID: space.id, name: "Private", isPinned: true)
        folder.live = LiveFolderConfiguration(source: source)
        try await service.setPrivateAddress(old, for: folder.id, folderName: folder.name)
        service.register(LiveFolderTabs.configurations(in: [folder]))
        service.store.update(folder.id) { $0.recordSuccess(items: items(3), at: Date()) }

        // The sheet shows the whole address the Keychain gave; unchanged, Save writes nothing to the Keychain.
        let lookups = StubLookups()
        var submitted: LiveFolderSheetModel.Submission?
        let unchanged = editSheet(folder, wholeAddress: old, lookups: lookups) { submitted = $0 }
        #expect(unchanged.address == old.absoluteString && unchanged.keepsAddressInKeychain && unchanged.keychainReadError == nil)
        await unchanged.add()
        #expect(submitted?.keychainAddress == nil && submitted?.configuration.source == source)

        // A new token keeps the source, which leaves out the query, and the Keychain write starts the folder over.
        let new = URL(string: "https://feeds.example.org/private.xml?token=new")!
        lookups.outcomes[new] = .feed(feed("Private"))
        submitted = nil
        let tokenEdit = editSheet(folder, wholeAddress: old, lookups: lookups) { submitted = $0 }
        tokenEdit.address = new.absoluteString
        await tokenEdit.add()
        let submission = try #require(submitted)
        #expect(submission.configuration.source == source && submission.keychainAddress == new)
        try await commitEdit(submission, to: &folder, service: service)
        #expect(try await keychain.address(for: folder.id) == new)
        #expect(service.store[folder.id].items.isEmpty)

        // Without the whole address from the Keychain, the field shows the address without its query, and an unchanged field keeps the private source.
        submitted = nil
        let unread = editSheet(folder, wholeAddress: nil, keychainReadError: "The Keychain is locked.", lookups: lookups) { submitted = $0 }
        #expect(unread.address == "https://feeds.example.org/private.xml" && unread.keychainReadError == "The Keychain is locked." && unread.keepsAddressInKeychain)
        await unread.add()
        #expect(submitted?.configuration.source == source && submitted?.keychainAddress == nil)
    }

    @Test func aNewFolderJoinsThePinnedListExpandedWithItsConfiguration() {
        let configuration = LiveFolderConfiguration(source: .gitHub(search: GitHubSearch(kind: .reviewRequests)))
        let folder = LiveFolderSheetModel.Submission(name: "Review Requests", configuration: configuration, keychainAddress: nil).newFolder(in: space.id)
        #expect(folder.spaceID == space.id && folder.name == "Review Requests" && folder.isPinned && !folder.isCollapsed && folder.parentID == nil)
        #expect(folder.live == configuration)
    }

    // MARK: The title

    @Test func theTitleNamesTheSpaceWithItsPersonaWhenThereAreTwo() {
        let work = Persona(name: "Work")
        #expect(LiveFolderSheetModel.title(newIn: space, among: [defaultPersona]) == "New Live Folder in Research")
        #expect(LiveFolderSheetModel.title(newIn: Space(name: "Research", personaID: work.id), among: [defaultPersona, work]) == "New Live Folder in Work / Research")
        #expect(LiveFolderSheetModel.title(editingIn: Space(name: "Research", personaID: work.id), among: [defaultPersona, work]) == "Edit Live Folder in Work / Research")
        let sheet = LiveFolderSheetModel(newIn: Space(name: "Research", personaID: work.id), personas: [defaultPersona, work], liveFolderCount: 0, address: nil,
                                         openTerminal: nil, lookups: StubLookups().lookups) { _ in }
        #expect(sheet.title == "New Live Folder in Work / Research" && sheet.isNew)
    }

    @Test func refreshIntervalsFollowTheSourceUntilChosen() {
        let sheet = newSheet(lookups: StubLookups())
        #expect(sheet.refreshMinutes == 30)
        sheet.sourceKind = .gitHub
        #expect(sheet.refreshMinutes == 15)
        sheet.chosenRefreshMinutes = 180
        sheet.sourceKind = .feed
        #expect(sheet.refreshMinutes == 180)
        #expect(LiveFolderConfiguration.refreshIntervals.map(LiveFolderSheetView.intervalTitle) == ["Every 15 Minutes", "Every 30 Minutes", "Every Hour", "Every 3 Hours"])
    }
}

/// The folders that a sheet's Add or Save handed over.
@MainActor
private final class Committed {
    var submissions: [LiveFolderSheetModel.Submission] = []
}

/// Lookups that answer from tables and record what the sheet asked, so tests never reach the network or `gh`.
@MainActor
private final class StubLookups {
    var outcomes: [URL: FeedDiscovery.Outcome] = [:]
    var failures: [URL: any Error] = [:]
    var statuses: [String: GitHubCLIStatus] = [:]
    /// Hosts whose check waits until the test resumes it.
    var heldHosts: Set<String> = []
    private(set) var discovered: [URL] = []
    private(set) var checks: [(host: String, again: Bool)] = []
    var held: [CheckedContinuation<GitHubCLIStatus, Never>] = []

    var lookups: LiveFolderSheetModel.Lookups {
        LiveFolderSheetModel.Lookups(discover: { url in
            self.discovered.append(url)
            if let failure = self.failures[url] { throw failure }
            return self.outcomes[url] ?? .links([])
        }, gitHubStatus: { host, again in
            self.checks.append((host, again))
            if self.heldHosts.contains(host) {
                return await withCheckedContinuation { self.held.append($0) }
            }
            return self.statuses[host] ?? .signedOut
        })
    }
}

/// Fetchers that answer every fetch as offline.
private struct OfflineSheetFetchers: LiveFolderFetching {
    func fetchFeed(_ address: URL, validators: FeedValidators) async throws -> FeedFetchResult {
        throw LiveFolderError.offline
    }

    func searchGitHub(_ search: GitHubSearch, limit: Int) async throws -> GitHubSearchResult {
        throw LiveFolderError.offline
    }
}

/// Waits up to `limit` for `condition`, checking every 10 milliseconds.
@MainActor
private func waitUntil(_ limit: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
