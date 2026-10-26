// The Chromium adapter's rules that need no engine: how cookies cross into CEF's store and back, where Chromium keeps a profile's caches, where an extension's grant lets it run, and when a load keeps the copy Chromium runs. Cookie stores and extensions in a profile need the engine and the app.
import ARCHEngine
import CEFBridge
import Foundation
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumAdapterRulesTests {
    // MARK: Cookies

    @Test func aCookieComesBackFromCEFsStoreAsItWent() {
        let cookie = EngineCookie(name: "id", value: "1", domain: ".example.org", path: "/account", expires: Date(timeIntervalSince1970: 2_000_000_000),
                                  isSecure: true, isHTTPOnly: true, sameSite: .noRestriction)
        #expect(ChromiumBrowser.engineCookie(ChromiumBrowser.bridgeCookie(cookie)) == cookie)
        for sameSite in [EngineCookieSameSite.unspecified, .lax, .strict] {
            var other = cookie
            other.sameSite = sameSite
            other.expires = nil
            #expect(ChromiumBrowser.engineCookie(ChromiumBrowser.bridgeCookie(other)) == other)
        }
    }

    @Test func aCookieWithoutALeadingDotGoesToCEFAsHostOnly() {
        #expect(ChromiumBrowser.bridgeCookie(EngineCookie(name: "id", value: "1", domain: "example.org")).domain == "")
        #expect(ChromiumBrowser.bridgeCookie(EngineCookie(name: "id", value: "1", domain: ".example.org")).domain == ".example.org")
    }

    /// Chromium refuses a `SameSite=None` cookie that is not secure, which WebKit gives every cookie without a policy.
    @Test func anInsecureCookieForEverySiteGoesWithoutAPolicy() {
        #expect(ChromiumBrowser.bridgeCookie(EngineCookie(name: "id", value: "1", domain: ".example.org", sameSite: .noRestriction)).sameSite == .unspecified)
        #expect(ChromiumBrowser.bridgeCookie(EngineCookie(name: "id", value: "1", domain: ".example.org", isSecure: true, sameSite: .noRestriction)).sameSite == .noRestriction)
    }

    // MARK: Profiles

    @Test func aProfileUnderApplicationSupportKeepsItsCachesUnderCaches() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = "ArchChromiumAdapterRulesTests-\(UUID().uuidString)"
        let configuration = EngineApplicationConfiguration(userDataDirectory: applicationSupport.appendingPathComponent(name, isDirectory: true),
                                                           cacheDirectory: applicationSupport.appendingPathComponent("\(name)/Cache", isDirectory: true))
        #expect(configuration.chromiumProfileRoots.map(\.path) == [applicationSupport.path + "/\(name)/Cache/Chromium", caches.path + "/\(name)/Cache/Chromium"])
        let elsewhere = EngineApplicationConfiguration(userDataDirectory: URL(fileURLWithPath: "/private/tmp/\(name)", isDirectory: true),
                                                       cacheDirectory: URL(fileURLWithPath: "/private/tmp/\(name)/Cache", isDirectory: true))
        #expect(elsewhere.chromiumProfileRoots.map(\.path) == ["/private/tmp/\(name)/Cache/Chromium"])
    }

    // MARK: Extensions

    /// Runs `body` with a package folder whose manifest is `manifest`, then removes the folder.
    private func withPackage(_ manifest: String, _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchChromiumAdapterRulesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: root.appendingPathComponent("manifest.json"))
        try body(root)
    }

    @Test func anExtensionRunsOnEverySiteItAsksForOnlyWithAGrantOfThemAll() throws {
        try withPackage(#"{"host_permissions": ["https://example.org/*"], "content_scripts": [{"matches": ["https://example.com/*"]}]}"#) { package in
            let access = { (sites: Set<String>) in ChromiumExtensions.siteAccess(for: EngineExtension(id: "a", packageURL: package, permissions: [], sites: sites)) }
            #expect(access(["https://example.org/*", "https://example.com/*"]) == .onAllSites)
            #expect(access(["<all_urls>"]) == .onAllSites)
            #expect(access(["https://example.org/*"]) == .onClick)
            #expect(access([]) == .onClick)
        }
    }

    @Test func aFirstLoadKeepsChromiumsCopyOnlyOfThePackageChromiumReadAtStart() throws {
        try withPackage(#"{"version": "1.0"}"#) { package in
            let startedAt = Date()
            let path = package.path
            let keepsCopy = { (copy: (path: String, version: String)?, installedAt: Date?, loadedInRun: Bool) in
                ChromiumExtensions.keepsCopy(copy, of: EngineExtension(id: "a", packageURL: package, permissions: [], sites: [], installedAt: installedAt), at: path,
                                             loadedInRun: loadedInRun, engineStartedAt: startedAt)
            }
            #expect(keepsCopy((path, "1.0"), startedAt - 60, false))
            // A later load in the run, a package installed after the engine started or at an unknown time, and a copy from another folder or version, or none, load the package again.
            #expect(!keepsCopy((path, "1.0"), startedAt - 60, true))
            #expect(!keepsCopy((path, "1.0"), startedAt + 60, false))
            #expect(!keepsCopy((path, "1.0"), nil, false))
            #expect(!keepsCopy(("/elsewhere", "1.0"), startedAt - 60, false))
            #expect(!keepsCopy((path, "0.9"), startedAt - 60, false))
            #expect(!keepsCopy(nil, startedAt - 60, false))
        }
    }
}
