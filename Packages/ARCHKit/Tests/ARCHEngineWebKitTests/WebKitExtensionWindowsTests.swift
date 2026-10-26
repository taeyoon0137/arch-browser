// What a profile's web extensions hear when the app reports its windows: a window that closes while its tab moves to another window closes after the tab has moved there, a window that closes with its tabs closes after them, and the active tab and focus follow. The tests use a private profile, which keeps nothing on disk, and load no page.
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing
import WebKit

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)), "WebKit runs web extensions from macOS 15.4"))
struct WebKitExtensionWindowsTests {
    private let context: WebKitBrowserContext
    private let browser: any EngineBrowser
    private let browserDelegate = NoBrowserDelegate()

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        let application = try WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder))
        var created: (any EngineBrowserContext)?
        application.createBrowserContext(EngineBrowserContextAttributes(id: EngineBrowserContextID(rawValue: "windows"), userVisibleName: "Windows", type: .incognito)) { created = try? $0.get() }
        context = try #require(created as? WebKitBrowserContext)
        browser = application.createBrowser(EngineBrowserCreateParams(initialBounds: .zero), context: context, delegate: browserDelegate, window: nil)
    }

    /// As Move to Main Window moves a small window's tab into a main window and closes the small window.
    @Test func aWindowClosesAfterItsTabMovesOut() throws {
        guard #available(macOS 15.4, *) else { return }
        let extensions = try #require(context.webExtensions)
        let recorder = WindowEventRecorder()
        extensions.windowEvents = recorder
        let kept = try makeTab(), moved = try makeTab()
        let main = UUID(), small = UUID()
        recorder.tabNames = [ObjectIdentifier(kept.extensionTab): "kept", ObjectIdentifier(moved.extensionTab): "moved"]
        recorder.windowNames = [main: "main", small: "small"]
        extensions.setWindows([EngineExtensionWindow(id: main, tabs: [kept], activeTab: kept, window: nil),
                               EngineExtensionWindow(id: small, tabs: [moved], activeTab: moved, window: nil)], focusedWindowID: small)
        recorder.events.removeAll()

        extensions.setWindows([EngineExtensionWindow(id: main, tabs: [kept, moved], activeTab: moved, window: nil)], focusedWindowID: main)
        #expect(recorder.events == ["move moved from 0 in small", "close window small", "activate moved after kept", "focus main"])
        recorder.events.removeAll()

        extensions.setWindows([], focusedWindowID: nil)
        #expect(recorder.events == ["close kept with its window", "close moved with its window", "close window main", "focus none"])
    }

    private func makeTab() throws -> WebKitWebContents {
        try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
    }

    private final class NoBrowserDelegate: EngineBrowserDelegate {}

    /// Records each call as a line that names the tabs and windows.
    @available(macOS 15.4, *)
    private final class WindowEventRecorder: WebKitExtensionWindowEvents {
        var tabNames: [ObjectIdentifier: String] = [:]
        var windowNames: [UUID: String] = [:]
        var events: [String] = []

        private func name(_ tab: (any WKWebExtensionTab)?) -> String {
            tab.map { tabNames[ObjectIdentifier($0)] ?? "an unknown tab" } ?? "none"
        }

        private func name(_ window: (any WKWebExtensionWindow)?) -> String {
            window.map { ($0 as? WebKitExtensionWindow).flatMap { windowNames[$0.id] } ?? "an unknown window" } ?? "none"
        }

        func didOpenWindow(_ newWindow: any WKWebExtensionWindow) { events.append("open window \(name(newWindow))") }
        func didCloseWindow(_ closedWindow: any WKWebExtensionWindow) { events.append("close window \(name(closedWindow))") }
        func didFocusWindow(_ focusedWindow: (any WKWebExtensionWindow)?) { events.append("focus \(name(focusedWindow))") }
        func didOpenTab(_ newTab: any WKWebExtensionTab) { events.append("open \(name(newTab))") }
        func didCloseTab(_ closedTab: any WKWebExtensionTab, windowIsClosing: Bool) {
            events.append("close \(name(closedTab))" + (windowIsClosing ? " with its window" : ""))
        }
        func didActivateTab(_ activatedTab: any WKWebExtensionTab, previousActiveTab previousTab: (any WKWebExtensionTab)?) {
            events.append("activate \(name(activatedTab)) after \(name(previousTab))")
        }
        func didMoveTab(_ movedTab: any WKWebExtensionTab, from index: Int, in oldWindow: (any WKWebExtensionWindow)?) {
            events.append("move \(name(movedTab)) from \(index) in \(name(oldWindow))")
        }
    }
}
