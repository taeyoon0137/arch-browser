// How a WebKit page reaches its web contents: the web view of a tab and of a popup knows the web contents that made it, a page script's message reaches the page script delegate of that web contents, and the favicon lookup reads the page's declared icon from a world of the app's own. Find counts only the matches WebKit's find sees. Closing all of a browser's web contents ends each page. The tests use a private profile, which keeps nothing on disk, and load no page from the network.
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing

@MainActor @Suite struct WebKitWebContentsTests {
    private let application: WebKitApplication
    private let context: WebKitBrowserContext
    private let browser: any EngineBrowser

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder)) as? WebKitApplication)
        context = application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent())
        browser = application.createBrowser(context: context)
    }

    @Test(arguments: [false, true]) func reloadingARestoredLocalFileThatHasReturned(_ withoutCache: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = directory.appendingPathComponent("earlier.html")
        let file = directory.appendingPathComponent("notes.html")
        try Data("<title>Earlier</title>".utf8).write(to: earlier)
        try Data("<title>Original</title>".utf8).write(to: file)
        let first = try #require(browser.createWebContents(EngineWebContentsConfiguration(initialURL: earlier)) as? WebKitWebContents)
        try #require(await eventually { first.webView.title == "Earlier" && !first.isLoading })
        first.navigationController.load(URLRequest(url: file))
        try #require(await eventually { first.webView.title == "Original" && !first.isLoading })
        let state = try #require(first.restorableState)
        browser.closeWebContents(first)
        try FileManager.default.removeItem(at: file)
        let restored = try #require(browser.createWebContents(EngineWebContentsConfiguration(initialURL: file, restorableState: state)) as? WebKitWebContents)
        try #require(await eventually { !restored.webView.isLoading && restored.webView.url == nil && restored.webView.backForwardList.currentItem?.url == file })
        #expect(restored.url == file)
        try Data("<title>Returned</title>".utf8).write(to: file)
        if withoutCache { restored.navigationController.reloadWithoutCache() } else { restored.navigationController.reload() }
        #expect(await eventually { restored.webView.title == "Returned" && !restored.isLoading })
        #expect(restored.url == file)
        #expect(restored.webView.backForwardList.backList.map(\.url) == [earlier])
    }

    @Test func aResearchPopupRefusalPrecedesWindowCreation() async throws {
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        let policy = PopupPolicy()
        tab.uiDelegate = policy
        tab.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        tab.webView.loadHTMLString("<title>Ready</title>", baseURL: nil)
        #expect(await eventually { tab.webView.title == "Ready" })
        let refused = try await tab.webView.evaluateJavaScript("window.open('about:blank') === null") as? Bool
        #expect(refused == true && policy.checks == 1 && policy.children.isEmpty)
        policy.allows = true
        let opened = try await tab.webView.evaluateJavaScript("window.open('about:blank') !== null") as? Bool
        #expect(opened == true && policy.checks == 2 && policy.children.count == 1)
    }

    private final class PopupPolicy: EngineWebContentsUIDelegate {
        var allows = false
        var checks = 0
        var children: [any EngineWebContents] = []

        func webContentsMayCreatePopup(_ webContents: any EngineWebContents) -> Bool {
            checks += 1
            return allows
        }

        func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents child: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition) {
            children.append(child)
        }
    }

    @Test func eachWebViewKnowsItsWebContents() throws {
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        let popup = WebKitWebContents(parentConfiguration: tab.webView.configuration, extensionBaseURL: nil, context: context)
        #expect((tab.webView as? WebKitWebView)?.contents === tab)
        #expect((popup.webView as? WebKitWebView)?.contents === popup)
    }

    @Test func aPageScriptMessageReachesItsWebContents() async throws {
        let script = EnginePageScript(world: "test", source: "(channel) => { channel.send({ ready: true }); }", injectionTime: .documentEnd, mainFrameOnly: true)
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration(pageScripts: [script])) as? WebKitWebContents)
        let recorder = PageScriptRecorder()
        tab.pageScriptDelegate = recorder
        tab.webView.loadHTMLString("<!doctype html><title>Test</title>", baseURL: nil)
        #expect(await eventually { !recorder.messages.isEmpty })
        #expect(recorder.messages.first?.world == "test")
        #expect(recorder.messages.first?.json == #"{"ready":true}"#)
        #expect(recorder.sender === tab)
    }

    /// WebKit's find matches no text that spans two blocks, so the count leaves such text out too, while text in inline elements runs on.
    @Test func findCountsNoMatchAcrossBlocks() async throws {
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        tab.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        tab.webView.loadHTMLString("<!doctype html><body><p>foo</p><p>bar</p><p>foobar</p><span>foo</span><b>bar</b></body>", baseURL: nil)
        #expect(await eventually { !tab.webView.isLoading })
        var result: EngineFindResult?
        for _ in 0..<20 where result.map({ $0.numberOfMatches == 0 }) ?? true {
            result = await withCheckedContinuation { continuation in
                tab.find("foobar", forward: true, matchCase: false) { continuation.resume(returning: $0) }
            }
            if result?.numberOfMatches == 0 { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(result?.numberOfMatches == 2)
    }

    /// The favicon lookup runs in a world of the app's own and still reads the page's declared icon, here a one-pixel image in a data address.
    @Test func theIconLookupReadsThePagesDeclaredIcon() async throws {
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        let icon = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        tab.webView.loadHTMLString("<!doctype html><title>Test</title><link rel=\"icon\" href=\"\(icon)\">", baseURL: nil)
        #expect(await eventually { tab.favicon != nil })
    }

    @Test func closingAllWebContentsEndsEachPage() throws {
        let tabs = try (0..<2).map { _ in try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents) }
        browser.closeAllWebContents()
        for tab in tabs {
            #expect(tab.bridge == nil)
            #expect(tab.webView.superview == nil)
        }
    }

    private final class PageScriptRecorder: EnginePageScriptDelegate {
        private(set) var messages: [EnginePageScriptMessage] = []
        private(set) weak var sender: (any EngineWebContents)?

        func webContents(_ webContents: any EngineWebContents, didReceive message: EnginePageScriptMessage, reply: @escaping (String?) -> Void) {
            sender = webContents
            messages.append(message)
            reply(nil)
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
