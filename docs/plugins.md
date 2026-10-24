# Plugin system design

## Purpose and scope

- This note designs Arch's plugin system for queue task V.11 and rows 44 and 50 of `docs/features.md`. It also covers how tasks that build on plugins fit: web extensions on WebKit (IV.12) and on Chromium (VI.1), the password manager plugins (IV.13, row 39), Personas (III.12), AI hooks (VII.6), and plugins that AI writes (VII.7, row 55).
- A plugin can add sidebar items, palette commands, menu items, keyboard shortcuts, settings, panels, and page scripts that run on both engines. Plugins have more capabilities than browser extensions. Each capability uses the app's own interface.
- Built-in plugins ship with the app. Later features can ship as built-in plugins and reach the browser only through the plugin API.
- Installed plugins belong to one Persona. Manifest V3 web extensions are one kind of installed plugin.
- Plugins use public APIs only. Nothing in this note needs a private API or a flag on `flags://`.

## Principles

- All plugin kinds call one API. Built-in, installed, and AI-written plugins call the Swift API defined by `PluginContext`. Script plugins reach it through a JavaScript bridge, and web extensions reach it through a manifest mapping. A plugin gains a capability only when `PluginContext` gains a member. The engine protocols follow the same rule.
- Declare first. A plugin's manifest lists its contributions, permissions, and requested events. Arch shows the contributions and starts the plugin's code only when one of them is used.
- Only built-in Swift plugins, which are part of the app, run in the app process. Installed code runs in a WebKit web content process or in an engine's own extension runtime.
- Only code the user reviewed runs. Script plugins load scripts only from their own package, and page scripts come only from package files.
- No servers, no store, no automatic updates. Plugins come from the app bundle, user-selected files, or the AI feature (VII.7). An update is a new install of the same identifier.

## Plugin kinds

| Kind | Code | Where it runs | Supplied by | Persona |
|---|---|---|---|---|
| `builtIn` | Swift type in an Arch module, conforming to `BuiltInPlugin` | App process, main actor | The app bundle | Present in every Persona; enabled or disabled per Persona |
| `script` | Arch package: `plugin.json`, HTML, JavaScript, CSS | A hidden `WKWebView` per running plugin; page scripts in the tab's engine | A folder or `.zip` the user chooses, or VII.7 | Installed in one Persona |
| `webExtension` | Manifest V3 web extension package | `WKWebExtensionController` on WebKit tabs; CEF's extension runtime on Chromium tabs after VI.1 | A folder, `.zip`, or `.crx` file the user chooses | Installed in one Persona |

A folder with `plugin.json` is a script plugin. A folder with a `manifest.json` that has `manifest_version` 3 is a web extension. Arch refuses other folders, and manifests with an `apiVersion` higher than the app supports.

## Package and manifest

A script plugin's `plugin.json`:

```json
{
  "id": "org.example.reading-time",
  "name": "Reading Time",
  "version": "1.2.0",
  "apiVersion": 1,
  "summary": "Shows how long the current page takes to read.",
  "permissions": ["tabs", "notifications"],
  "sites": ["https://*/*"],
  "siteAccess": "whenInvoked",
  "network": [],
  "events": ["pageLoaded"],
  "background": "background.js",
  "contributes": {
    "commands": [
      { "id": "show", "title": "Show Reading Time", "symbol": "clock", "keywords": ["read", "time"], "shortcut": "ctrl+opt+r" }
    ],
    "menus": [
      { "command": "show", "location": "pageContextMenu", "contexts": ["page", "selection"] }
    ],
    "sidebarItems": [
      { "id": "panel", "title": "Reading", "symbol": "book", "panel": "panel.html", "presentation": "popover" }
    ],
    "settings": [
      { "key": "wordsPerMinute", "title": "Words per minute", "type": "number", "default": 230, "min": 100, "max": 600 }
    ],
    "pageScripts": [
      { "matches": ["https://*/*"], "js": ["count.js"], "css": [], "runAt": "documentEnd", "allFrames": false }
    ]
  }
}
```

| Field | Meaning |
|---|---|
| `id` | Reverse-DNS identifier, at most 128 characters of letters, digits, `-`, and `.`. A later install with the same `id` in the same Persona is an update |
| `apiVersion` | The plugin API version the package targets. The app supports versions up to `PluginManifest.apiVersion` |
| `permissions` | Capabilities from the permission table below |
| `sites` | Match patterns (see below) for the pages the plugin's page scripts and page calls may reach |
| `siteAccess` | `listedSites` (every page that matches `sites`) or `whenInvoked` (only the selected tab's site after the user runs one of the plugin's commands there) |
| `network` | Hosts the plugin may fetch from through `arch.net.fetch` |
| `events` | Events that start the plugin's background code |
| `background` | The background script. A plugin without one can still add page scripts, settings, and panels |
| `contributes` | Commands, menu items, sidebar items, settings, a settings page, and page scripts |

Symbols use SF Symbols names, so plugins need no image files. A package may still carry an `icon` image for its Settings row.

### Match patterns

`sites` and a page script's `matches` and `excludes` hold match patterns. A pattern is `<scheme>://<host><path>` or `<all_urls>`, which equals `*://*/*`.

| Part | Rule |
|---|---|
| Scheme | `http`, `https`, or `*` for both. Patterns reach web pages only, never local files or internal pages |
| Host | `*` for every host, a name such as `example.com` for that host only, or `*.example.com` for that host and its subdomains. A name is dot-separated labels of ASCII letters, digits, and `-`; an internationalized name uses its `xn--` form. A pattern has no port and covers every port of its host |
| Path | Starts with `/`. Each `*` matches any run of characters. The path is compared with the address's percent-encoded path and query, without the fragment, so `/search*` covers `/search?q=arch` |

- Schemes and hosts ignore case; paths do not.
- Text that breaks these rules throws `PluginError.invalidMatchPattern` with the text.
- Without `tabs`, a plugin still sees the title and address of a tab whose page its granted sites cover.

## Contributions

Each contribution names its plugin wherever it appears: in the palette row's subtitle, in the menu item's section, in the sidebar item's tooltip, and in the Settings section. Identifiers belong to the plugin, so two plugins can use the same command `id`.

| Contribution | Where it appears | Notes |
|---|---|---|
| Command | The command palette, after the primary row and before history suggestions, when the typed text matches the title or a keyword; Settings ▸ Shortcuts (IV.3) | A command with `takesArgument` shows its title as a token in the palette field and receives the text the user types after it |
| Shortcut | The command's menu item | App shortcuts take priority over plugin shortcuts. Between plugins, the first installed keeps the shortcut, and Settings shows the conflict |
| Menu item | A Plugins menu in the menu bar, grouped by plugin; the page context menu for the listed contexts (page, link, image, selection, editable); the tab context menu; the space menu | Page context menu items run app-side, so they work alike on both engines, as row 49 requires |
| Sidebar item | A row below the favorites with a symbol, a title, and an optional badge | It runs a command or opens a panel |
| Panel | A popover beside the sidebar item, or a page that takes the sidebar's place as the library does | A script plugin's panel uses one of its HTML files in a sandboxed web view. A built-in plugin's panel uses a view controller |
| Settings | Settings ▸ Plugins ▸ the plugin's name, rendered by Arch as a native form | Toggle, text, number, choice, and secret fields. A script plugin may add an HTML settings page below the form |
| Page script | Pages that match the plugin's grant, on both engines | See Page scripts |
| Event | Not shown | `tabOpened`, `tabClosed`, `tabSelected`, `pageLoaded`, `downloadFinished`, `spaceChanged`, `settingChanged` |

## Page scripts

A page script is a JavaScript or CSS file from the plugin's package that runs in the pages its grant covers. Arch wraps each script in a guard that checks the frame's address against the plugin's patterns. Engines only need to inject scripts; they do not need to match addresses. Each plugin has its own world name, `ARCHPlugin.<plugin id>`.

- WebKit: each script becomes a `WKUserScript` in the plugin's `WKContentWorld.world(name:)`, so the page and other plugins cannot see its globals. Messages from the script go through a `WKScriptMessageHandlerWithReply` added only to that world. Arch reaches the script with `evaluateJavaScript(_:in:in:)` in the same world. Style files go through the existing `insertStylesheet`.
- Chromium: CEF 156's public API has no isolated worlds (needs verification). The app passes the scripts to the renderer in `extra_info` when it creates the browser and in a process message when they change. The helper's `CefRenderProcessHandler::OnContextCreated` runs them in the page's main world before the page's own scripts. A native function made with `CefV8Value::CreateFunction` carries messages to the browser process as `CefProcessMessage`s. Each plugin's wrapper keeps that function and its delivery function in a closure. It removes them from `window` before the page runs. Document-end scripts wait for `DOMContentLoaded`.
- The Chromium difference: the page can see what a plugin's script changes in the DOM and can replace DOM methods the script calls later. The script's closure stays private. Plugins treat pages as untrusted on both engines. The app treats every page script message as page input. The difference therefore affects plugin reliability, not app safety. A CEF patch that adds isolated worlds can join Phase VI if a plugin needs one.
- With `listedSites`, the scripts join every matching tab's script list. With `whenInvoked`, the host runs them in the selected tab's current page through `executeJavaScript(_:inWorld:completion:)` when the user runs one of that plugin's commands there. They stay in that tab's list until it leaves the site.
- Scripts change from the next document a tab loads. Enabling a plugin does not reload open pages; Settings offers Reload Matching Tabs. Disabling a plugin closes its message channel at once. Running scripts cannot reach it and stop at the next load.
- Messages carry JSON. The app delivers a page message to the plugin only when the sending frame's address still matches the plugin's grant.

## Permissions

| Permission | Grants | Without it |
|---|---|---|
| `tabs` | Titles and addresses of the Persona's tabs, in calls and events | Tabs and events carry identifiers, engines, and pinned state only, except for pages the site grant covers |
| `tabs.manage` | Open, close, select, rename, and move tabs | Calls throw `permissionDenied` |
| Sites (`sites` with `siteAccess`) | Page scripts, page messages, and running package scripts in matching pages | No page access |
| `network` hosts | `fetch` to the listed hosts through an ephemeral `URLSession` with no cookies | No network access from plugin code |
| `history` | Search browsing history | Calls throw `permissionDenied` |
| `downloads` | `downloadFinished` events with file names and addresses; renaming finished downloads | No download events |
| `clipboard` | Writing text to the clipboard | Calls throw `permissionDenied` |
| `notifications` | Local notifications through UserNotifications | Calls throw `permissionDenied` |
| `ai` | Requests through the AI interface (VII.1) under the plugin's own routing entry | No AI access |
| `nativeMessaging` | Messages to a native helper app that the extension names | Web extensions only; Arch refuses it in other kinds |

- Installation shows a sheet that states each permission in a plain sentence, such as "Read the titles and addresses of your tabs" or "Run scripts on pages from example.com". The user can narrow the sites and switch `siteAccess` to `whenInvoked` before installing. When a manifest asks for all sites, the sheet starts with `whenInvoked`. The result is the plugin's `PluginGrant`.
- Granting access to all sites or `nativeMessaging` asks for Touch ID through LocalAuthentication, following the Platform integration table.
- Settings ▸ Plugins lists each grant and revokes any part of it. Calls that need a revoked permission get `permissionDenied`. Contributions that need it are hidden.
- An update that asks for more than the current grant shows the sheet again with the new items marked. An update that asks for less narrows the grant without asking.
- Built-in plugins declare permissions the same way. The app does not sandbox their code, but `PluginContext` checks their grant like any other. Settings shows the grant, and the user can switch the plugin off.
- A plugin never sees cookies, passwords, or API keys. Its fetches carry no Persona cookies, so a plugin cannot act as the user on a site. Site data stays in the engines.

## Sandboxing

- Built-in plugins run in the app process. They are trusted, reviewed with the app, and limited to `PluginContext` by convention.
- Script plugins run their background script in a hidden `WKWebView` owned by the `Plugins` module. The code runs in a separate WebKit web content process, regardless of the tabs' engine:
  - Its documents load from `arch-plugin://<plugin id>/` through a `WKURLSchemeHandler` that serves only the installed package.
  - Every document has a content security policy of `default-src 'self'` and a `connect-src` limited to the scheme itself, with no `unsafe-eval`. Network access goes through `arch.net.fetch`, which the host checks against the grant's hosts.
  - A `WKContentRuleList` blocks every load outside the plugin's scheme as a second layer.
  - Each plugin uses its own `WKWebsiteDataStore.nonPersistent()`, so it shares no cookies or site storage with any Persona or plugin. Its lasting state goes through `arch.storage`.
  - The bridge is a `WKScriptMessageHandlerWithReply` on that web view only. The host identifies the calling plugin by the sending web view, never by the message.
  - Panels and HTML settings pages use the same configuration and bridge.
- Web extensions run in the engines' own extension sandboxes: WebKit's for `WKWebExtensionController`, Chromium's for CEF's extension runtime.
- Hangs and crashes: a background is hung if it leaves an event or command unanswered for 10 seconds. The host releases its web view (whether WebKit then ends the process at once needs verification) and starts it again at the next event. `webViewWebContentProcessDidTerminate` reports crashes the same way. After three failures within five minutes, the host disables the plugin. Its Settings row says why.
- Resources: a background starts at its first event, command, or page message and stops after 30 seconds without work. A panel's web view lives only while the panel is open.

## Lifecycle

| State | Meaning |
|---|---|
| `disabled` | Installed; no contributions show and no code runs |
| `idle` | Enabled; contributions show, page scripts inject, no background runs |
| `running` | Enabled with its background or panel running |
| `failed` | Disabled by the host after repeated failures, with the reason |
| `unavailable` | Cannot run on this system or engine, with the reason, such as a web extension below macOS 15.4 |

1. Stage: the user chooses a folder or archive with `NSOpenPanel`, or VII.7 hands over a folder. Arch copies it to a staging folder, reads and validates the manifest, and lists the files.
2. Review: the install sheet shows the name, version, origin, permissions, and sites. For an AI-written plugin it also shows every file's source.
3. Install: Arch moves the staged package into the Persona's plugin folder and records it in `plugins.json`. It is disabled unless the user chose Install and Enable.
4. Enable: Arch registers the contributions, adds the page scripts to the Persona's tabs from their next load, and sends `activate` when the background first starts.
5. Update: installing the same `id` again replaces the package after review and keeps storage. A running background stops and restarts on the new code.
6. Disable: Arch removes the contributions, closes page message channels, sends `deactivate`, and stops the background.
7. Remove: after a confirmation sheet, Arch disables the plugin and deletes its package, storage, and Keychain items. Built-in plugins cannot be removed, only disabled.
8. Launch: each Persona's manager reads `plugins.json`, registers the built-in types, and shows enabled contributions. Installed plugin code runs only when needed.

## Storage

```
~/Library/Application Support/Arch/Plugins/<persona id>/
  plugins.json                  Installed plugins: manifest, origin, grant, enabled state, install date
  <plugin id>/package/          The installed package (script and web extension plugins)
  <plugin id>/storage.json      Key-value storage, written atomically after changes settle
```

- `<persona id>` is the Persona's UUID as `UUID.uuidString` writes it, so the default Persona's folder is `Plugins/D59DAF4B-E372-4AF9-890E-455B8B3860F3/`. The app gives `PluginManager` its Application Support folder, and the manager derives the Persona's folder from it.
- `storage.json` is a JSON object of the plugin's keys and `PluginValue`s, up to 5 MB (5,000,000 bytes) per plugin, counted as the UTF-8 bytes of each key plus the JSON of its value. A write that grows the storage past the limit throws `quotaExceeded`; removals and writes that do not grow it always succeed. Settings values live in the same file under a reserved prefix.
- Changes reach `storage.json` together 0.5 seconds after the last one, and at quit. A missing or unreadable file counts as empty. The manager keeps one storage per plugin while it runs, so a plugin that starts again after a failed activation finds the changes that have not reached the file.
- Secret settings and `arch.secrets` use Keychain Services: generic password items with the service `local.arch.browser.plugin.<plugin id>` and the account `<persona id>/<key>`.
- Web extensions keep their own extension storage in the engine: WebKit under the Persona's `WKWebExtensionController` configuration identifier, Chromium in the Persona's CEF cache path.
- Sync (V.9) does not cover plugins. A later task can sync `plugins.json` without packages or secrets.

## Personas

- Each Persona has one `PluginManager`. A plugin sees only its Persona's spaces, tabs, history, and downloads. It gets events only from them.
- Installing a plugin in two Personas creates two installations with separate grants, storage, secrets, and background processes. Settings offers Install in Another Persona, which copies the package and asks for a new grant.
- Built-in plugins exist in every Persona. A new Persona enables the built-in plugins that are on by default.
- V.11 builds after III.12. If it starts first, every plugin belongs to one default Persona whose identifier III.12 adopts.

## Web extensions as plugins

The `Extensions` module (IV.12) turns a web extension into a plugin. It synthesizes a `PluginManifest` from `manifest.json` and runs the extension in each engine's runtime.

| Extension feature | Plugin contribution or permission |
|---|---|
| `action` | An item in the site settings popover (IV.12) and a palette command with the extension's name. The popup shows in Arch's own popover on both engines |
| `commands` | Commands with their suggested shortcuts |
| `options_ui` or `options_page` | A settings page entry that opens the options page in a sheet |
| `permissions` and `host_permissions` | The install sheet's permissions and sites; requests at run time show Arch's own sheet |
| `content_scripts` | Run by the engine's extension runtime, not by Arch's page scripts |
| `nativeMessaging` | Arch relays messages to the native helper (see below) |

- WebKit: one `WKWebExtensionController` per Persona, made with `WKWebExtensionController.Configuration(identifier:)` and the Persona's identifier, and set as each WebKit tab's `webExtensionController`. Arch adapts its tabs and windows to `WKWebExtensionTab` and `WKWebExtensionWindow`. It handles permission prompts, action popups, and options pages from the controller's delegate with its own sheets and popovers. Requires macOS 15.4; below it, web extension plugins are `unavailable`.
- Chromium: after VI.1, CEF's extension runtime loads the same package into the Persona's `CefRequestContext` (needs verification). Until then, an extension runs on WebKit tabs only, and its contributions say so on Chromium tabs.
- One install, two runtimes: each engine runs its own copy of the extension with its own background and storage. An extension's state, such as a password manager's lock, is not shared between engines. Each copy lists its own engine's tabs. Whether WebKit can list Chromium tabs as tabs without a web view needs verification.
- Identifier: Arch uses one extension identifier for both engines. It takes the identifier from the package's public key if present; otherwise, it generates one at install. WebKit receives it as the context's `uniqueIdentifier` (needs verification for helpers that check the calling extension's origin).
- Native messaging: Arch answers `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:)` and the matching port call on WebKit. It finds the helper through a host manifest in `~/Library/Application Support/Arch/NativeMessagingHosts/`, starts it with `Process`, and exchanges length-prefixed JSON over its standard input and output. Chromium's runtime does its own native messaging after VI.1. Whether the vendors' helpers install host manifests for Arch needs verification in IV.13.

## Password manager plugins

- The user installs the 1Password and iCloud Passwords web extension plugins in each Persona that needs them. Arch bundles no third-party code.
- Both need `nativeMessaging` to reach their desktop helpers, so installing them asks for Touch ID.
- 1Password's desktop app accepts a browser it does not list only when the browser is signed and installed in `/Applications`. The iCloud Passwords helper starts only for browsers on Apple's `apple/password-manager-resources` list. Both remain blocked on a stable signing identity (I.7), and on Chromium also on VI.1, as IV.13 records.
- Universal Autofill (⌘\\) reads the page's accessibility tree and is not a plugin matter; it needs II.13 on Chromium.
- Each plugin's Settings row shows whether its helper answered. A missing allow-list entry shows as a status instead of failing silently.

## AI hooks and plugins that AI writes

- AI hooks (VII.6) are built-in plugins. They subscribe to `pageLoaded` and `downloadFinished` and call the AI interface through the `ai` permission. Naming a tab uses `renameTab`; renaming a download uses `renameDownload`.
- The plugin API has no other AI-specific part. A plugin with `ai` sends requests through the AI interface (VII.1), which applies the routing table and page data rules. The plugin never sees a provider or a key.
- VII.7 writes a script plugin only, never a built-in plugin or a web extension, and never with `nativeMessaging`. It puts the package in a staging folder and calls `PluginManager.stage(_:)`.
- An AI-written plugin uses the same review sheet, showing every file's full source and the permissions. It installs disabled with the origin `generated`, and Settings labels it Written by AI. The user enables it.
- When the user requests a change, the AI writes a new plugin version with the same `id`. The review shows the files that changed and any added permission. Removing it works like any plugin.
- Script plugins load code only from their package, so only reviewed files run. A plugin can still act on data it fetches, so its `network` hosts are part of the review.
- The AI receives the JavaScript API reference below as its context for writing plugins (VII.7 decides how).

## Swift API

The `Plugins` module lives in `Packages/ARCH/Sources/Plugins` and depends on `ARCHEngine`. `Browsing` and `Preferences` depend on it to show contributions. `Plugins` reaches tabs through `PluginBrowserHost`, which `Browsing` implements. This avoids a dependency loop. `Extensions` (IV.12) depends on `Plugins` and supplies the web extension runtime. All types below are public.

### Identity and manifest

```swift
public typealias PersonaID = UUID

public struct PluginID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    /// Fails for anything but letters, digits, `-`, and `.`, or more than 128 characters.
    public init?(rawValue: String)
}

public enum PluginKind: String, Codable, Sendable {
    case builtIn, script, webExtension
}

public enum PluginOrigin: Hashable, Codable, Sendable {
    case bundled
    case file(URL)
    /// Written by the AI feature (VII.7).
    case generated
}

public struct PluginManifest: Hashable, Codable, Sendable {
    /// The highest `apiVersion` this app runs.
    public static let apiVersion = 1
    public var id: PluginID
    public var name: String
    public var version: String
    public var summary: String
    public var kind: PluginKind
    public var apiVersion: Int
    public var permissions: Set<PluginPermission>
    public var sites: [MatchPattern]
    public var siteAccess: SiteAccess
    public var network: [String]
    public var events: Set<PluginEventKind>
    public var contributions: PluginContributions
}

public enum PluginPermission: String, Hashable, Codable, Sendable, CaseIterable {
    case tabs
    case manageTabs = "tabs.manage"
    case history, downloads, clipboard, notifications, ai, nativeMessaging
}

public struct MatchPattern: Hashable, Codable, Sendable, CustomStringConvertible {
    public static var allSites: MatchPattern { get }
    /// `scheme://host/path` with `*` wildcards, or `<all_urls>`, under the rules in Match patterns. Throws `PluginError.invalidMatchPattern`.
    public init(_ pattern: String) throws
    public func matches(_ url: URL) -> Bool
    public var description: String { get }
}

public enum SiteAccess: String, Codable, Sendable {
    case none, listedSites, whenInvoked
}

/// What the user granted: a subset of what the manifest asks for.
public struct PluginGrant: Hashable, Codable, Sendable {
    public var permissions: Set<PluginPermission>
    public var sites: [MatchPattern]
    public var siteAccess: SiteAccess
    public var network: [String]
    public init(permissions: Set<PluginPermission>, sites: [MatchPattern], siteAccess: SiteAccess, network: [String])
    /// Everything the manifest asks for.
    public init(requestedBy manifest: PluginManifest)
}
```

### Contributions

```swift
public struct PluginContributions: Hashable, Codable, Sendable {
    public var commands: [PluginCommand]
    public var menuItems: [PluginMenuItem]
    public var sidebarItems: [PluginSidebarItem]
    public var settings: [PluginSetting]
    /// A package path to an HTML page shown below the settings form. Script plugins only.
    public var settingsPage: String?
    public var pageScripts: [PluginPageScript]
}

public struct PluginCommand: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String?
    public var keywords: [String]
    public var takesArgument: Bool
    /// For example `ctrl+opt+r`. The user can change it in Settings.
    public var shortcut: String?
}

public enum PluginPageContext: String, Hashable, Codable, Sendable {
    case page, link, image, selection, editable
}

public enum PluginMenuLocation: Hashable, Codable, Sendable {
    case pluginsMenu
    case pageContextMenu(Set<PluginPageContext>)
    case tabContextMenu
    case spaceMenu
}

public struct PluginMenuItem: Hashable, Codable, Sendable {
    public var command: String
    public var location: PluginMenuLocation
    /// The command's title when nil.
    public var title: String?
}

public enum PluginPanelPresentation: String, Hashable, Codable, Sendable {
    case popover, sidebar
}

public struct PluginSidebarItem: Identifiable, Hashable, Codable, Sendable {
    public enum Action: Hashable, Codable, Sendable {
        case command(String)
        /// A package path for script plugins; built-in plugins return their panel from `Plugin.panel(for:)`.
        case panel(path: String?, presentation: PluginPanelPresentation)
    }
    public var id: String
    public var title: String
    public var symbol: String
    public var action: Action
}

public struct PluginSetting: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        case toggle(default: Bool)
        case text(default: String)
        case number(default: Double, range: ClosedRange<Double>?)
        case choice(default: String, options: [String])
        /// Kept in the Keychain; the form never shows the value.
        case secret
    }
    public var key: String
    public var id: String { key }
    public var title: String
    public var help: String?
    public var kind: Kind
}

public struct PluginPageScript: Hashable, Codable, Sendable {
    public enum RunAt: String, Hashable, Codable, Sendable { case documentStart, documentEnd }
    public var matches: [MatchPattern]
    public var excludes: [MatchPattern]
    public var scripts: [String]
    public var styles: [String]
    public var runAt: RunAt
    public var allFrames: Bool
}
```

### Plugins and the context

```swift
/// A running plugin in one Persona. Built-in plugins implement it in Swift; the runtimes implement it for installed plugins.
@MainActor
public protocol Plugin: AnyObject {
    /// Called when the plugin starts. The context stays valid until `deactivate()`.
    func activate(in context: any PluginContext) async throws
    func deactivate() async
    func run(_ command: String, _ invocation: PluginInvocation) async throws
    /// Receives only the events the manifest lists.
    func handle(_ event: PluginEvent) async
    /// A message from one of the plugin's page scripts. The returned value is the script's reply.
    func receive(_ message: PluginPageMessage) async throws -> PluginValue?
    /// The panel for a sidebar item whose action is `.panel(path: nil, …)`.
    func panel(for sidebarItemID: String) -> NSViewController?
    func settingsPage() -> NSViewController?
}

extension Plugin {
    public func deactivate() async {}
    public func handle(_ event: PluginEvent) async {}
    public func receive(_ message: PluginPageMessage) async throws -> PluginValue? { nil }
    public func panel(for sidebarItemID: String) -> NSViewController? { nil }
    public func settingsPage() -> NSViewController? { nil }
}

/// A plugin compiled into the app. The app shell passes the list of these types to each Persona's manager.
@MainActor
public protocol BuiltInPlugin: Plugin {
    static var manifest: PluginManifest { get }
    /// Whether a new Persona enables the plugin.
    static var isOnByDefault: Bool { get }
    init()
}

/// The plugin's handle on the browser, scoped to one plugin in one Persona. Each call checks the plugin's grant and throws `PluginError.permissionDenied` or `.siteNotGranted` when it does not cover the call.
@MainActor
public protocol PluginContext: AnyObject {
    var pluginID: PluginID { get }
    var personaID: PersonaID { get }
    var grant: PluginGrant { get }
    var storage: any PluginStorage { get }
    var secrets: any PluginSecrets { get }
    func setting(_ key: String) -> PluginValue?

    // Tabs: `tabs` to read titles and addresses, `tabs.manage` to change tabs.
    func tabs() throws -> [PluginTab]
    func selectedTab() throws -> PluginTab?
    func openTab(_ url: URL, _ options: PluginOpenTabOptions) throws -> PluginTab.ID
    func closeTab(_ id: PluginTab.ID) throws
    func selectTab(_ id: PluginTab.ID) throws
    /// nil restores the page's title.
    func renameTab(_ id: PluginTab.ID, to name: String?) throws

    // Pages: the tab's page must match the grant.
    func runPageScript(_ script: PluginScript, in tab: PluginTab.ID) async throws -> PluginValue
    func postMessage(_ message: PluginValue, toTab tab: PluginTab.ID) throws

    // Data.
    func history(matching text: String, limit: Int) throws -> [PluginHistoryEntry]
    func renameDownload(_ id: PluginDownload.ID, to filename: String) throws
    /// Uses an ephemeral session without cookies. The host must be in the grant's `network`.
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    // Interface.
    func setBadge(_ text: String?, onSidebarItem id: String)
    func setEnabled(_ isEnabled: Bool, command id: String)
    func showPanel(_ sidebarItemID: String)
    func notify(title: String, body: String) throws
    func copyToClipboard(_ text: String) throws
}
```

`PluginContext` gains the `ai` member when VII.1 defines the AI interface's client type. That member throws `permissionDenied` without the `ai` permission and sends every request under the plugin's own routing entry.

### Values, events, and storage

```swift
public enum PluginValue: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PluginValue])
    case object([String: PluginValue])
}

public struct PluginTab: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var spaceID: UUID
    /// nil unless the grant has `tabs` or covers the page.
    public var title: String?
    public var url: URL?
    public var engine: EngineKind
    public var isPinned: Bool
    public var isSelected: Bool
}

public struct PluginOpenTabOptions: Hashable, Sendable {
    public var spaceID: UUID?
    public var select: Bool
    public var engine: EngineKind?
    public init(spaceID: UUID? = nil, select: Bool = true, engine: EngineKind? = nil)
}

public struct PluginDownload: Identifiable, Hashable, Sendable {
    public let id: String
    public var fileURL: URL
    public var sourceURL: URL?
    public var tabID: UUID?
}

public struct PluginHistoryEntry: Hashable, Sendable {
    public var url: URL
    public var title: String
    public var lastVisit: Date
    public var visitCount: Int
}

public enum PluginScript: Hashable, Sendable {
    /// A file from the plugin's package.
    case file(String)
    /// Script text. Built-in plugins only; other kinds get `PluginError.permissionDenied`.
    case source(String)
}

public struct PluginInvocation: Sendable {
    public enum Source: String, Sendable { case palette, menu, contextMenu, shortcut, sidebar }
    public var source: Source
    public var argument: String?
    public var tab: PluginTab?
    /// Set for page context menu items.
    public var linkURL: URL?
    public var imageURL: URL?
    public var selection: String?
}

public struct PluginPageMessage: Sendable {
    public var tab: PluginTab
    public var frameURL: URL
    public var isMainFrame: Bool
    public var body: PluginValue
}

public enum PluginEventKind: String, Hashable, Codable, Sendable, CaseIterable {
    case tabOpened, tabClosed, tabSelected, pageLoaded, downloadFinished, spaceChanged, settingChanged
}

public enum PluginEvent: Sendable {
    case tabOpened(PluginTab)
    case tabClosed(PluginTab.ID)
    case tabSelected(PluginTab.ID)
    /// After the main frame finishes loading.
    case pageLoaded(PluginTab)
    case downloadFinished(PluginDownload)
    case spaceChanged(UUID)
    case settingChanged(key: String)
}

@MainActor
public protocol PluginStorage: AnyObject {
    func value(forKey key: String) -> PluginValue?
    /// nil removes the key. Throws `quotaExceeded` past 5 MB.
    func setValue(_ value: PluginValue?, forKey key: String) throws
    func allKeys() -> [String]
}

@MainActor
public protocol PluginSecrets: AnyObject {
    func secret(forKey key: String) throws -> String?
    /// nil deletes the Keychain item.
    func setSecret(_ secret: String?, forKey key: String) throws
}

public enum PluginError: Error, Hashable, Sendable {
    case invalidPackage(String)
    case unsupportedAPIVersion(Int)
    case permissionDenied(PluginPermission?)
    case invalidMatchPattern(String)
    case siteNotGranted(URL)
    case networkHostNotGranted(String)
    case quotaExceeded
    case unavailable(String)
    case timedOut
}
```

### Manager, runtimes, and the browser host

```swift
public struct InstalledPlugin: Identifiable, Hashable, Sendable {
    public var id: PluginID { manifest.id }
    public var manifest: PluginManifest
    public var origin: PluginOrigin
    public var grant: PluginGrant
    public var isEnabled: Bool
    public var state: PluginState
    public var installedAt: Date
}

public enum PluginState: Hashable, Sendable {
    case disabled, idle, running
    case failed(String)
    case unavailable(String)
}

/// A validated package in the staging folder, ready for the review sheet.
public struct PluginPackage: Sendable {
    public let manifest: PluginManifest
    public let rootURL: URL
    /// Package-relative paths, shown in the review.
    public let files: [String]
}

public struct PluginCommandRef: Hashable, Sendable {
    public var plugin: PluginID
    public var command: String
}

/// A contribution with the plugin that adds it, for attribution in the interface.
public struct Attributed<Item: Sendable>: Sendable {
    public var plugin: PluginID
    public var pluginName: String
    public var item: Item
}

public struct PluginContributionIndex: Sendable {
    public func paletteCommands(matching text: String) -> [Attributed<PluginCommand>]
    public var sidebarItems: [Attributed<PluginSidebarItem>] { get }
    public func menuItems(at location: PluginMenuLocation) -> [Attributed<PluginMenuItem>]
    public var shortcutConflicts: [PluginCommandRef] { get }
}

/// Runs installed plugins of one kind in one Persona. `Plugins` provides the script runtime; `Extensions` provides the web extension runtime.
@MainActor
public protocol PluginRuntime: AnyObject {
    var kind: PluginKind { get }
    /// Reads a staged folder of this kind into a manifest.
    func manifest(forPackageAt url: URL) throws -> PluginManifest
    func makePlugin(_ installed: InstalledPlugin, packageURL: URL) throws -> any Plugin
}

/// What `Browsing` provides so that plugins can act on tabs without `Plugins` depending on `Browsing`.
@MainActor
public protocol PluginBrowserHost: AnyObject {
    func tabs(in persona: PersonaID) -> [PluginTab]
    func webContents(forTab id: UUID) -> (any EngineWebContents)?
    func openTab(_ url: URL, _ options: PluginOpenTabOptions, in persona: PersonaID) -> UUID
    func closeTab(_ id: UUID)
    func selectTab(_ id: UUID)
    func renameTab(_ id: UUID, to name: String?)
    func renameDownload(_ id: String, to filename: String) throws
    func present(_ panel: NSViewController, for item: Attributed<PluginSidebarItem>)
}

/// The plugins of one Persona.
@MainActor
public final class PluginManager: ObservableObject {
    @Published public private(set) var plugins: [InstalledPlugin]
    @Published public private(set) var contributions: PluginContributionIndex

    /// `directory` is the app's Application Support folder; the Persona's plugins live in `Plugins/<persona id>/` inside it.
    public init(persona: PersonaID, directory: URL, builtIns: [any BuiltInPlugin.Type],
                runtimes: [any PluginRuntime], browser: any PluginBrowserHost)

    /// Reads `plugins.json` and registers built-in plugins. Starts no installed code.
    public func load() throws
    /// Copies a folder or archive into staging and validates it.
    public func stage(_ url: URL) async throws -> PluginPackage
    public func install(_ package: PluginPackage, origin: PluginOrigin, grant: PluginGrant, enable: Bool) async throws
    public func setEnabled(_ isEnabled: Bool, for id: PluginID) async throws
    public func setGrant(_ grant: PluginGrant, for id: PluginID) async throws
    public func remove(_ id: PluginID) async throws

    public func run(_ command: PluginCommandRef, _ invocation: PluginInvocation) async
    public func post(_ event: PluginEvent)
    /// The page scripts of every enabled plugin, wrapped with their address guards, for a tab of this Persona.
    public func pageScripts() -> [EnginePageScript]
    /// A message from a page script. Returns the JSON reply, or nil.
    public func receive(_ message: EnginePageScriptMessage, fromTab tab: UUID) async -> String?
}
```

### JavaScript API for script plugins

The runtime adds a bridge script to every plugin document to define `arch`. Each call is a promise that resolves with the Swift call's result or rejects with the `PluginError` case name.

| JavaScript | Swift |
|---|---|
| `arch.commands.onRun(id, (invocation) => …)` | `Plugin.run(_:_:)` |
| `arch.events.on(kind, (event) => …)` | `Plugin.handle(_:)`; `kind` must be in the manifest's `events` |
| `arch.tabs.list()`, `selected()`, `open(url, options)`, `close(id)`, `select(id)`, `rename(id, name)` | The tab members of `PluginContext` |
| `arch.pages.run(tabId, file)`, `post(tabId, message)`, `onMessage((message) => reply)` | `runPageScript(.file(_:), in:)`, `postMessage(_:toTab:)`, `Plugin.receive(_:)` |
| `arch.storage.get(key)`, `set(key, value)`, `keys()` | `PluginStorage` |
| `arch.secrets.get(key)`, `set(key, value)` | `PluginSecrets` |
| `arch.settings.get(key)` | `setting(_:)` |
| `arch.net.fetch(url, init)` | `fetch(_:)` |
| `arch.history.search(text, limit)`, `arch.downloads.rename(id, name)` | `history(matching:limit:)`, `renameDownload(_:to:)` |
| `arch.ui.setBadge(itemId, text)`, `setEnabled(commandId, flag)`, `showPanel(itemId)`, `notify(title, body)`, `copy(text)` | The interface members of `PluginContext` |

Page scripts get a smaller `arch` in their world: `arch.send(message)` resolves with the plugin's reply, and `arch.onMessage((message) => …)` receives `postMessage(_:toTab:)`.

## Engine protocol additions

V.11 adds these Tier 1 members, which both adapters implement, and records them in `docs/engine-protocol.md` when implemented:

```swift
public enum EnginePageScriptInjectionTime: String, Sendable {
    case documentStart, documentEnd
}

public struct EnginePageScript: Hashable, Sendable {
    public var id: String
    /// Scripts in one world share globals. WebKit gives each world its own `WKContentWorld`; Chromium runs every world in the page's main world.
    public var world: String
    public var source: String
    public var injectionTime: EnginePageScriptInjectionTime
    public var mainFrameOnly: Bool
}

public struct EnginePageScriptMessage: Sendable {
    public var world: String
    public var frameURL: URL?
    public var isMainFrame: Bool
    public var json: String
}

public protocol EnginePageScriptDelegate: AnyObject {
    func webContents(_ webContents: any EngineWebContents, didReceive message: EnginePageScriptMessage,
                     reply: @escaping (String?) -> Void)
}

// EngineWebContentsConfiguration
public var pageScripts: [EnginePageScript]

// EngineWebContents
var pageScriptDelegate: (any EnginePageScriptDelegate)? { get set }
/// Replaces the scripts that run in each new document, from the next navigation on.
func setPageScripts(_ scripts: [EnginePageScript])
/// Runs a script in a world of the main frame and returns its JSON result.
func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void)
/// Delivers a JSON message to the scripts of a world in the main frame.
func postPageScriptMessage(_ json: String, toWorld world: String)
```

Chromium's `executeJavaScript(_:inWorld:completion:)` evaluates in the renderer and answers with a process message, like the theme color, because CEF's `ExecuteJavaScript` returns no value.

## Build order

1. `Plugins` module with the manifest, match patterns, storage, `PluginManager`, `BuiltInPlugin`, and a built-in sample plugin with one palette command; the palette shows plugin commands. This meets V.11's done condition.
2. Menus, shortcuts, sidebar items, panels for built-in plugins, and Settings ▸ Plugins in `Preferences`.
3. The engine page script members on both adapters, including the helper's renderer process handler on Chromium.
4. The script runtime with its sandboxed web view, scheme handler, bridge, install sheet, and lifecycle.
5. IV.12 builds the web extension runtime on WebKit as a `PluginRuntime`; VI.1 adds Chromium; IV.13 follows both.
6. VII.6 and VII.7 build on the `ai` permission and the staging and review path.

## Open decisions

- Isolation on Chromium: plugin page scripts share the page's main world until a CEF patch adds isolated worlds. The alternative is to run plugin page scripts on WebKit tabs only.
- Sandbox for script plugins: a hidden `WKWebView` per running plugin costs a web content process each. JavaScriptCore in the app process would cost less. It provides no process isolation, and its execution time limit is private API.
- One extension, two runtimes: each engine keeps its own copy of an extension's state and storage, so the user may unlock a password manager once per engine.
- Install sources: folders, `.zip`, and `.crx` files only. No direct installs from an online store.
- Plugin fetches carry no Persona cookies. A plugin that needs a signed-in site must use a page script on that site.
- Site access defaults to `whenInvoked` when a manifest asks for all sites.
- The 10-second hang limit, 30-second idle stop, and 5 MB storage limit are starting values.
