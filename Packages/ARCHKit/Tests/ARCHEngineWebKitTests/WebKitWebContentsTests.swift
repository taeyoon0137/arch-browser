// How a WebKit page reaches its web contents: the web view of a tab and of a popup knows the web contents that made it, and a page script's message reaches the page script delegate of that web contents, and the favicon lookup reads the page's declared icon from a world of the app's own. Closing all of a browser's web contents ends each page. The tests use a private profile, which keeps nothing on disk, and load no page from the network.
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
