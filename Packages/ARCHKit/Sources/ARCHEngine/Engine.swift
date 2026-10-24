// Entry point of the engine abstraction. The Swift layer sees only these protocols; adapter modules provide the implementations.
import AppKit
import Foundation

/// Selectable engine kinds. The raw value is used as-is in UserDefaults and the debug menu.
public enum EngineKind: String, CaseIterable, Codable, Sendable {
    case legacy
    case webKit
    case chromium

    /// The engine's name as the interface shows it.
    public var displayName: String {
        switch self {
        case .legacy: return "Legacy"
        case .webKit: return "WebKit"
        case .chromium: return "Chromium"
        }
    }
}

/// Optional capabilities that differ per engine. The UI hides features that are missing from this set.
public enum EngineCapability: String, CaseIterable, Codable, Sendable {
    case extensions
    case devTools
    case pdfController
    case importSources
    case notifications
    case accessibilityTree
    case tabGroups
    case translation
    case pictureInPicture
    case sessionRestore
    case contentBlocking
    case cookies
}

public struct EngineApplicationConfiguration: Sendable {
    public var userDataDirectory: URL
    public var cacheDirectory: URL
    public var userAgentSuffix: String?
    public var commandLineFlags: [String]

    public init(userDataDirectory: URL, cacheDirectory: URL, userAgentSuffix: String? = nil, commandLineFlags: [String] = []) {
        self.userDataDirectory = userDataDirectory
        self.cacheDirectory = cacheDirectory
        self.userAgentSuffix = userAgentSuffix
        self.commandLineFlags = commandLineFlags
    }
}

public protocol Engine: AnyObject {
    var kind: EngineKind { get }
    var capabilities: Set<EngineCapability> { get }
    func makeApplication(configuration: EngineApplicationConfiguration) throws -> any EngineApplication
    /// Removes what a context with the storage identifier `identifier` stored, while no context of this process uses it, as at launch before `makeApplication`. Reports on the main thread whether the data is gone; false means try again at a later launch.
    func removeStoredData(forStorage identifier: UUID, configuration: EngineApplicationConfiguration, completion: @escaping (Bool) -> Void)
}

/// Holds the registered engines and the default selection. The default is stored in UserDefaults under `ARCHDefaultEngine`.
public final class EngineRegistry {
    public static let shared = EngineRegistry()
    public static let defaultEngineKey = "ARCHDefaultEngine"

    private var engines: [EngineKind: any Engine] = [:]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func register(_ engine: any Engine) {
        engines[engine.kind] = engine
    }

    public func engine(for kind: EngineKind) -> (any Engine)? {
        engines[kind]
    }

    public var registeredKinds: [EngineKind] {
        EngineKind.allCases.filter { engines[$0] != nil }
    }

    /// Default engine. Falls back to Chromium, then WebKit, then the first registered engine.
    public var defaultKind: EngineKind {
        get {
            if let raw = defaults.string(forKey: Self.defaultEngineKey), let kind = EngineKind(rawValue: raw), engines[kind] != nil {
                return kind
            }
            for preferred in [EngineKind.chromium, .webKit] where engines[preferred] != nil {
                return preferred
            }
            return registeredKinds.first ?? .chromium
        }
        set { defaults.set(newValue.rawValue, forKey: Self.defaultEngineKey) }
    }
}

/// Engine selection. A per-tab override wins over the profile default.
public struct EngineSelection: Hashable, Codable, Sendable {
    public var profileDefault: EngineKind
    public var tabOverride: EngineKind?

    public init(profileDefault: EngineKind, tabOverride: EngineKind? = nil) {
        self.profileDefault = profileDefault
        self.tabOverride = tabOverride
    }

    public var effective: EngineKind { tabOverride ?? profileDefault }
}
