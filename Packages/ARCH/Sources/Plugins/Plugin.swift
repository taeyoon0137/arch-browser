// The plugin API: the protocols a plugin implements, the context through which it reaches the browser, and the values it receives. Every kind of plugin calls the same API, and a plugin gains a capability only when `PluginContext` gains a member.
import ARCHEngine
import Foundation

/// A running plugin in one Persona.
@MainActor
public protocol Plugin: AnyObject {
    /// Called once, before the plugin's first command runs. The context stays valid while the plugin runs.
    func activate(in context: any PluginContext) async throws
    /// Runs one of the commands the manifest lists.
    func run(_ command: String, _ invocation: PluginInvocation) async throws
}

/// A plugin compiled into the app. The app passes the list of these types to the plugin manager.
@MainActor
public protocol BuiltInPlugin: Plugin {
    static var manifest: PluginManifest { get }
    /// Whether the plugin is enabled in a Persona where the user has not switched it on or off.
    static var isOnByDefault: Bool { get }
    init()
}

/// The plugin's handle on the browser, scoped to one plugin in one Persona. Each call checks the plugin's grant and throws `PluginError.permissionDenied` when the grant does not cover it.
@MainActor
public protocol PluginContext: AnyObject {
    var pluginID: PluginID { get }
    var personaID: PersonaID { get }
    var grant: PluginGrant { get }
    /// The plugin's own storage in its Persona. Needs no permission.
    var storage: any PluginStorage { get }
    /// Needs `clipboard`.
    func copyToClipboard(_ text: String) throws
}

/// What a command runs on.
public struct PluginInvocation: Sendable {
    /// The selected tab, or nil when no tab is selected or an internal page covers it.
    public var tab: PluginTab?

    public init(tab: PluginTab?) {
        self.tab = tab
    }
}

/// A tab as a plugin sees it.
public struct PluginTab: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// `nil` for a favorite's tab, which belongs to no space.
    public var spaceID: UUID?
    /// nil unless the grant has `tabs` or its sites cover the page.
    public var title: String?
    /// nil unless the grant has `tabs` or its sites cover the page.
    public var url: URL?
    public var engine: EngineKind
    public var isPinned: Bool
    public var isSelected: Bool

    public init(id: UUID, spaceID: UUID?, title: String?, url: URL?, engine: EngineKind, isPinned: Bool, isSelected: Bool) {
        self.id = id
        self.spaceID = spaceID
        self.title = title
        self.url = url
        self.engine = engine
        self.isPinned = isPinned
        self.isSelected = isSelected
    }

    /// The tab without what the grant does not cover.
    func redacted(for grant: PluginGrant) -> PluginTab {
        guard !grant.permissions.contains(.tabs), !(url.map(grant.covers) ?? false) else { return self }
        var tab = self
        tab.title = nil
        tab.url = nil
        return tab
    }
}

/// A JSON value: the form of everything a plugin stores. It encodes as the plain JSON value, such as `true` or `[1, "a"]`.
public enum PluginValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PluginValue])
    case object([String: PluginValue])
}

extension PluginValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([PluginValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: PluginValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(bool): try container.encode(bool)
        case let .number(number): try container.encode(number)
        case let .string(string): try container.encode(string)
        case let .array(array): try container.encode(array)
        case let .object(object): try container.encode(object)
        }
    }
}

/// A plugin's key-value storage in one Persona. Values last across launches until the plugin removes them.
@MainActor
public protocol PluginStorage: AnyObject {
    func value(forKey key: String) -> PluginValue?
    /// nil removes the key. Throws `PluginError.quotaExceeded` when the storage would grow past its limit, and an encoding error for a number JSON cannot hold, such as infinity; the storage then keeps its previous value.
    func setValue(_ value: PluginValue?, forKey key: String) throws
    /// In ascending order.
    func allKeys() -> [String]
}

public enum PluginError: Error, Hashable, Sendable {
    /// The plugin's grant lacks the permission a call needs.
    case permissionDenied(PluginPermission)
    /// The command acts on a page, and the invocation has none.
    case noPage
    /// The text is not a match pattern.
    case invalidMatchPattern(String)
    /// A write would take the plugin's storage past its limit.
    case quotaExceeded
}
