// Each Persona has its own runtime in each engine, so the session finds a tab's profile and browser by the tab's Persona and engine. Cookies copy between the engines of one Persona and never to another Persona's.
import ARCHEngine
import Foundation

/// One Persona's engine contexts: a context and browser per engine, started on first use, and the CookieSync that copies cookies between them.
final class PersonaEngines {
    let personaID: Persona.ID
    var runtimes: [EngineKind: EngineRuntime] = [:]
    let cookieSync = CookieSync()

    init(personaID: Persona.ID) {
        self.personaID = personaID
        cookieSync.runtimes = { [weak self] in self.map { Array($0.runtimes.values) } ?? [] }
    }
}
