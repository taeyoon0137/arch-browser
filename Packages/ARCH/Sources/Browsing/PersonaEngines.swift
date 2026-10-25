// Each Persona has its own runtime in each engine and its own plugins, so the session finds a tab's profile and browser by the tab's Persona and engine, and a window's plugins by the window's Persona. Cookies copy between the engines of one Persona and never to another Persona's.
import ARCHEngine
import Extensions
import Foundation
import Plugins

/// One Persona's engine contexts: a context and browser per engine, started on first use, the CookieSync that copies cookies between them, and the Persona's plugin manager with its web extensions.
final class PersonaEngines {
    let personaID: Persona.ID
    var runtimes: [EngineKind: EngineRuntime] = [:]
    let cookieSync = CookieSync()
    /// Created when a tab or window of the Persona first needs it (`BrowserSession.plugins(in:)`). Deleting the Persona closes it and drops it, so its plugins stop and write nothing more to the Persona's folder.
    var plugins: PluginManager?
    /// The runtime of the Persona's web extensions, which the plugin manager runs them with, made and dropped with it.
    var webExtensions: WebExtensionRuntime?

    init(personaID: Persona.ID) {
        self.personaID = personaID
        cookieSync.runtimes = { [weak self] in self.map { Array($0.runtimes.values) } ?? [] }
    }
}
