// When a tab's icon outlives a change of its page's address: within one host, including the same-document navigations a single-page app makes, and never onto another host or a page without one. Icons load without any profile's cookies or stored credentials.
@testable import ARCHEngine
import Foundation
import Testing

@Suite struct FaviconLoaderTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func pagesOfOneHostKeepTheIcon() {
        // `history.pushState`, a fragment, another document, and the secure scheme stay on the host.
        #expect(FaviconLoader.keepsIcon(from: url("https://example.com/"), to: url("https://example.com/repo/issues")))
        #expect(FaviconLoader.keepsIcon(from: url("https://example.com/page"), to: url("https://example.com/page#section")))
        #expect(FaviconLoader.keepsIcon(from: url("http://example.com/"), to: url("https://example.com/sign-in?next=%2F")))
        #expect(FaviconLoader.keepsIcon(from: url("https://Example.com/"), to: url("https://example.com/")))
    }

    @Test func anotherHostOrAPageWithoutOneDropsTheIcon() {
        #expect(!FaviconLoader.keepsIcon(from: url("https://example.com/"), to: url("https://example.org/")))
        #expect(!FaviconLoader.keepsIcon(from: url("https://example.com/"), to: url("https://www.example.com/")))
        #expect(!FaviconLoader.keepsIcon(from: url("https://example.com/"), to: url("about:blank")))
        #expect(!FaviconLoader.keepsIcon(from: url("file:///tmp/a.html"), to: url("file:///tmp/b.html")))
        #expect(!FaviconLoader.keepsIcon(from: nil, to: url("https://example.com/")))
        #expect(!FaviconLoader.keepsIcon(from: url("https://example.com/"), to: nil))
    }

    @Test func iconsLoadWithoutCookiesOrCredentials() {
        let configuration = FaviconLoader.session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCredentialStorage == nil)
    }
}
