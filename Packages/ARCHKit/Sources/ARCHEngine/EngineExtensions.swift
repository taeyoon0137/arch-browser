// Tier 2: web extensions. An engine that runs Manifest V3 extensions gives each browser context an `EngineExtensions`, which runs the extensions the app loads into that profile in the engine's own extension runtime: their background, their content scripts, their popups, and their storage. The app keeps the installed list, tells the engine its windows and tabs, opens the tabs and windows that extensions ask for, and shows everything around an extension in its own interface: the actions, the popovers that popups show in, and the questions about access.
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
    /// When the app installed the package, which an update changes, or nil when unknown. An engine that keeps a copy of the extension from an earlier launch keeps it only for a package installed before the engine started.
    public var installedAt: Date?

    public init(id: String, packageURL: URL, permissions: Set<String>, sites: Set<String>, installedAt: Date? = nil) {
        self.id = id
        self.packageURL = packageURL
        self.permissions = permissions
        self.sites = sites
        self.installedAt = installedAt
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
    /// Whether the engine kept the extension from running on the tab's site, as Chromium does for an extension whose sites wait for a click, so that the app offers to allow it there (`EngineExtensions.grantSiteAccess(of:for:)`).
    public var wantsSiteAccess: Bool

    public init(label: String, icon: NSImage?, badgeText: String, isEnabled: Bool, wantsSiteAccess: Bool = false) {
        self.label = label
        self.icon = icon
        self.badgeText = badgeText
        self.isEnabled = isEnabled
        self.wantsSiteAccess = wantsSiteAccess
    }
}

/// An action's popup, as an engine hands it to the app to show from the site settings button.
public enum EngineExtensionPopup {
    /// A popover that the engine filled and that sizes itself to the popup and closes when the popup closes itself, as WebKit's `popupPopover`; the app chooses where it shows.
    case popover(NSPopover)
    /// The popup page's view, which the app shows in a popover of its own and sizes as the page asks.
    case view(any EngineExtensionPopupView)
}

/// An action's popup page as a view, as Chromium's runtime gives it.
public protocol EngineExtensionPopupView: AnyObject {
    /// The page's view. It belongs in the app's popover while the popup is open.
    var view: NSView { get }
    /// The size the page asks for, in points.
    var preferredSize: CGSize { get }
    /// Called when the page asks for another size.
    var sizeDidChange: ((CGSize) -> Void)? { get set }
    /// Called once when the popup closes for any reason: the page closed itself, the user pressed Escape, its tab went, or `close()`.
    var didClose: (() -> Void)? { get set }
    func close()
}

/// A question that an engine's extension runtime needs the user to answer, beyond the access questions of `EngineExtensionAccess`.
public struct EngineExtensionPrompt {
    public enum Kind: Equatable {
        /// More access that the extension asks for at run time, such as with `permissions.request()`, in the engine's own sentences, which do not say which permissions or sites they stand for. Chromium keeps what the user allows until the extension's storage goes, except sites: a grant that covers every site lasts until the extension next loads while its install grant leaves sites out, and a load that moves the install grant from every site to some revokes every site granted at run time.
        case permissions([String])
        /// A reload of the tab, so that the actions that the named extensions were kept from running there run.
        case reload([String])
    }

    public var kind: Kind
    /// The tab the question belongs to, if any.
    public var tab: (any EngineWebContents)?

    public init(kind: Kind, tab: (any EngineWebContents)?) {
        self.kind = kind
        self.tab = tab
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
    /// Shows the action's popup for `tab`. Returns false when the app cannot show it, as when no window shows the tab; the engine then closes the popup.
    func extensions(_ extensions: any EngineExtensions, present popup: EngineExtensionPopup, ofExtension id: String, for tab: (any EngineWebContents)?) -> Bool
    /// Opens a tab of the engine that loads `url`, or the new tab page for nil, as `tabs.create` and an options page ask: in the window `windowID` as `setWindows` reported it, or in the focused window for nil, at `index` among that window's tabs of the engine, or where the app chooses for nil, and selects it when `active`. Completes with the tab's web contents once the app has reported it in its window, or with nil when it did not open.
    func extensions(_ extensions: any EngineExtensions, openTabWith url: URL?, inWindow windowID: UUID?, active: Bool, index: Int?,
                    completion: @escaping ((any EngineWebContents)?) -> Void)
    /// Opens a window with a tab of the engine for each address, or with the new tab page for none, as `windows.create` asks, and brings it forward when `focused`. Completes with the identity of the window as `setWindows` reports it, a new window that lists only the tabs it opened, or with nil when none opened.
    func extensions(_ extensions: any EngineExtensions, openWindowWith urls: [URL], focused: Bool, completion: @escaping (UUID?) -> Void)
    /// Asks the user the engine's question for the extension and answers whether the user accepted.
    func extensions(_ extensions: any EngineExtensions, extension id: String, asks prompt: EngineExtensionPrompt, completion: @escaping (Bool) -> Void)
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
    /// Stops each extension that the profile runs from an earlier launch and that the app has not loaded in this run, now and whenever the engine lists another. The app calls it after each pass of loads, once every load of the pass has ended, and as the profile starts while the app loads no extension in it; until the first call such extensions keep running, so that one the app is about to load does not stop and start again. An engine that keeps no extension from one launch to the next does nothing.
    func stopUnloadedExtensions()
    /// The extension's action for the tab, or nil when it is not loaded or has no action.
    func action(of id: String, for tab: any EngineWebContents) -> EngineExtensionAction?
    /// Runs the action for the tab, as a click on it does: the extension shows its popup or receives the click.
    func performAction(of id: String, for tab: any EngineWebContents)
    /// Allows the extension on the tab's site, where the engine kept it from running (`EngineExtensionAction.wantsSiteAccess`), which runs what it was kept from running there.
    func grantSiteAccess(of id: String, for tab: any EngineWebContents)
    /// The app's windows and the focused one, if extensions may see it, each time they change. The engine answers extensions' questions about windows and tabs from the last call and tells them what opened, closed, moved, and became active since the call before. A window whose identity an earlier window in the list has is left out.
    func setWindows(_ windows: [EngineExtensionWindow], focusedWindowID: UUID?)
}
