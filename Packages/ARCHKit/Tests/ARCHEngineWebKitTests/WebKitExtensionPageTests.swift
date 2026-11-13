// How a WebKit tab moves into and out of a web extension's pages, which WebKit loads only in a web view made for the extension, and no other page there: a main frame navigation across that line, as an extension's `tabs.update` to its own page on a web page's tab, a link from its options page to a web page, or an address typed on that page, loads in a replacement that the web contents hands its UI delegate, and a page of an extension that loads after the page opens, as a restored tab's, waits for the extension and then loads in a replacement. A web page's own link or script reaches only the extension's pages that the extension makes web-accessible to the site, as on Chromium. The tests use a private profile, which keeps nothing on disk, and load no page from the network: the web page is a string, and the web addresses never resolve.
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing
import WebKit

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)), "WebKit runs web extensions from macOS 15.4"))
struct WebKitExtensionPageTests {
    private static let extensionID = "abcdefghijklmnopabcdefghijklmnop"
    private static let baseURL = URL(string: "webkit-extension://\(extensionID)/")!
    private static let optionsURL = URL(string: "options.html", relativeTo: baseURL)!.absoluteURL
    private static let welcomeURL = URL(string: "welcome.html", relativeTo: baseURL)!.absoluteURL
    private let context: WebKitBrowserContext
    private let browser: any EngineBrowser

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        let application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder)) as? WebKitApplication)
        context = application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent())
        browser = application.createBrowser(context: context)
    }

    /// The extension's action takes the tab it is clicked on to one of the extension's pages with `tabs.update`.
    @Test func anExtensionsTabsUpdateToItsOwnPageLoadsInAReplacement() async throws {
        guard #available(macOS 15.4, *) else { return }
        try await withLoadedExtension { extensions in
            let tab = makeTab()
            let replacements = ReplacementRecorder()
            tab.uiDelegate = replacements
            tab.webView.loadHTMLString("<!doctype html><title>Example</title>", baseURL: URL(string: "https://example.org/")!)
            #expect(await eventually { tab.webView.title == "Example" })
            let window = UUID()
            extensions.setWindows([EngineExtensionWindow(id: window, tabs: [tab], activeTab: tab, window: nil)], focusedWindowID: window)

            extensions.performAction(of: Self.extensionID, for: tab)
            #expect(await eventually { !replacements.replacements.isEmpty })
            let replacement = try #require(replacements.replacements.first)
            #expect(replacements.replaced === tab)
            #expect(replacement.extensionBaseURL == Self.baseURL)
            #expect(replacement.extensionTab.replacedTab === tab.extensionTab)
            #expect(await eventually { replacement.webView.title == "Extension page" })
            // The tab keeps its page until the app puts the replacement in its place.
            #expect(tab.webView.url?.host == "example.org")
            #expect(replacements.replacements.count == 1)
        }
    }

    /// A link without a new window on the options page, and an address typed in the address field there, each load the web page in a replacement of a web view for web pages.
    @Test func aLinkAndAnAddressFromTheOptionsPageLoadInAReplacement() async throws {
        guard #available(macOS 15.4, *) else { return }
        try await withLoadedExtension { _ in
            let tab = makeTab(at: Self.optionsURL)
            let replacements = ReplacementRecorder()
            tab.uiDelegate = replacements
            #expect(await eventually { tab.webView.title == "Options" })

            _ = try await tab.webView.evaluateJavaScript("document.querySelector('a').click(); 1")
            #expect(await eventually { replacements.replacements.count == 1 })
            #expect(replacements.replacements.first?.extensionBaseURL == nil)
            #expect(await eventually { replacements.navigations == ["https://example.invalid/linked"] })

            tab.navigationController.load(URLRequest(url: URL(string: "https://example.invalid/typed")!))
            #expect(await eventually { replacements.replacements.count == 2 })
            #expect(replacements.replacements.last?.extensionBaseURL == nil)
            #expect(await eventually { replacements.navigations == ["https://example.invalid/linked", "https://example.invalid/typed"] })
            #expect(tab.webView.url == Self.optionsURL)

            // The extension's own pages still load in place.
            tab.navigationController.load(URLRequest(url: URL(string: "page.html", relativeTo: Self.baseURL)!.absoluteURL))
            #expect(await eventually { tab.webView.title == "Extension page" })
            #expect(replacements.replacements.count == 2)
        }
    }

    /// As a tab restored at the options page before the app loads the extension: the web contents loads nothing and keeps the page's address and saved state until the extension loads, and then hands over a replacement that loads the page.
    @Test func aPageOfAnExtensionThatLoadsLaterWaitsForIt() async throws {
        guard #available(macOS 15.4, *) else { return }
        let state = Data("saved state".utf8)
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration(initialURL: Self.optionsURL, restorableState: state)) as? WebKitWebContents)
        let replacements = ReplacementRecorder()
        tab.uiDelegate = replacements
        #expect(tab.url == Self.optionsURL)
        #expect(tab.restorableState == state)
        #expect(tab.webView.url == nil)

        try await withLoadedExtension { _ in
            #expect(await eventually { replacements.replacements.count == 1 })
            let replacement = try #require(replacements.replacements.first)
            #expect(replacement.extensionBaseURL == Self.baseURL)
            // WebKit cannot read the made-up state, so the replacement loads the page's address.
            #expect(await eventually { replacement.webView.title == "Options" })
        }
    }

    /// A web page's link and script reach no page of the extension that the extension does not make web-accessible to the site: the navigation policy sees them and no replacement loads them. A link to the page that the site may reach, and the app's own load of any of the extension's pages, load in a replacement.
    @Test func aWebPageReachesOnlyTheExtensionsPagesThatItMayReach() async throws {
        guard #available(macOS 15.4, *) else { return }
        try await withLoadedExtension { _ in
            let tab = makeTab()
            let replacements = ReplacementRecorder()
            tab.uiDelegate = replacements
            tab.navigationDelegate = replacements
            let linked = Self.optionsURL.absoluteString + "?from=link"
            let scripted = Self.optionsURL.absoluteString + "?from=script"
            tab.webView.loadHTMLString(#"<!doctype html><title>Example</title><a href="\#(linked)">Options</a><a href="\#(Self.welcomeURL.absoluteString)">Welcome</a>"#,
                                       baseURL: URL(string: "https://example.org/")!)
            #expect(await eventually { tab.webView.title == "Example" })

            _ = try await tab.webView.evaluateJavaScript("document.querySelector('a').click(); 1")
            #expect(await eventually { replacements.navigations.contains(linked) })
            _ = try await tab.webView.evaluateJavaScript("location.href = '\(scripted)'; 1")
            #expect(await eventually { replacements.navigations.contains(scripted) })
            try await Task.sleep(for: .milliseconds(300))
            #expect(replacements.replacements.isEmpty)
            #expect(tab.webView.url?.host == "example.org")

            _ = try await tab.webView.evaluateJavaScript("document.querySelectorAll('a')[1].click(); 1")
            #expect(await eventually { replacements.replacements.count == 1 })
            #expect(await eventually { replacements.replacements.first?.webView.title == "Welcome" })

            tab.navigationController.load(URLRequest(url: Self.optionsURL))
            #expect(await eventually { replacements.replacements.count == 2 })
            #expect(await eventually { replacements.replacements.last?.webView.title == "Options" })
        }
    }

    /// A frame of the extension may take a tab to any of its pages, a frame of a site only to a page that the extension makes web-accessible to that site, and a frame of another extension or of an unknown origin to none of them. Any frame may leave for a web page.
    @Test func onlyTheExtensionAndTheSitesItNamesMayOpenItsPages() async throws {
        guard #available(macOS 15.4, *) else { return }
        try await withLoadedExtension { _ in
            let tab = makeTab()
            let site = URL(string: "https://example.org/")
            #expect(tab.mayStartReplacement(toLoad: Self.optionsURL, from: Self.baseURL))
            #expect(!tab.mayStartReplacement(toLoad: Self.optionsURL, from: site))
            #expect(tab.mayStartReplacement(toLoad: Self.welcomeURL, from: site))
            #expect(!tab.mayStartReplacement(toLoad: Self.welcomeURL, from: URL(string: "https://other.example/")))
            #expect(!tab.mayStartReplacement(toLoad: Self.welcomeURL, from: nil))
            #expect(!tab.mayStartReplacement(toLoad: Self.optionsURL, from: URL(string: "webkit-extension://ponmlkjihgfedcbaponmlkjihgfedcba/")))
            #expect(tab.mayStartReplacement(toLoad: URL(string: "https://example.invalid/")!, from: nil))
        }
    }

    /// `web_accessible_resources` as Chromium reads it: Manifest V2 paths that any frame reaches, and Manifest V3 resources for the sites that `matches` match and the extensions that `extension_ids` name, with `*` and `?` in paths.
    @Test func webAccessibleResourcesNameTheResourcesAndTheFramesThatReachThem() {
        guard #available(macOS 15.4, *) else { return }
        let site = URL(string: "https://example.org/")
        let other = URL(string: "webkit-extension://other/")
        let version2: [String: Any] = ["web_accessible_resources": ["pages/*.html", "/welcome.html"]]
        #expect(WebKitExtensions.isWebAccessible("/pages/a/b.html", in: version2, from: nil, ofExtension: nil))
        #expect(WebKitExtensions.isWebAccessible("/welcome.html", in: version2, from: site, ofExtension: nil))
        #expect(!WebKitExtensions.isWebAccessible("/options.html", in: version2, from: site, ofExtension: nil))
        let version3: [String: Any] = ["web_accessible_resources": [["resources": ["welcome.html"], "matches": ["https://example.org/*"]],
                                                                    ["resources": ["shared/?.html"], "extension_ids": ["other"]]]]
        #expect(WebKitExtensions.isWebAccessible("/welcome.html", in: version3, from: site, ofExtension: nil))
        #expect(!WebKitExtensions.isWebAccessible("/welcome.html", in: version3, from: URL(string: "https://other.example/"), ofExtension: nil))
        #expect(WebKitExtensions.isWebAccessible("/shared/a.html", in: version3, from: other, ofExtension: "other"))
        #expect(!WebKitExtensions.isWebAccessible("/shared/ab.html", in: version3, from: other, ofExtension: "other"))
        #expect(!WebKitExtensions.isWebAccessible("/shared/a.html", in: version3, from: site, ofExtension: nil))
        #expect(!WebKitExtensions.isWebAccessible("/welcome.html", in: [:], from: site, ofExtension: nil))
    }

    /// A page that waits for its extension stops waiting once another navigation goes ahead in it.
    @Test func aNavigationEndsTheWaitForAnExtension() async throws {
        guard #available(macOS 15.4, *) else { return }
        let tab = makeTab(at: Self.optionsURL)
        let replacements = ReplacementRecorder()
        tab.uiDelegate = replacements
        tab.webView.loadHTMLString("<!doctype html><title>Example</title>", baseURL: URL(string: "https://example.org/")!)
        #expect(await eventually { tab.webView.title == "Example" })
        #expect(tab.waitingPage == nil)

        try await withLoadedExtension { _ in
            try await Task.sleep(for: .milliseconds(300))
            #expect(replacements.replacements.isEmpty)
        }
    }

    /// Loads an extension with an options page that links to a web page, another page, an action that takes the clicked tab to that page, and a welcome page that pages of example.org may reach, runs `body`, and unloads it.
    @available(macOS 15.4, *)
    private func withLoadedExtension(_ body: (WebKitExtensions) async throws -> Void) async throws {
        let extensions = try #require(context.webExtensions)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("arch-extension-pages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let files = [
            "manifest.json": #"{"manifest_version": 3, "name": "Pages", "version": "1.0", "options_page": "options.html", "action": {"default_title": "Open Page"}, "background": {"service_worker": "background.js"}, "web_accessible_resources": [{"resources": ["welcome.html"], "matches": ["https://example.org/*"]}]}"#,
            "background.js": #"browser.action.onClicked.addListener((tab) => { browser.tabs.update(tab.id, { url: browser.runtime.getURL("page.html") }); });"#,
            "options.html": #"<!doctype html><title>Options</title><a href="https://example.invalid/linked">Web page</a>"#,
            "page.html": "<!doctype html><title>Extension page</title>",
            "welcome.html": "<!doctype html><title>Welcome</title>",
        ]
        for (name, contents) in files { try contents.write(to: package.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try await extensions.load(EngineExtension(id: Self.extensionID, packageURL: package, permissions: [], sites: []))
        defer { extensions.unload(Self.extensionID) }
        try await body(extensions)
    }

    private func makeTab(at url: URL? = nil) -> WebKitWebContents {
        browser.createWebContents(EngineWebContentsConfiguration(initialURL: url)) as! WebKitWebContents
    }

    /// Keeps the replacements that a web contents hands over, as the session would put them in its tab's place, and the addresses that they go to load. A web address that never resolves leaves a web view without an address once its load fails, so the address comes from the navigation policy.
    private final class ReplacementRecorder: EngineWebContentsUIDelegate, EngineWebContentsNavigationDelegate {
        private(set) var replacements: [WebKitWebContents] = []
        private(set) weak var replaced: (any EngineWebContents)?
        private(set) var navigations: [String] = []

        func webContents(_ webContents: any EngineWebContents, didCreateReplacement replacement: any EngineWebContents) {
            replaced = webContents
            replacement.navigationDelegate = self
            replacements.append(replacement as! WebKitWebContents)
        }

        func webContents(_ webContents: any EngineWebContents, decidePolicyFor action: EngineNavigationAction) -> EngineNavigationPolicy {
            navigations.append(action.url.absoluteString)
            return .allow
        }
    }

    /// Waits up to ten seconds for `condition`, checking every tenth of a second, and reports whether it held.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
