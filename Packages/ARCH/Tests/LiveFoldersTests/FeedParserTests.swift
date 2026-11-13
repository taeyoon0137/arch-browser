// Parsing synthetic RSS 2.0, RSS 1.0, and Atom files, and finding feeds in HTML pages (docs/bookmarks.md, Tests ▸ LiveFoldersTests).
import Foundation
import Testing
@testable import LiveFolders

private let feedAddress = URL(string: "https://blog.example.org/feed.xml")!

private func parse(_ text: String, address: URL = feedAddress) throws -> Feed {
    try FeedParser.parse(Data(text.utf8), address: address)
}

private func utc(_ text: String) -> Date {
    try! Date.ISO8601FormatStyle().parse(text)
}

/// Whether two dates agree to the millisecond, since fractions of a second pass through floating point.
private func same(_ date: Date?, _ expected: Date) -> Bool {
    date.map { abs($0.timeIntervalSince(expected)) < 0.001 } ?? false
}

/// The error that parsing `text` throws.
private func parseError(_ text: String) -> LiveFolderError? {
    do {
        _ = try parse(text)
        return nil
    } catch {
        return error as? LiveFolderError
    }
}

@Suite struct FeedParserTests {
    @Test func readsRSS2() throws {
        let feed = try parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom">
          <channel>
            <title>Example &amp; Blog</title>
            <atom:link href="https://blog.example.org/other" rel="self"/>
            <ttl>90</ttl>
            <item>
              <title>First &lt;b&gt;post&lt;/b&gt; &amp;amp; more</title>
              <link>https://blog.example.org/first</link>
              <guid isPermaLink="false">post-1</guid>
              <pubDate>Mon, 02 Nov 2026 15:04:05 -0700</pubDate>
            </item>
            <item>
              <title><![CDATA[Second <i>post</i> &#233;&#x2014;&hellip;]]></title>
              <guid>https://blog.example.org/second</guid>
              <pubDate>3 Nov 2026 08:00 GMT</pubDate>
            </item>
            <item>
              <title>Third</title>
              <link>/third</link>
              <dc:date>2026-11-01T10:00:00.250+09:00</dc:date>
            </item>
          </channel>
        </rss>
        """)
        #expect(feed.title == "Example & Blog")
        #expect(feed.interval == TimeInterval(90 * 60))
        // Newest first, since every item has a date.
        #expect(feed.items.map(\.id) == ["https://blog.example.org/second", "post-1", "https://blog.example.org/third"])
        let first = try #require(feed.items.first { $0.id == "post-1" })
        #expect(first.url.absoluteString == "https://blog.example.org/first")
        #expect(first.title == "First post & more")
        #expect(first.date == utc("2026-11-02T22:04:05Z"))
        let second = feed.items[0]
        #expect(second.url.absoluteString == "https://blog.example.org/second")
        #expect(second.title == "Second post é—…")
        #expect(second.date == utc("2026-11-03T08:00:00Z"))
        #expect(feed.items[2].url.absoluteString == "https://blog.example.org/third")
        #expect(same(feed.items[2].date, utc("2026-11-01T01:00:00Z").addingTimeInterval(0.25)))
    }

    @Test func readsRSS1WithTheSyndicationInterval() throws {
        let feed = try parse("""
        <?xml version="1.0"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/"
                 xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:sy="http://purl.org/rss/1.0/modules/syndication/">
          <channel rdf:about="https://news.example.org/">
            <title>News</title>
            <sy:updatePeriod>hourly</sy:updatePeriod>
            <sy:updateFrequency>2</sy:updateFrequency>
          </channel>
          <item rdf:about="https://news.example.org/a">
            <title>A</title>
            <link>https://news.example.org/a</link>
            <dc:date>2026-11-01T10:00:00Z</dc:date>
          </item>
          <item rdf:about="urn:news:b">
            <title>B</title>
            <link>https://news.example.org/b</link>
          </item>
        </rdf:RDF>
        """)
        #expect(feed.title == "News")
        #expect(feed.interval == 1_800)
        // B has no date, so document order stays.
        #expect(feed.items.map(\.id) == ["https://news.example.org/a", "urn:news:b"])
        #expect(feed.items[0].date == utc("2026-11-01T10:00:00Z"))
        #expect(feed.items[1].url.absoluteString == "https://news.example.org/b")
    }

    @Test func readsAtomWithBaseAddressesAndTextTypes() throws {
        let feed = try parse("""
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://site.example.org/blog/">
          <title type="text">Site &lt;Blog&gt;</title>
          <entry>
            <id>tag:site.example.org,2026:1</id>
            <title type="html">&lt;em&gt;Hello&lt;/em&gt; &amp;amp; welcome</title>
            <link rel="edit" href="https://site.example.org/edit/1"/>
            <link href="posts/1"/>
            <updated>2026-11-02T10:00:00Z</updated>
            <published>2026-10-01T10:00:00Z</published>
          </entry>
          <entry xml:base="/archive/">
            <title type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">Rich <b>title</b></div></title>
            <link rel="alternate" type="text/html" href="2"/>
            <published>2026-11-03T10:00:00Z</published>
          </entry>
          <entry>
            <id>tag:site.example.org,2026:3</id>
            <title>Plain a &lt; b</title>
            <link rel="alternate" href="mailto:someone@example.org"/>
          </entry>
        </feed>
        """)
        #expect(feed.title == "Site <Blog>")
        #expect(feed.interval == nil)
        // The third entry has no web address.
        #expect(feed.items.count == 2)
        let first = try #require(feed.items.first { $0.id == "tag:site.example.org,2026:1" })
        #expect(first.url.absoluteString == "https://site.example.org/blog/posts/1")
        #expect(first.title == "Hello & welcome")
        #expect(first.date == utc("2026-11-02T10:00:00Z"))
        let second = feed.items[0]
        #expect(second.id == "https://site.example.org/archive/2")
        #expect(second.title == "Rich title")
        #expect(second.date == utc("2026-11-03T10:00:00Z"))
    }

    @Test func skipsItemsWithoutWebAddressesAndKeepsTitlesShort() throws {
        let long = String(repeating: "word ", count: 100)
        let feed = try parse("""
        <rss version="2.0"><channel>
          <item><title>No link</title><guid isPermaLink="false">x</guid></item>
          <item><title>Other scheme</title><link>ftp://files.example.org/a</link></item>
          <item><title>   </title><link>https://blog.example.org/untitled?id=1</link></item>
          <item><title>\(long)</title><link>https://blog.example.org/long</link></item>
          <item><title>Twice</title><link>https://blog.example.org/long</link></item>
        </channel></rss>
        """)
        // Twice has the same address and so the same ID as the long one.
        #expect(feed.items.map(\.id) == ["https://blog.example.org/untitled?id=1", "https://blog.example.org/long"])
        #expect(feed.items[0].title == "blog.example.org/untitled?id=1")
        #expect(feed.items[1].title.hasPrefix("word word"))
        #expect(feed.items[1].title.count == LiveItem.maximumTitleLength)
    }

    @Test func refusesDocumentsThatAreNotFeeds() {
        #expect(throws: LiveFolderError.notAFeed) { try parse("<html><head><title>Page</title></head><body></body></html>") }
        #expect(throws: LiveFolderError.notAFeed) { try parse("not XML at all") }
        #expect(throws: LiveFolderError.notAFeed) { try parse("<opml version=\"2.0\"><body/></opml>") }
        // A feed that is not well-formed XML, here for an entity XML does not define, is unreadable rather than no feed.
        guard case .unreadableFeed(let message) = parseError("<rss><channel><title>a &nbsp; b</title></channel></rss>") else {
            Issue.record("Expected an unreadable feed")
            return
        }
        #expect(message.contains("nbsp"))
    }

    @Test func readsDatesInTheirForms() {
        #expect(FeedDate.rfc822("Tue, 10 Nov 2026 09:30:00 +0900") == utc("2026-11-10T00:30:00Z"))
        #expect(FeedDate.rfc822("10 Nov 26 09:30 EST") == utc("2026-11-10T14:30:00Z"))
        #expect(FeedDate.rfc822("Tue, 10 Nov 2026 09:30:00 PDT") == utc("2026-11-10T16:30:00Z"))
        #expect(FeedDate.rfc822("Tue, 10 Nov 2026 09:30:00") == utc("2026-11-10T09:30:00Z"))
        #expect(FeedDate.rfc822("10 November 2026 25:00:00 GMT") == nil)
        #expect(FeedDate.rfc822("yesterday") == nil)
        #expect(FeedDate.iso8601("2026-11-10T09:30:00Z") == utc("2026-11-10T09:30:00Z"))
        #expect(same(FeedDate.iso8601("2026-11-10T09:30:00.5-01:00"), utc("2026-11-10T10:30:00Z").addingTimeInterval(0.5)))
        #expect(FeedDate.iso8601("2026-11-10") == utc("2026-11-10T00:00:00Z"))
        #expect(FeedDate.iso8601("soon") == nil)
    }

    @Test func decodesCharacterReferencesAndRemovesTags() {
        #expect(FeedText.plain("a <b>bold</b> &amp; &#169; &#xA9; &unknown; <3 b") == "a bold & © © &unknown; <3 b")
        #expect(FeedText.plain("line<br/>break\n\t  spaced") == "line break spaced")
    }
}

@Suite struct FeedDiscoveryTests {
    private let page = URL(string: "https://www.example.org/blog/post.html")!

    @Test func findsAlternateLinksOfBothTypes() {
        let html = """
        <!doctype html><html><head>
        <link rel="stylesheet" href="/style.css">
        <LINK REL="alternate" TYPE="application/rss+xml" TITLE="Posts &amp; notes" HREF="/feed.xml">
        <link rel='alternate feed' type='application/atom+xml; charset=utf-8' href='atom.xml'>
        <!-- <link rel="alternate" type="application/rss+xml" href="/commented.xml"> -->
        <link rel="alternate" type="text/html" hreflang="fr" href="/fr/">
        <link rel="alternate" type="application/rss+xml" href="/feed.xml">
        <link rel=alternate type=application/rss+xml href=https://feeds.example.net/comments>
        <link rel="alternate" type="application/rss+xml" href="javascript:alert(1)">
        </head><body></body></html>
        """
        let links = FeedDiscovery.links(inHTML: Data(html.utf8), address: page)
        #expect(links == [
            FeedLink(url: URL(string: "https://www.example.org/feed.xml")!, title: "Posts & notes"),
            FeedLink(url: URL(string: "https://www.example.org/blog/atom.xml")!, title: nil),
            FeedLink(url: URL(string: "https://feeds.example.net/comments")!, title: nil),
        ])
    }

    @Test func returnsAtMostTenLinksFromTheStartOfThePage() {
        let tags = (1...12).map { "<link rel=\"alternate\" type=\"application/atom+xml\" href=\"/f\($0).xml\">" }.joined()
        #expect(FeedDiscovery.links(inHTML: Data(tags.utf8), address: page).count == 10)
        let late = String(repeating: " ", count: FeedDiscovery.readLimit) + "<link rel=\"alternate\" type=\"application/rss+xml\" href=\"/late.xml\">"
        #expect(FeedDiscovery.links(inHTML: Data(late.utf8), address: page).isEmpty)
    }
}
