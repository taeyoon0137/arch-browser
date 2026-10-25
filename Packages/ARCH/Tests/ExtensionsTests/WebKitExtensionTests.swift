// The sample extension on a WebKit tab, as the app runs it: installed through the plugin manager, loaded by the runtime into a profile's `WKWebExtensionController`, its content script running in the tab's page and telling its background script, which sets the action's badge for the tab, and its popup finding the tab through the windows the runtime reports.
import ARCHEngine
import ARCHEngineWebKit
@testable import Extensions
import Foundation
@testable import Plugins
import Testing
import WebKit

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)), "WebKit runs web extensions from macOS 15.4"))
struct WebKitExtensionTests {
    private let folder = TemporaryFolder()

    @Test func runsTheContentScriptAndThePopupOnAWebKitTab() async throws {
        try await WebKitProfile.run { profile in
            let host = RecordingHost()
            host.engines = [try #require(profile.context.extensions)]
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

            try manager.remove(installed.id)
            #expect(await eventually { runtime.actions(for: tab).isEmpty })
        }
    }

    /// The web view in a popover's view, which shows the popup.
    private static func webView(in view: NSView) -> WKWebView? {
        (view as? WKWebView) ?? view.subviews.lazy.compactMap(webView(in:)).first
    }
}
