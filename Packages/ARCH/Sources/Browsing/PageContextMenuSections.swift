// The sections of a page context menu that hold the items an engine hands its UI delegate, in the order of WebKit's own menu, so that every menu built from them, the tab's and the preview panel's, places them alike on both engines.
import AppKit
import ARCHEngine

/// The items an engine hands for a page context menu (`EngineContextMenuItem`), taken out of the menu and sorted into the sections of WebKit's own menu. A delegate puts its own sections between them and shows them all with `show(_:in:)`. The engine's own items take the app's titles, and macOS's text items keep theirs.
struct PageContextMenuSections {
    /// Up to five spelling suggestions, or No Guesses Found, which is off.
    let suggestions: [NSMenuItem]
    /// Ignore Spelling and Learn Spelling.
    let spelling: [NSMenuItem]
    /// Look Up “…” and Translate “…”.
    let lookUp: [NSMenuItem]
    /// Cut, Copy, Paste, and Select All in a field, or Copy for a selection outside one.
    let editing: [NSMenuItem]
    /// A field's Spelling and Grammar, Substitutions, Transformations, and Speech submenus.
    let fieldSubmenus: [NSMenuItem]
    /// Share…, followed outside a field by Speech, as WebKit places it.
    let share: [NSMenuItem]

    /// Takes the handed items out of `menu`, which the delegate fills again, and stops it from enabling items itself, so each item keeps its state.
    init(takingItemsOf menu: NSMenu, for element: EngineContextMenuElement) {
        let handed = menu.items
        menu.removeAllItems()
        menu.autoenablesItems = false
        func item(_ identifier: NSUserInterfaceItemIdentifier) -> NSMenuItem? {
            handed.first { $0.identifier == identifier }
        }
        func titled(_ identifier: NSUserInterfaceItemIdentifier, _ title: String) -> NSMenuItem? {
            let found = item(identifier)
            found?.title = title
            return found
        }
        let guesses = handed.filter { $0.identifier == EngineContextMenuItem.spellingSuggestion }
        if !guesses.isEmpty {
            suggestions = Array(guesses.prefix(5))
        } else if let noGuesses = titled(EngineContextMenuItem.noSpellingSuggestions, localized("No Guesses Found")) {
            noGuesses.isEnabled = false
            suggestions = [noGuesses]
        } else {
            suggestions = []
        }
        spelling = [titled(EngineContextMenuItem.ignoreSpelling, localized("Ignore Spelling")), titled(EngineContextMenuItem.learnSpelling, localized("Learn Spelling"))].compactMap { $0 }
        lookUp = [item(EngineContextMenuItem.lookUp), item(EngineContextMenuItem.translate)].compactMap { $0 }
        if element.isEditable {
            editing = [titled(EngineContextMenuItem.cut, localized("Cut")), titled(EngineContextMenuItem.copy, localized("Copy")), titled(EngineContextMenuItem.paste, localized("Paste")),
                       titled(EngineContextMenuItem.selectAll, localized("Select All"))].compactMap { $0 }
        } else if element.linkURL == nil, element.imageURL == nil, element.mediaURL == nil, let copy = titled(EngineContextMenuItem.copy, localized("Copy")) {
            // WebKit offers Copy outside fields only when the click is not on a link, image, or media, so Chromium follows it.
            editing = [copy]
        } else {
            editing = []
        }
        // WebKit puts Speech among a field's submenus, and after Share… outside a field.
        let submenus = [EngineContextMenuItem.spellingAndGrammar, EngineContextMenuItem.substitutions, EngineContextMenuItem.transformations]
            + (element.isEditable ? [EngineContextMenuItem.speech] : [])
        fieldSubmenus = submenus.compactMap(item)
        share = ([EngineContextMenuItem.share] + (element.isEditable ? [] : [EngineContextMenuItem.speech])).compactMap(item)
    }

    /// Adds the sections that have items to `menu`, separated by lines.
    static func show(_ sections: [[NSMenuItem]], in menu: NSMenu) {
        for (index, section) in sections.filter({ !$0.isEmpty }).enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
    }
}
