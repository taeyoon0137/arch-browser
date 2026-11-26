import Foundation

/// Hears of events in an engine's whole process. `BrowserSession` counts renderer process crashes through it.
public protocol EngineApplicationDelegate: AnyObject {
    func application(_ application: any EngineApplication, didReceiveRendererProcessCrash count: Int)
}

/// The engine in the app's process: its profiles (browser contexts) and their browsers.
public protocol EngineApplication: AnyObject {
    var engineKind: EngineKind { get }
    var delegate: (any EngineApplicationDelegate)? { get set }

    /// Makes a profile whose data lives in the storage `storageIdentifier` names. nil: the engine's default storage, which keeps the data of builds before Personas, WebKit's default data store and CEF's global request context. A UUID: storage of its own, `WKWebsiteDataStore(forIdentifier:)` or a CEF request context whose profile is the `Persona-<UUID>` directory under the root cache path.
    func createBrowserContext(storageIdentifier: UUID?, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void)
    /// Makes an independent profile whose cookies, cache, site storage, permissions, and download list live only in memory. Each call creates fresh storage, shared only by browsers made from the returned context. It must never fall back to persistent storage.
    func createEphemeralBrowserContext(completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void)
    func createBrowser(context: any EngineBrowserContext) -> any EngineBrowser
}

public enum EngineBrowserContextError: Error {
    case ephemeralStorageUnavailable
}

public extension EngineApplication {
    func createEphemeralBrowserContext(completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void) {
        completion(.failure(EngineBrowserContextError.ephemeralStorageUnavailable))
    }
}
