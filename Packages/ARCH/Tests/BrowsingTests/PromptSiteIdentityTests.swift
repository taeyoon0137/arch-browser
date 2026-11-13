// Who a tab's prompt comes from: the tab's own site with its icon, another site with a globe and where it is, a page without a host, the lock for https and for a login received securely, and a proxy with its tag.
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

    @Test func aPageWithoutAHostIsThisPage() {
        let identity = PromptSiteIdentity.make(for: URL(fileURLWithPath: "/tmp/page.html"), tabURL: nil, favicon: nil)
        #expect(identity == PromptIdentity(icon: .symbol("doc"), name: "This page", isSecure: false))
        #expect(PromptSiteIdentity.make(for: nil, tabURL: Self.tabURL, favicon: nil).name == "This page")
    }

    @Test func aLoginShowsTheLockOnlyWhenThePasswordGoesSecurely() {
        let plain = URLProtectionSpace(host: "example.com", port: 80, protocol: "http", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let site = PromptSiteIdentity.signIn(plain, tabURL: Self.tabURL, favicon: nil)
        #expect(site.name == "example.com" && !site.isSecure && site.tag == nil && site.context == nil)
        let secure = URLProtectionSpace(host: "example.com", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(PromptSiteIdentity.signIn(secure, tabURL: Self.tabURL, favicon: nil).isSecure)

        let proxy = URLProtectionSpace(proxyHost: "proxy.example", port: 8080, type: NSURLProtectionSpaceHTTPProxy, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(PromptSiteIdentity.signIn(proxy, tabURL: Self.tabURL, favicon: nil) == PromptIdentity(icon: .symbol("network"), name: "proxy.example", isSecure: false, tag: "Proxy"))
    }
}
