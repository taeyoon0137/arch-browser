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
    /// The identity row of a Clear Site Data card, which names the tab's site.
    private let site = PromptIdentity(icon: .symbol("globe"), name: "www.example.org", isSecure: true)

    @Test func oneDefaultPersonaIsNeverNamed() {
        let personal = Space(name: "Personal", personaID: Persona.defaultID)
        #expect(BrowserSession.displayedPlace(ofPersona: Persona.defaultID, space: personal, among: [defaultPersona]) == nil)
        #expect(BrowserSession.displayedPlace(ofPersona: Persona.defaultID, space: nil, among: [defaultPersona]) == nil)
        #expect(BrowserWindowController.title(tabTitle: "Example Domain", spaceName: "Personal", place: nil) == "Example Domain")
        #expect(BrowserWindowController.title(tabTitle: nil, spaceName: "Personal", place: nil) == "Personal")
        #expect(BrowserWindowModel.sheetName(ofPersona: Persona.defaultID, space: personal, among: [defaultPersona]) == nil)
        let clear = TabPromptContent.clearSiteData(persona: nil, identity: site)
        #expect(clear.identity == site)
        #expect(clear.message == "Its cookies and other website data are removed from both engines, which signs you out of the website. Its open tabs load again.")
    }

    @Test func twoPersonasNameThePersonaWithTheSpace() {
        let personas = [defaultPersona, work]
        let place = BrowserSession.displayedPlace(ofPersona: work.id, space: research, among: personas)
        #expect(place == "Work / Research")
        #expect(BrowserWindowController.title(tabTitle: "Example Domain", spaceName: "Research", place: place) == "Example Domain \u{2014} Work / Research")
        #expect(BrowserWindowController.title(tabTitle: nil, spaceName: "Research", place: place) == "Work / Research")
        let persona = BrowserWindowModel.sheetName(ofPersona: work.id, space: research, among: personas)
        #expect(persona == "the Persona of \u{201C}Work / Research\u{201D}")
        let clear = TabPromptContent.clearSiteData(persona: persona, identity: site)
        #expect(clear.identity == site)
        #expect(clear.message == "Its cookies and other website data are removed from both engines in the Persona of \u{201C}Work / Research\u{201D}, which signs you out of the website. Its open tabs load again.")
        let delete = BrowserWindowModel.deletePersonaTexts(persona: persona ?? "", spaceCount: 2, favoriteCount: 1, tabCount: 3, downloadCount: 2)
        #expect(delete.message == "Delete the Persona of \u{201C}Work / Research\u{201D}?")
        #expect(delete.information == "Its 2 spaces and 1 favorite are removed, and its 3 tabs close into the closed list. Its 2 downloads in progress stop. Arch removes its plugins, cookies, and website data from this Mac the next time it opens.")
        #expect(BrowserWindowModel.deletePersonaTexts(persona: persona ?? "", spaceCount: 1, favoriteCount: 0, tabCount: 1, downloadCount: 0).information.hasPrefix("Its space is removed, and its tab closes into the closed list. Arch removes"))
    }

    /// A favorite's tab belongs to no space and shows in the window's current space, so a sheet or card about it names the Persona with that space, as the window title does.
    @Test func aFavoritesTabTakesTheWindowsSpace() {
        let personas = [defaultPersona, work]
        let research = self.research
        let archive = Space(name: "Archive", personaID: work.id)
        let personal = Space(name: "Personal", personaID: Persona.defaultID)
        let spaces = [personal, research, archive]
        // A tab in a space names its own space, whichever space the window shows.
        #expect(BrowserWindowModel.sheetSpace(ofTabIn: archive.id, personaID: work.id, spaces: spaces, currentSpace: research)?.id == archive.id)
        let space = BrowserWindowModel.sheetSpace(ofTabIn: nil, personaID: work.id, spaces: spaces, currentSpace: research)
        #expect(space?.id == research.id)
        let persona = BrowserWindowModel.sheetName(ofPersona: work.id, space: space, among: personas)
        #expect(persona == "the Persona of \u{201C}Work / Research\u{201D}")
        #expect(TabPromptContent.clearSiteData(persona: persona, identity: site).message
            == "Its cookies and other website data are removed from both engines in the Persona of \u{201C}Work / Research\u{201D}, which signs you out of the website. Its open tabs load again.")
        // Only a tab outside every space of its Persona names the Persona alone.
        #expect(BrowserWindowModel.sheetSpace(ofTabIn: nil, personaID: work.id, spaces: spaces, currentSpace: personal) == nil)
        #expect(BrowserSession.displayedPlace(ofPersona: work.id, space: nil, among: personas) == "Work")
        #expect(BrowserWindowModel.sheetName(ofPersona: work.id, space: nil, among: personas) == "the Persona \u{201C}Work\u{201D}")
    }

    /// A Persona that is no longer listed, as while its deletion finishes, is not named.
    @Test func aDeletedPersonaIsNotNamed() {
        #expect(BrowserSession.displayedPlace(ofPersona: UUID(), space: research, among: [defaultPersona, work]) == nil)
    }
}
