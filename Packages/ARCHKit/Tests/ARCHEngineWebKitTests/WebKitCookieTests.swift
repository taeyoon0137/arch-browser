// How a cookie's SameSite policy and its other contents pass through a WebKit profile's cookie store, which the session copies cookies into and out of for the other engine. The tests use a private profile, which keeps nothing on disk.
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing

@MainActor @Suite struct WebKitCookieTests {
    private let browser: any EngineBrowser
    private let browserDelegate = NoBrowserDelegate()

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        let application = try WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder))
        var created: (any EngineBrowserContext)?
        application.createBrowserContext(EngineBrowserContextAttributes(id: EngineBrowserContextID(rawValue: "cookies"), userVisibleName: "Cookies", type: .incognito)) { created = try? $0.get() }
        browser = application.createBrowser(EngineBrowserCreateParams(initialBounds: .zero), context: try #require(created), delegate: browserDelegate, window: nil)
    }

    /// WebKit keeps a lax or strict policy, and sends a cookie without one, also one that names none, with requests from other sites.
    @Test func aCookieKeepsItsSameSitePolicyInTheStore() async {
        let policies: [String: EngineCookieSameSite] = ["lax": .lax, "strict": .strict, "none": .noRestriction, "unnamed": .unspecified]
        let cookies = policies.map { name, policy in
            EngineCookie(name: name, value: "1", domain: "example.com", isSecure: true, sameSite: policy)
        }
        await withCheckedContinuation { continuation in browser.setCookies(cookies) { continuation.resume() } }
        let stored = await withCheckedContinuation { continuation in browser.allCookies { continuation.resume(returning: $0) } }
        let storedPolicies = Dictionary(stored.map { ($0.name, $0.sameSite) }, uniquingKeysWith: { first, _ in first })
        #expect(storedPolicies == ["lax": .lax, "strict": .strict, "none": .noRestriction, "unnamed": .noRestriction])
    }

    /// A cookie that Chromium holds without a policy reads back from WebKit as `SameSite=None` but with the same contents otherwise, so the session's copy back to Chromium leaves Chromium's cookie and its policy as they were.
    @Test func aCookieReadsBackWithTheSameContents() async throws {
        let hostOnly = EngineCookie(name: "sid", value: "a1", domain: "example.com", path: "/account", expires: Date(timeIntervalSinceNow: 86_400.375),
                                    isSecure: true, isHTTPOnly: true)
        let domainWide = EngineCookie(name: "pref", value: "b2", domain: ".example.com", isSecure: true)
        await withCheckedContinuation { continuation in browser.setCookies([hostOnly, domainWide]) { continuation.resume() } }
        let stored = await withCheckedContinuation { continuation in browser.allCookies { continuation.resume(returning: $0) } }
        for cookie in [hostOnly, domainWide] {
            let readBack = try #require(stored.first { $0.name == cookie.name })
            #expect(readBack.sameSite == .noRestriction)
            #expect(readBack.hasSameContents(as: cookie))
        }
    }

    private final class NoBrowserDelegate: EngineBrowserDelegate {}
}
