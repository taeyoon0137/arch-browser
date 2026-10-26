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
        // Schemes and hosts compare in lowercase, as the app's grants write them.
        try withPackage(#"{"host_permissions": ["HTTPS://Mail.Example.com/Inbox*"], "content_scripts": [{"matches": ["https://example.org/*"]}]}"#) { package in
            #expect(ChromiumExtensions.siteAccess(for: EngineExtension(id: "a", packageURL: package, permissions: [], sites: ["https://mail.example.com/Inbox*", "https://example.org/*"])) == .onAllSites)
        }
        #expect(ChromiumExtensions.lowercasingSchemeAndHost("HTTPS://Mail.Example.com/Inbox*") == "https://mail.example.com/Inbox*")
        #expect(ChromiumExtensions.lowercasingSchemeAndHost("https://Example.org") == "https://example.org")
        #expect(ChromiumExtensions.lowercasingSchemeAndHost("<all_urls>") == "<all_urls>")
    }

    /// The install sheet lists only `http`, `https`, and `*` patterns without a port, and Arch's engine keeps extensions out of `file:` pages, so a grant of every site the sheet listed runs everywhere it asked, while a pattern with a port keeps the click.
    @Test func aGrantOfEverySiteTheInstallSheetListedRunsOnThemAllWithoutAClick() throws {
        try withPackage(#"{"content_scripts": [{"matches": ["http://*/*", "https://*/*", "FILE:///*"]}], "host_permissions": ["ftp://example.org/*"]}"#) { package in
            let access = { (sites: Set<String>) in ChromiumExtensions.siteAccess(for: EngineExtension(id: "a", packageURL: package, permissions: [], sites: sites)) }
            #expect(access(["http://*/*", "https://*/*"]) == .onAllSites)
            #expect(access(["https://*/*"]) == .onClick)
        }
        // A WebSocket pattern, which the install sheet never showed, keeps the click, so that Chromium grants it with no other site.
        try withPackage(#"{"permissions": ["webRequest"], "host_permissions": ["https://mail.example.com/*", "wss://*/*"]}"#) { package in
            #expect(ChromiumExtensions.siteAccess(for: EngineExtension(id: "a", packageURL: package, permissions: [], sites: ["https://mail.example.com/*"])) == .onClick)
        }
        try withPackage(#"{"host_permissions": ["wss://*/*"]}"#) { package in
            #expect(ChromiumExtensions.siteAccess(for: EngineExtension(id: "a", packageURL: package, permissions: [], sites: [])) == .onClick)
        }
        try withPackage(#"{"host_permissions": ["*://example.org/*", "https://example.org:8080/*"]}"#) { package in
            #expect(ChromiumExtensions.siteAccess(for: EngineExtension(id: "a", packageURL: package, permissions: [], sites: ["*://example.org/*"])) == .onClick)
        }
        try withPackage(#"{"host_permissions": ["<all_urls>", "file:///*"]}"#) { package in
            let access = { (sites: Set<String>) in ChromiumExtensions.siteAccess(for: EngineExtension(id: "a", packageURL: package, permissions: [], sites: sites)) }
            #expect(access(["<all_urls>"]) == .onAllSites)
            #expect(access(["https://example.org/*"]) == .onClick)
        }
        #expect(ChromiumExtensions.countsForSiteAccess("<all_urls>"))
        #expect(ChromiumExtensions.countsForSiteAccess("*://*/*"))
        #expect(ChromiumExtensions.countsForSiteAccess("http://example.org/*"))
        #expect(ChromiumExtensions.countsForSiteAccess("ws://example.org/*"))
        #expect(ChromiumExtensions.countsForSiteAccess("chrome://favicon/*"))
        #expect(ChromiumExtensions.countsForSiteAccess("uuid-in-package:*"))
        #expect(!ChromiumExtensions.countsForSiteAccess("file:///*"))
        #expect(!ChromiumExtensions.countsForSiteAccess("ftp://example.org/*"))
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
