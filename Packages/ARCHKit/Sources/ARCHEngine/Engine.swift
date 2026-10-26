// Entry point of the engine abstraction. The Swift layer sees only these protocols; adapter modules provide the implementations.
import AppKit
import Foundation

/// Selectable engine kinds. The raw value is used as-is in UserDefaults and the debug menu.
public enum EngineKind: String, CaseIterable, Codable, Sendable {
    case webKit
    case chromium

    /// The engine's name as the interface shows it.
    public var displayName: String {
        switch self {
        case .webKit: return "WebKit"
        case .chromium: return "Chromium"
        }
    }
}

/// Optional capabilities that feature code must know of before an engine starts. An engine lists those its adapter implements. Feature code tests an optional member, such as `devTools`, directly.
public enum EngineCapability: String, CaseIterable, Codable, Sendable {
    /// Manifest V3 web extensions through `EngineBrowserContext.extensions`, which the session asks about before it starts an engine for them.
    case extensions
}

public struct EngineApplicationConfiguration: Sendable {
    public var userDataDirectory: URL
    public var cacheDirectory: URL

    public init(userDataDirectory: URL, cacheDirectory: URL) {
        self.userDataDirectory = userDataDirectory
        self.cacheDirectory = cacheDirectory
    }
}

public protocol Engine: AnyObject {
    var kind: EngineKind { get }
    var capabilities: Set<EngineCapability> { get }
    /// The version of the engine's web extension runtime, read without starting the engine, or nil without the `extensions` capability. What a check of a package found holds while the engine has this version.
    var extensionRuntimeVersion: String? { get }
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
