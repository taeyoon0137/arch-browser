import AppKit
import Foundation

public struct EngineBrowserContextID: Hashable, Codable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public extension EngineBrowserContextID {
    /// The engine's default profile, which keeps the data of builds before Personas: WebKit's default data store and CEF's global request context.
    static let `default` = EngineBrowserContextID(rawValue: "default")
}

public enum EngineBrowserContextType: String, Codable, Sendable {
    case regular
    case incognito
}

public struct EngineBrowserContextAttributes: Hashable, Codable, Sendable {
    public var id: EngineBrowserContextID
    public var userVisibleName: String
    public var type: EngineBrowserContextType
    /// Where a regular context keeps its data. nil: the engine's default storage. A UUID: storage of its own, `WKWebsiteDataStore(forIdentifier:)` or a CEF request context whose profile is the `Persona-<UUID>` directory under the root cache path.
    public var storageIdentifier: UUID?
    public init(id: EngineBrowserContextID, userVisibleName: String, type: EngineBrowserContextType, storageIdentifier: UUID? = nil) {
        self.id = id
        self.userVisibleName = userVisibleName
        self.type = type
        self.storageIdentifier = storageIdentifier
    }
}

public struct EngineBrowserCreateParams: Sendable {
    public var initialBounds: CGRect
    public var isPopup: Bool
    public init(initialBounds: CGRect, isPopup: Bool = false) {
        self.initialBounds = initialBounds
        self.isPopup = isPopup
    }
}

public protocol EngineApplicationDelegate: AnyObject {
    func applicationDidInitialize(_ application: any EngineApplication)
    func applicationDidQuitRunLoop(_ application: any EngineApplication)
    func application(_ application: any EngineApplication, didCreateBrowser browser: any EngineBrowser)
    func application(_ application: any EngineApplication, didCloseBrowser browser: any EngineBrowser)
    func application(_ application: any EngineApplication, didChangeBrowserContextAttributes attributes: [EngineBrowserContextAttributes])
    func application(_ application: any EngineApplication, didReceiveRendererProcessCrash count: Int)
}

/// Engine process lifecycle, profiles (browser contexts), window-level browsers, and block lists.
public protocol EngineApplication: AnyObject {
    var engineKind: EngineKind { get }
    var version: String { get }
    var delegate: (any EngineApplicationDelegate)? { get set }

    func run()
    func tryToTerminate(completion: @escaping (Bool) -> Void)

    var availableBrowserContextAttributes: [EngineBrowserContextAttributes] { get }
    func createBrowserContext(_ attributes: EngineBrowserContextAttributes, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void)
    func loadBrowserContext(_ id: EngineBrowserContextID, type: EngineBrowserContextType, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void)
    func browserContext(_ id: EngineBrowserContextID, type: EngineBrowserContextType) -> (any EngineBrowserContext)?
    func deleteBrowserContext(_ id: EngineBrowserContextID) throws

    func createBrowser(_ params: EngineBrowserCreateParams, context: any EngineBrowserContext, delegate: any EngineBrowserDelegate, window: NSWindow?) -> any EngineBrowser
    func restoreBrowser(context: any EngineBrowserContext, sessionID: String, delegate: any EngineBrowserDelegate, completion: @escaping (any EngineBrowser) -> Void)

    /// Ad and tracker block lists (EasyList format). WebKit converts them to WKContentRuleList.
    func setBlockLists(_ lists: [URL])
    func setExcludedDomains(_ domains: [String])
}
