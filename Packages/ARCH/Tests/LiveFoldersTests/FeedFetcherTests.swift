// Fetching feeds through a URL protocol stub, so no request leaves the process (docs/bookmarks.md, Tests ▸ LiveFoldersTests).
import Foundation
import Testing
@testable import LiveFolders

private let rss = Data("""
<rss version="2.0"><channel><title>Stub</title>
<item><title>One</title><link>https://blog.example.org/1</link></item>
</channel></rss>
""".utf8)

@Suite(.timeLimit(.minutes(1))) struct FeedFetcherTests {
    private let fetcher = FeedStubProtocol.fetcher()

    @Test func sendsAndStoresValidatorsAndKeepsItemsOn304() async throws {
        let host = FeedStubProtocol.host { request in
            guard request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" else {
                return .init(headers: ["Content-Type": "application/rss+xml", "ETag": "\"v1\"", "Last-Modified": "Mon, 02 Nov 2026 10:00:00 GMT"], body: rss)
            }
            return .init(status: 304, headers: [:])
        }
        let address = URL(string: "https://\(host)/feed.xml")!
        guard case .fetched(let feed, let validators) = try await fetcher.fetch(address) else {
            Issue.record("Expected a feed")
            return
        }
        #expect(feed.title == "Stub")
        #expect(feed.items.map(\.title) == ["One"])
        #expect(validators == FeedValidators(entityTag: "\"v1\"", lastModified: "Mon, 02 Nov 2026 10:00:00 GMT"))
        #expect(try await fetcher.fetch(address, validators: validators) == .notModified)
        let requests = FeedStubProtocol.requests(to: host)
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[0].value(forHTTPHeaderField: "Accept")?.hasPrefix("application/rss+xml") == true)
        #expect(requests[1].value(forHTTPHeaderField: "If-Modified-Since") == "Mon, 02 Nov 2026 10:00:00 GMT")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    @Test func triesHTTPAddressesAsHTTPS() async throws {
        let host = FeedStubProtocol.host { _ in .init(body: rss) }
        _ = try await fetcher.fetch(URL(string: "http://\(host)/feed.xml?token=secret")!)
        #expect(FeedStubProtocol.requests(to: host).map(\.url?.absoluteString) == ["https://\(host)/feed.xml?token=secret"])
    }

    @Test func refusesAddressesThatAreNotFeedAddresses() async {
        await #expect(throws: LiveFolderError.self) { try await fetcher.fetch(URL(string: "ftp://files.example.test/feed.xml")!) }
        await #expect(throws: LiveFolderError.self) { try await fetcher.fetch(URL(string: "https://user:password@blog.example.test/feed.xml")!) }
    }

    @Test func stopsAtFiveMegabytes() async {
        let host = FeedStubProtocol.host { _ in .init(body: Data(count: FeedFetcher.sizeLimit + 1)) }
        await #expect(throws: LiveFolderError.tooLarge(bytes: FeedFetcher.sizeLimit)) { try await fetcher.fetch(URL(string: "https://\(host)/big.xml")!) }
    }

    @Test func readsRetryAfterInSecondsAndAsADate() async throws {
        let seconds = FeedStubProtocol.host { _ in .init(status: 429, headers: ["Retry-After": "120"]) }
        let before = Date()
        guard case .httpStatus(429, let delayed?) = await error(fetching: "https://\(seconds)/feed.xml") else {
            Issue.record("Expected 429 with a retry date")
            return
        }
        #expect(delayed.timeIntervalSince(before) >= 119 && delayed.timeIntervalSince(before) < 130)

        let date = FeedStubProtocol.host { _ in .init(status: 503, headers: ["Retry-After": "Wed, 11 Nov 2026 07:28:00 GMT"]) }
        guard case .httpStatus(503, let retry?) = await error(fetching: "https://\(date)/feed.xml") else {
            Issue.record("Expected 503 with a retry date")
            return
        }
        #expect(retry == (try Date.ISO8601FormatStyle().parse("2026-11-11T07:28:00Z")))
        #expect(FeedFetcher.retryDate("soon") == nil)
    }

    @Test func otherStatusesAreErrorsThatNameThem() async {
        let host = FeedStubProtocol.host { _ in .init(status: 404, headers: ["Retry-After": "60"]) }
        let failure = await error(fetching: "https://\(host)/missing.xml")
        #expect(failure == .httpStatus(404, retryAfter: nil))
        #expect(failure?.message.contains("404") == true)
    }

    @Test func anOfflineMacIsReportedAsOffline() async {
        let host = FeedStubProtocol.host { _ in .init(failure: .notConnectedToInternet) }
        let failure = await error(fetching: "https://\(host)/feed.xml")
        #expect(failure == .offline)
        #expect(failure?.isOffline == true)
    }

    @Test func discoversAFeedOrThePageLinks() async throws {
        let feedHost = FeedStubProtocol.host { _ in .init(body: rss) }
        guard case .feed(let feed) = try await fetcher.discover(URL(string: "https://\(feedHost)/feed.xml")!) else {
            Issue.record("Expected a feed")
            return
        }
        #expect(feed.title == "Stub")
        let page = Data("<html><head><link rel=\"alternate\" type=\"application/atom+xml\" href=\"/atom\"></head><body><p>Hi<br></body></html>".utf8)
        let pageHost = FeedStubProtocol.host { _ in .init(headers: ["Content-Type": "text/html"], body: page) }
        #expect(try await fetcher.discover(URL(string: "https://\(pageHost)/post")!) == .links([FeedLink(url: URL(string: "https://\(pageHost)/atom")!, title: nil)]))
    }

    private func error(fetching address: String) async -> LiveFolderError? {
        do {
            _ = try await fetcher.fetch(URL(string: address)!)
            return nil
        } catch {
            return error as? LiveFolderError
        }
    }
}
