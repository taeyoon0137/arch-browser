// When a tab's icon outlives a change of its page's address: within one host, including the same-document navigations a single-page app makes, and never onto another host or a page without one. Icons load without any profile's cookies or stored credentials, only from web and data URLs, and only up to a size and a time limit; other images that a page names load the same way up to a limit of their own.
import AppKit
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

    @Test func iconsLoadWithoutCookiesOrCredentialsWithinThirtySeconds() {
        let configuration = FaviconLoader.session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForResource == 30)
    }

    @MainActor @Test func iconsOfOtherSchemesLoadNothing() {
        for string in ["file:///etc/hosts", "FILE:///dev/zero", "ftp://example.com/favicon.ico", "about:blank"] {
            var answers: [NSImage?] = []
            FaviconLoader.load(url(string)) { answers.append($0) }
            #expect(answers == [nil], "\(string)")
        }
    }

    @Test func aBodyPastTheLimitLoadsNothing() async {
        let limit = FaviconLoader.maximumSize
        let body = { (count: Int) in self.url("data:application/octet-stream;base64," + Data(repeating: 7, count: count).base64EncodedString()) }
        #expect(await FaviconLoader.download(body(limit))?.count == limit)
        #expect(await FaviconLoader.download(body(limit + 1)) == nil)
        // An endless body without a stated length stops at the limit.
        #expect(await FaviconLoader.download(URL(fileURLWithPath: "/dev/zero")) == nil)
        // Another image, such as Now Playing's artwork, sets a limit of its own.
        #expect(await FaviconLoader.download(body(limit + 1), limit: limit + 1)?.count == limit + 1)
        #expect(await FaviconLoader.download(body(11), limit: 10) == nil)
        #expect(await FaviconLoader.download(URL(fileURLWithPath: "/dev/zero"), limit: 4 * limit) == nil)
    }
}
