// Who a tab's prompt comes from: the tab's own site with its icon, another site with a globe and where it is, a page without a host, the lock for https, also for a login, and a proxy with its tag and without the lock; and the host of a page dialog's frame when it is not the page's.
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

    /// A dialog's frame on another host than the page's is named; the page's own frame, in any case, and a frame whose origin the engine does not name are not.
    @Test func aDialogsFrameOnAnotherHostIsNamed() {
        #expect(PromptSiteIdentity.embeddedHost(of: URL(string: "https://widget.example"), tabURL: Self.tabURL) == "widget.example")
        #expect(PromptSiteIdentity.embeddedHost(of: URL(string: "https://mail.example.com"), tabURL: Self.tabURL) == "mail.example.com")
        #expect(PromptSiteIdentity.embeddedHost(of: URL(string: "http://Example.COM:8080"), tabURL: Self.tabURL) == nil)
        #expect(PromptSiteIdentity.embeddedHost(of: nil, tabURL: Self.tabURL) == nil)
        #expect(PromptSiteIdentity.embeddedHost(of: URL(string: "https://widget.example"), tabURL: URL(fileURLWithPath: "/tmp/page.html")) == "widget.example")
    }

    @Test func aPageWithoutAHostIsThisPage() {
        let identity = PromptSiteIdentity.make(for: URL(fileURLWithPath: "/tmp/page.html"), tabURL: nil, favicon: nil)
        #expect(identity == PromptIdentity(icon: .symbol("doc"), name: "This page", isSecure: false))
        #expect(PromptSiteIdentity.make(for: nil, tabURL: Self.tabURL, favicon: nil).name == "This page")
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
