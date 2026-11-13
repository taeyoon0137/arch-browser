// The storage each Persona asks the engines for: the default Persona keeps the engines' default storage, which holds the data of builds before Personas. And the labels that name Personas under Persona rule 7: "Persona / Space" for one space, the Persona's name alone for a whole Persona, and neither with the default Persona alone.
import Foundation
import Testing
@testable import Browsing

@Suite struct PersonaTests {
    private let defaultPersona = Persona(id: Persona.defaultID, name: "Default")
    private let work = Persona(name: "Work")

    @Test func theDefaultPersonaKeepsTheDefaultStorage() {
        #expect(Persona(id: Persona.defaultID, name: "Default").storageIdentifier == nil)
    }

    @Test func otherPersonasNameTheirStorageByTheirID() {
        let persona = Persona(name: "Work")
        #expect(persona.storageIdentifier == persona.id)
    }

    @Test func withOnePersonaASpaceShowsItsNameAlone() {
        let space = Space(name: "Research", personaID: Persona.defaultID)
        #expect(BrowserSession.label(ofSpace: space, among: [defaultPersona]) == "Research")
        // A space from a file before Personas has no Persona of its own and belongs to the default one.
        #expect(BrowserSession.label(ofSpace: Space(name: "Research"), among: [defaultPersona]) == "Research")
    }

    @Test func withTwoPersonasASpaceShowsPersonaSlashSpace() {
        let space = Space(name: "Research", personaID: work.id)
        #expect(BrowserSession.label(ofSpace: space, among: [defaultPersona, work]) == "Work / Research")
    }

    @Test func twoPersonasSpacesNamedPersonalAreToldApart() {
        let personas = [defaultPersona, work]
        let defaultPersonal = BrowserSession.label(ofSpace: Space(name: "Personal", personaID: Persona.defaultID), among: personas)
        let workPersonal = BrowserSession.label(ofSpace: Space(name: "Personal", personaID: work.id), among: personas)
        #expect(defaultPersonal == "Default / Personal")
        #expect(workPersonal == "Work / Personal")
        #expect(defaultPersonal != workPersonal)
    }

    @Test func aPersonaWideLabelShowsThePersonasNameAlone() {
        #expect(BrowserSession.displayedName(ofPersona: work.id, among: [defaultPersona, work]) == "Work")
        #expect(BrowserSession.displayedName(ofPersona: Persona.defaultID, among: [defaultPersona]) == nil)
        // A Persona that is gone has no name to show, so its space's label is the space's name.
        let gone = Space(name: "Research", personaID: UUID())
        #expect(BrowserSession.displayedName(ofPersona: gone.resolvedPersonaID, among: [defaultPersona, work]) == nil)
        #expect(BrowserSession.label(ofSpace: gone, among: [defaultPersona, work]) == "Research")
    }

    @Test func withOnePersonaTheWindowTitleNamesNoPersona() {
        let space = Space(name: "Research", personaID: Persona.defaultID)
        #expect(BrowserWindowController.title(tabTitle: "Inbox", space: space, among: [defaultPersona]) == "Inbox")
        #expect(BrowserWindowController.title(tabTitle: nil, space: space, among: [defaultPersona]) == "Research")
    }

    @Test func withTwoPersonasTheWindowTitleEndsWithTheSpacesLabel() {
        let space = Space(name: "Personal", personaID: work.id)
        #expect(BrowserWindowController.title(tabTitle: "Inbox", space: space, among: [defaultPersona, work]) == "Inbox \u{2014} Work / Personal")
        #expect(BrowserWindowController.title(tabTitle: nil, space: space, among: [defaultPersona, work]) == "Work / Personal")
    }
}
