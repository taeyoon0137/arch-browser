// An in-app session's site scope (docs/agents.md, Site scope and navigation; rule P13): what joins the scope, sites as registrable domains, followed links against written addresses, written addresses on a site in scope whose path, query, or fragment no page showed, seen addresses after normalizing, the search engine's results address and its other addresses, bare origins, and redirect hops of written and followed navigations.
import Foundation
import Testing
@testable import Agent

@Suite struct SiteScopeTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    private let search = AgentSearchResultsAddress(base: URL(string: "https://www.google.com/search")!)

    @Test func sitesAreRegistrableDomains() {
        #expect(AgentSite.of(url("https://shop.example.co.uk/cart")) == "example.co.uk")
        #expect(AgentSite.of(url("https://a.b.example.com/")) == "example.com")
        #expect(AgentSite.of(url("https://someone.github.io/page")) == "someone.github.io")
        #expect(AgentSite.of(url("http://127.0.0.1:8080/")) == "127.0.0.1")
        #expect(AgentSite.of(url("http://localhost:3000/")) == "localhost")
        #expect(AgentSite.of(url("HTTPS://WWW.Example.ORG")) == "example.org")
        #expect(AgentSite.of(url("file:///Users/someone/a.html")) == nil)
        #expect(AgentSite.of(url("mailto:someone@example.org")) == nil)
    }

    @Test func theScopeGrowsFromTabsTheUsersWordsAndApprovals() {
        var scope = AgentSiteScope(searchResults: search)
        scope.add(url("https://docs.example.com/guide"))
        scope.addAddresses(inUserText: "Compare example.org/plans with https://www.other.example.net/a?b=1 and mail someone@person.example")
        #expect(scope.sites == ["example.com", "example.org", "example.net"])
        // The addresses the user wrote are seen as the link detector reads them, so they open even with their paths and queries.
        #expect(scope.written(url("https://www.other.example.net/a?b=1")) == .opens)
        #expect(scope.written(url("https://example.org/plans")) == .opens)
        // An address the user allowed joins with its site.
        scope.add(url("https://approved.example/one?x=2"))
        #expect(scope.contains(url("https://approved.example/")))
        #expect(scope.written(url("https://approved.example/one?x=2")) == .opens)
        // The search engine's site is not in scope.
        #expect(!scope.contains(url("https://www.google.com/")))
    }

    @Test func followedLinksOpenAndWrittenCopiesOfThemOnlyAsSeen() {
        var scope = AgentSiteScope()
        scope.add(url("https://news.example/today"))
        // The full address behind a link ref in a snapshot.
        let link = url("https://elsewhere.example/story/42?ref=front")
        scope.see(link)
        #expect(scope.followed(link) == .opens)
        #expect(scope.followed(url("https://tracker.example/?d=secret")) == .opens)
        // Written, the same address opens because the page showed it; with another query it asks, naming only the part no page showed.
        #expect(scope.written(link) == .opens)
        #expect(scope.written(url("https://elsewhere.example/story/42?ref=secret")) == .asks(AgentAddressQuestion(url: url("https://elsewhere.example/story/42?ref=secret"), unseenParts: [.query], isOutsideScope: true)))
        // Following a link adds nothing to the scope.
        #expect(!scope.contains(link))
    }

    @Test func writtenAddressesOnASiteInScopeAskForWhatNoPageShowed() {
        var scope = AgentSiteScope(searchResults: search)
        scope.add(url("https://shop.example/cart"))
        #expect(scope.written(url("https://shop.example/")) == .opens)
        #expect(scope.written(url("https://www.shop.example")) == .opens)
        let path = url("https://shop.example/t")
        #expect(scope.written(path) == .asks(AgentAddressQuestion(url: path, unseenParts: [.path], isOutsideScope: false)))
        let query = url("https://shop.example/cart?d=inbox")
        #expect(scope.written(query) == .asks(AgentAddressQuestion(url: query, unseenParts: [.query], isOutsideScope: false)))
        let fragment = url("https://shop.example/cart#d=inbox")
        #expect(scope.written(fragment) == .asks(AgentAddressQuestion(url: fragment, unseenParts: [.fragment], isOutsideScope: false)))
        let both = url("https://shop.example/t?d=inbox")
        #expect(scope.written(both) == .asks(AgentAddressQuestion(url: both, unseenParts: [.path, .query], isOutsideScope: false)))
        // A bare origin with a query is not bare; one outside the scope asks for its site alone.
        #expect(scope.written(url("https://shop.example/?d=inbox")) == .asks(AgentAddressQuestion(url: url("https://shop.example/?d=inbox"), unseenParts: [.query], isOutsideScope: false)))
        #expect(scope.written(url("https://other.example/")) == .asks(AgentAddressQuestion(url: url("https://other.example/"), unseenParts: [], isOutsideScope: true)))
        // Seen addresses compare after normalizing the scheme, host case, default port, and an empty path.
        #expect(scope.written(url("HTTPS://Shop.Example:443/cart")) == .opens)
        #expect(scope.written(url("https://shop.example:8443/")) == .asks(AgentAddressQuestion(url: url("https://shop.example:8443/"), unseenParts: [], isOutsideScope: false)))
        #expect(scope.written(url("https://user:pass@shop.example/")) != .opens)
        // The cards' sentences.
        #expect(AgentAddressQuestion(url: both, unseenParts: [.path, .query], isOutsideScope: true).sentence == "The agent wants to open https://shop.example/t?d=inbox \u{2014} an address no page showed, on a site you did not name.")
        #expect(AgentAddressQuestion(url: url("https://other.example/"), unseenParts: [], isOutsideScope: true).sentence == "The agent wants to open https://other.example/ \u{2014} a site you did not name.")
    }

    @Test func theSearchEnginesResultsAddressOpensAndItsOtherAddressesAsk() {
        let scope = AgentSiteScope(searchResults: search)
        #expect(scope.written(url("https://www.google.com/search?q=arch+agents")) == .opens)
        #expect(scope.written(url("https://www.google.com/search?q=")) == .opens)
        #expect(scope.written(url("https://www.google.com/search?q=a&d=inbox")) != .opens)
        #expect(scope.written(url("https://www.google.com/search?q=a#d=inbox")) != .opens)
        #expect(scope.written(url("https://www.google.com/url?q=https://leak.example/?d=inbox")) != .opens)
        #expect(scope.written(url("https://www.google.com/")) != .opens)
        #expect(AgentSiteScope().written(url("https://www.google.com/search?q=a")) != .opens)
    }

    @Test func redirectHopsOfWrittenAddressesAskWhenTheyLeaveTheScope() {
        var scope = AgentSiteScope(searchResults: search)
        scope.add(url("http://127.0.0.1:8000/start"))
        let away = url("http://localhost:8000/landing?from=302")
        #expect(scope.hop(to: away, ofWrittenAddress: true) == .asks(AgentAddressQuestion(url: away, unseenParts: [.path, .query], isOutsideScope: true)))
        #expect(scope.hop(to: url("http://127.0.0.1:8000/next"), ofWrittenAddress: true) == .opens)
        #expect(scope.hop(to: url("https://www.google.com/search?q=a"), ofWrittenAddress: true) == .opens)
        // A followed link's hops go on wherever they lead; the read checks and site exclusions still apply to them.
        #expect(scope.hop(to: away, ofWrittenAddress: false) == .opens)
    }
}
