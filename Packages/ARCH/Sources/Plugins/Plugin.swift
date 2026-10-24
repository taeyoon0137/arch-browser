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
    public var spaceID: UUID
    /// nil unless the grant has `tabs`.
    public var title: String?
    /// nil unless the grant has `tabs`.
    public var url: URL?
    public var engine: EngineKind
    public var isPinned: Bool
    public var isSelected: Bool

    public init(id: UUID, spaceID: UUID, title: String?, url: URL?, engine: EngineKind, isPinned: Bool, isSelected: Bool) {
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
        guard !grant.permissions.contains(.tabs) else { return self }
        var tab = self
        tab.title = nil
        tab.url = nil
        return tab
    }
}

public enum PluginError: Error, Hashable, Sendable {
    /// The plugin's grant lacks the permission a call needs.
    case permissionDenied(PluginPermission)
}
