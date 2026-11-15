// Who a tab's prompt comes from: the tab's own site with its icon, another site with a globe and where it is, a file page by its file, a page without a host, an extension's page by the extension, the lock for https, also for a login, and a proxy with its tag and without the lock; and the frame of a page dialog when it is not the page's.
import AppKit
import Foundation
import Testing
@testable import Browsing

@Suite struct PromptSiteIdentityTests {
    private static let tabURL = URL(string: "https://example.com/page")!

    @Test func theTabsOwnSiteKeepsTheTabsIcon() {
        let favicon = NSImage(size: NSSize(width: 16, height: 16))
        let identity = PromptSiteIdentity.make(for: URL(string: "https://example.com/frame"), tabURL: Self.tabURL, favicon: favicon)
        #expect(identity == PromptIdentity(icon: .image(favicon), name: "example.com", isSecure: true))
        #expect(PromptSiteIdentity.make(for: Self.tabURL, tabURL: Self.tabURL, favicon: nil).icon == .symbol("globe"))
    }

    @Test func anotherSiteSaysWhereItIs() {
        let identity = PromptSiteIdentity.make(for: URL(string: "http://ads.example.net/frame"), tabURL: Self.tabURL, favicon: NSImage())
        #expect(identity == PromptIdentity(icon: .symbol("globe"), name: "ads.example.net", isSecure: false, context: "in example.com"))
    }

    /// A dialog's frame on another host than the page's is named, and one whose origin the engine does not name is embedded without a name while the page has a host; the page's own frame, in any case, is neither.
    @Test func aDialogsFrameOnAnotherHostIsNamed() {
        #expect(PromptSiteIdentity.embeddedFrame(of: URL(string: "https://widget.example"), pageURL: Self.tabURL) == .host("widget.example"))
        #expect(PromptSiteIdentity.embeddedFrame(of: URL(string: "https://mail.example.com"), pageURL: Self.tabURL) == .host("mail.example.com"))
        #expect(PromptSiteIdentity.embeddedFrame(of: URL(string: "http://Example.COM:8080"), pageURL: Self.tabURL) == nil)
        #expect(PromptSiteIdentity.embeddedFrame(of: nil, pageURL: Self.tabURL) == .unnamed)
        #expect(PromptSiteIdentity.embeddedFrame(of: URL(string: "https://widget.example"), pageURL: URL(fileURLWithPath: "/tmp/page.html")) == .host("widget.example"))
        #expect(PromptSiteIdentity.embeddedFrame(of: nil, pageURL: URL(fileURLWithPath: "/tmp/page.html")) == nil)
        #expect(PromptSiteIdentity.embeddedFrame(of: nil, pageURL: nil) == nil)
    }

    @Test func aFilePageIsItsFileAndAnotherPageWithoutAHostIsThisPage() {
        let file = URL(fileURLWithPath: "/tmp/page.html")
        let identity = PromptSiteIdentity.make(for: file, tabURL: nil, favicon: nil)
        #expect(identity == PromptIdentity(icon: .symbol("doc"), name: "page.html", isSecure: false))
        // Chromium asks for a file page's permission from the origin `file:///`, which the tab's file names.
        #expect(PromptSiteIdentity.make(for: URL(string: "file:///"), tabURL: file, favicon: nil).name == "page.html")
        #expect(PromptSiteIdentity.make(for: URL(string: "about:blank"), tabURL: nil, favicon: nil).name == "This page")
        #expect(PromptSiteIdentity.make(for: nil, tabURL: Self.tabURL, favicon: nil).name == "This page")
    }

    /// An extension's page is the extension's name with its symbol and tag, never the tab's icon or the lock, and a frame of another site in it is "in" that name.
    @Test func anExtensionsPageIsTheExtension() {
        let page = URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html")!
        let name = { (url: URL) in url.scheme == "chrome-extension" ? "Reader" : nil }
        #expect(PromptSiteIdentity.make(for: page, tabURL: page, favicon: NSImage(), extensionName: name)
            == PromptIdentity(icon: .symbol("puzzlepiece.extension"), name: "Reader", isSecure: false, tag: "Extension"))
        #expect(PromptSiteIdentity.make(for: page, tabURL: Self.tabURL, favicon: nil, extensionName: name).context == "in example.com")
        #expect(PromptSiteIdentity.make(for: URL(string: "https://maps.example/embed"), tabURL: page, favicon: nil, extensionName: name)
            == PromptIdentity(icon: .symbol("globe"), name: "maps.example", isSecure: true, context: "in Reader"))
        // Without a name, as for an extension that is not installed, the identifier shows.
        #expect(PromptSiteIdentity.make(for: page, tabURL: page, favicon: nil).name == "abcdefghijklmnopabcdefghijklmnop")
    }

    @Test func aLoginShowsTheLockOnlyForASiteOverHTTPS() {
        let plain = URLProtectionSpace(host: "example.com", port: 80, protocol: "http", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let site = PromptSiteIdentity.signIn(plain, tabURL: Self.tabURL, favicon: nil)
        #expect(site.name == "example.com" && !site.isSecure && site.tag == nil && site.context == nil)
        let secure = URLProtectionSpace(host: "example.com", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(PromptSiteIdentity.signIn(secure, tabURL: Self.tabURL, favicon: nil).isSecure)
        // Digest keeps the password from the wire but encrypts nothing else, so plain http gets no lock.
        let digest = URLProtectionSpace(host: "intranet.local", port: 80, protocol: "http", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPDigest)
        #expect(digest.receivesCredentialSecurely)
        #expect(!PromptSiteIdentity.signIn(digest, tabURL: Self.tabURL, favicon: nil).isSecure)

        let proxy = URLProtectionSpace(proxyHost: "proxy.example", port: 8080, type: NSURLProtectionSpaceHTTPProxy, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(PromptSiteIdentity.signIn(proxy, tabURL: Self.tabURL, favicon: nil) == PromptIdentity(icon: .symbol("network"), name: "proxy.example", isSecure: false, tag: "Proxy"))
        // The space does not say whether the connection to a proxy is encrypted.
        let digestProxy = URLProtectionSpace(proxyHost: "proxy.example", port: 8080, type: NSURLProtectionSpaceHTTPSProxy, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPDigest)
        #expect(!PromptSiteIdentity.signIn(digestProxy, tabURL: Self.tabURL, favicon: nil).isSecure)
    }
}
