// How a WebKit page reaches its web contents: the web view of a tab and of a popup knows the web contents that made it, and a page script's message reaches the page script delegate of that web contents. The tests use a private profile, which keeps nothing on disk, and load no page from the network.
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing

@MainActor @Suite struct WebKitWebContentsTests {
    private let application: any EngineApplication
    private let context: WebKitBrowserContext
    private let browser: any EngineBrowser
    private let browserDelegate = NoBrowserDelegate()

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        application = try WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder))
        var created: (any EngineBrowserContext)?
        application.createBrowserContext(EngineBrowserContextAttributes(id: EngineBrowserContextID(rawValue: "test"), userVisibleName: "Test", type: .incognito)) { created = try? $0.get() }
        context = try #require(created as? WebKitBrowserContext)
        browser = application.createBrowser(EngineBrowserCreateParams(initialBounds: .zero), context: context, delegate: browserDelegate, window: nil)
    }

    @Test func eachWebViewKnowsItsWebContents() throws {
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        let popup = WebKitWebContents(sessionID: UUID().uuidString, parentConfiguration: tab.webView.configuration, context: context)
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

    private final class NoBrowserDelegate: EngineBrowserDelegate {}

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
