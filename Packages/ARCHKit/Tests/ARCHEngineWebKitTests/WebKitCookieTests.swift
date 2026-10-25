// How a cookie's SameSite policy passes through a WebKit profile's cookie store, which the session copies cookies into and out of for the other engine. The tests use a private profile, which keeps nothing on disk.
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

    private final class NoBrowserDelegate: EngineBrowserDelegate {}
}
