// One page context menu on both engines (docs/features.md row 49). In each situation, the Chromium adapter hands the tab the same items, in the same order and with the same enabled state, as the WebKit adapter keeps from the menu WebKit builds, so the tab builds the same menu on both, except for a difference row 49 lists. Nine of WebKit's menus are those the context menu prototype recorded on macOS 27.2, by WebCore tag; the rest, marked `recorded: false`, are assumed from those records and WebCore's rules. The prototype recorded no CEF parameters, so each situation's Chromium input is what Blink's source reports there: the selection from `SelectionController::UpdateSelectionForContextMenuEvent`, and the edit commands from `ComputeEditFlags` in `context_menu_controller.cc`, which takes Cut, Copy, and Paste from the editor's `CanCut`, `CanCopy`, and `CanPaste` and Select All from `EnabledSelectAll` in `editor_command.cc`. AppKit's own items (AutoFill, Services, Writing Tools) never enter a menu's items; the table names the view AppKit is asked about on Chromium, and the running app shows the items (the page context menu check in `docs/plan.md` Regression checks).
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

    /// The view AppKit is asked about on Chromium: the page's text input view, the clicked link, or the container, which offers nothing.
    enum Asked {
        case page, link, container
    }

    struct Situation {
        var name: String
        var webKit: [WebKitEntry]
        /// Whether `webKit` is the prototype's record rather than assumed.
        var recorded = true
        /// What WebKit's script and CEF report, except that WebKit learns that the menu is in a field from its Paste item.
        var element = EngineContextMenuElement()
        var isEditable = false
        var misspelledWord = ""
        var suggestions: [String] = []
        /// What CEF reports, from Blink's source.
        var editCommands: ARCHCEFEditCommand = []
        /// What CEF reports where Blink selects otherwise than WebKit.
        var chromiumElement: EngineContextMenuElement?
        var items: [NSUserInterfaceItemIdentifier]
        var enabled: [Bool]
        /// Chromium's enabled state where it differs from WebKit's, as row 49 lists.
        var chromiumEnabled: [Bool]?
        var asks = Asked.container
        /// Whether Chromium's page view has no text input context there, as in a password field.
        var isPasswordField = false
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
    /// WebKit's menu in a password field, where WebKit leaves out the text items and keeps the editing items of any field, with Cut and Copy off.
    private static let passwordField: [WebKitEntry] = [.item(13, enabled: false), .item(8, enabled: false), .item(14)]
    private static let allCommands: ARCHCEFEditCommand = [.cut, .copy, .paste, .selectAll]

    static let situations: [Situation] = [
        // Without a selection, Select All is enabled, but it shows only in a field.
        Situation(name: "page background", webKit: [.item(12)], editCommands: [.selectAll], items: [], enabled: []),
        // A right click inside a selection keeps it. WebKit's view offers no Services for it.
        Situation(name: "selected text outside fields", webKit: textItems + [.item(8), .item(102, enabled: false), .separator, .share, .submenu([49, 50])],
                  element: EngineContextMenuElement(selectedText: "quick brown fox"), editCommands: [.copy, .selectAll],
                  items: [EngineContextMenuItem.copy], enabled: [true]),
        // Blink's Select All is off in a field without text; the adapters enable it in any field.
        Situation(name: "empty field", webKit: [.item(13, enabled: false), .item(8, enabled: false), .item(14), .separator,
                                                .submenu([36, 37, 38, 39, 62]), .submenu([64, 65, 66, 67, 68, 69]), .submenu([41, 42, 43, 44, 45, 46, 47]),
                                                .submenu([49, 50]), .submenu([52, 53, 54])],
                  isEditable: true, editCommands: [.paste], items: fieldItems, enabled: [false, false, true, true], asks: .page),
        // A right click past a field's text, where its caret is, selects the word before it on WebKit; Blink keeps the caret when the click lands on it.
        Situation(name: "field with a caret", webKit: textItems + [.item(13), .item(8), .item(14)] + fieldSubmenus + [.separator, .share],
                  element: EngineContextMenuElement(selectedText: "world"), isEditable: true, editCommands: [.paste, .selectAll],
                  chromiumElement: EngineContextMenuElement(), items: fieldItems, enabled: [true, true, true, true],
                  chromiumEnabled: [false, false, true, true], asks: .page),
        Situation(name: "field with a selection", webKit: textItems + [.item(13), .item(8), .item(14)] + fieldSubmenus + [.separator, .share],
                  element: EngineContextMenuElement(selectedText: "hello"), isEditable: true, editCommands: allCommands,
                  items: fieldItems, enabled: [true, true, true, true], asks: .page),
        // Both engines select the misspelled word first.
        Situation(name: "misspelled word", webKit: [.item(15), .separator, .item(17), .item(18), .separator] + textItems + [.item(13), .item(8), .item(14)]
                    + fieldSubmenus + [.separator, .share],
                  element: EngineContextMenuElement(selectedText: "mispeled"), isEditable: true, misspelledWord: "mispeled", suggestions: ["misspelled"],
                  editCommands: allCommands, items: [EngineContextMenuItem.spellingSuggestion] + fieldItems,
                  enabled: [true, true, true, true, true], asks: .page),
        // The misspelled word's record with No Guesses Found (16) in place of the suggestion.
        Situation(name: "misspelled word without guesses", webKit: [.item(16, enabled: false), .separator, .item(17), .item(18), .separator] + textItems
                    + [.item(13), .item(8), .item(14)] + fieldSubmenus + [.separator, .share], recorded: false,
                  element: EngineContextMenuElement(selectedText: "qzxv"), isEditable: true, misspelledWord: "qzxv", editCommands: allCommands,
                  items: [EngineContextMenuItem.noSpellingSuggestions] + fieldItems, enabled: [false, true, true, true, true], asks: .page),
        // The prototype opened no password field. Blink, like WebKit, copies and cuts nothing from a password field.
        Situation(name: "password field", webKit: passwordField, recorded: false, isEditable: true, editCommands: [.paste], items: fieldItems,
                  enabled: [false, false, true, true], isPasswordField: true),
        Situation(name: "password field with a selection", webKit: passwordField, recorded: false, element: EngineContextMenuElement(selectedText: "secret"),
                  isEditable: true, editCommands: [.paste, .selectAll], items: fieldItems, enabled: [false, false, true, true], isPasswordField: true),
        // A right click on a text link selects the link's text on both engines.
        Situation(name: "link", webKit: [.item(33), .item(1), .item(2), .item(3), .separator, .share],
                  element: EngineContextMenuElement(linkURL: link, selectedText: "Next page"), editCommands: [.copy, .selectAll], items: [], enabled: [],
                  asks: .link),
        Situation(name: "image", webKit: [.item(4), .item(5, enabled: false), .item(6), .item(97, enabled: false), .item(94, enabled: false), .separator, .share],
                  element: EngineContextMenuElement(imageURL: image), editCommands: [.selectAll], items: [], enabled: []),
        // The link's and the image's records together. Neither engine selects anything above an image.
        Situation(name: "link around an image", webKit: [.item(33), .item(1), .item(2), .item(3), .separator, .item(4), .item(5), .item(6), .separator, .share],
                  recorded: false, element: EngineContextMenuElement(linkURL: link, imageURL: image), editCommands: [.selectAll], items: [], enabled: [],
                  asks: .link),
        Situation(name: "video", webKit: [.item(81), .item(82), .item(78), .item(79), .item(88), .item(90, enabled: false), .item(91), .separator,
                                          .item(77), .item(75), .item(76, enabled: false), .separator, .share],
                  element: EngineContextMenuElement(mediaURL: video), editCommands: [.selectAll], items: [], enabled: []),
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
    /// Chromium's page view in a password field, which has no text input context there.
    private final class PasswordFieldView: NSTextView {
        override var inputContext: NSTextInputContext? { nil }
    }

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

        var element = situation.chromiumElement ?? situation.element
        element.isEditable = situation.isEditable
        let chromium = ChromiumWebContents.engineMenuItems(misspelledWord: situation.misspelledWord, suggestions: situation.suggestions, element: element,
                                                           editCommands: situation.editCommands)
        #expect(chromium.map(\.identifier) == situation.items)
        #expect(chromium.map(\.isEnabled) == (situation.chromiumEnabled ?? situation.enabled))

        let page = situation.isPasswordField ? PasswordFieldView() : NSTextView()
        let subject = EngineContextMenuPresenter.subject(for: element, textInputView: page)
        switch situation.asks {
        case .page: #expect(subject == .textInput(page))
        case .link: #expect(subject == .link(Parity.link))
        case .container: #expect(subject == .container)
        }
    }

    /// What each of Chromium's items runs: a suggestion replaces the word with its title, and an editing item runs its command.
    @Test func chromiumsItemsCarryWhatTheyRun() {
        let items = ChromiumWebContents.engineMenuItems(misspelledWord: "mispeled", suggestions: ["misspelled", "dispelled"],
                                                        element: EngineContextMenuElement(isEditable: true), editCommands: [.cut, .copy, .paste, .selectAll])
        #expect(items.map(\.title) == ["misspelled", "dispelled", "Cut", "Copy", "Paste", "Select All"])
        #expect(items.prefix(2).map { $0.representedObject as? String } == ["misspelled", "dispelled"])
        #expect(items.dropFirst(2).map(\.tag) == [ARCHCEFEditCommand.cut, .copy, .paste, .selectAll].map { Int($0.rawValue) })
        #expect(items.allSatisfy { $0.target == nil && $0.action != nil })
    }

    /// Outside a field, Copy shows only for a selection that is not on a link, image, or media, as on WebKit.
    @Test func copyOutsideAFieldNeedsASelectionOffLinksAndMedia() {
        func items(_ element: EngineContextMenuElement) -> [NSUserInterfaceItemIdentifier?] {
            ChromiumWebContents.engineMenuItems(misspelledWord: "", suggestions: [], element: element, editCommands: [.copy, .selectAll]).map(\.identifier)
        }
        #expect(items(EngineContextMenuElement(selectedText: "text")) == [EngineContextMenuItem.copy])
        #expect(items(EngineContextMenuElement()).isEmpty)
        #expect(items(EngineContextMenuElement(linkURL: Parity.link, selectedText: "text")).isEmpty)
        #expect(items(EngineContextMenuElement(imageURL: Parity.image, selectedText: "text")).isEmpty)
        #expect(items(EngineContextMenuElement(mediaURL: Parity.video, selectedText: "text")).isEmpty)
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
