// The tab places the items an engine hands it in the page context menu in the order of WebKit's own menu, the same on both engines: spelling suggestions, Ignore and Learn Spelling, the link and image items, Look Up and Translate, Search with, editing or Copy, the field's text submenus, and Share… with Speech outside a field, separated by lines; Back, Forward, and Reload only when nothing else applies. The engine's own items take the tab's titles, and macOS's text items keep theirs. The preview panel places the same items in the same sections, without the tab's own. The tests hand the tab and the preview the items an adapter would and open no menu.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct PageContextMenuTests {
    private func tab() -> Tab {
        Tab(id: UUID(), webContents: UnloadedWebContents(url: URL(string: "https://example.com/"), title: "", engine: .webKit, state: nil), spaceID: nil,
            isPinned: false, personaID: UUID())
    }

    /// The menu an adapter hands the tab for `element`: the engine's own items, titled by their WebCore tags as WebKit's are, then macOS's text items.
    private func handedMenu(_ engineItems: [NSUserInterfaceItemIdentifier], for element: EngineContextMenuElement) -> NSMenu {
        let menu = NSMenu()
        for (index, identifier) in engineItems.enumerated() {
            let item = NSMenuItem(title: "\(index)", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            item.identifier = identifier
            menu.addItem(item)
        }
        EngineTextMenuItems.items(for: element, pageView: NSTextView(), anchor: NSView(), at: .zero, panels: .init()).forEach(menu.addItem)
        return menu
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private func shareTitle(_ menu: NSMenu) throws -> String {
        try #require(menu.items.first { $0.identifier == EngineContextMenuItem.share }).title
    }

    /// Translate “…”, where macOS offers it.
    private func translate(_ quoted: String) -> [String] {
        if #available(macOS 14.4, *) { return ["Translate \(quoted)"] }
        return []
    }

    private let search = "Search with \(SearchEngine.current.title)"

    @Test func aMisspelledWordInAFieldGetsWebKitsOrder() throws {
        let tab = tab()
        tab.searchInNewTab = { _ in }
        let element = EngineContextMenuElement(selectedText: "mispeled", isEditable: true)
        let menu = handedMenu([EngineContextMenuItem.spellingSuggestion, EngineContextMenuItem.ignoreSpelling, EngineContextMenuItem.learnSpelling,
                               EngineContextMenuItem.cut, EngineContextMenuItem.copy, EngineContextMenuItem.paste, EngineContextMenuItem.selectAll], for: element)
        let share = try shareTitle(menu)
        tab.webContents(tab.webContents, willShowContextMenuFor: element, menu: menu)
        #expect(titles(menu) == ["0", "—", "Ignore Spelling", "Learn Spelling", "—", "Look Up “mispeled”"] + translate("“mispeled”") + ["—", search, "—",
                                 "Cut", "Copy", "Paste", "Select All", "—", "Spelling and Grammar", "Substitutions", "Transformations", "Speech", "—", share])
        #expect(!menu.autoenablesItems)
    }

    /// In a field, as in a message being written, WebKit puts a link's items before the selection's.
    @Test func aLinkInAFieldComesBeforeTheSelectionsItems() throws {
        let tab = tab()
        tab.searchInNewTab = { _ in }
        let element = EngineContextMenuElement(linkURL: URL(string: "https://example.com/next"), selectedText: "Next page", isEditable: true)
        let menu = handedMenu([EngineContextMenuItem.cut, EngineContextMenuItem.copy, EngineContextMenuItem.paste, EngineContextMenuItem.selectAll], for: element)
        let share = try shareTitle(menu)
        tab.webContents(tab.webContents, willShowContextMenuFor: element, menu: menu)
        #expect(titles(menu) == ["Open Link in New Tab", "Download Linked File", "Copy Link", "—", "Look Up “Next page”"] + translate("“Next page”") + ["—", search, "—",
                                 "Cut", "Copy", "Paste", "Select All", "—", "Spelling and Grammar", "Substitutions", "Transformations", "Speech", "—", share])
    }

    @Test func thePreviewPlacesTheHandedItemsAsTheTabDoesWithoutTheTabsOwn() throws {
        let contents = UnloadedWebContents(url: URL(string: "https://example.com/"), title: "", engine: .webKit, state: nil)
        let preview = PagePreview(webContents: contents, personaID: UUID(), requestedEngine: contents.engineKind, openedURL: URL(string: "https://example.com/")!)
        let element = EngineContextMenuElement(selectedText: "mispeled", isEditable: true)
        let menu = handedMenu([EngineContextMenuItem.spellingSuggestion, EngineContextMenuItem.ignoreSpelling, EngineContextMenuItem.learnSpelling,
                               EngineContextMenuItem.cut, EngineContextMenuItem.copy, EngineContextMenuItem.paste, EngineContextMenuItem.selectAll], for: element)
        let share = try shareTitle(menu)
        preview.webContents(contents, willShowContextMenuFor: element, menu: menu)
        #expect(titles(menu) == ["0", "—", "Ignore Spelling", "Learn Spelling", "—", "Look Up “mispeled”"] + translate("“mispeled”") + ["—",
                                 "Cut", "Copy", "Paste", "Select All", "—", "Spelling and Grammar", "Substitutions", "Transformations", "Speech", "—", share])
        #expect(!menu.autoenablesItems)
        // A link shows only Share…, and the page background nothing, since Open Link in New Tab, Back, Forward, and Reload belong to a tab.
        let link = EngineContextMenuElement(linkURL: URL(string: "https://example.com/next"), selectedText: "Next page")
        let linkMenu = handedMenu([], for: link)
        preview.webContents(contents, willShowContextMenuFor: link, menu: linkMenu)
        #expect(titles(linkMenu) == [share])
        let background = handedMenu([], for: EngineContextMenuElement())
        preview.webContents(contents, willShowContextMenuFor: EngineContextMenuElement(), menu: background)
        #expect(background.items.isEmpty)
    }

    @Test func aSelectionOutsideAFieldPutsSpeechAfterShare() throws {
        let tab = tab()
        tab.searchInNewTab = { _ in }
        let element = EngineContextMenuElement(selectedText: "quick brown fox")
        let menu = handedMenu([EngineContextMenuItem.copy], for: element)
        let share = try shareTitle(menu)
        tab.webContents(tab.webContents, willShowContextMenuFor: element, menu: menu)
        #expect(titles(menu) == ["Look Up “quick brown fox”"] + translate("“quick brown fox”") + ["—", search, "—", "Copy", "—", share, "Speech"])
    }

    @Test func searchWithSearchesTheTrimmedSelection() throws {
        let tab = tab()
        var searched: [String] = []
        tab.searchInNewTab = { searched.append($0) }
        let element = EngineContextMenuElement(selectedText: "  quick brown fox\n")
        let menu = handedMenu([EngineContextMenuItem.copy], for: element)
        tab.webContents(tab.webContents, willShowContextMenuFor: element, menu: menu)
        let item = try #require(menu.items.first { $0.title == search })
        let action = try #require(item.action)
        _ = (item.target as AnyObject).perform(action, with: item)
        #expect(searched == ["quick brown fox"])
        // A link's selected text is not searched, as on WebKit, and without the session's callback there is no Search with.
        let link = EngineContextMenuElement(linkURL: URL(string: "https://example.com/next"), selectedText: "Next page")
        let linkMenu = handedMenu([], for: link)
        tab.webContents(tab.webContents, willShowContextMenuFor: link, menu: linkMenu)
        #expect(!titles(linkMenu).contains(search))
        let unwired = self.tab()
        let plain = handedMenu([EngineContextMenuItem.copy], for: element)
        unwired.webContents(unwired.webContents, willShowContextMenuFor: element, menu: plain)
        #expect(!titles(plain).contains(search))
    }

    @Test func aLinkImageOrVideoEndsWithShare() throws {
        let tab = tab()
        let link = EngineContextMenuElement(linkURL: URL(string: "https://example.com/next"), selectedText: "Next page")
        let linkMenu = handedMenu([], for: link)
        let share = try shareTitle(linkMenu)
        tab.webContents(tab.webContents, willShowContextMenuFor: link, menu: linkMenu)
        #expect(titles(linkMenu) == ["Open Link in New Tab", "Download Linked File", "Copy Link", "—", share])
        // A video has only Share…, so Back, Forward, and Reload stay out.
        let video = EngineContextMenuElement(mediaURL: URL(string: "https://example.com/clip.mp4"))
        let videoMenu = handedMenu([], for: video)
        tab.webContents(tab.webContents, willShowContextMenuFor: video, menu: videoMenu)
        #expect(titles(videoMenu) == [share])
    }

    @Test func thePageBackgroundAndAPasswordFieldKeepTheirMenus() {
        let tab = tab()
        let background = handedMenu([], for: EngineContextMenuElement())
        tab.webContents(tab.webContents, willShowContextMenuFor: EngineContextMenuElement(), menu: background)
        #expect(titles(background) == ["Back", "Forward", "Reload"])
        let password = EngineContextMenuElement(selectedText: "secret", isEditable: true, isPasswordField: true)
        let field = handedMenu([EngineContextMenuItem.cut, EngineContextMenuItem.copy, EngineContextMenuItem.paste, EngineContextMenuItem.selectAll], for: password)
        tab.webContents(tab.webContents, willShowContextMenuFor: password, menu: field)
        #expect(titles(field) == ["Cut", "Copy", "Paste", "Select All"])
    }
}
