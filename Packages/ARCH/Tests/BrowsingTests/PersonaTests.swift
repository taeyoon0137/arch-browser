// The storage each Persona asks the engines for: the default Persona keeps the engines' default storage, which holds the data of builds before Personas. And how the interface names a Persona: "Persona / Space" from a place with a space, the Persona alone without one, and nothing with one Persona (Persona rule 7 in `docs/windows-personas.md`).
import Foundation
import Testing
@testable import Browsing

@Suite struct PersonaTests {
    @Test func theDefaultPersonaKeepsTheDefaultStorage() {
        #expect(Persona(id: Persona.defaultID, name: "Default").storageIdentifier == nil)
    }

    @Test func otherPersonasNameTheirStorageByTheirID() {
        let persona = Persona(name: "Work")
        #expect(persona.storageIdentifier == persona.id)
    }

    // MARK: Naming

    private let defaultPersona = Persona(id: Persona.defaultID, name: "Default")
    private let work = Persona(name: "Work")
    private var research: Space { Space(name: "Research", personaID: work.id) }

    @Test func oneDefaultPersonaIsNeverNamed() {
        let personal = Space(name: "Personal", personaID: Persona.defaultID)
        #expect(BrowserSession.displayedPlace(ofPersona: Persona.defaultID, space: personal, among: [defaultPersona]) == nil)
        #expect(BrowserSession.displayedPlace(ofPersona: Persona.defaultID, space: nil, among: [defaultPersona]) == nil)
        #expect(BrowserWindowController.title(tabTitle: "Example Domain", spaceName: "Personal", place: nil) == "Example Domain")
        #expect(BrowserWindowController.title(tabTitle: nil, spaceName: "Personal", place: nil) == "Personal")
        #expect(BrowserWindowModel.sheetName(ofPersona: Persona.defaultID, space: personal, among: [defaultPersona]) == nil)
        #expect(BrowserWindowModel.clearSiteDataTexts(site: "example.org", persona: nil).information
            == "Its cookies and other website data are removed from both engines, which signs you out of the site. Its open tabs load again.")
    }

    @Test func twoPersonasNameThePersonaWithTheSpace() {
        let personas = [defaultPersona, work]
        let place = BrowserSession.displayedPlace(ofPersona: work.id, space: research, among: personas)
        #expect(place == "Work / Research")
        #expect(BrowserWindowController.title(tabTitle: "Example Domain", spaceName: "Research", place: place) == "Example Domain \u{2014} Work / Research")
        #expect(BrowserWindowController.title(tabTitle: nil, spaceName: "Research", place: place) == "Work / Research")
        let persona = BrowserWindowModel.sheetName(ofPersona: work.id, space: research, among: personas)
        #expect(persona == "the Persona of \u{201C}Work / Research\u{201D}")
        let clear = BrowserWindowModel.clearSiteDataTexts(site: "example.org", persona: persona)
        #expect(clear.message == "Clear the data stored by \u{201C}example.org\u{201D}?")
        #expect(clear.information == "Its cookies and other website data are removed from both engines in the Persona of \u{201C}Work / Research\u{201D}, which signs you out of the site. Its open tabs load again.")
        let delete = BrowserWindowModel.deletePersonaTexts(persona: persona ?? "", spaceCount: 2, favoriteCount: 1, tabCount: 3)
        #expect(delete.message == "Delete the Persona of \u{201C}Work / Research\u{201D}?")
        #expect(delete.information == "Its 2 spaces and 1 favorite are removed, and its 3 tabs close into the closed list. Its downloads in progress stop. Arch removes its cookies and website data from this Mac the next time it opens.")
        #expect(BrowserWindowModel.deletePersonaTexts(persona: persona ?? "", spaceCount: 1, favoriteCount: 0, tabCount: 1).information.hasPrefix("Its 1 space and 0 favorites are removed, and its 1 tab closes into"))
    }

    /// A favorite's tab belongs to no space, so a sheet about it names the Persona alone.
    @Test func aTabWithoutASpaceNamesThePersonaAlone() {
        let personas = [defaultPersona, work]
        #expect(BrowserSession.displayedPlace(ofPersona: work.id, space: nil, among: personas) == "Work")
        let persona = BrowserWindowModel.sheetName(ofPersona: work.id, space: nil, among: personas)
        #expect(persona == "the Persona \u{201C}Work\u{201D}")
        #expect(BrowserWindowModel.clearSiteDataTexts(site: "example.org", persona: persona).information
            == "Its cookies and other website data are removed from both engines in the Persona \u{201C}Work\u{201D}, which signs you out of the site. Its open tabs load again.")
    }

    /// A Persona that is no longer listed, as while its deletion finishes, is not named.
    @Test func aDeletedPersonaIsNotNamed() {
        #expect(BrowserSession.displayedPlace(ofPersona: UUID(), space: research, among: [defaultPersona, work]) == nil)
    }
}
