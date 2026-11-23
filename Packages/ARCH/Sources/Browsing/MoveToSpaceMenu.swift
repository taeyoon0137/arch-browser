// Move to Space: the submenu of a tab row's and a folder row's context menus that moves the item to another space of any Persona, and the sections that it, the menu bar's Tab ▸ Move Tab to Space, and the command palette list (`docs/windows-personas.md`, Moving tabs between spaces).
import SwiftUI

/// One Persona's part of Move to Space: its spaces in switcher order, under its name while there is more than one Persona, and the reason its spaces refuse the item, if any.
public struct SpaceMoveSection: Identifiable {
    public let personaID: Persona.ID
    /// The Persona's name, or nil with one Persona, where the spaces' names alone name them.
    public let title: String?
    public let spaces: [Space]
    let refusal: BrowserSession.SpaceMoveRefusal?

    public var id: Persona.ID { personaID }
    /// The help of the section's items while its spaces refuse the item, which disables them.
    public var refusalHelp: String? { refusal?.help }
}

extension BrowserSession {
    /// Move to Space's sections, one per Persona in order, where `refusal` says why a Persona's spaces refuse the item.
    func spaceMoveSections(refusal: (Persona.ID) -> SpaceMoveRefusal?) -> [SpaceMoveSection] {
        personas.map { persona in
            SpaceMoveSection(personaID: persona.id, title: personas.count > 1 ? persona.name : nil, spaces: spaces(in: persona.id), refusal: refusal(persona.id))
        }
    }

    /// Move to Space's sections for the tab, or none for a tab that no menu moves, such as a favorite's or a small window's.
    public func spaceMoveSections(forTab tab: Tab) -> [SpaceMoveSection] {
        guard canMoveToAnotherSpace(tab) else { return [] }
        return spaceMoveSections { spaceMoveRefusal(ofTab: tab, toPersona: $0) }
    }
}

/// Move to Space: each Persona's spaces, under the Persona's name while there are several (Persona rule 7), with the item's own space checked and disabled, and New Space at the end of each Persona's section, which makes a space there and moves the item into it. A Persona whose spaces refuse the item shows them disabled, with the reason as their help.
struct MoveToSpaceMenu: View {
    let sections: [SpaceMoveSection]
    let currentSpaceID: UUID
    let move: (UUID) -> Void
    let moveToNewSpace: (Persona.ID) -> Void

    var body: some View {
        Menu(localized("Move to Space")) {
            ForEach(sections) { section in
                if section.id != sections.first?.id { Divider() }
                if let title = section.title {
                    Section(title) { items(of: section) }
                } else {
                    items(of: section)
                }
            }
        }
    }

    @ViewBuilder private func items(of section: SpaceMoveSection) -> some View {
        ForEach(section.spaces) { space in
            if space.id == currentSpaceID {
                // A checked item marks where the item is, as a menu marks its current choice.
                Toggle(space.name, isOn: .constant(true)).disabled(true)
            } else {
                RefusableItem(title: space.name, help: section.refusalHelp) { move(space.id) }
            }
        }
        RefusableItem(title: localized("New Space"), help: section.refusalHelp) { moveToNewSpace(section.personaID) }
    }
}

/// A command palette row that moves the window's selected tab to a space: Move Tab to Space with the space named as one line names it, "Persona / Space" while there are several Personas (Persona rule 7).
struct SpaceMoveCommand: Identifiable {
    let space: Space
    let title: String

    var id: UUID { space.id }
}

extension BrowserSession {
    /// The palette's Move Tab to Space rows for the typed text: each space other than the tab's that takes it, in switcher order, while the typed words begin the row's title or its English one, as Ask About This Page matches. A tab that no menu moves gets none.
    func spaceMoveCommands(matching text: String, forTab tab: Tab) -> [SpaceMoveCommand] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty, canMoveToAnotherSpace(tab) else { return [] }
        return spaces.compactMap { space in
            guard canCarryTab(tab.id, toSpace: space.id) else { return nil }
            let place = displayedPlace(ofPersona: space.resolvedPersonaID, space: space) ?? space.name
            let title = localized("Move Tab to \(place)")
            guard title.lowercased().hasPrefix(words) || "move tab to \(place.lowercased())".hasPrefix(words) else { return nil }
            return SpaceMoveCommand(space: space, title: title)
        }
    }
}

/// A menu item that `help`, when given, disables and explains.
private struct RefusableItem: View {
    let title: String
    let help: String?
    let action: () -> Void

    var body: some View {
        if let help {
            Button(title, action: action).disabled(true).help(help)
        } else {
            Button(title, action: action)
        }
    }
}
