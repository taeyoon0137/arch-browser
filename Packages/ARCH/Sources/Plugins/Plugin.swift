// The plugin API: the protocols a plugin implements, the context through which it reaches the browser, and the values it receives. Every kind of plugin calls the same API, and a plugin gains a capability only when `PluginContext` gains a member.
import AppKit
import ARCHEngine
import Events

/// A running plugin in one Persona.
@MainActor
public protocol Plugin: AnyObject {
    /// Called once, before the instance's first command, panel, or page script value, whichever comes first, reaches it. The context acts for this instance until it stops: when the user switches the plugin off, updates it, removes it, or deletes its Persona, when the activation throws, and for a script plugin also when its background script stops for being idle, hung, or ended.
    func activate(in context: any PluginContext) async throws
    /// Called when the instance stops, once its activation has ended, after which the manager drops the instance. Its context has stopped acting by then. The plugin's next use starts a new instance.
    func deactivate() async
    /// Runs one of the commands the manifest lists.
    func run(_ command: String, _ invocation: PluginInvocation) async throws
    /// A value one of the plugin's page scripts sent. The returned value is the script's reply.
    func receive(_ message: PluginPageMessage) async throws -> PluginValue?
    /// The panel of one of the plugin's sidebar items whose action is `.panel`. The manager asks each time the item opens it, and the popover holds it while it shows.
    func panel(for sidebarItemID: String) -> NSViewController?
    /// An event of a kind the manifest's `events` lists. The manager starts the plugin for it and ignores what it throws; a hook script's run ends when it returns and fails when it throws, a script plugin's with `PluginError.noListener` or `listenerFailed` for its listeners.
    func handle(_ event: PluginEvent) async throws
}

extension Plugin {
    public func deactivate() async {}
    /// Without an implementation, the plugin replies with nothing.
    public func receive(_ message: PluginPageMessage) async throws -> PluginValue? { nil }
    /// Without an implementation, the item opens nothing.
    public func panel(for sidebarItemID: String) -> NSViewController? { nil }
    /// Without an implementation, the plugin ignores events.
    public func handle(_ event: PluginEvent) async throws {}
}

/// A plugin compiled into the app. The app passes the list of these types to the plugin manager.
@MainActor
public protocol BuiltInPlugin: Plugin {
    static var manifest: PluginManifest { get }
    /// Whether the plugin is enabled in a Persona where the user has not switched it on or off.
    static var isOnByDefault: Bool { get }
    init()
}

/// The plugin's handle on the browser, scoped to one plugin instance in one Persona. Each call checks the plugin's grant and throws `PluginError.permissionDenied` when the grant does not cover it. Once the instance stops, the storage and secrets only read, the other calls that act throw `PluginError.stopped`, and badges do nothing.
@MainActor
public protocol PluginContext: AnyObject {
    var pluginID: PluginID { get }
    var personaID: PersonaID { get }
    var grant: PluginGrant { get }
    /// The plugin's own storage in its Persona. Needs no permission.
    var storage: any PluginStorage { get }
    /// The plugin's secrets in its Persona, its secret settings among them under their keys. Needs no permission.
    var secrets: any PluginSecrets { get }
    /// The value of one of the plugin's settings: the user's, or the manifest's default. Nil for a key the manifest does not list and for a secret setting, whose value `secrets` holds.
    func setting(_ key: String) -> PluginValue?
    /// Shows `text` as the badge of one of the plugin's sidebar items, or no badge for nil or empty text. The badge stays until the plugin changes it or the user switches the plugin off, updates it, or removes it, also after a script plugin's instance stops on its own.
    func setBadge(_ text: String?, onSidebarItem id: String)
    /// Needs `clipboard`.
    func copyToClipboard(_ text: String) throws
    /// The tabs the plugin reaches, in sidebar order, each without what the grant does not cover: its Persona's open tabs, never agent tabs. Needs no permission.
    func tabs() throws -> [PluginTab]
    /// One of the tabs the plugin reaches, or nil for any other tab.
    func tab(_ id: PluginTab.ID) throws -> PluginTab?
    /// Needs `tabs.rename`. Sets the tab's suggested name, or with nil removes it, under the rules of `PluginBrowserHost.renameTab(_:to:showing:cause:applying:)`, for the document the tab shows when the call arrives. Returns whether the tab took the change. Throws `PluginError.notGranted` for a tab the plugin does not reach.
    func renameTab(_ id: PluginTab.ID, to name: String?) throws -> Bool
}

/// A sandbox that may hand a script's agent options to a user-authorized browser hook.
@MainActor
public protocol PluginAgentContext: PluginContext {
    var permitsAgentRuns: Bool { get }
    func runAgent(_ options: PluginValue) async throws -> PluginValue
}

/// What `Browsing` provides so that plugins and hook scripts reach tabs without `Plugins` depending on `Browsing`. One host serves every Persona.
@MainActor
public protocol PluginBrowserHost: AnyObject {
    /// The Persona's open tabs in sidebar order, with titles and addresses before any grant applies; never agent tabs.
    func tabs(in persona: PersonaID) -> [PluginTab]
    /// Sets the tab's suggested name under the AI hooks' rules (`docs/hooks.md`, hook decision 13): the name's first line, trimmed and cut to `PluginTab.maximumNameLength` characters, while the tab still shows `document`, ignoring the fragment, the user has not named it, and the user has not turned down a suggested name for that document. Nil removes a suggested name for the document. A nil `document` stands for the tab's committed address now. The change's events carry `cause`. With `applying` false, nothing changes and the answer says whether the tab would take it. False for a favorite's tab, which goes by its favorite's name, for an agent tab, and for a tab that is gone.
    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool
}

/// What a command runs on.
public struct PluginInvocation: Sendable {
    /// The tab the command acts on: the selected tab, or the tab of the page or tab row the user chose the item on. Nil when there is none, when the selected tab belongs to another Persona, as a favorite's tab can, and while an internal page or the preview panel covers its page.
    public var tab: PluginTab?
    /// The space whose menu holds the item, for a space menu item.
    public var spaceID: UUID?
    /// For a page context menu item, the link, image, and selected text the user clicked on. The user chose the item there, so the plugin receives them whatever its grant.
    public var linkURL: URL?
    public var imageURL: URL?
    public var selection: String?

    public init(tab: PluginTab?, spaceID: UUID? = nil, linkURL: URL? = nil, imageURL: URL? = nil, selection: String? = nil) {
        self.tab = tab
        self.spaceID = spaceID
        self.linkURL = linkURL
        self.imageURL = imageURL
        self.selection = selection
    }
}

/// A value a page script sent to its plugin.
public struct PluginPageMessage: Sendable {
    /// The tab whose page holds the sending frame.
    public var tab: PluginTab
    /// The address of the sending frame's document, which the plugin's granted sites cover.
    public var frameURL: URL
    public var isMainFrame: Bool
    public var body: PluginValue
}

/// A tab as a plugin sees it.
public struct PluginTab: Identifiable, Hashable, Sendable {
    /// The longest name that code gives a tab.
    public static let maximumNameLength = 60

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
    /// Where the tab lives, as events name it.
    public var kind: BrowserTabKind

    public init(id: UUID, spaceID: UUID?, title: String?, url: URL?, engine: EngineKind, isPinned: Bool, isSelected: Bool, kind: BrowserTabKind = .open) {
        self.id = id
        self.spaceID = spaceID
        self.title = title
        self.url = url
        self.engine = engine
        self.isPinned = isPinned
        self.isSelected = isSelected
        self.kind = kind
    }

    /// The name that code gives a tab from `text`: its first line, trimmed and cut to `maximumNameLength` characters, or nil when nothing is left.
    public static func name(from text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let name = String(line.trimmingCharacters(in: .whitespaces).prefix(maximumNameLength)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
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

/// An event a plugin receives: only the kinds its manifest's `events` lists reach it.
public enum PluginEvent: Sendable {
    /// A bus event as the receiver's grant lets it see it (`BrowserEvent.view(_:)`), with members that the sender adds to its JSON, such as a hook script's `hook`.
    case browser(BrowserEventScriptView, extra: [String: PluginValue] = [:])

    public var kind: BrowserEventKind {
        switch self {
        case .browser(let view, _): return view.kind
        }
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
    /// Nil for a key the storage does not hold, and for a reserved key.
    func value(forKey key: String) -> PluginValue?
    /// nil removes the key. Throws `PluginError.reservedKey` for a key that starts with the prefix of the plugin's settings, `PluginError.quotaExceeded` when the storage would grow past its limit, and an encoding error for a value JSON cannot hold, such as infinity or arrays and objects nested more than 510 levels deep; the storage then keeps its previous value.
    func setValue(_ value: PluginValue?, forKey key: String) throws
    /// In ascending order, without the reserved keys.
    func allKeys() -> [String]
}

/// A plugin's secrets in one Persona, kept in the Keychain. Each call waits off the main thread, since macOS may first ask for the login keychain password.
@MainActor
public protocol PluginSecrets: AnyObject {
    func secret(forKey key: String) async throws -> String?
    /// nil deletes the Keychain item. Throws `PluginError.quotaExceeded` for a secret of more than 16 KB, and for a new key once the plugin keeps 64 secrets in the Persona, its secret settings among them.
    func setSecret(_ secret: String?, forKey key: String) async throws
}

public enum PluginError: Error, Hashable, Sendable {
    /// The plugin's grant lacks the permission a call needs.
    case permissionDenied(PluginPermission)
    /// The plugin instance whose context the call went through has stopped.
    case stopped
    /// The command acts on a page, and the invocation has none.
    case noPage
    /// The text is not a match pattern.
    case invalidMatchPattern(String)
    /// The text is not a shortcut.
    case invalidShortcut(String)
    /// The storage key starts with the prefix that the plugin's settings use.
    case reservedKey(String)
    /// A write would take the plugin's storage, or its secrets, past their limits.
    case quotaExceeded
    /// The folder or archive is not a package Arch can install, for the reason the text gives as a sentence.
    case invalidPackage(String)
    /// The package targets a plugin API newer than `PluginManifest.apiVersion`.
    case unsupportedAPIVersion(Int)
    /// A script plugin's background script left its start, a command, or a page script value unanswered past the hang limit.
    case timedOut
    /// Two plugins cannot become, or stop being, versions of one plugin, for the reason the text gives as a sentence.
    case invalidVersions(String)
    /// The manager's Persona was deleted, so it stages, installs, and stores nothing.
    case closed
    /// The call names a tab the plugin or hook script does not reach: another Persona's, an agent tab, or for a hook one its filter does not cover.
    case notGranted(UUID)
    /// A script plugin's background script set no listener for the event's kind with `arch.events.on`.
    case noListener
    /// A listener of the event threw, or its promise rejected, with what it threw as text, such as an error's message.
    case listenerFailed(String)
}

extension PluginError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .permissionDenied(permission): return "The plugin may not \(permission.summary.prefix(1).lowercased() + permission.summary.dropFirst())."
        case .stopped: return "The plugin has stopped."
        case .noPage: return "The command needs a page."
        case let .invalidMatchPattern(text): return "“\(text)” is not a site pattern."
        case let .invalidShortcut(text): return "“\(text)” is not a shortcut."
        case let .reservedKey(key): return "The storage key “\(key)” belongs to the plugin\u{2019}s settings."
        case .quotaExceeded: return "The plugin has no room left for the value."
        case let .invalidPackage(reason): return reason
        case let .unsupportedAPIVersion(version): return "The plugin needs a newer version of Arch, with plugin API version \(version)."
        case .timedOut: return "The plugin did not answer in time."
        case let .invalidVersions(reason): return reason
        case .closed: return "The plugin\u{2019}s Persona was deleted."
        case .notGranted: return "The tab is not one this plugin or hook may reach."
        case .noListener: return "The plugin\u{2019}s script set no listener for the event."
        case let .listenerFailed(message): return message
        }
    }
}
