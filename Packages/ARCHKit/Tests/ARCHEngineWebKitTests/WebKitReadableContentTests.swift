// What a WebKit page's readable content holds of its selection: text selected outside fields and editable areas, and none for a selection that reaches an editable area, also one in an open shadow tree, so a draft never goes with a question. The tests use a private profile and load no page from the network.
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing

@MainActor @Suite struct WebKitReadableContentTests {
    private let browser: any EngineBrowser
    private let browserDelegate = NoBrowserDelegate()

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        let application = try WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder))
        var created: (any EngineBrowserContext)?
        application.createBrowserContext(EngineBrowserContextAttributes(id: EngineBrowserContextID(rawValue: "test"), userVisibleName: "Test", type: .incognito)) { created = try? $0.get() }
        let context = try #require(created as? WebKitBrowserContext)
        browser = application.createBrowser(EngineBrowserCreateParams(initialBounds: .zero), context: context, delegate: browserDelegate, window: nil)
    }

    private static let page = """
        <!doctype html><title>Test</title>
        <p id="intro">Intro text</p>
        <div contenteditable>My draft reply</div>
        <p id="middle">Middle text</p>
        <div id="host"></div>
        <p id="outro">Outro text</p>
        <script>document.getElementById("host").attachShadow({ mode: "open" }).innerHTML = "<div contenteditable>Shadow draft</div>";</script>
        """

    @Test func textSelectedOutsideEditableAreasIsTheSelection() async throws {
        let tab = try await loadedTab()
        try await select(in: tab, from: "intro", to: "intro")
        #expect(try await selection(of: tab) == "Intro text")
    }

    @Test func aSelectionAcrossAnEditableAreaIsNone() async throws {
        let tab = try await loadedTab()
        try await select(in: tab, from: "intro", to: "middle")
        #expect(try await selection(of: tab) == nil)
    }

    @Test func aSelectionAcrossAnEditableAreaInAShadowTreeIsNone() async throws {
        let tab = try await loadedTab()
        try await select(in: tab, from: "middle", to: "outro")
        #expect(try await selection(of: tab) == nil)
    }

    private func loadedTab() async throws -> WebKitWebContents {
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        tab.webView.loadHTMLString(Self.page, baseURL: nil)
        for _ in 0..<100 {
            if (try? await tab.webView.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('host').shadowRoot")) as? Bool == true { return tab }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TestPageError.notLoaded
    }

    /// Selects from the start of one element's text to the end of another's, as dragging across the page does.
    private func select(in tab: WebKitWebContents, from start: String, to end: String) async throws {
        let script = "const end = document.getElementById('\(end)').firstChild; getSelection().setBaseAndExtent(document.getElementById('\(start)').firstChild, 0, end, end.length); true"
        _ = try await tab.webView.evaluateJavaScript(script)
    }

    private func selection(of tab: WebKitWebContents) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            tab.readableContent(limit: 0) { continuation.resume(with: $0.map(\.selection)) }
        }
    }

    private enum TestPageError: Error { case notLoaded }

    private final class NoBrowserDelegate: EngineBrowserDelegate {}
}
