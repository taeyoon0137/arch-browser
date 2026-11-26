import Foundation
import Testing
@testable import Browsing

@Suite struct SiteRuleSetTests {
    private func rule(_ host: String = "example.com", path: String = "", id: UUID = UUID()) -> SiteRule {
        SiteRule(id: id, host: host, pathPrefix: path, spaceID: UUID(), personaID: UUID())
    }

    @Test func hostsIncludeSubdomainsButNotLookalikes() throws {
        let rule = rule()
        for address in ["https://example.com", "http://www.example.com", "https://a.mail.example.com:8443/inbox", "https://EXAMPLE.COM./"] {
            #expect(SiteRuleSet.match(url: try #require(URL(string: address)), rules: [rule]) == rule)
        }
        for address in ["https://notexample.com", "https://example.com.other", "https://elsewhere.example"] {
            #expect(SiteRuleSet.match(url: try #require(URL(string: address)), rules: [rule]) == nil)
        }
    }

    @Test func localhostAndIPAddressesMatchOnlyThemselves() throws {
        for (host, matching, excluded) in [
            ("localhost", "http://LOCALHOST.:3000/a", "http://sub.localhost/a"),
            ("127.0.0.1", "http://127.0.0.1:8080/a", "http://sub.127.0.0.1/a"),
            ("::1", "http://[::1]:8080/a", "http://[::2]/a"),
        ] {
            let rule = rule(host)
            #expect(SiteRuleSet.match(url: try #require(URL(string: matching)), rules: [rule]) == rule)
            #expect(SiteRuleSet.match(url: try #require(URL(string: excluded)), rules: [rule]) == nil)
        }
    }

    @Test func pathPrefixesEndAtSegmentBoundariesAndKeepCase() throws {
        let rule = rule(path: "/work")
        for path in ["/work", "/work/", "/work/inbox", "/work?where=/personal#fragment"] {
            #expect(SiteRuleSet.match(url: try #require(URL(string: "https://example.com" + path)), rules: [rule]) == rule)
        }
        for path in ["/workshop", "/Work", "/?path=/work", "/personal#work", "/work%2Finbox"] {
            #expect(SiteRuleSet.match(url: try #require(URL(string: "https://example.com" + path)), rules: [rule]) == nil)
        }
    }

    @Test func onlyWebSchemesMatch() throws {
        let rule = rule()
        for address in ["file://example.com/work", "ftp://example.com/work", "arch://example.com", "mailto:hello@example.com", "about:blank"] {
            #expect(SiteRuleSet.match(url: try #require(URL(string: address)), rules: [rule]) == nil)
        }
    }

    @Test func aMoreSpecificHostWinsBeforeALongerPath() throws {
        let broad = rule(path: "/work/inbox")
        let specific = rule("mail.example.com")
        let url = try #require(URL(string: "https://mail.example.com/work/inbox/message"))
        #expect(SiteRuleSet.match(url: url, rules: [broad, specific]) == specific)
        #expect(SiteRuleSet.match(url: url, rules: [specific, broad]) == specific)
    }

    @Test func aLongerPathWinsWithinTheSameHost() throws {
        let broad = rule(path: "/work")
        let specific = rule(path: "/work/inbox")
        let url = try #require(URL(string: "https://example.com/work/inbox/message"))
        #expect(SiteRuleSet.match(url: url, rules: [broad, specific]) == specific)
        #expect(SiteRuleSet.match(url: url, rules: [specific, broad]) == specific)
    }

    @Test func concurrentDuplicatesHaveAStableWinner() throws {
        let first = rule(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let second = rule(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
        let url = try #require(URL(string: "https://example.com"))
        #expect(SiteRuleSet.match(url: url, rules: [first, second]) == first)
        #expect(SiteRuleSet.match(url: url, rules: [second, first]) == first)
    }

    @Test func parsingKeepsOnlyTheNormalizedHostAndCaseSensitivePath() throws {
        let site = try SiteRuleSite(parsing: " HTTPS://*.Mail.Example.COM.:443/Work/inbox/?private=1#secret ")
        #expect(site.host == "mail.example.com")
        #expect(site.pathPrefix == "/Work/inbox")
        #expect(try SiteRuleSite(parsing: "example.com/").pathPrefix == "")
        #expect(try SiteRuleSite(parsing: "example.com").pathPrefix == "")
        #expect(try SiteRuleSite(parsing: "[::1]:8080/work").host == "::1")
        #expect(try SiteRuleSite(host: "::1", pathPrefix: "/work/").pathPrefix == "/work")
    }

    @Test func parsingRefusesCredentialsSchemesAndHostWildcards() {
        for text in ["", "https://", "https://person@example.com/work", "https://person:secret@example.com", "https://@example.com", "ftp://example.com", "file:///tmp/page", "ex*ample.com", "*.*.example.com", "not a host"] {
            #expect(throws: SiteRuleStore.Error.invalidSite) { try SiteRuleSite(parsing: text) }
        }
        for (host, path) in [("example.com/work", ""), ("example.com", "work"), ("example.com", "/work?secret=1"), ("example.com", "/work#secret")] {
            #expect(throws: SiteRuleStore.Error.invalidSite) { try SiteRuleSite(host: host, pathPrefix: path) }
        }
    }
}
