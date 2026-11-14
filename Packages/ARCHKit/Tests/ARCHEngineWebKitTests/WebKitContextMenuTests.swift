// Which of WebKit's context menu items the app's menu keeps: WebKit's own editing and spelling items, matched by tag, in WebKit's order, with their roles and Select All beside Paste, followed by macOS's text items, which the adapter aims at the web view. WebKit's menu stays as it is when it has none of WebKit's own items, holds items a page element provides, or shows a link or image that the script could not see. The tests build WebKit's menus by hand and load no page.
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
