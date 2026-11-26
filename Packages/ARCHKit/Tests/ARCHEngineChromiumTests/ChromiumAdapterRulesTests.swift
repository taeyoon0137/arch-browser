// The Chromium adapter's rules that need no engine: how cookies cross into CEF's store and back, when a crashed page reloads, where Chromium keeps a profile's caches, where an extension's grant lets it run and which granted sites go with a click, and when a load keeps the copy Chromium runs. Cookie stores and extensions in a profile need the engine and the app.
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

    // MARK: Start

    /// The app's debug window shows why the engine or a Persona's profile did not start, in the interface's language.
    @Test func aStartErrorNamesItsReason() {
        #expect(ChromiumEngine.StartError.initializationFailed.localizedDescription == catalogText("CEF did not initialize."))
        #expect(ChromiumEngine.StartError.profileUnavailable.localizedDescription == catalogText("CEF refused the Persona's profile folder."))
    }

    // MARK: Links opened in a new tab

    /// CEF already applies the click's modifiers; a delayed callback must not read the keyboard's current state.
    @Test func modifiedLinksCarryTheirGestureAndClickTimeDisposition() throws {
        let link = try #require(URL(string: "https://example.org/next"))
        let cases: [(ARCHCEFPopupDisposition, EngineNavigationDisposition, Bool)] = [(.backgroundTab, .newBackgroundTab, true), (.foregroundTab, .newForegroundTab, true),
                                                                                     (.window, .newWindow, false)]
        for (cef, disposition, opensTab) in cases {
            for gesture in [false, true] {
                let action = ChromiumWebContents.openingAction(to: link, disposition: cef, userGesture: gesture, isPopup: false)
                #expect(action.url == link && action.disposition == disposition && action.opensLinkInNewTab == opensTab)
                #expect(action.isUserInitiated == gesture && action.isLinkActivation && !action.isRedirect)
            }
        }
    }

    @Test func aPopupDispositionIsNotARecognizedLink() throws {
        let link = try #require(URL(string: "https://example.org/sign-in"))
        for gesture in [false, true] {
            let action = ChromiumWebContents.openingAction(to: link, disposition: .popup, userGesture: gesture, isPopup: false)
            #expect(action.disposition == .newPopup && action.isUserInitiated == gesture)
            #expect(!action.isLinkActivation && !action.opensLinkInNewTab)
        }
    }

    /// window.open can inherit a click's gesture and modifiers. Keep its native page and opener even when CEF requests a tab or a window.
    @Test func nativePopupCreationNeverBecomesALinkEvenWithAUserGesture() throws {
        let link = try #require(URL(string: "https://example.org/sign-in"))
        let cases: [(ARCHCEFPopupDisposition, EngineNavigationDisposition)] = [(.backgroundTab, .newBackgroundTab), (.foregroundTab, .newForegroundTab),
                                                                             (.window, .newWindow), (.popup, .newPopup)]
        for (cef, disposition) in cases {
            for gesture in [false, true] {
                let action = ChromiumWebContents.openingAction(to: link, disposition: cef, userGesture: gesture, isPopup: true)
                #expect(action.url == link && action.disposition == disposition && action.isUserInitiated == gesture)
                #expect(!action.isLinkActivation && !action.opensLinkInNewTab && !action.isRedirect)
            }
        }
    }

    // MARK: Crashes

    /// A page that crashes again within a minute of its reload stays blank, so that it cannot reload in a loop, and a crash later than that, or of another page, reloads it.
    @Test func aCrashReloadsThePageUnlessItCrashedJustAfterItsLastReload() {
        let page = URL(string: "https://mail.example.org/")!
        let reload = (url: page, date: Date(timeIntervalSinceReferenceDate: 0))
        let reloads = { (url: URL, seconds: TimeInterval, last: (url: URL, date: Date)?) in
            ChromiumWebContents.reloadsAfterCrash(of: url, now: Date(timeIntervalSinceReferenceDate: seconds), lastReload: last)
        }
        #expect(reloads(page, 0, nil))
        #expect(!reloads(page, 30, reload))
        #expect(reloads(page, 4 * 3600, reload))
        #expect(reloads(URL(string: "https://news.example.org/")!, 30, reload))
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

    /// Without a grant of every site, the grant's sites go with the click, so that Chromium runs the extension there and waits for a click on the others.
    @Test func anExtensionWaitsForAClickOnlyOutsideTheSitesOfItsGrant() throws {
        try withPackage(#"{"host_permissions": ["https://example.org/*", "wss://*/*"], "content_scripts": [{"matches": ["https://example.com/*", "http://example.net/*"]}]}"#) { package in
            let grant = { (sites: Set<String>) in ChromiumExtensions.siteGrant(for: EngineExtension(id: "a", packageURL: package, permissions: [], sites: sites)) }
            // Schemes and hosts go in lowercase and the patterns in order, without those for `file:` and `ftp:` pages.
            let some = grant(["https://example.org/*", "HTTPS://Example.com/Path*", "https://example.com/Path*", "file:///*", "ftp://example.org/*"])
            #expect(some.access == .onClick && some.sites == ["https://example.com/Path*", "https://example.org/*"])
            let none = grant([])
            #expect(none.access == .onClick && none.sites.isEmpty)
            // The WebSocket pattern, which no grant holds, keeps the click with every site the install sheet listed, which go with it.
            let listed = grant(["https://example.org/*", "https://example.com/*", "http://example.net/*"])
            #expect(listed.access == .onClick && listed.sites == ["http://example.net/*", "https://example.com/*", "https://example.org/*"])
            let all = grant(["<all_urls>"])
            #expect(all.access == .onAllSites && all.sites.isEmpty)
        }
        try withPackage(#"{"host_permissions": ["https://example.org/*"]}"#) { package in
            let all = ChromiumExtensions.siteGrant(for: EngineExtension(id: "a", packageURL: package, permissions: [], sites: ["https://example.org/*"]))
            #expect(all.access == .onAllSites && all.sites.isEmpty)
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
