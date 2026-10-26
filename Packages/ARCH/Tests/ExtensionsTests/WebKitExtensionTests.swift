// The sample extension on a WebKit tab, as the app runs it: installed through the plugin manager, loaded by the runtime into a profile's `WKWebExtensionController`, its content script running in the tab's page and telling its background script, which sets the action's badge for the tab, and its popup finding the tab through the windows the runtime reports; its pages also load in a tab, a window such a page opens for a web page gets a web view of its own, and a page loads an extension's web-accessible page in a frame. WebKit's check passes the sample and refuses a package it cannot read, and the engine names its extension runtime's version.
import ARCHEngine
import ARCHEngineWebKit
@testable import Extensions
import Foundation
@testable import Plugins
import Testing
import WebKit

@MainActor
@Suite(.enabled(if: systemRunsWebExtensions, "WebKit runs web extensions from macOS 15.4"))
struct WebKitExtensionTests {
    private let folder = TemporaryFolder()

    @Test func runsTheContentScriptAndThePopupOnAWebKitTab() async throws {
        try await WebKitProfile.run { profile in
            let host = RecordingHost()
            host.engines = [.webKit: try #require(profile.context.extensions)]
            let runtime = WebExtensionRuntime(persona: UUID(), host: host, nativeMessagingHosts: folder.url)
            let manager = PluginManager.withWebExtensions(runtime, in: folder)
            let installed = try await manager.installEverything(from: sampleExtensionFolder)
            let tab = profile.makeTab()
            let window = UUID()
            runtime.setWindows([EngineExtensionWindow(id: window, tabs: [tab], activeTab: tab, window: nil)], focusedWindowID: window)
            #expect(await eventually { runtime.actions(for: tab).first?.action?.label == "Show Sample Popup" })

            tab.webView.loadHTMLString("<!doctype html><title>Example</title><p>Example page", baseURL: URL(string: "https://example.org/")!)
            #expect(try await eventually { try await tab.webView.evaluateJavaScript("document.documentElement.dataset.sampleExtension ?? ''") as? String == "ran" })
            #expect(await eventually { runtime.actions(for: tab).first?.action?.badgeText == "1" })

            #expect(runtime.performAction(of: installed.id, for: tab))
            #expect(await eventually { !host.popups.isEmpty })
            let popup = try #require(host.popups.first?.contentViewController.flatMap { Self.webView(in: $0.view) })
            #expect(await eventually { popup.title == "Sample popup: https://example.org/" })
            host.popups.first?.close()

            // An extension page loads in a tab, as an options page or a tab that `tabs.create` opens at `runtime.getURL(…)` does.
            let extensionID = String(installed.id.rawValue.dropFirst("extension.".count))
            let pageTab = profile.makeTab(at: URL(string: "webkit-extension://\(extensionID)/popup.html")!)
            #expect(await eventually { pageTab.webView.title?.hasPrefix("Sample popup") == true })
            #expect(pageTab.webView.url?.scheme == "webkit-extension")
            // WebKit loads no web page in that tab's web view, so a window the page opens for one gets a web view of its own. An address that never resolves keeps the test off the network.
            let opened = OpenedWebContents()
            pageTab.uiDelegate = opened
            _ = try await pageTab.webView.evaluateJavaScript("window.open('https://example.invalid/'); 1")
            #expect(await eventually { (opened.webContents as? WebKitWebContents)?.webView.url?.host == "example.invalid" })

            try manager.remove(installed.id)
            #expect(await eventually { runtime.actions(for: tab).isEmpty })
        }
    }

    /// A page that a content script would add an extension's frame to, as a password manager adds its menu: the page loads the extension's web-accessible page in a frame, which tells the page.
    @Test func loadsAnExtensionFrameInAWebKitPage() async throws {
        try await WebKitProfile.run { profile in
            let host = RecordingHost()
            host.engines = [.webKit: try #require(profile.context.extensions)]
            let runtime = WebExtensionRuntime(persona: UUID(), host: host, nativeMessagingHosts: folder.url)
            let manager = PluginManager.withWebExtensions(runtime, in: folder)
            let package = try folder.package("frame", [
                "manifest.json": #"{"manifest_version": 3, "name": "Frame", "version": "1.0", "web_accessible_resources": [{"resources": ["frame.html"], "matches": ["https://example.org/*"]}]}"#,
                "frame.html": #"<!doctype html><title>Frame</title><script src="frame.js"></script>"#,
                "frame.js": #"parent.postMessage("frame loaded", "*");"#,
            ])
            let installed = try await manager.installEverything(from: package)
            let extensionID = String(installed.id.rawValue.dropFirst("extension.".count))
            let tab = profile.makeTab()
            let page = """
                <!doctype html><title>Example</title>
                <script>addEventListener("message", (event) => { document.title = event.data; });</script>
                <iframe src="webkit-extension://\(extensionID)/frame.html"></iframe>
                """
            tab.webView.loadHTMLString(page, baseURL: URL(string: "https://example.org/")!)
            #expect(await eventually { tab.webView.title == "frame loaded" })
            try manager.remove(installed.id)
        }
    }

    @Test func checksPackagesWithoutRunningThem() async throws {
        #expect(WebKitEngine().extensionRuntimeVersion?.isEmpty == false)
        try await WebKitProfile.run { profile in
            let extensions = try #require(profile.context.extensions)
            try await extensions.check(sampleExtensionFolder)
            let unreadable = try folder.package("unreadable", ["manifest.json": "{"])
            await #expect(throws: (any Error).self) { try await extensions.check(unreadable) }
            await #expect(throws: (any Error).self) { try await extensions.check(folder.package("empty", ["notes.txt": ""])) }
        }
    }

    /// Keeps the web contents that a page opens.
    private final class OpenedWebContents: EngineWebContentsUIDelegate {
        private(set) var webContents: (any EngineWebContents)?

        func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition) {
            self.webContents = newWebContents
        }
    }

    /// The web view in a popover's view, which shows the popup.
    private static func webView(in view: NSView) -> WKWebView? {
        (view as? WKWebView) ?? view.subviews.lazy.compactMap(webView(in:)).first
    }
}
