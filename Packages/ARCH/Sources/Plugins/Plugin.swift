// The plugin API: the protocols a plugin implements, the context through which it reaches the browser, and the values it receives. Every kind of plugin calls the same API, and a plugin gains a capability only when `PluginContext` gains a member.
import AI
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
    /// The panel of one of the plugin's sidebar items whose action is `.panel`. The manager asks each time the item opens it, and the popover holds it while it shows. A panel that can end while it shows conforms to `PluginEndingPanel`.
    func panel(for sidebarItemID: String) -> NSViewController?
    /// An event of a kind the manifest's `events` lists, or a change the user made to one of its settings when the manifest asks for those. The manager starts the plugin for it and ignores what it throws; a hook script's run ends when it returns and fails when it throws, a script plugin's with `PluginError.noListener` or `listenerFailed` for its listeners.
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

/// A panel that can end while its popover shows, as a script plugin's does once its instance stops and its page can do nothing more. The popover sets `onEnd` as it shows the panel and closes when the panel calls it.
@MainActor
public protocol PluginEndingPanel: NSViewController {
    var onEnd: (@MainActor () -> Void)? { get set }
}

/// A plugin compiled into the app. The app passes the list of these types to the plugin manager.
@MainActor
public protocol BuiltInPlugin: Plugin {
    static var manifest: PluginManifest { get }
    /// Whether the plugin is enabled in a Persona where the user has not switched it on or off.
    static var isOnByDefault: Bool { get }
    init()
}

/// The plugin's handle on the browser, scoped to one plugin instance in one Persona. Each call checks the plugin's grant and throws `PluginError.permissionDenied` when the grant does not cover it, and a page call `PluginError.siteNotGranted` for a page outside its sites. Once the instance stops, the storage and secrets only read, the other calls that act throw `PluginError.stopped`, and badges do nothing.
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
    /// The tabs the plugin reaches, in sidebar order, each without what the grant does not cover: its Persona's open tabs, never agent tabs. Without `tabs`, a tab shows its title and address only where the granted sites cover its page, and for `whenInvoked` only where the plugin has access in it. A plugin with `ai` gets no title or address of a tab on a site excluded from AI. Needs no permission.
    func tabs() throws -> [PluginTab]
    /// One of the tabs the plugin reaches, or nil for any other tab.
    func tab(_ id: PluginTab.ID) throws -> PluginTab?
    /// The tab the user has in front, as `tab(_:)` gives it: the selected tab of the browser window that last became main, when it is one of the tabs the plugin reaches and no internal page or the preview panel covers its page, as a command gets it. Nil otherwise. Needs no permission.
    func selectedTab() throws -> PluginTab?
    /// Needs `tabs.manage`. Opens a tab at the web address, `http` or `https`, in the space the options name, which must be one of the Persona's, or else in the last main window's space while it is the Persona's, or the Persona's first space, in the engine they name or the default engine, where a new tab that the user opens goes, and selects it unless they say not to, as `selectTab(_:)` does. Returns its identifier. The tab's opening, its selection, and its first load come with the plugin as their cause, so the plugin does not hear of them. Until the user clicks in the tab or loads an address in it, it downloads no file without asking, and at a file's address it closes without downloading. Throws `PluginError.invalidAddress` for any other address, `notGranted` for a space that is not the Persona's, and `closed` once the Persona is gone.
    func openTab(_ url: URL, _ options: PluginOpenTabOptions) throws -> PluginTab.ID
    /// Needs `tabs.manage`. Closes one of the tabs the plugin reaches without asking its page, as a web extension's `tabs.remove` does: a pinned tab unloads and keeps its place, a favorite's tab ends, a live folder item's tab is dismissed, and any other tab joins the closed list, from which Reopen Last Closed Tab and the Library reopen it; ⌘Z then reopens none of the tabs that the user closed before it, as after a page's own close. The close comes with the plugin as its cause. Throws `PluginError.notGranted` for any other tab.
    func closeTab(_ id: PluginTab.ID) throws
    /// Needs `tabs.manage`. Selects one of the tabs the plugin reaches in a browser window of its Persona: the window that shows the tab, else the front main window on its space, else the front main window of its Persona, which then shows its space. A window of another Persona keeps its Persona / Space, so without a main window of the Persona nothing changes, and no window or the app comes forward. The selection comes with the plugin as its cause. Throws `PluginError.notGranted` for any other tab.
    func selectTab(_ id: PluginTab.ID) throws
    /// Needs `tabs.rename`, which `tabs.manage` includes. Sets the tab's suggested name, or with nil removes it, under the rules of `PluginBrowserHost.renameTab(_:to:showing:cause:applying:)`, for the document the tab shows when the call arrives; while a hook step of the plugin runs, a rename of its event's tab is for its event's document, and once the scheduler has stopped the step, the tab does not take it; a script plugin's panel renames outside any step. Returns whether the tab took the change. Throws `PluginError.notGranted` for a tab the plugin does not reach.
    func renameTab(_ id: PluginTab.ID, to name: String?) throws -> Bool
    /// Needs `ai`. The AI interface under the plugin's own feature, `plugin.<id>`, whose requests carry text only: each request goes out under that feature and its route, whatever feature, route, or model it names. The client belongs to the plugin's hook step that runs at this call, if any, and a script plugin's panel's to none: its requests count toward the scheduler's pause, end with `cancelled` when the scheduler stops the step, and end at once after that, so a plugin asks for a client for each request. Every request stops when the instance stops.
    func ai() throws -> any AIClient
    /// Runs the script once in the main frame of the tab's page, in the world of the plugin's page scripts, as the body of a function with the world's channel as `arch`, and returns what the body returns at once as JSON: null for `undefined`, a function, or a symbol. A script that has to wait sends its result with `arch.send`. The tab must be one the plugin reaches, its document one the granted sites cover, and for a plugin that reaches its sites `whenInvoked` on the host where the user ran one of its commands in the tab, and for a plugin with `ai` neither the document nor the address the tab shows on a site excluded from AI; the script runs only while the granted sites cover the document, and its value comes back only while the tab still shows that document. Throws `PluginError.notGranted` for another tab, `siteNotGranted` for a page outside the sites, `noPage` for a tab without a page to run in or whose page changed meanwhile, `invalidPageScript` for a script the plugin may not run, `pageScriptFailed` with what the script threw, `pageRunUnavailable` where the tab's engine could run the script only with the user's gesture, as a WebKit tab while the flags switch plugins' page runs off, `timedOut` for a run that the page leaves unanswered for the hang limit, 10 seconds, as while a script loops, and `stopped` for one that the instance's stop ends.
    func runPageScript(_ script: PluginScript, in tab: PluginTab.ID) async throws -> PluginValue
    /// Delivers the value to the `arch.onMessage` listeners of the plugin's page scripts in the main frame of the tab's page, under the rules of `runPageScript(_:in:)` for the tab and its page, without the user's gesture: where the tab's engine could deliver it only with the gesture, as a WebKit tab while the flags switch plugins' page runs off, it throws `PluginError.pageRunUnavailable`. Nothing happens where no page script listens.
    func postMessage(_ message: PluginValue, toTab tab: PluginTab.ID) throws
}

extension PluginContext {
    /// A context that offers no selected tab, such as a hook script's, which acts on its run's tabs, gives none.
    public func selectedTab() throws -> PluginTab? { nil }

    /// A context that changes no tabs, such as a hook script's, refuses to open, close, and select them.
    public func openTab(_ url: URL, _ options: PluginOpenTabOptions) throws -> PluginTab.ID {
        throw PluginError.permissionDenied(.manageTabs)
    }

    public func closeTab(_ id: PluginTab.ID) throws {
        throw PluginError.permissionDenied(.manageTabs)
    }

    public func selectTab(_ id: PluginTab.ID) throws {
        throw PluginError.permissionDenied(.manageTabs)
    }

    /// A context that offers no AI, such as a hook script's, refuses it.
    public func ai() throws -> any AIClient {
        throw PluginError.permissionDenied(.ai)
    }

    /// A context that reaches no page, such as a hook script's, refuses page calls as for a tab it does not reach.
    public func runPageScript(_ script: PluginScript, in tab: PluginTab.ID) async throws -> PluginValue {
        throw PluginError.notGranted(tab)
    }

    public func postMessage(_ message: PluginValue, toTab tab: PluginTab.ID) throws {
        throw PluginError.notGranted(tab)
    }
}

/// A script that a plugin runs in a page with `PluginContext.runPageScript(_:in:)`. It must parse as the body of a function on its own, as a page script must.
public enum PluginScript: Hashable, Sendable {
    /// A UTF-8 text file of the plugin's package, by package path, such as `scripts/read.js`.
    case file(String)
    /// Script text, which only plugins built into Arch may run.
    case source(String)
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
    /// The page of a tab that `tabs(in:)` lists, through which plugins run scripts in it and post to its page scripts; nil for an agent tab and for a tab that is gone.
    func webContents(forTab id: UUID) -> (any EngineWebContents)?
    /// The selected tab of the browser window that last became main, a main or a small window, when it is the Persona's and no internal page or the preview panel covers its page; nil otherwise. It can be an agent tab, which the caller leaves out.
    func selectedTab(in persona: PersonaID) -> UUID?
    /// Opens a tab of the Persona at the address as `PluginContext.openTab(_:_:)` describes, with its events, its selection's, and its first load's carrying `cause`, and returns its identifier. Throws `PluginError.notGranted` when the options name a space that is not the Persona's, and `closed` once the Persona is gone.
    func openTab(_ url: URL, _ options: PluginOpenTabOptions, in persona: PersonaID, cause: BrowserEventCause) throws -> UUID
    /// Closes a tab that `tabs(in:)` lists as `PluginContext.closeTab(_:)` describes, with its event carrying `cause`. Nothing happens for an agent tab or a tab that is gone.
    func closeTab(_ id: UUID, cause: BrowserEventCause)
    /// Selects a tab that `tabs(in:)` lists as `PluginContext.selectTab(_:)` describes, with its event carrying `cause`. Nothing happens for an agent tab or a tab that is gone.
    func selectTab(_ id: UUID, cause: BrowserEventCause)
}

/// Where `PluginContext.openTab(_:_:)` opens a tab.
public struct PluginOpenTabOptions: Hashable, Sendable {
    /// A space of the plugin's Persona; nil for the space where a new tab that the user opens goes.
    public var spaceID: UUID?
    /// Whether the tab is selected once it opens.
    public var select: Bool
    /// nil for the default engine.
    public var engine: EngineKind?

    public init(spaceID: UUID? = nil, select: Bool = true, engine: EngineKind? = nil) {
        self.spaceID = spaceID
        self.select = select
        self.engine = engine
    }
}

/// What a command runs on.
public struct PluginInvocation: Sendable {
    /// The tab the command acts on: the selected tab, or the tab of the page or tab row the user chose the item on. Nil when there is none, when the selected tab belongs to another Persona, as a favorite's tab can, and while an internal page or the preview panel covers its page.
    public var tab: PluginTab?
    /// The space whose menu holds the item, for a space menu item.
    public var spaceID: UUID?
    /// For a page context menu item, the link, image, and selected text the user clicked on. The user chose the item there, so the plugin receives them whatever its grant, except that a plugin with `ai` receives none of them on a page on a site excluded from AI, and no link or image address on such a site.
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
    /// Arch uses this token to bind a hook to its document. Script values omit it.
    public var documentID: UUID?
    /// The address of the document the tab shows, which the engine committed, while `url` can already be a navigation's that has not. A tab that leaves a page keeps that page's title until the next document commits, so the check for sites excluded from AI reads both. nil where `title` and `url` are; script values omit it.
    public var documentURL: URL?

    public init(id: UUID, spaceID: UUID?, title: String?, url: URL?, engine: EngineKind, isPinned: Bool, isSelected: Bool, kind: BrowserTabKind = .open, documentID: UUID? = nil,
                documentURL: URL? = nil) {
        self.id = id
        self.spaceID = spaceID
        self.title = title
        self.url = url
        self.engine = engine
        self.isPinned = isPinned
        self.isSelected = isSelected
        self.kind = kind
        self.documentID = documentID
        self.documentURL = documentURL
    }

    /// The name that code gives a tab from `text`: its first line, trimmed and cut to `maximumNameLength` characters, or nil when nothing is left.
    public static func name(from text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let name = String(line.trimmingCharacters(in: .whitespaces).prefix(maximumNameLength)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The tab without its title and addresses unless the grant has `tabs` or the plugin `reaches` the address it shows: its granted sites cover it, and for `whenInvoked` its access in the tab does too.
    func redacted(for grant: PluginGrant, reaches: (URL) -> Bool) -> PluginTab {
        guard !grant.permissions.contains(.tabs), !(url.map(reaches) ?? false) else { return self }
        var tab = self
        tab.title = nil
        tab.url = nil
        tab.documentURL = nil
        return tab
    }
}

/// An event a plugin receives: only the kinds its manifest's `events` lists reach it.
public enum PluginEvent: Sendable {
    /// A bus event as the receiver's grant lets it see it (`BrowserEvent.view(_:)`), with members that the sender adds to its JSON, such as a hook script's `hook`.
    case browser(BrowserEventScriptView, extra: [String: PluginValue] = [:])
    /// The user changed the plugin's setting `key` in Settings ▸ Plugins, which reaches a plugin whose manifest asks for its setting changes (`PluginManifest.receivesSettingChanges`). The plugin reads the new value with `PluginContext.setting(_:)`, or a secret setting's with `secrets`.
    case settingChanged(key: String)

    /// The name of a setting change's kind, which `plugin.json`'s `events` lists and `arch.events.on` takes.
    static let settingChangedKind = "settingChanged"

    /// The bus kind of a browser event; nil for a setting change, which comes from Settings rather than the bus.
    public var kind: BrowserEventKind? {
        switch self {
        case .browser(let view, _): return view.kind
        case .settingChanged: return nil
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
    /// The command acts on a page, and the invocation has none, or a page call's tab has no page to run in, or its page changed while the call ran.
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
    /// A script plugin's background script left its start, a command, or a page script value unanswered past the hang limit, or a page left a page call's run unanswered for as long.
    case timedOut
    /// Two plugins cannot become, or stop being, versions of one plugin, for the reason the text gives as a sentence.
    case invalidVersions(String)
    /// The manager's Persona was deleted, so it stages, installs, and stores nothing.
    case closed
    /// The call names a tab the plugin or hook script does not reach: another Persona's, an agent tab, or for a hook one its filter does not cover; or a space of another Persona.
    case notGranted(UUID)
    /// A script plugin's background script set no listener for the event's kind with `arch.events.on`.
    case noListener
    /// A listener of the event threw, or its promise rejected, with what it threw as text, such as an error's message.
    case listenerFailed(String)
    /// A page call's page is outside the plugin's granted sites, or for a plugin with `ai` on a site excluded from AI. It names no address, since the grant may keep the page's from the plugin.
    case siteNotGranted
    /// The script is not one the plugin may run in a page, for the reason the text gives as a sentence: a path that names no text file of its package, a source that does not parse as the body of a function, or script text from a plugin that is not built in.
    case invalidPageScript(String)
    /// The script that the plugin ran in a page threw, with what it threw as text, or returned a value that JSON cannot hold.
    case pageScriptFailed(String)
    /// The tab's engine could run a page call's script, or deliver its message, only with the user's gesture, which would give the page's handlers for the events it dispatches user activation, so it ran nothing: on WebKit while the flags on `flags://` switch off plugins' page runs and messages, or the private member they use is gone.
    case pageRunUnavailable
    /// The address that the plugin would open a tab at is not a web page's, `http` or `https`, such as a file's or an internal page's, as the text gives it.
    case invalidAddress(String)
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
        case .notGranted: return "The tab or space is not one this plugin or hook may reach."
        case .noListener: return "The plugin\u{2019}s script set no listener for the event."
        case let .listenerFailed(message): return message
        case .siteNotGranted: return "The page is not on a website this plugin may reach."
        case let .invalidPageScript(reason): return reason
        case let .pageScriptFailed(message): return message
        case .pageRunUnavailable: return "Arch cannot reach this tab\u{2019}s page for the plugin without your gesture now."
        case let .invalidAddress(text): return "\u{201C}\(text)\u{201D} is not the address of a web page."
        }
    }
}
