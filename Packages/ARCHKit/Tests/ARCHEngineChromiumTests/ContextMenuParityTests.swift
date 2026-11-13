// One page context menu on both engines (docs/features.md row 49). In each situation, the Chromium adapter hands the tab the same items, in the same order and with the same enabled state, as the WebKit adapter keeps from the menu WebKit builds, so the tab builds the same menu on both. The WebKit menus are those the context menu prototype recorded on macOS 27.2, by WebCore tag. AppKit's own items (Siri, AutoFill, Services, Writing Tools) never enter a menu's items; the table names the view AppKit is asked about on Chromium, and the running app shows the items (regression check 60).
import AppKit
import ARCHEngine
import CEFBridge
import Foundation
import Testing
@testable import ARCHEngineChromium
@testable import ARCHEngineWebKit

/// The situations, outside the main actor so that the test's arguments can name them.
private enum Parity {
    /// One entry of a menu WebKit builds: an item WebKit runs, by WebCore tag, Share, a submenu of items WebKit runs, or a separator.
    enum WebKitEntry {
        case item(Int, enabled: Bool = true)
        case share
        case submenu([Int])
        case separator
    }

    struct Situation {
        var name: String
        var webKit: [WebKitEntry]
        /// What WebKit's script and CEF report, except that WebKit learns that the menu is in a field from its Paste item.
        var element = EngineContextMenuElement()
        var isEditable = false
        var misspelledWord = ""
        var suggestions: [String] = []
        var editCommands: ARCHCEFEditCommand = []
        var items: [NSUserInterfaceItemIdentifier]
        var enabled: [Bool]
        /// Whether AppKit is asked about the link rather than the page's text input view.
        var asksAboutLink = false
    }

    static let link = URL(string: "https://example.com/next")!
    static let image = URL(string: "https://example.com/a.png")!
    static let video = URL(string: "https://example.com/clip.mp4")!
    static let fieldItems = [EngineContextMenuItem.cut, EngineContextMenuItem.copy, EngineContextMenuItem.paste, EngineContextMenuItem.selectAll]
    /// The submenus WebKit adds in a field with text: Spelling and Grammar, Substitutions, Transformations, Font, Speech, and Paragraph and Selection Direction.
    private static let fieldSubmenus: [WebKitEntry] = [
        .separator, .submenu([36, 37, 38, 39, 62]), .submenu([64, 65, 66, 67, 68, 69]), .submenu([71, 72, 73]), .submenu([41, 42, 43, 44, 45, 46, 47]),
        .submenu([49, 50]), .submenu([52, 53, 54]), .submenu([59, 60, 61]),
    ]
    /// Look Up, Translate, and Search with, which WebKit puts first for a selected word.
    private static let textItems: [WebKitEntry] = [.item(22), .item(95), .separator, .item(21), .separator]

    static let situations: [Situation] = [
        Situation(name: "page background", webKit: [.item(12)], items: [], enabled: []),
        Situation(name: "selected text outside fields", webKit: textItems + [.item(8), .item(102, enabled: false), .separator, .share, .submenu([49, 50])],
                  element: EngineContextMenuElement(selectedText: "quick brown fox"), editCommands: [.copy, .selectAll],
                  items: [EngineContextMenuItem.copy], enabled: [true]),
        Situation(name: "empty field", webKit: [.item(13, enabled: false), .item(8, enabled: false), .item(14), .separator,
                                                .submenu([36, 37, 38, 39, 62]), .submenu([64, 65, 66, 67, 68, 69]), .submenu([41, 42, 43, 44, 45, 46, 47]),
                                                .submenu([49, 50]), .submenu([52, 53, 54])],
                  isEditable: true, editCommands: [.paste, .selectAll], items: fieldItems, enabled: [false, false, true, true]),
        // A right click past a field's text selects the word before it, as it does on both engines.
        Situation(name: "field with a caret", webKit: textItems + [.item(13), .item(8), .item(14)] + fieldSubmenus + [.separator, .share],
                  element: EngineContextMenuElement(selectedText: "world"), isEditable: true, editCommands: [.cut, .copy, .paste, .selectAll],
                  items: fieldItems, enabled: [true, true, true, true]),
        Situation(name: "field with a selection", webKit: textItems + [.item(13), .item(8), .item(14)] + fieldSubmenus + [.separator, .share],
                  element: EngineContextMenuElement(selectedText: "hello"), isEditable: true, editCommands: [.cut, .copy, .paste, .selectAll],
                  items: fieldItems, enabled: [true, true, true, true]),
        Situation(name: "misspelled word", webKit: [.item(15), .separator, .item(17), .item(18), .separator] + textItems + [.item(13), .item(8), .item(14)]
                    + fieldSubmenus + [.separator, .share],
                  element: EngineContextMenuElement(selectedText: "mispeled"), isEditable: true, misspelledWord: "mispeled", suggestions: ["misspelled"],
                  editCommands: [.cut, .copy, .paste, .selectAll], items: [EngineContextMenuItem.spellingSuggestion] + fieldItems,
                  enabled: [true, true, true, true, true]),
        Situation(name: "misspelled word without guesses", webKit: [.item(16, enabled: false), .separator, .item(17), .item(18), .separator] + textItems
                    + [.item(13), .item(8), .item(14)] + fieldSubmenus + [.separator, .share],
                  element: EngineContextMenuElement(selectedText: "qzxv"), isEditable: true, misspelledWord: "qzxv", editCommands: [.cut, .copy, .paste, .selectAll],
                  items: [EngineContextMenuItem.noSpellingSuggestions] + fieldItems, enabled: [false, true, true, true, true]),
        // The prototype opened no password field. WebKit leaves out the text items there and keeps the editing items of any field.
        Situation(name: "password field", webKit: [.item(13, enabled: false), .item(8, enabled: false), .item(14)],
                  isEditable: true, editCommands: [.paste, .selectAll], items: fieldItems, enabled: [false, false, true, true]),
        Situation(name: "link", webKit: [.item(33), .item(1), .item(2), .item(3), .separator, .share],
                  element: EngineContextMenuElement(linkURL: link), items: [], enabled: [], asksAboutLink: true),
        Situation(name: "image", webKit: [.item(4), .item(5, enabled: false), .item(6), .item(97, enabled: false), .item(94, enabled: false), .separator, .share],
                  element: EngineContextMenuElement(imageURL: image), items: [], enabled: []),
        Situation(name: "link around an image", webKit: [.item(33), .item(1), .item(2), .item(3), .separator, .item(4), .item(5), .item(6), .separator, .share],
                  element: EngineContextMenuElement(linkURL: link, imageURL: image), items: [], enabled: [], asksAboutLink: true),
        Situation(name: "video", webKit: [.item(81), .item(82), .item(78), .item(79), .item(88), .item(90, enabled: false), .item(91), .separator,
                                          .item(77), .item(75), .item(76, enabled: false), .separator, .share],
                  element: EngineContextMenuElement(mediaURL: video), items: [], enabled: []),
    ]

    static let forward = Selector(("forwardContextMenuAction:"))

    @MainActor static func webKitMenu(_ entries: [WebKitEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ tag: Int, enabled: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: "\(tag)", action: forward, keyEquivalent: "")
            item.tag = tag
            item.isEnabled = enabled
            return item
        }
        for entry in entries {
            switch entry {
            case let .item(tag, enabled): menu.addItem(item(tag, enabled: enabled))
            case .share: menu.addItem(NSMenuItem(title: "Share…", action: Selector(("performShare:")), keyEquivalent: ""))
            case let .submenu(tags):
                let parent = NSMenuItem(title: "Submenu", action: nil, keyEquivalent: "")
                parent.submenu = NSMenu()
                tags.forEach { parent.submenu?.addItem(item($0, enabled: true)) }
                menu.addItem(parent)
            case .separator: menu.addItem(.separator())
            }
        }
        return menu
    }
}

@MainActor @Suite struct ContextMenuParityTests {
    private func webKitContents() throws -> WebKitWebContents {
        let folder = FileManager.default.temporaryDirectory
        let application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder))
            as? WebKitApplication)
        let browser = application.createBrowser(context: application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent()))
        return try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
    }

    @Test(arguments: Parity.situations.map(\.name))
    func bothEnginesHandTheTabTheSameItems(_ name: String) throws {
        let situation = try #require(Parity.situations.first { $0.name == name })
        let contents = try webKitContents()
        let recorder = MenuRecorder()
        contents.uiDelegate = recorder
        contents.prepareContextMenu(Parity.webKitMenu(situation.webKit), for: situation.element)
        let webKit = try #require(recorder.menus.last)
        #expect(webKit.items == situation.items)
        #expect(webKit.enabled == situation.enabled)
        #expect(webKit.isEditable == situation.isEditable)

        let chromium = ChromiumWebContents.engineMenuItems(misspelledWord: situation.misspelledWord, suggestions: situation.suggestions,
                                                           isEditable: situation.isEditable, selectionText: situation.element.selectedText ?? "",
                                                           editCommands: situation.editCommands)
        #expect(chromium.map(\.identifier) == situation.items)
        #expect(chromium.map(\.isEnabled) == situation.enabled)

        var element = situation.element
        element.isEditable = situation.isEditable
        let page = NSTextView()
        let subject = EngineContextMenuPresenter.subject(for: element, textInputView: page)
        #expect(subject == (situation.asksAboutLink ? .link(Parity.link) : .textInput(page)))
    }

    /// What each of Chromium's items runs: a suggestion replaces the word with its title, and an editing item runs its command.
    @Test func chromiumsItemsCarryWhatTheyRun() {
        let items = ChromiumWebContents.engineMenuItems(misspelledWord: "mispeled", suggestions: ["misspelled", "dispelled"], isEditable: true, selectionText: "",
                                                        editCommands: [.cut, .copy, .paste, .selectAll])
        #expect(items.map(\.title) == ["misspelled", "dispelled", "Cut", "Copy", "Paste", "Select All"])
        #expect(items.prefix(2).map { $0.representedObject as? String } == ["misspelled", "dispelled"])
        #expect(items.dropFirst(2).map(\.tag) == [ARCHCEFEditCommand.cut, .copy, .paste, .selectAll].map { Int($0.rawValue) })
        #expect(items.allSatisfy { $0.target == nil && $0.action != nil })
        // Outside a field, Copy shows only with a selection.
        #expect(ChromiumWebContents.engineMenuItems(misspelledWord: "", suggestions: [], isEditable: false, selectionText: "", editCommands: [.copy]).isEmpty)
    }

    private final class MenuRecorder: EngineWebContentsUIDelegate {
        struct Menu {
            var items: [NSUserInterfaceItemIdentifier?]
            var enabled: [Bool]
            var isEditable: Bool
        }

        private(set) var menus: [Menu] = []

        func webContents(_ webContents: any EngineWebContents, willShowContextMenuFor element: EngineContextMenuElement, menu: NSMenu) {
            menus.append(Menu(items: menu.items.map(\.identifier), enabled: menu.items.map(\.isEnabled), isEditable: element.isEditable))
        }
    }
}
