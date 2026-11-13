// Which of WebKit's context menu items the app's menu keeps: WebKit's own editing and spelling items, matched by tag, in WebKit's order, with their roles and Select All beside Paste. WebKit's menu stays as it is when it has none of WebKit's own items, holds items a page element provides, or shows a link or image that the script could not see. The tests build WebKit's menus by hand and load no page.
import AppKit
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing

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
        // Open Link, Copy Link, Copy, a spelling guess, Ignore Spelling, Cut, Paste, and Look Up, then an item of another app with Copy's tag.
        let menu = menu([1, 3, 8, 15, 17, 13, 14, 22])
        menu.addItem(item(8, action: #selector(NSText.copy(_:))))
        let kept = WebKitWebContents.keptContextMenuItems(of: menu, for: link)
        #expect(kept?.map(\.tag) == [8, 15, 13, 14])
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
        tab.prepareContextMenu(editable, for: EngineContextMenuElement(selectedText: "text"))
        #expect(editable.items.map(\.identifier) == [EngineContextMenuItem.cut, EngineContextMenuItem.copy, EngineContextMenuItem.paste, EngineContextMenuItem.selectAll])
        #expect(editable.items.allSatisfy { $0.image == nil })
        #expect(recorder.elements.last?.isEditable == true)
        #expect(recorder.elements.last?.selectedText == "text")

        let selection = menu([8, 22])
        tab.prepareContextMenu(selection, for: EngineContextMenuElement(selectedText: "text"))
        #expect(selection.items.map(\.identifier) == [EngineContextMenuItem.copy])
        #expect(recorder.elements.last?.isEditable == false)

        let unseen = menu([3, 8])
        tab.prepareContextMenu(unseen, for: EngineContextMenuElement())
        #expect(unseen.items.map(\.tag) == [3, 8])
        #expect(recorder.elements.count == 2)
    }

    private final class MenuRecorder: EngineWebContentsUIDelegate {
        private(set) var elements: [EngineContextMenuElement] = []

        func webContents(_ webContents: any EngineWebContents, willShowContextMenuFor element: EngineContextMenuElement, menu: NSMenu) {
            elements.append(element)
        }
    }
}
