// Which of WebKit's context menu items the app's menu keeps: WebKit's own editing and spelling items, matched by tag, in WebKit's order, with their roles and Select All beside Paste, followed by macOS's text items, which the adapter aims at the web view. WebKit's menu stays as it is when it has none of WebKit's own items, holds items a page element provides, or shows a link or image that the script could not see. The selection reaches the menu only when the click is on it, and the script counts a field as a password field while it is one, masks its text, or has been one. The menu tests build WebKit's menus by hand; the script's test loads a page from a string in a private profile.
import AppKit
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing
import WebKit

@MainActor @Suite struct WebKitContextMenuTests {
    /// WebKit's action for the items it runs; WebCore's menu actions are their tags.
    private nonisolated static let forward = Selector(("forwardContextMenuAction:"))
    private let link = EngineContextMenuElement(linkURL: URL(string: "https://example.com/"))

    private func menu(_ tags: [Int]) -> NSMenu {
        let menu = NSMenu()
        for tag in tags { menu.addItem(item(tag)) }
        return menu
    }

    private func item(_ tag: Int, action: Selector? = forward) -> NSMenuItem {
        let item = NSMenuItem(title: "\(tag)", action: action, keyEquivalent: "")
        item.tag = tag
        return item
    }

    @Test func keepsWebKitsEditingAndSpellingItemsInWebKitsOrder() {
        // Open Link, Copy Link, Copy, a spelling guess, Ignore Spelling, Learn Spelling, Cut, Paste, and Look Up, then an item of another app with Copy's tag.
        let menu = menu([1, 3, 8, 15, 17, 18, 13, 14, 22])
        menu.addItem(item(8, action: #selector(NSText.copy(_:))))
        let kept = WebKitWebContents.keptContextMenuItems(of: menu, for: link)
        #expect(kept?.map(\.tag) == [8, 15, 17, 18, 13, 14])
        #expect(kept?.allSatisfy { $0.action == Self.forward } == true)
    }

    @Test func leavesAMenuWithoutWebKitsOwnItems() {
        let menu = NSMenu()
        menu.addItem(item(8, action: #selector(NSText.copy(_:))))
        #expect(WebKitWebContents.keptContextMenuItems(of: menu, for: link) == nil)
    }

    @Test func leavesAMenuThatAPageElementProvides() {
        let menu = menu([8])
        let speed = item(0, action: nil)
        speed.submenu = self.menu([5001, 5002])
        menu.addItem(speed)
        #expect(WebKitWebContents.keptContextMenuItems(of: menu, for: link) == nil)
    }

    @Test func leavesAMenuWhoseLinkOrImageTheScriptCouldNotSee() {
        #expect(WebKitWebContents.keptContextMenuItems(of: menu([3, 8]), for: EngineContextMenuElement()) == nil)
        #expect(WebKitWebContents.keptContextMenuItems(of: menu([6, 8]), for: link) == nil)
        #expect(WebKitWebContents.keptContextMenuItems(of: menu([6, 8]), for: EngineContextMenuElement(imageURL: URL(string: "https://example.com/a.png")))?.map(\.tag) == [8])
    }

    @Test func handsTheKeptItemsWithTheirRolesToTheDelegate() throws {
        let folder = FileManager.default.temporaryDirectory
        let application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder)) as? WebKitApplication)
        let browser = application.createBrowser(context: application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent()))
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        let recorder = MenuRecorder()
        tab.uiDelegate = recorder

        let editable = menu([13, 8, 14, 22])
        editable.items.forEach { $0.image = NSImage(size: NSSize(width: 1, height: 1)) }
        tab.prepareContextMenu(editable, for: EngineContextMenuElement(selectedText: "text"), panels: EngineTextMenuItems.Panels())
        let fieldItems = [EngineContextMenuItem.cut, EngineContextMenuItem.copy, EngineContextMenuItem.paste, EngineContextMenuItem.selectAll]
        #expect(Array(editable.items.prefix(4).map(\.identifier)) == fieldItems)
        #expect(editable.items.prefix(4).allSatisfy { $0.image == nil })
        #expect(recorder.elements.last?.isEditable == true)
        #expect(recorder.elements.last?.selectedText == "text")
        // The text items follow, with WebKit's own Look Up (22) left out, and their submenus aim at the web view.
        let textItems = editable.items.dropFirst(4)
        #expect(textItems.first?.identifier == EngineContextMenuItem.lookUp)
        #expect(!editable.items.contains { $0.tag == 22 })
        #expect(textItems.compactMap(\.submenu).flatMap(\.items).filter { !$0.isSeparatorItem }.allSatisfy { $0.target === tab.webView })

        let selection = menu([8, 22])
        tab.prepareContextMenu(selection, for: EngineContextMenuElement(selectedText: "text"), panels: EngineTextMenuItems.Panels())
        #expect(selection.items.first?.identifier == EngineContextMenuItem.copy)
        #expect(selection.items.last?.identifier == EngineContextMenuItem.speech)
        #expect(recorder.elements.last?.isEditable == false)

        let unseen = menu([3, 8])
        tab.prepareContextMenu(unseen, for: EngineContextMenuElement())
        #expect(unseen.items.map(\.tag) == [3, 8])
        #expect(recorder.elements.count == 2)
    }

    /// The script reads the page's selection wherever the click is, as on a part of the page a click cannot select; the selection reaches the menu only where Chromium's would: in a field, with WebKit's Copy, which it shows for a click on the selection, and on a text link, whose text the right click selects.
    @Test func theSelectionReachesTheMenuOnlyWhenTheClickIsOnIt() throws {
        let copy = [item(8)]
        let stale = "quick brown fox"
        #expect(WebKitWebContents.selectionUnderClick(EngineContextMenuElement(selectedText: stale), keptItems: copy) == stale)
        #expect(WebKitWebContents.selectionUnderClick(EngineContextMenuElement(selectedText: stale), keptItems: []) == nil)
        #expect(WebKitWebContents.selectionUnderClick(EngineContextMenuElement(selectedText: "hello", isEditable: true), keptItems: []) == "hello")
        #expect(WebKitWebContents.selectionUnderClick(EngineContextMenuElement(linkURL: URL(string: "https://example.com/"), selectedText: "Next"), keptItems: []) == "Next")
        #expect(WebKitWebContents.selectionUnderClick(EngineContextMenuElement(imageURL: URL(string: "https://example.com/a.png"), selectedText: stale),
                                                      keptItems: []) == nil)
        #expect(WebKitWebContents.selectionUnderClick(EngineContextMenuElement(mediaURL: URL(string: "https://example.com/clip.mp4"), selectedText: stale),
                                                      keptItems: []) == nil)

        // WebKit's menu for a click away from the selection has Reload (12) and no Copy, so the menu keeps Back, Forward, and Reload.
        let folder = FileManager.default.temporaryDirectory
        let application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder)) as? WebKitApplication)
        let browser = application.createBrowser(context: application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent()))
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        let recorder = MenuRecorder()
        tab.uiDelegate = recorder
        let away = menu([12])
        tab.prepareContextMenu(away, for: EngineContextMenuElement(selectedText: stale), panels: EngineTextMenuItems.Panels())
        #expect(recorder.elements.last?.selectedText == nil)
        #expect(away.items.isEmpty)
    }

    /// The script counts a field as a password field while it is one or masks its text, and keeps counting one that was one when it got the focus or when the page changed its type, as a page does to show a password, as Chromium does.
    @Test func theScriptRemembersPasswordFields() async throws {
        let folder = FileManager.default.temporaryDirectory
        let application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder)) as? WebKitApplication)
        let browser = application.createBrowser(context: application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent()))
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        tab.webView.loadHTMLString("""
            <!doctype html><title>Test</title>
            <input id="password" type="password"><input id="shown" type="password"><input id="text">
            <input id="masked" style="-webkit-text-security: disc"><textarea id="notes"></textarea><div id="host"></div>
            <script>document.getElementById("host").attachShadow({ mode: "open" }).innerHTML = '<input type="password">';</script>
            """, baseURL: URL(string: "https://example.org/"))
        var isLoaded = false
        for _ in 0..<100 where !isLoaded {
            isLoaded = (try? await tab.webView.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('host')?.shadowRoot")) as? Bool == true
            if !isLoaded { try await Task.sleep(for: .milliseconds(100)) }
        }
        try #require(isLoaded)
        // The page shows one password by changing its field's type, which the observer reports before the next script runs. It shows the one in its shadow tree, which the observer does not watch, after the field had the focus.
        _ = try await tab.webView.callAsyncJavaScript("""
            document.getElementById('shown').type = 'text';
            const inner = document.getElementById('host').shadowRoot.querySelector('input');
            inner.dispatchEvent(new FocusEvent('focusin', { bubbles: true, composed: true }));
            inner.type = 'text';
            return true;
            """, contentWorld: .page)
        let found = try await tab.webView.callAsyncJavaScript("""
            const fields = ['password', 'shown', 'text', 'masked', 'notes'].map((id) => document.getElementById(id));
            return [...fields, document.getElementById('host').shadowRoot.querySelector('input')].map(archIsPasswordField);
            """, contentWorld: WebKitContextMenuScript.world) as? [Bool]
        #expect(found == [true, true, false, true, false, true])
    }

    /// WebKit's web view takes every standard action the text submenus send, as a text view does, so none of them drops out on WebKit, and it takes the `ignoreSpelling:` that Chromium's Ignore Spelling sends.
    @Test func theWebViewTakesTheTextSubmenusActions() {
        func titles(_ pageView: NSView) -> [String] {
            EngineTextMenuItems.items(for: EngineContextMenuElement(selectedText: "hello", isEditable: true), pageView: pageView, anchor: NSView(), at: .zero,
                                      panels: EngineTextMenuItems.Panels())
                .flatMap { [$0.title] + ($0.submenu?.items.map(\.title) ?? []) }
        }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #expect(titles(webView) == titles(NSTextView()))
        #expect(webView.responds(to: #selector(NSTextView.ignoreSpelling(_:))))
    }

    private final class MenuRecorder: EngineWebContentsUIDelegate {
        private(set) var elements: [EngineContextMenuElement] = []

        func webContents(_ webContents: any EngineWebContents, willShowContextMenuFor element: EngineContextMenuElement, menu: NSMenu) {
            elements.append(element)
        }
    }
}
