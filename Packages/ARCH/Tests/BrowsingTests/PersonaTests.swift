// The storage each Persona asks the engines for: the default Persona keeps the engines' default storage, which holds the data of builds before Personas.
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
}
