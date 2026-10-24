// The profile each Persona asks the engines for: the default Persona keeps the engines' default profile, which holds the data of builds before Personas.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@Suite struct PersonaTests {
    @Test func theDefaultPersonaKeepsTheDefaultProfile() {
        let attributes = Persona(id: Persona.defaultID, name: "Default").contextAttributes
        #expect(attributes.id == .default)
        #expect(attributes.id.rawValue == "default")
        #expect(attributes.type == .regular)
    }

    @Test func otherPersonasNameTheirProfileByTheirID() {
        let persona = Persona(name: "Work")
        let attributes = persona.contextAttributes
        #expect(attributes.id.rawValue == persona.id.uuidString)
        #expect(attributes.userVisibleName == "Work")
        #expect(attributes.type == .regular)
    }
}
