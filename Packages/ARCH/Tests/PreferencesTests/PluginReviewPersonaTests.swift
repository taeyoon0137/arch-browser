// How the review sheet names the Persona a package installs in (`docs/web-store.md`, Decision 7; Persona rule 7 in `docs/windows-personas.md`): with the space of the tab or the window for an install that starts there, as from a store page or the palette, alone for one that starts in Settings ▸ Plugins, and not at all with one Persona.
import Browsing
import Foundation
@testable import Preferences
import Testing

@Suite struct PluginReviewPersonaTests {
    private let defaultPersona = Persona(id: Persona.defaultID, name: "Default")
    private let work = Persona(name: "Work")

    @Test func aStartFromATabOrThePaletteNamesThePersonaWithTheSpace() {
        let research = Space(name: "Research", personaID: work.id)
        #expect(PluginInstallSheet.personaSentence(persona: work.id, space: research, among: [defaultPersona, work])
            == "Installs in the Persona of \u{201C}Work / Research\u{201D} for all its spaces.")
    }

    @Test func aStartInSettingsNamesThePersonaAlone() {
        #expect(PluginInstallSheet.personaSentence(persona: work.id, space: nil, among: [defaultPersona, work]) == "Installs in \u{201C}Work\u{201D} for all its spaces.")
    }

    @Test func onePersonaIsNeverNamed() {
        let personal = Space(name: "Personal", personaID: Persona.defaultID)
        #expect(PluginInstallSheet.personaSentence(persona: Persona.defaultID, space: personal, among: [defaultPersona]) == nil)
        #expect(PluginInstallSheet.personaSentence(persona: Persona.defaultID, space: nil, among: [defaultPersona]) == nil)
        // Nor a Persona that is no longer listed.
        #expect(PluginInstallSheet.personaSentence(persona: work.id, space: nil, among: [defaultPersona, Persona(name: "Home")]) == nil)
    }
}
