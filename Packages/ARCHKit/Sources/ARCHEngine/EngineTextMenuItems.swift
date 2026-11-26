// macOS's text items in the page context menu, built once for both engines so that both menus hold the same items (docs/features.md row 49): Look Up “…” and Translate “…” for a selection, the Spelling and Grammar, Substitutions, Transformations, and Speech submenus, and Share…, in the order and wording of WebKit's own menu. The submenus send AppKit's standard actions to the engine's page view, through `EngineStandardActionSubmenu`. Each action is one that both page views take: WebKit's `WKWebView`, and Chromium's `RenderWidgetHostViewCocoa` through its own methods, its edit command list (`render_widget_host_view_mac_editcommand_helper.mm`), and the responder delegate that CEF sets on it (`ChromeRenderWidgetHostViewMacDelegate`, from `ChromeWebContentsViewDelegateCef`). The items of WebKit's menu that Chromium's view cannot run stay out on both engines: Check Grammar With Spelling and Correct Spelling Automatically (no `toggleGrammarChecking:` or `toggleAutomaticSpellingCorrection:`), Smart Copy/Paste and Smart Links (no `toggleSmartInsertDelete:` or `toggleAutomaticLinkDetection:`), the Font submenu (only `underline:`, no font or color panel), Paragraph Direction (no base writing direction actions), Selection Direction (Blink runs those actions only in rich text, and Chromium's view shows no check marks for them), and Transformations' Convert to Traditional Chinese and Convert to Simplified Chinese (WebKit's own editing commands, with no standard action).
import AppKit

/// Builds macOS's text items for a page context menu. The UI delegate places them by their `EngineContextMenuItem` identifiers.
public enum EngineTextMenuItems {
    /// Whether the system's spelling and substitutions panels show, which decides whether their items show or hide them, as in WebKit's menu.
    public struct Panels: Equatable {
        public var isSpellingVisible: Bool
        public var isSubstitutionsVisible: Bool

        public init(isSpellingVisible: Bool = false, isSubstitutionsVisible: Bool = false) {
            self.isSpellingVisible = isSpellingVisible
            self.isSubstitutionsVisible = isSubstitutionsVisible
        }

        /// The shared spell checker's panels as they are now.
        public static var current: Panels {
            let checker = NSSpellChecker.shared
            return Panels(isSpellingVisible: checker.spellingPanel.isVisible, isSubstitutionsVisible: checker.substitutionsPanel.isVisible)
        }
    }

    /// The selected text that Look Up, Translate, Search with, Transformations, and Speech act on: the selection without surrounding spaces and line breaks, in a field, or outside one when the click is not on a link, image, or media, where WebKit's menu offers none of them. Nil in a password field and without a selection.
    public static func selection(of element: EngineContextMenuElement) -> String? {
        guard !element.isPasswordField, element.isEditable || (element.linkURL == nil && element.imageURL == nil && element.mediaURL == nil && element.media == nil),
              let text = element.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The text items for `element`, in WebKit's order: Look Up and Translate (macOS 14.4 and later) for a selection; in a field that is not a password field, the Spelling and Grammar, Substitutions, Transformations (for a selection whose case can change, `canChangeCase(of:)`), and Speech submenus, then Share…; outside a field, Share…, then Speech for a selection. The submenus' actions go to `pageView`; without it there are none. Look Up and Translate open at `location`, in `anchor`'s coordinates. `panels` defaults to the system's panels as they are now.
    public static func items(for element: EngineContextMenuElement, pageView: NSView?, anchor: NSView, at location: NSPoint, panels: Panels? = nil) -> [NSMenuItem] {
        let selection = selection(of: element)
        var items: [NSMenuItem] = []
        if let selection {
            items.append(lookUpItem(selection, anchor: anchor, at: location))
            if #available(macOS 14.4, *) {
                items.append(translateItem(selection, anchor: anchor, at: location, replace: translationReplacement(for: element, pageView: pageView)))
            }
        }
        let isField = element.isEditable && !element.isPasswordField
        let speech = pageView.flatMap { isField || selection != nil ? speechItem(pageView: $0) : nil }
        let share = shareItem(for: element)
        if isField, let pageView {
            let panels = panels ?? .current
            items += [spellingAndGrammarItem(pageView: pageView, panels: panels), substitutionsItem(pageView: pageView, panels: panels),
                      selection.flatMap { canChangeCase(of: $0) ? transformationsItem(pageView: pageView) : nil }, speech, share].compactMap { $0 }
        } else {
            items += [share, speech].compactMap { $0 }
        }
        return items
    }

    /// Whether Transformations ▸ shows for `selection`, as in WebKit's own menu: when the selection holds an upper or lower case letter, or is longer than the 200 UTF-16 code units WebKit reads for this. A selection of digits or of Korean, which no change of case alters, gets none.
    private static func canChangeCase(of selection: String) -> Bool {
        selection.utf16.count > 200 || selection.rangeOfCharacter(from: CharacterSet.lowercaseLetters.union(.uppercaseLetters)) != nil
    }

    /// A menu title that quotes `text` as WebKit's Look Up and Translate items do: without surrounding spaces, cut after 24 characters with an ellipsis. Runs of spaces and line breaks become one space, so the title stays on one line, where WebKit's own titles keep them.
    public static func quoted(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limit = 24
        return "“" + (line.count > limit ? line.prefix(limit) + "…" : line) + "”"
    }

    /// What Share… shares, as WebKit's share item does: the link, media, and image by their web (http or https) addresses, then the selected text. Nothing in a password field, and no address of another kind, such as a `file:`, `blob:`, or `mailto:` address.
    public static func shareItems(for element: EngineContextMenuElement) -> [Any] {
        guard !element.isPasswordField else { return [] }
        let addresses = [element.linkURL, element.mediaURL, element.imageURL].compactMap { $0 }.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        var items: [Any] = addresses
        if let text = element.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            items.append(text)
        }
        return items
    }

    // MARK: Items

    /// Replace with Translation in the translation popover of a field that is not a password field, as WebKit's own menu offers it there: the translation takes the place of the field's selection through `pageView`'s `insertText(_:)`, AppKit's standard text input action, which both page views take. Nil outside a field and without a page view.
    static func translationReplacement(for element: EngineContextMenuElement, pageView: NSView?) -> ((String) -> Void)? {
        guard element.isEditable, !element.isPasswordField, let pageView else { return nil }
        return { [weak pageView] translation in pageView?.insertText(translation) }
    }

    /// Shows the dictionary's definition of the selection at the click through `NSView.showDefinition(for:at:)`, which works in any view, so both engines show the same panel for the whole selection. A page view's `quickLookWithEvent:` would look up only the word under the click on Chromium.
    private static func lookUpItem(_ selection: String, anchor: NSView, at location: NSPoint) -> NSMenuItem {
        let item = EngineActionMenuItem(localized("Look Up \(quoted(selection))")) { [weak anchor] in
            let text = NSAttributedString(string: selection, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
            anchor?.showDefinition(for: text, at: location)
        }
        item.identifier = EngineContextMenuItem.lookUp
        return item
    }

    @available(macOS 14.4, *)
    private static func translateItem(_ selection: String, anchor: NSView, at location: NSPoint, replace: ((String) -> Void)?) -> NSMenuItem {
        let item = EngineActionMenuItem(localized("Translate \(quoted(selection))")) { [weak anchor] in
            guard let anchor else { return }
            EngineTranslationPopover.show(selection, at: location, in: anchor, replace: replace)
        }
        item.identifier = EngineContextMenuItem.translate
        return item
    }

    /// Showing the panel goes to the page view, which moves to the next misspelled word as it shows it; hiding it sends `orderOut:` to the system's panel, which both engines then find hidden.
    private static func spellingAndGrammarItem(pageView: NSView, panels: Panels) -> NSMenuItem? {
        EngineStandardActionSubmenu.item(localized("Spelling and Grammar"), EngineContextMenuItem.spellingAndGrammar, sendingTo: pageView, [
            panels.isSpellingVisible ? .send(localized("Hide Spelling and Grammar"), #selector(NSWindow.orderOut(_:)), to: NSSpellChecker.shared.spellingPanel)
                : .action(localized("Show Spelling and Grammar"), #selector(NSText.showGuessPanel(_:))),
            .action(localized("Check Document Now"), #selector(NSText.checkSpelling(_:))),
            .separator,
            .action(localized("Check Spelling While Typing"), #selector(NSTextView.toggleContinuousSpellChecking(_:))),
        ])
    }

    /// Hiding the panel sends `orderOut:` to the system's panel, because the page views' action only shows it.
    private static func substitutionsItem(pageView: NSView, panels: Panels) -> NSMenuItem? {
        EngineStandardActionSubmenu.item(localized("Substitutions"), EngineContextMenuItem.substitutions, sendingTo: pageView, [
            panels.isSubstitutionsVisible ? .send(localized("Hide Substitutions"), #selector(NSWindow.orderOut(_:)), to: NSSpellChecker.shared.substitutionsPanel)
                : .action(localized("Show Substitutions"), #selector(NSTextView.orderFrontSubstitutionsPanel(_:))),
            .separator,
            .action(localized("Smart Quotes"), #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
            .action(localized("Smart Dashes"), #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
            .action(localized("Text Replacement"), #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
        ])
    }

    private static func transformationsItem(pageView: NSView) -> NSMenuItem? {
        EngineStandardActionSubmenu.item(localized("Transformations"), EngineContextMenuItem.transformations, sendingTo: pageView, [
            .action(localized("Make Upper Case"), #selector(NSResponder.uppercaseWord(_:))),
            .action(localized("Make Lower Case"), #selector(NSResponder.lowercaseWord(_:))),
            .action(localized("Capitalize"), #selector(NSResponder.capitalizeWord(_:))),
        ])
    }

    private static func speechItem(pageView: NSView) -> NSMenuItem? {
        EngineStandardActionSubmenu.item(localized("Speech"), EngineContextMenuItem.speech, sendingTo: pageView, [
            .action(localized("Start Speaking"), #selector(NSTextView.startSpeaking(_:))),
            .action(localized("Stop Speaking"), #selector(NSTextView.stopSpeaking(_:))),
        ])
    }

    /// The system's share item, which keeps its sharing service picker and shows it when chosen. Nil when there is nothing to share.
    private static func shareItem(for element: EngineContextMenuElement) -> NSMenuItem? {
        let items = shareItems(for: element)
        guard !items.isEmpty else { return nil }
        let item = NSSharingServicePicker(items: items).standardShareMenuItem
        item.identifier = EngineContextMenuItem.share
        item.isEnabled = true
        return item
    }
}
