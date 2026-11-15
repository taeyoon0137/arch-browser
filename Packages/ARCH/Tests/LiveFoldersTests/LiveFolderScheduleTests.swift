// When folders refresh (live folder rule 6), and what their sources and configurations accept (live folder rules 2, 7, and 8), with no timers or network (docs/bookmarks.md, Tests ▸ LiveFoldersTests).
import Foundation
import Testing
@testable import LiveFolders

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let feed = LiveFolderConfiguration(source: .feed(address: URL(string: "https://blog.example.org/feed.xml")!, isPrivate: false))
private let gitHub = LiveFolderConfiguration(source: .gitHub(search: GitHubSearch(kind: .myPullRequests)))

private func minutes(_ count: Double) -> TimeInterval {
    count * 60
}

private func state(attempt: Date? = start, failures: Int = 0, feedInterval: TimeInterval? = nil, earliest: Date? = nil) -> LiveFolderState {
    var state = LiveFolderState()
    state.lastAttempt = attempt
    state.failureCount = failures
    state.feedInterval = feedInterval
    state.earliestNextAttempt = earliest
    return state
}

private func due(_ configuration: LiveFolderConfiguration, _ state: LiveFolderState, lowPowerMode: Bool = false) -> TimeInterval {
    LiveFolderSchedule.nextAttempt(configuration: configuration, state: state, lowPowerMode: lowPowerMode).timeIntervalSince(start)
}

@Suite struct LiveFolderScheduleTests {
    @Test func eachIntervalAndTheDefaults() {
        #expect(feed.refreshMinutes == 30)
        #expect(gitHub.refreshMinutes == 15)
        for minutesBetween in LiveFolderConfiguration.refreshIntervals {
            let configuration = LiveFolderConfiguration(source: feed.source, refreshMinutes: minutesBetween)
            #expect(due(configuration, state()) == minutes(Double(minutesBetween)))
        }
        #expect(LiveFolderSchedule.nextAttempt(configuration: feed, state: state(attempt: nil), lowPowerMode: false) == .distantPast)
        #expect(!LiveFolderSchedule.shouldRefresh(.timer, configuration: feed, state: state(), now: start + minutes(29), lowPowerMode: false))
        #expect(LiveFolderSchedule.shouldRefresh(.timer, configuration: feed, state: state(), now: start + minutes(30), lowPowerMode: false))
        #expect(LiveFolderSchedule.shouldRefresh(.refreshNow, configuration: feed, state: state(earliest: start + minutes(60)), now: start, lowPowerMode: false))
    }

    @Test func activationRefreshesGitHubFoldersAfterFiveMinutesAndFeedsNever() {
        #expect(!LiveFolderSchedule.shouldRefresh(.activation, configuration: gitHub, state: state(), now: start + minutes(4), lowPowerMode: false))
        #expect(LiveFolderSchedule.shouldRefresh(.activation, configuration: gitHub, state: state(), now: start + minutes(5), lowPowerMode: false))
        #expect(!LiveFolderSchedule.shouldRefresh(.activation, configuration: feed, state: state(), now: start + minutes(20), lowPowerMode: false))
        // A failing folder waits for its backoff, and the gap doubles in Low Power Mode.
        #expect(!LiveFolderSchedule.shouldRefresh(.activation, configuration: gitHub, state: state(failures: 1), now: start + minutes(10), lowPowerMode: false))
        #expect(!LiveFolderSchedule.shouldRefresh(.activation, configuration: gitHub, state: state(), now: start + minutes(9), lowPowerMode: true))
        #expect(LiveFolderSchedule.shouldRefresh(.activation, configuration: gitHub, state: state(), now: start + minutes(10), lowPowerMode: true))
        #expect(!LiveFolderSchedule.shouldRefresh(.activation, configuration: gitHub, state: state(earliest: start + minutes(12)), now: start + minutes(10), lowPowerMode: false))
    }

    @Test func aFeedsOwnIntervalLengthensItsWaitUpToADay() {
        #expect(due(feed, state(feedInterval: minutes(10))) == minutes(30))
        #expect(due(feed, state(feedInterval: minutes(90))) == minutes(90))
        #expect(due(feed, state(feedInterval: 7 * 86_400)) == 86_400)
        // GitHub folders have no feed interval to follow.
        #expect(due(gitHub, state(feedInterval: minutes(90))) == minutes(15))
    }

    @Test func failuresDoubleTheWaitUpToSixHours() {
        #expect(due(feed, state(failures: 1)) == minutes(60))
        #expect(due(feed, state(failures: 2)) == minutes(120))
        #expect(due(feed, state(failures: 3)) == minutes(240))
        #expect(due(feed, state(failures: 4)) == minutes(360))
        #expect(due(feed, state(failures: 400)) == minutes(360))
        // Never below the interval a feed asks for.
        #expect(due(feed, state(failures: 3, feedInterval: 86_400)) == 86_400)
    }

    @Test func offlineFailuresDoNotCount() {
        var folder = state()
        folder.recordFailure(.offline, at: start)
        #expect(folder.failureCount == 0)
        #expect(folder.lastError == LiveFolderError.offline.message)
        folder.recordFailure(.httpStatus(500, retryAfter: nil), at: start)
        folder.recordFailure(.timedOut, at: start)
        #expect(folder.failureCount == 2)
        folder.recordNotModified(at: start)
        #expect(folder.failureCount == 0)
        #expect(folder.lastError == nil)
    }

    @Test func retryAfterAndTheRateLimitResetPostponeTheNextAttempt() {
        var folder = state()
        folder.recordFailure(.httpStatus(429, retryAfter: start + 7_200), at: start)
        #expect(due(feed, folder) == 7_200)
        #expect(!LiveFolderSchedule.shouldRefresh(.timer, configuration: feed, state: folder, now: start + 7_000, lowPowerMode: false))
        folder.recordFailure(.rateLimited(until: start + minutes(20)), at: start)
        // The backoff after two failures, 1 hour for a 15-minute folder, is longer than the reset.
        #expect(due(gitHub, folder) == minutes(60))
        folder.failureCount = 0
        #expect(due(gitHub, folder) == minutes(20))
        // A time already past postpones nothing.
        folder.recordFailure(.httpStatus(503, retryAfter: start - 60), at: start)
        #expect(folder.earliestNextAttempt == nil)
    }

    @Test func lowPowerModeDoublesEveryInterval() {
        #expect(due(feed, state(), lowPowerMode: true) == minutes(60))
        #expect(due(feed, state(failures: 4), lowPowerMode: true) == minutes(720))
        #expect(due(feed, state(feedInterval: 86_400), lowPowerMode: true) == 2 * 86_400)
    }
}

@Suite struct LiveFolderSourceTests {
    @Test func feedAddressesBecomeHTTPSAndRefuseCredentialsAndOtherSchemes() throws {
        let plain = try LiveFolderSource.makeFeed(address: URL(string: "http://blog.example.org/feed.xml#top")!)
        #expect(plain.source == .feed(address: URL(string: "https://blog.example.org/feed.xml")!, isPrivate: false))
        #expect(plain.keychainAddress == nil)
        #expect(throws: LiveFolderError.self) { try LiveFolderSource.makeFeed(address: URL(string: "ftp://blog.example.org/feed.xml")!) }
        #expect(throws: LiveFolderError.self) { try LiveFolderSource.makeFeed(address: URL(string: "https://me:secret@blog.example.org/feed.xml")!) }
        #expect(throws: LiveFolderError.self) { try LiveFolderSource.makeFeed(address: URL(string: "file:///feed.xml")!) }
    }

    @Test func anAddressWithAQueryGoesToTheKeychain() throws {
        let made = try LiveFolderSource.makeFeed(address: URL(string: "https://tracker.example.org/feed.atom?token=abc123&scope=all#latest")!)
        #expect(made.source == .feed(address: URL(string: "https://tracker.example.org/feed.atom")!, isPrivate: true))
        #expect(made.keychainAddress == URL(string: "https://tracker.example.org/feed.atom?token=abc123&scope=all"))
        let encoded = String(decoding: try JSONEncoder().encode(LiveFolderConfiguration(source: made.source)), as: UTF8.self)
        #expect(!encoded.contains("abc123"))
    }

    @Test func gitHubSearchesAndNames() {
        #expect(GitHubSearch(kind: .myPullRequests).query == "is:pr is:open author:@me archived:false sort:updated-desc")
        #expect(GitHubSearch(kind: .reviewRequests).query == "is:pr is:open user-review-requested:@me archived:false sort:updated-desc")
        #expect(GitHubSearch(kind: .assignedIssues).query == "is:issue is:open assignee:@me archived:false sort:updated-desc")
        #expect(GitHubSearch(kind: .search, text: " label:bug ").query == "label:bug sort:updated-desc")
        #expect(GitHubSearch(kind: .search, text: "label:bug sort:created-asc").query == "label:bug sort:created-asc")
        #expect(GitHubSearch.Kind.allCases.map { GitHubSearch(kind: $0).defaultName } == ["Pull Requests", "Review Requests", "Issues", "GitHub Search"])
    }

    @Test func configurationsKeepAllowedValues() throws {
        let configuration = LiveFolderConfiguration(source: gitHub.source, itemLimit: 40, refreshMinutes: 100)
        #expect(configuration.itemLimit == 50)
        #expect(configuration.refreshMinutes == 60)
        let edited = Data(#"{"source":{"gitHub":{"search":{"host":"github.com","kind":"search","text":"is:open"}}},"itemLimit":3,"refreshMinutes":1000}"#.utf8)
        let decoded = try JSONDecoder().decode(LiveFolderConfiguration.self, from: edited)
        #expect(decoded == LiveFolderConfiguration(source: .gitHub(search: GitHubSearch(kind: .search, text: "is:open")), itemLimit: 10, refreshMinutes: 180))
        let roundTrip = try JSONDecoder().decode(LiveFolderConfiguration.self, from: JSONEncoder().encode(feed))
        #expect(roundTrip == feed)
    }
}
