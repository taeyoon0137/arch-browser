// macOS's text items in the page context menu, which `EngineTextMenuItems` builds alike for both engines from its parts: which items an element gets, in WebKit's order and wording; the submenus of standard actions aimed at the page view, which leave out what the view does not take; the closure items; Share…'s contents; Replace with Translation in a field; and the translation popover's anchor. A text view stands in for the page view, since it takes every standard action the submenus send. No menu, panel, or popover opens.
import AppKit
import Testing
@testable import ARCHEngine

@MainActor @Suite struct EngineTextMenuItemsTests {
    private let link = URL(string: "https://example.com/next")!
    private let image = URL(string: "https://example.com/a.png")!
    private let video = URL(string: "https://example.com/clip.mp4")!

    /// Look Up, and Translate where macOS offers it.
    private var selectionItems: [NSUserInterfaceItemIdentifier] {
        if #available(macOS 14.4, *) { return [EngineContextMenuItem.lookUp, EngineContextMenuItem.translate] }
        return [EngineContextMenuItem.lookUp]
    }

    /// The text items for `element` with a text view as the page view, or with none when `hasPageView` is false.
    private func items(_ element: EngineContextMenuElement, hasPageView: Bool = true, panels: EngineTextMenuItems.Panels = .init()) -> [NSMenuItem] {
        EngineTextMenuItems.items(for: element, pageView: hasPageView ? NSTextView() : nil, anchor: NSView(), at: NSPoint(x: 10, y: 20), panels: panels)
    }

    private func identifiers(_ element: EngineContextMenuElement, hasPageView: Bool = true) -> [NSUserInterfaceItemIdentifier?] {
        items(element, hasPageView: hasPageView).map(\.identifier)
    }

    private func submenu(_ identifier: NSUserInterfaceItemIdentifier, of items: [NSMenuItem]) -> NSMenu? {
        items.first { $0.identifier == identifier }?.submenu
    }

    // MARK: Which items show

    @Test func aSelectionOutsideAFieldGetsLookUpTranslateShareAndSpeech() {
        #expect(identifiers(EngineContextMenuElement(selectedText: " quick brown fox\n")) == selectionItems + [EngineContextMenuItem.share, EngineContextMenuItem.speech])
        let titles = items(EngineContextMenuElement(selectedText: " quick brown fox\n")).map(\.title)
        #expect(titles.first == "Look Up “quick brown fox”")
        if #available(macOS 14.4, *) { #expect(titles[1] == "Translate “quick brown fox”") }
    }

    @Test func aFieldGetsItsSubmenusInWebKitsOrder() {
        let withSelection = EngineContextMenuElement(selectedText: "hello", isEditable: true)
        #expect(identifiers(withSelection) == selectionItems + [EngineContextMenuItem.spellingAndGrammar, EngineContextMenuItem.substitutions,
                                                                  EngineContextMenuItem.transformations, EngineContextMenuItem.speech, EngineContextMenuItem.share])
        // Without a selection there is nothing to transform or share, but Speech still speaks the field.
        #expect(identifiers(EngineContextMenuElement(isEditable: true)) == [EngineContextMenuItem.spellingAndGrammar, EngineContextMenuItem.substitutions,
                                                                             EngineContextMenuItem.speech])
    }

    /// As in WebKit's own menu, Transformations ▸ needs a letter with case, unless the selection is longer than WebKit reads for this.
    @Test func aSelectionWithoutCaseGetsNoTransformations() {
        let withoutCase = selectionItems + [EngineContextMenuItem.spellingAndGrammar, EngineContextMenuItem.substitutions, EngineContextMenuItem.speech,
                                            EngineContextMenuItem.share]
        #expect(identifiers(EngineContextMenuElement(selectedText: "안녕하세요", isEditable: true)) == withoutCase)
        #expect(identifiers(EngineContextMenuElement(selectedText: "2026", isEditable: true)) == withoutCase)
        #expect(identifiers(EngineContextMenuElement(selectedText: "안녕 Arch", isEditable: true)).contains(EngineContextMenuItem.transformations))
        #expect(identifiers(EngineContextMenuElement(selectedText: String(repeating: "7", count: 201), isEditable: true)).contains(EngineContextMenuItem.transformations))
        #expect(!identifiers(EngineContextMenuElement(selectedText: String(repeating: "7", count: 200), isEditable: true)).contains(EngineContextMenuItem.transformations))
    }

    @Test func aPasswordFieldGetsNoTextItems() {
        #expect(identifiers(EngineContextMenuElement(selectedText: "secret", isEditable: true, isPasswordField: true)).isEmpty)
        #expect(identifiers(EngineContextMenuElement(isEditable: true, isPasswordField: true)).isEmpty)
    }

    @Test func linksImagesAndMediaGetOnlyShare() {
        #expect(identifiers(EngineContextMenuElement(linkURL: link, selectedText: "Next page")) == [EngineContextMenuItem.share])
        #expect(identifiers(EngineContextMenuElement(imageURL: image)) == [EngineContextMenuItem.share])
        #expect(identifiers(EngineContextMenuElement(mediaURL: video)) == [EngineContextMenuItem.share])
        // A link for another app, or media the page plays from memory, has nothing to share.
        #expect(identifiers(EngineContextMenuElement(linkURL: URL(string: "mailto:someone@example.com"))).isEmpty)
        #expect(identifiers(EngineContextMenuElement(mediaURL: URL(string: "blob:https://example.com/1"))).isEmpty)
        #expect(identifiers(EngineContextMenuElement()).isEmpty)
    }

    @Test func withoutAPageViewThereAreNoSubmenus() {
        #expect(identifiers(EngineContextMenuElement(selectedText: "hello", isEditable: true), hasPageView: false) == selectionItems + [EngineContextMenuItem.share])
        #expect(identifiers(EngineContextMenuElement(selectedText: "fox"), hasPageView: false) == selectionItems + [EngineContextMenuItem.share])
    }

    @Test func theSelectionIsTrimmedAndNeverReadFromAPasswordFieldOrALink() {
        #expect(EngineTextMenuItems.selection(of: EngineContextMenuElement(selectedText: "  fox \n")) == "fox")
        #expect(EngineTextMenuItems.selection(of: EngineContextMenuElement(selectedText: " \n ")) == nil)
        #expect(EngineTextMenuItems.selection(of: EngineContextMenuElement(selectedText: "secret", isEditable: true, isPasswordField: true)) == nil)
        #expect(EngineTextMenuItems.selection(of: EngineContextMenuElement(linkURL: link, selectedText: "Next")) == nil)
        #expect(EngineTextMenuItems.selection(of: EngineContextMenuElement(imageURL: image, selectedText: "Next")) == nil)
        // In a field, a link's address does not hide the field's selection.
        #expect(EngineTextMenuItems.selection(of: EngineContextMenuElement(linkURL: link, selectedText: "Next", isEditable: true)) == "Next")
    }

    // MARK: Wording

    @Test func titlesQuoteTheSelectionOnOneLineAndCutItAfterTwentyFourCharacters() {
        #expect(EngineTextMenuItems.quoted("fox") == "“fox”")
        #expect(EngineTextMenuItems.quoted("  quick\n\nbrown\tfox ") == "“quick brown fox”")
        #expect(EngineTextMenuItems.quoted(String(repeating: "a", count: 24)) == "“\(String(repeating: "a", count: 24))”")
        #expect(EngineTextMenuItems.quoted(String(repeating: "a", count: 25)) == "“\(String(repeating: "a", count: 24))…”")
        // Characters count as the user sees them.
        #expect(EngineTextMenuItems.quoted(String(repeating: "👍🏽", count: 25)) == "“\(String(repeating: "👍🏽", count: 24))…”")
    }

    @Test func theSubmenusReadAsWebKitsAndShowOrHideThePanels() {
        let element = EngineContextMenuElement(selectedText: "hello", isEditable: true)
        func titles(_ identifier: NSUserInterfaceItemIdentifier, _ panels: EngineTextMenuItems.Panels = .init()) -> [String] {
            submenu(identifier, of: items(element, panels: panels))?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
        }
        #expect(titles(EngineContextMenuItem.spellingAndGrammar) == ["Show Spelling and Grammar", "Check Document Now", "—", "Check Spelling While Typing"])
        #expect(titles(EngineContextMenuItem.substitutions) == ["Show Substitutions", "—", "Smart Quotes", "Smart Dashes", "Text Replacement"])
        #expect(titles(EngineContextMenuItem.transformations) == ["Make Upper Case", "Make Lower Case", "Capitalize"])
        #expect(titles(EngineContextMenuItem.speech) == ["Start Speaking", "Stop Speaking"])
        let shown = EngineTextMenuItems.Panels(isSpellingVisible: true, isSubstitutionsVisible: true)
        #expect(titles(EngineContextMenuItem.spellingAndGrammar, shown).first == "Hide Spelling and Grammar")
        #expect(titles(EngineContextMenuItem.substitutions, shown).first == "Hide Substitutions")
        let parents = items(element).filter { $0.submenu != nil }
        #expect(parents.map(\.title) == ["Spelling and Grammar", "Substitutions", "Transformations", "Speech"])
        #expect(parents.allSatisfy { $0.isEnabled })
    }

    /// Showing a panel goes to the page view; hiding one sends `orderOut:` to the system's panel itself, which neither page view's action does. The panels are only named, never shown.
    @Test func thePanelItemsShowThroughThePageViewAndHideThroughThePanel() {
        let page = NSTextView()
        let element = EngineContextMenuElement(isEditable: true)
        let hidden = EngineTextMenuItems.items(for: element, pageView: page, anchor: NSView(), at: .zero, panels: .init())
        #expect(submenu(EngineContextMenuItem.spellingAndGrammar, of: hidden)?.items.first?.action == #selector(NSText.showGuessPanel(_:)))
        #expect(submenu(EngineContextMenuItem.substitutions, of: hidden)?.items.first?.action == #selector(NSTextView.orderFrontSubstitutionsPanel(_:)))
        #expect(submenu(EngineContextMenuItem.spellingAndGrammar, of: hidden)?.items.first?.target === page)
        let shown = EngineTextMenuItems.items(for: element, pageView: page, anchor: NSView(), at: .zero,
                                              panels: .init(isSpellingVisible: true, isSubstitutionsVisible: true))
        let hideSpelling = submenu(EngineContextMenuItem.spellingAndGrammar, of: shown)?.items.first
        let hideSubstitutions = submenu(EngineContextMenuItem.substitutions, of: shown)?.items.first
        #expect(hideSpelling?.action == #selector(NSWindow.orderOut(_:)))
        #expect(hideSpelling?.target === NSSpellChecker.shared.spellingPanel)
        #expect(hideSubstitutions?.action == #selector(NSWindow.orderOut(_:)))
        #expect(hideSubstitutions?.target === NSSpellChecker.shared.substitutionsPanel)
    }

    @Test func everySubmenuActionGoesToThePageView() {
        let page = NSTextView()
        let submenus = EngineTextMenuItems.items(for: EngineContextMenuElement(selectedText: "hello", isEditable: true), pageView: page, anchor: NSView(), at: .zero,
                                                 panels: .init()).compactMap(\.submenu)
        let actions = submenus.flatMap(\.items).filter { !$0.isSeparatorItem }
        #expect(actions.count == 12)
        #expect(actions.allSatisfy { $0.target === page && $0.action.map(page.responds(to:)) == true })
    }

    // MARK: Share…

    @Test func shareSharesAddressesThenTheSelection() {
        let both = EngineTextMenuItems.shareItems(for: EngineContextMenuElement(linkURL: link, imageURL: image, mediaURL: video, selectedText: " Next page "))
        #expect(both.compactMap { $0 as? URL } == [link, video, image])
        #expect(both.last as? String == "Next page")
        #expect(EngineTextMenuItems.shareItems(for: EngineContextMenuElement(selectedText: "secret", isEditable: true, isPasswordField: true)).isEmpty)
        #expect(EngineTextMenuItems.shareItems(for: EngineContextMenuElement(linkURL: URL(string: "javascript:void(0)"))).isEmpty)
        // Only web addresses are shared, so an image of a page opened from a file shares nothing.
        #expect(EngineTextMenuItems.shareItems(for: EngineContextMenuElement(imageURL: URL(string: "file:///Users/me/page/a.png"))).isEmpty)
        let share = items(EngineContextMenuElement(imageURL: image)).first
        #expect(share?.identifier == EngineContextMenuItem.share)
        #expect(share?.isEnabled == true)
    }

    // MARK: Parts

    @Test func aSubmenuLeavesOutTheActionsItsViewDoesNotTake() {
        let view = SpeakingView()
        let item = EngineStandardActionSubmenu.item("Speech", EngineContextMenuItem.speech, sendingTo: view, [
            .separator,
            .action("Start Speaking", #selector(NSTextView.startSpeaking(_:))),
            .separator,
            .separator,
            .action("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))),
            .separator,
        ])
        #expect(item?.identifier == EngineContextMenuItem.speech)
        #expect(item?.title == "Speech")
        #expect(item?.isEnabled == true)
        #expect(item?.submenu?.items.map(\.title) == ["Start Speaking"])
        #expect(item?.submenu?.items.first?.target === view)
        // A submenu whose view takes none of its actions is left out, even with an item of its own.
        #expect(EngineStandardActionSubmenu.item("Transformations", EngineContextMenuItem.transformations, sendingTo: NSView(), [
            .send("Hide", #selector(NSObject.copy), to: NSObject()),
            .action("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))),
        ]) == nil)
    }

    @Test func aSeparatorShowsOnlyBetweenItems() {
        let item = EngineStandardActionSubmenu.item("Speech", EngineContextMenuItem.speech, sendingTo: NSTextView(), [
            .separator,
            .action("Start Speaking", #selector(NSTextView.startSpeaking(_:))),
            .separator,
            .separator,
            .action("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))),
            .separator,
        ])
        #expect(item?.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } == ["Start Speaking", "—", "Stop Speaking"])
    }

    @Test func anActionItemRunsItsClosure() throws {
        var runs = 0
        let item = EngineActionMenuItem("Look Up") { runs += 1 }
        #expect(item.target === item)
        let action = try #require(item.action)
        _ = item.perform(action, with: item)
        #expect(runs == 1)
        #expect(item.isEnabled)
        #expect(!EngineActionMenuItem("Back", isEnabled: false) {}.isEnabled)
    }

    // MARK: Translate

    /// Replace with Translation shows in a field's popover, as in WebKit's own menu, and puts the translation in place of the field's selection through the page view's `insertText(_:)`.
    @Test func aFieldsTranslationReplacesItsSelectionThroughThePageView() throws {
        let page = InsertingView()
        let replace = try #require(EngineTextMenuItems.translationReplacement(for: EngineContextMenuElement(selectedText: "Hallo", isEditable: true), pageView: page))
        replace("Hello")
        #expect(page.inserted == ["Hello"])
        // Outside a field, in a password field, and without a page view, the popover offers no replacement.
        #expect(EngineTextMenuItems.translationReplacement(for: EngineContextMenuElement(selectedText: "Hallo"), pageView: page) == nil)
        #expect(EngineTextMenuItems.translationReplacement(for: EngineContextMenuElement(selectedText: "secret", isEditable: true, isPasswordField: true),
                                                           pageView: page) == nil)
        #expect(EngineTextMenuItems.translationReplacement(for: EngineContextMenuElement(selectedText: "Hallo", isEditable: true), pageView: nil) == nil)
    }

    @Test func theTranslationAnchorIsOnePointAtTheClick() {
        guard #available(macOS 14.4, *) else { return }
        let anchor = EngineTranslationPopover.anchor(for: "fox", at: NSPoint(x: 12, y: 34))
        #expect(anchor.frame == NSRect(x: 12, y: 34, width: 1, height: 1))
        #expect(EngineTranslationPopover.anchor(for: "fox", at: NSPoint(x: 12, y: 34)) { _ in }.frame == anchor.frame)
        // Without a window the popover has nowhere to show, so nothing is added to the view.
        let view = NSView()
        EngineTranslationPopover.show("fox", at: .zero, in: view)
        #expect(view.subviews.isEmpty)
    }
}

/// A page view that takes only Start Speaking.
private final class SpeakingView: NSView {
    @objc func startSpeaking(_ sender: Any?) {}
}

/// A page view that records the text it is given to insert.
private final class InsertingView: NSView {
    private(set) var inserted: [String] = []

    override func insertText(_ insertString: Any) {
        inserted.append(insertString as? String ?? "")
    }
}
