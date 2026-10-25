// Tier 2: web extensions. An engine that runs Manifest V3 extensions gives each browser context an `EngineExtensions`, which runs the extensions the app loads into that profile in the engine's own extension runtime: their background, their content scripts, their popups, and their storage. The app keeps the installed list, tells the engine its windows and tabs, and shows everything around an extension in its own interface: the actions, the popovers that popups show in, and the questions about access.
import AppKit
import Foundation

/// A web extension as the app hands it to an engine: its package and what the user granted it.
public struct EngineExtension: Hashable, Sendable {
    /// The extension's identifier, the same in every engine, which the extension reads as `runtime.id`. It is lowercase letters, so it can stand as a host name.
    public var id: String
    /// The folder that holds the extension's `manifest.json`.
    public var packageURL: URL
    /// The API permissions the user granted, as the manifest names them, such as `storage`.
    public var permissions: Set<String>
    /// The sites the user granted, as match patterns such as `https://*.example.com/*`.
    public var sites: Set<String>

    public init(id: String, packageURL: URL, permissions: Set<String>, sites: Set<String>) {
        self.id = id
        self.packageURL = packageURL
        self.permissions = permissions
        self.sites = sites
    }
}

/// An extension's action as it stands for one tab.
public struct EngineExtensionAction {
    /// What the action does, by default the extension's name.
    public var label: String
    public var icon: NSImage?
    /// Short text the extension shows with the action, such as a count; empty for none.
    public var badgeText: String
    public var isEnabled: Bool

    public init(label: String, icon: NSImage?, badgeText: String, isEnabled: Bool) {
        self.label = label
        self.icon = icon
        self.badgeText = badgeText
        self.isEnabled = isEnabled
    }
}

/// A window as the app shows it to extensions, with its tabs.
public struct EngineExtensionWindow {
    /// The window's identity, which stays while the window exists.
    public var id: UUID
    /// The window's tabs in order, of every engine; each engine lists its own.
    public var tabs: [any EngineWebContents]
    public var activeTab: (any EngineWebContents)?
    /// The AppKit window that shows it, if one does, whose frame extensions can read.
    public weak var window: NSWindow?

    public init(id: UUID, tabs: [any EngineWebContents], activeTab: (any EngineWebContents)?, window: NSWindow?) {
        self.id = id
        self.tabs = tabs
        self.activeTab = activeTab
        self.window = window
    }
}

/// Access an extension asks for while it runs, beyond what the user granted at install.
public enum EngineExtensionAccess: Hashable, Sendable {
    /// An API permission, such as `cookies`.
    case permission(String)
    /// The pages a match pattern covers, such as `https://example.com/*`.
    case site(String)
    /// One page.
    case page(URL)
}

/// A connection an extension opened to a native app with `runtime.connectNative`. Messages are JSON.
public protocol EngineNativeMessagingPort: AnyObject {
    /// The native app the extension named.
    var application: String? { get }
    /// Receives each message the extension posts.
    var onMessage: ((Data) -> Void)? { get set }
    /// Called once when the extension disconnects.
    var onDisconnect: (() -> Void)? { get set }
    /// Delivers a message from the native app to the extension.
    func send(_ message: Data)
    /// Ends the connection. The extension receives `error`'s description as the reason, if any.
    func disconnect(_ error: (any Error)?)
}

/// What the app does for an engine's extensions. Calls that concern one extension name it by its identifier.
public protocol EngineExtensionsDelegate: AnyObject {
    /// Selects the tab in its window, as `tabs.update` with `active` asks.
    func extensions(_ extensions: any EngineExtensions, activate tab: any EngineWebContents)
    /// Closes the tab, as `tabs.remove` asks.
    func extensions(_ extensions: any EngineExtensions, close tab: any EngineWebContents)
    /// The extension changed its action, such as its badge or whether it is enabled.
    func extensions(_ extensions: any EngineExtensions, didUpdateActionOf id: String)
    /// Shows the popover with the action's popup, which the engine filled, for `tab`. Returns false when the app cannot show it, as when no window shows the tab; the engine then closes the popup.
    func extensions(_ extensions: any EngineExtensions, present popup: NSPopover, ofExtension id: String, for tab: (any EngineWebContents)?) -> Bool
    /// Asks the user about access the extension requests while it runs and answers with what the user allowed, until the extension unloads.
    func extensions(_ extensions: any EngineExtensions, extension id: String, requests access: Set<EngineExtensionAccess>, in tab: (any EngineWebContents)?,
                    completion: @escaping (Set<EngineExtensionAccess>) -> Void)
    /// Sends one JSON message to the native app that the extension names, as `runtime.sendNativeMessage` does, and answers with the app's JSON reply.
    func extensions(_ extensions: any EngineExtensions, extension id: String, sendNativeMessage message: Data, toApplication application: String?,
                    reply: @escaping (Result<Data, any Error>) -> Void)
    /// Connects a port the extension opened to the native app it names. Throws when the app cannot be reached.
    func extensions(_ extensions: any EngineExtensions, extension id: String, connect port: any EngineNativeMessagingPort) throws
}

/// The web extensions of one browser context.
public protocol EngineExtensions: AnyObject {
    var delegate: (any EngineExtensionsDelegate)? { get set }
    /// Reads the package in the folder at `packageURL` as `load(_:)` would, without starting any of it. Throws with why the engine cannot run it.
    func check(_ packageURL: URL) async throws
    /// Loads the extension, in place of a loaded one with the same identifier, and starts it: its background, and its content scripts in the pages its granted sites cover from their next load. Throws when the engine cannot read or start it.
    func load(_ extension: EngineExtension) async throws
    /// Stops the extension and takes it out of the profile. Its storage stays.
    func unload(_ id: String)
    /// Deletes the storage the extension keeps in the profile.
    func removeData(of id: String) async
    /// The extension's action for the tab, or nil when it is not loaded or has no action.
    func action(of id: String, for tab: any EngineWebContents) -> EngineExtensionAction?
    /// Runs the action for the tab, as a click on it does: the extension shows its popup or receives the click.
    func performAction(of id: String, for tab: any EngineWebContents)
    /// The app's windows and the focused one, if extensions may see it, each time they change. The engine answers extensions' questions about windows and tabs from the last call and tells them what opened, closed, moved, and became active since the call before. A window whose identity an earlier window in the list has is left out.
    func setWindows(_ windows: [EngineExtensionWindow], focusedWindowID: UUID?)
}
