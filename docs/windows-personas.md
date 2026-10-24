# Multiple windows, small window, and Personas design

## Purpose and scope

- This note designs queue tasks III.6 (multiple windows), III.7 (small window), and III.12 (Personas) in `docs/plan.md`, rows 7, 6, and 9 of `docs/features.md`. It also fixes the parts of live favorites (III.13), sync (V.9), plugins (V.11), and the AI tasks (VII) that depend on windows or Personas.
- The three tasks share one change. Today `BrowserSession` holds the user's data, the state of the one window, and one engine profile per engine. After this work, a window owns only what it shows, a Persona owns its engine storage, and the session owns everything else.
- Folders (III.3), split view (III.5), previews (III.11), live favorites (III.13), and the plugin core (V.11) were built while this note was written. It states the design as types and responsibilities, and Interactions with other features says how windows and Personas apply to them.
- The default Persona keeps today's storage, so the upgrade moves no site data and signs nobody out.
- Nothing here uses a private API or needs a flag on `flags://`.

## Facts this design relies on

Verified by reading the code at commit 985b464, the CEF 156 headers in `Packages/ARCHKit/Sources/CEFBridge/cefroot/include`, and the macOS 27 SDK headers.

Session and windows
- `BrowserSession` keeps one runtime per engine (`runtimes: [EngineKind: EngineRuntime]`, BrowserSession.swift:27). `startEngine` creates the application and a context with the ID `"default"` (:190) and reads the context synchronously from `createBrowserContext`'s completion (:191–192). `adoptRuntime` creates one `EngineBrowser` with `window: nil` (:201). Both adapters call that completion before `createBrowserContext` returns.
- The window's state lives on the session: `currentSpaceID`, `selectedTabID` (its `didSet`, :36–56, leaves the internal page, ends page fullscreen, stamps the activation, clears the unread dot, follows the tab's space, stops find, defers and shows sheets, and retargets `devToolsDock`), `isSidebarVisible`, `isLibraryVisible`, the palette's mode, generation, and origin, the find state, `internalPage`, `fullscreenTabID`, `regionCaptureTabID`, `tabSwitcherHighlightID`, `activationOrder`, `renamingSpaceID`, `renamingTabID`, `devToolsDock`, `shareButtonView`, `sharePicker`, and one `visibleSheet` slot (:118).
- Views select a tab by assigning `session.selectedTabID` (BrowserWindowView.swift:1326, CommandPaletteView.swift:81). `NowPlaying` subscribes to `session.$selectedTabID` (NowPlaying.swift:26), and `observeChanges` merges `$currentSpaceID` and `$selectedTabID` (BrowserSession.swift:1361–1362). A computed property has no `$` publisher, so a forwarding shim for these two members must stay a published stored property.
- Sheets wait in a queue per tab. `showNextSheet` uses `tab.webContents.view.window ?? NSApp.mainWindow` (:911), because a tab selected in `selectedTabID.didSet` enters the window only at SwiftUI's next update. A `didBecomeMainNotification` observer shows the sheets that restored tabs asked for before the window existed (:153). `canPrint`, the PDF render, sharing, and `canClearSiteData` also fall back to `NSApp.mainWindow` (:1051, :1089, :1187, :1265). The download save panel uses `NSApp.keyWindow` (:1476).
- These lookups use only the engine kind: popup `takeOwnership` (:397), `switchEngine` (:472–473), `applyRememberedPermissions` (:857), `clearSiteData` (:1283–1291), `downloadsDirectory` (:775), `retire` (:1438), and `closeDownloadPagesIfIdle` (:1447). `downloadPages` stores the engine kind, not the runtime (:113). `CookieSync.runtimes` returns every runtime (:147), and `CookieSync` keys its state by `EngineKind` (CookieSync.swift:8–10).
- Automatic selection: `closeTab` picks a sibling in the tab's space (:517–520), `switchToSpace` picks the space's first tab (:252–254), archiving exempts only the selected tab (:608), and a popup from the selected tab goes into `currentSpaceID` (:399).
- The session implements `EngineBrowserDelegate.browser(_:didCreateNewWebContents:isActive:)` (:1408–1410), but no adapter calls it. Popups reach the session through `EngineWebContentsUIDelegate` and `Tab.openNewTab`.
- `Tab.id` is a new `UUID()` at every launch (Tab.swift:9). `TabRecord` has no ID, and the selection is saved as `selectedTabIndex` (SessionStore.swift:30). `load()` decodes with `try?` (:43–46). A file that fails to decode starts a fresh session (BrowserSession.swift:140–142), and the next save overwrites the file. `version` is written but never read. `Space` and `Favorite` use synthesized `Codable`, which requires a key for every non-optional property.
- `WebContentsHostView.updateNSView` removes its container's other subviews and adds the tab's view with `addSubview` (WebContentsHostView.swift:18–25). An engine view therefore sits in one window at a time, and either of two windows may update first.
- `DevToolsDock` exists once per session. It reads the side and sizes from `UserDefaults` only in `init()` (DevToolsDock.swift:50–55) and keeps them as its own published values. `track(_:)` removes the previous tools window from its parent and orders it out (:61–66). `AppDelegate.chooseDevToolsSide` sets the side on that one dock.
- `AppDelegate` builds one `NSWindow` (AppDelegate.swift:51–76) and keeps it in `window` (:19). The full-screen toolbar observers are bound to it (:62–68). The Escape and ⌃Tab monitors compare `event.window === self.window` (:401, :448). ⌘W closes another key window when `key !== window` (:247). The global shortcut, History's open handler, Import, and the default-browser prompt use `window`. `applicationShouldTerminateAfterLastWindowClosed` returns true (:95). There is no Window menu, and no item uses ⌘N, ⇧⌘W, ⌘M, or ⌥⌘N; ⌃⌘N is New Space.
- `isReleasedWhenClosed = false` is set in PreferencesWindowController.swift:56, TabCloseLog.swift:89, and HistoryWindowController.swift:25. The browser window leaves it at its default. `allowsAutomaticWindowTabbing`, `tabbingMode`, and `isRestorable` are set nowhere in the package.
- `ShortcutSettings.manage(_:)` collects the menu bar's items once, at launch, and keys saved shortcuts by the selector name with the item's tag or represented string (ShortcutSettings.swift:54–62, :118–122). `installShortcuts()` runs before the window exists.
- `ARCHCEFApplication.terminate:` ends the sheets on every window before it quits (CEFBridge.mm:62–69). `SpaceSwipeView` already ignores scroll events from other windows (SpaceSwipeView.swift:57). `CommandKeyState` is app-wide.

Engines and bridge
- `WebKitBrowserContext` uses `.default()`, or `.nonPersistent()` for incognito, and ignores the context ID (WebKitEngine.swift:80–82). Tabs, popups (they reuse the parent's configuration, WebKitDelegateBridge.swift:137), the downloads' hidden `resumingWebView` (WebKitDownloads.swift:12–16), and the cookie observer all use the context's `dataStore`.
- `WebKitWebContents` holds its context strongly (WebKitEngine.swift:233). `WebKitDownloads` holds its context `unowned` (WebKitDownloads.swift:10). `WebKitDownloadItem` holds its list `unowned` and its web view weakly (:61–62). A download row that outlives its context crashes when it is removed or resumed.
- `ChromiumEngine.makeApplication` passes `<cacheDirectory>/Chromium` to `ARCHCEFRuntime.initialize`, which sets both `root_cache_path` and `cache_path` to it (CEFBridge.mm:676–677). On disk the global profile is `Cache/Chromium/Default`. `ChromiumApplication` does not keep the configuration. `ChromiumBrowserContext` has no storage of its own (ChromiumEngine.swift:73). `ChromiumWebContents` holds its context weakly (:204) and gives a popup the opener's context (:400).
- Every Chromium storage call uses the global profile: `CefCookieManager::GetGlobalManager` at CEFBridge.mm:437, 445, 453, 469, 504 (the flush in `CookieDeleter`'s destructor), and 622; `CefRequestContext::GetGlobalContext` at :743 (permission content settings); and `CefBrowserHost::CreateBrowser(…, nullptr)` at :641 (the hidden storage-clearing browser) and :1459 (every tab).
- `cef_types.h`: `CefRequestContextSettings.cache_path` "must be an absolute path that is either equal to or a child directory of CefSettings.root_cache_path"; an empty value means incognito. `persist_session_cookies`, `accept_language_list`, and the cookieable schemes are ignored when `cache_path` matches the global one. A `CefSettings.cache_path` that is a child of the root is ignored in favor of the default profile.
- `cef_request_context.h`: `CreateContext(settings, handler)` creates a context. `GetCookieManager(callback)` runs the callback "after the manager's storage has been initialized". "Browser objects with different request contexts will never be hosted in the same render process." Browsers that `window.open` creates share the source's context, but Arch cancels those in `OnBeforePopup` and creates its own browser. `cef_request_context_handler.h`: `OnRequestContextInitialized` runs on the UI thread. `cef_browser.h`: `CreateBrowser` "will not block", and an empty `request_context` means the global context. `cef_cookie.h`: `GetGlobalManager` equals the global context's default cookie manager.
- `wrapper_src/shutdown_checker.cc` is compiled (Package.swift:11). In DCHECK builds it asserts "Object reference incorrectly held at CefShutdown". `+[ARCHCEFRuntime shutdown]` closes the browsers, runs CEF's work for up to two seconds, then calls `CefShutdown` (CEFBridge.mm:700–715).
- `WKWebsiteDataStore.h` in the macOS 27 SDK: `+dataStoreForIdentifier:` (macOS 14; "Throws exception if identifier is 0"), `+removeDataStoreForIdentifier:completionHandler:` (macOS 14; "WKWebView using the data store must be released before removal"), `+fetchAllDataStoreIdentifiers:` (macOS 14), and `identifier` (nil for the default and non-persistent stores). `WKWebExtensionControllerConfiguration.h`: `+configurationWithIdentifier:` and `defaultWebsiteDataStore` (macOS 15.4). The package targets macOS 14 (open decision 1).

Checked at runtime for step 5, with the bundled app on the Chromium engine, a Work Persona added to `session.json` by hand, and pages from a local server that report `navigator.languages`
- Work's first Chromium tab creates a full profile in `Cache/Chromium/Persona-<UUID>`. Chromium keeps the HTTP and code caches of a profile under `~/Library/Application Support` at the same relative path under `~/Library/Caches`, so Work's are in `~/Library/Caches/Arch/Cache/Chromium/Persona-<UUID>` and the global profile's in `~/Library/Caches/Arch/Cache/Chromium/Default`.
- On Chromium, `navigator.languages` is `en-US,en` and `Accept-Language` is `en-US,en;q=0.9` in both the default and the Work Persona, so `initWithCachePath:` leaves `accept_language_list` empty.
- A Work Chromium tab restored at launch loads on its first request. The bridge creates the browser at once with the new context, so CEF's `CreateBrowser` waits for the context to initialize.
- WebKit keeps an identifier store, caches included, in `~/Library/WebKit/local.arch.browser/WebsiteDataStore/<UUID in lowercase>`, and `+removeDataStoreForIdentifier:completionHandler:` deletes that directory.
- Chromium's `Local State` lists every profile it has loaded in `profile.info_cache` and `profile.profiles_order` and keeps the entry after the removal pass deletes the profile's directories. Chromium starts normally with such entries. An entry holds the default name and avatar and empty account fields, no site data, so the removal pass leaves the file alone.

Not verified; the implementation order checks each
- That a CEF Alloy browser keeps input, IME, focus, accessibility, and backing scale when its parent view moves to another `NSWindow`.
- The order in which app activation and the URL event arrive when another app opens a link, and whether activation brings only the small window forward.
- That Chromium's developer tools for a tab use that tab's request context. The check needs the screen, so step 13 makes it.

## Decisions

### Placement rule

Every piece of state has exactly one owner. Parallel tasks follow the same table; step 6 copies it into `docs/plan.md` Decisions.

| State that… | Owner | Lifetime |
|---|---|---|
| can differ between two windows open at once: what is shown, focused, or being edited | `BrowserWindowModel` | One window |
| is bound to one Persona's engine storage: contexts, browsers, cookie copying, kept download pages, and later its plugin manager and extension controller | `PersonaEngines` | One Persona, from first use until quit |
| belongs to an engine process: the engine applications, CEF initialization, crash totals, the primary engine | `BrowserSession`, engine section | The app |
| is anything else the user owns: Personas, spaces, favorites, tabs, the closed list, downloads, permissions, zoom, persistence | `BrowserSession` | The app |

### Window rules

1. At most one window shows a tab. An engine view is one `NSView` with one superview. `BrowserWindowModel.shownTabIDs` lists what a window shows: its selected tab, and with split view (III.5) its panes.
2. Explicit selection moves the tab: a sidebar click, a palette tab row, the tab switcher, ⌘-numbers, Next and Previous Tab, a favorite's tab, a tab's `requestSelection`, and selection by sync or a plugin. The window that shows the tab gives it up first, through its own selection change to a fallback. Only then does the selecting window run its own side effects. This order lets the losing window undock the developer tools before the gaining window docks them.
3. Automatic selection never takes a tab that another window shows: `switchToSpace`, the `closeTab` fallback, restore, a new window, and the fallback in rule 2. When no tab is free, the window shows the empty page state that exists today.
4. A window's current space follows its selected tab, as today. Two windows may show the same space.
5. Closing a main window keeps its tabs. Closing a small window closes its tab into the closed list.
6. Closing the last browser window quits, as today. AppKit keeps the app running while Settings, History, or the tab close log is open; a Dock click, the global shortcut, History's Open, or a link then creates a main window.
7. Page commands act on the active window: the browser window, of either kind, that last became main. It stays the target while Settings or History is key, as today. Sidebar commands act on the last main window, which comes forward when a small window is active, or on a new main window when none is open.

### Persona rules

1. A Persona is a partition of the session. Every space, favorite, tab, closed-tab record, and engine runtime belongs to exactly one Persona.
2. The default Persona keeps today's storage: the context ID `default`, WebKit's `.default()` store, and CEF's global request context in `Cache/Chromium/Default`. Its fixed UUID is never passed to `WKWebsiteDataStore(forIdentifier:)`. Every other Persona has a WebKit identifier store and a CEF request context, both named by its UUID.
3. A tab's Persona is fixed when the tab is created, because its web contents belong to that Persona's context. Every change of a tab's space goes through one guard that refuses a space of another Persona. A space's Persona is fixed.
4. Cookies copy between the engines only within a Persona: each Persona has its own `CookieSync`.
5. A Persona's stored data is removed only through an explicit list in the snapshot, at the next launch, before any engine starts. Removal is never inferred from a missing Persona.
6. History, remembered permissions, zoom, site search, the search engine, the download settings, and `ai.json` stay app-wide (open decisions 2 and 3).

## Risks and mitigations

| # | What breaks | Mitigation | Step |
|---|---|---|---|
| R1 | One visible-sheet slot lets a sheet in one window block every other window, and the `NSApp.mainWindow` fallback can put a tab's sheet on the wrong window | `TabSheetQueue` keeps the queues per tab and one visible sheet per window. A window with no visible sheet shows its selected tab's oldest sheet on its own `nsWindow`, which exists from the window's creation, so a sheet requested at selection time shows at once. When a tab leaves a window, that window's sheet is deferred and shows again in the next window that shows the tab | 8 |
| R2 | Lookups by engine kind pick the default Persona's runtime: a kept download page is never closed, Clear Site Data clears the wrong profile, a popup is owned by the wrong browser | Every lookup goes through `runtime(of: tab)` or the runtime stored with the kept page | 3 |
| R3 | Cookie copies cross Personas | One `CookieSync` per Persona, whose `runtimes` closure returns only that Persona's runtimes | 3 |
| R4 | Clear Site Data on Chromium reaches the global profile through the hidden browser and the flush | The bridge's context object creates the hidden browser in its own context and flushes the manager it visited | 4 |
| R5 | Chromium keeps permission answers per profile, and the app writes only the global one | `setRememberedPermission` writes to the context's own request context, and every runtime follows the remembered answers | 4 |
| R6 | A new CEF context is used before its storage initializes, so a cookie copy reads nothing and counts as finished | The bridge queues cookie, storage, and content-setting calls until `OnRequestContextInitialized` and `GetCookieManager(callback)` have both fired. `createBrowserContext` still completes synchronously, and browsers are created at once | 4, 5 |
| R7 | A context reference held at `CefShutdown` asserts in debug builds | The bridge tracks its context objects and releases their references after the browsers close and before `CefShutdown` | 4 |
| R8 | `WKWebsiteDataStore(forIdentifier:)` needs macOS 14 | The package targets macOS 14 (open decision 1) | 5 |
| R9 | Moving the default Persona to new storage would sign the user out everywhere | The default Persona passes no storage identifier | 5 |
| R10 | WebKit cannot remove a store while a web view uses it, CEF keeps a loaded profile's files open, and a snapshot that failed to decode lists no Personas | `removedPersonaIDs` in the snapshot, processed at the next launch before any engine starts. An unreadable `session.json` is moved aside, never overwritten | 1, 5 |
| R11 | `moveTab(_:to:)`, `moveTab(_:toSpace:)`, `deleteSpace`, `reopenLastClosedTab`, drops on a space symbol, folders, and sync orphan moves put a web contents under another Persona's space | `Tab.personaID` is a constant; one guard for every space change; `deleteSpace` picks a neighbor in the same Persona and refuses a Persona's last space | 2, 13 |
| R12 | Two windows on one tab: the last `addSubview` wins and the other window goes blank | Window rules 1 to 3 | 8 |
| R13 | Palette, find, renaming, capture, switcher, and library state on the session appears in every window | All of it moves to `BrowserWindowModel` | 6 |
| R14 | One dock holds one browser window; per-window docks drift apart because each reads `UserDefaults` only at `init`; a dock can undock tools another window just docked | One dock per window; one shared `DevToolsDockSettings` that every dock observes; the rule 2 order; `track(_:)` removes the previous tools window only while it is still a child of its own browser window | 8 |
| R15 | `fullscreenTabID` is global, and the Escape monitor is bound to one window | `fullscreenTabID` per window; monitors resolve the window from `event.window`; a tab that leaves a window exits page fullscreen first | 6, 8 |
| R16 | Archiving exempts only one selected tab | Every shown tab and every small-window tab counts as active | 8, 11 |
| R17 | The last window closes before the quit saves; frames refer to removed displays; AppKit tabbing and restoration interfere; a window built in code is released when it closes | Keep the record of the last main window that closed; clamp frames; `NSWindow.allowsAutomaticWindowTabbing = false`, and `tabbingMode = .disallowed`, `isRestorable = false`, and `isReleasedWhenClosed = false` on every browser window | 9, 10 |
| R18 | AppKit adds window items, and on recent systems window tiling items, to the Window menu, which `manage` would list as commands | Set `NSApp.windowsMenu` after `installShortcuts()`, and check Settings ▸ Shortcuts | 9 |
| R19 | Small-window tabs must stay in `tabs` for sheets, permissions, downloads, Now Playing, and crash notices, but space lists would show, close, or select them | One predicate, `Tab.isListedInSidebar`, in every space-scoped filter (listed under Small window) | 11 |
| R20 | A deleted Persona's download rows keep `unowned` references to its WebKit context | Its runtimes stay referenced, without tabs, until quit; its unfinished downloads are cancelled first | 13 |
| R21 | Two tasks raise the snapshot version at once | New fields are optional, `normalized()` keys off their presence, and each landing takes the next free number | 1, 2, 5, 10 |

## Types

### Browsing

`Persona` (new, `Persona.swift`)

```swift
/// A set of spaces whose tabs share one engine context per engine: cookies, site storage, caches, and, with V.11, installed plugins.
public struct Persona: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String)

    /// The Persona that holds everything from builds before Personas. It keeps each engine's default storage. Sync names its record `default`; V.11 uses it for `Plugins/<id>/`.
    public static let defaultID = UUID(uuidString: "D59DAF4B-E372-4AF9-890E-455B8B3860F3")!
    public var isDefault: Bool { id == Self.defaultID }

    /// The default Persona keeps the `default` context and the engines' default storage. Any other Persona names its context, and from step 5 its storage, by its UUID.
    var contextAttributes: EngineBrowserContextAttributes { get }
}
```

- `Browsing` exports no `PersonaID` alias. `docs/plugins.md` declares `public typealias PersonaID = UUID` in `Plugins`, which `Browsing` will import, and a second public alias of that name would make lookups ambiguous. Browsing code writes `Persona.ID`.

`Space` and `Favorite` (changed)
- Each gains `public var personaID: UUID?`. It is optional so that synthesized `Codable` reads older files and so that fields other tasks add need no hand-written decoder. `normalized()` sets it on every item, and code reads `resolvedPersonaID` (`personaID ?? Persona.defaultID`). Their initializers gain `personaID: UUID? = nil`.

`Tab` (changed)
- `public let id: UUID`, set by `init(id: UUID = UUID(), webContents:spaceID:isPinned:personaID:)`.
- `public let personaID: UUID`.
- From step 11: `@Published public internal(set) var isInSmallWindow = false` and `var isListedInSidebar: Bool { !isInSmallWindow }`. III.13 extends the predicate if live favorite tabs leave space lists.

`BrowserWindowModel` (new, `BrowserWindowModel.swift`)

```swift
public enum BrowserWindowKind: String, Codable { case main, small }

/// The state of one browser window: what it shows and what the user is doing in it. Everything else belongs to the session.
public final class BrowserWindowModel: ObservableObject, Identifiable {
    public let id: UUID
    public let kind: BrowserWindowKind
    unowned let session: BrowserSession

    @Published public var currentSpaceID: UUID
    /// Assigning it applies window rule 2: another window that shows the tab falls back first.
    @Published public var selectedTabID: UUID?
    @Published public var isSidebarVisible: Bool
    @Published public var isLibraryVisible: Bool
    @Published public private(set) var internalPage: InternalPage?
    @Published public private(set) var fullscreenTabID: UUID?
    @Published public var commandPaletteMode: CommandPaletteMode?
    @Published public private(set) var commandPaletteGeneration: Int
    @Published public private(set) var commandPaletteOrigin: CommandPaletteOrigin
    @Published public private(set) var isFindBarVisible: Bool
    @Published public private(set) var findBarFocusRequests: Int
    @Published public var findText: String
    @Published public private(set) var findResult: EngineFindResult?
    @Published public var renamingSpaceID: UUID?
    @Published public var renamingTabID: UUID?
    @Published public private(set) var regionCaptureTabID: UUID?
    @Published public private(set) var tabSwitcherHighlightID: UUID?
    /// This window's tab switcher order, most recent first.
    private(set) var activationOrder: [UUID]
    public let devToolsDock: DevToolsDock
    weak var shareButtonView: NSView?
    var sharePicker: PageSharePicker?
    /// The AppKit window, set when it is created. Sheets, printing, export, and sharing use it.
    public weak var nsWindow: NSWindow?
    /// The frame outside full screen, which the window controller records.
    var restorableFrame: CGRect?

    public var shownTabIDs: [UUID] { get }
    public var selectedTab: Tab? { get }
    public var currentSpace: Space { get }
    /// A small window's tab's Persona, or the current space's.
    public var personaID: Persona.ID { get }
    public var recentTabs: [Tab] { get }
}
```

- These commands move here from the session with the same names and bodies, reading the user's data through `session`: `switchToSpace`, `switchToAdjacentSpace`, `addSpace` (adds a space to this window's Persona and switches to it), `selectTab(at:)`, `selectLastTab`, `selectAdjacentTab`, `moveSelectedTab`, `shortcutNumber(for:)`, `openTab(url:engine:)` (in the current space, selected here), `openFavorite`, `navigate(to:)`, `goHome`, `canGoHome`, `setCurrentPageAsHome(ofSpace:)`, `canSetCurrentPageAsHome`, `showCommandPalette`, `dismissCommandPalette`, `submitCommandPalette`, `focusCommandBar`, `closeInternalPage`, `exitPageFullscreen`, `focusPage`, `showFindBar`, `hideFindBar`, `findNext`, `findPrevious`, `toggleLibrary`, `toggleSidebar`, `goBack`, `goForward`, `go(to:inTab:)`, `recentBackItems`, `reload`, `stopLoading`, `toggleDeveloperTools` with the developer tools properties, zoom in, out, and reset with `canZoom`, `printPage`, `exportPageAsPDF`, `canPrint`, the capture commands with `canCapture`, `shareSelectedPage`, `canShareSelectedPage`, the tab switcher, `closeSelectedTab`, `closeOtherTabs`, `confirmClearSiteData`, `canClearSiteData`, `renameSpace`, `renameTab`, and `endRenaming`.
- `selectedTabID.didSet` runs these in order:
  1. `session.release(selectedTabID, except: self)`, which makes any other window that shows the tab select its fallback first.
  2. Today's window side effects: leave the internal page, end another tab's page fullscreen, stop find on the old tab, follow the tab's space (main windows only), and record this window's activation.
  3. `session.windowDidSelect(self, previous:)`: the activation date, the unread dot, sheets, the focused tab, and the save.
  4. `devToolsDock.track(selectedTab?.webContents.devTools)`.
  5. Subscribe to the selected tab's `objectWillChange` so that views reading the tab through the window refresh, as the session does today (:458–463).
- `fallbackTab(excluding:)` returns the first tab of `recentTabs` that is listed in the sidebar, is not `excluding`, and is not shown by another window, or nil.
- `isLibraryVisible.didSet` asks the session to mark finished downloads seen.

`PersonaEngines` (new, internal, `PersonaEngines.swift`)

```swift
/// One Persona's engine contexts: a context and browser per engine, started on first use, and the CookieSync that copies cookies between them.
final class PersonaEngines {
    let personaID: Persona.ID
    var runtimes: [EngineKind: EngineRuntime] = [:]
    let cookieSync = CookieSync()
    init(personaID: Persona.ID)
}
```

- `EngineRuntime` gains `let personaID: Persona.ID`. `CookieSync.swift` does not change: within one Persona, each engine kind has one runtime.

`TabSheetQueue` (new, internal, `TabSheetQueue.swift`, moved out of the session)

```swift
/// Sheets that tabs asked for, oldest first per tab, and the one sheet each window shows. A tab's sheet shows only on the window whose selected tab it is.
final class TabSheetQueue {
    var windows: () -> [BrowserWindowModel] = { [] }
    func enqueue(_ alert: NSAlert, for tab: Tab, isPageDialog: Bool, completion: @escaping (NSApplication.ModalResponse) -> Void)
    /// Each window that has an AppKit window and no visible sheet shows its selected tab's oldest sheet there.
    func showNext()
    /// Puts away a window's sheet when the window no longer selects its tab. It shows again first when a window selects that tab.
    func deferSheet(of window: BrowserWindowModel)
    func cancel(for tab: Tab, pageDialogsOnly: Bool)
    func cancelAll()
    func isShowingSheet(in window: BrowserWindowModel) -> Bool
}
```

- The deferral response, the page-dialog flag, and the permission waiters keep today's rules. `isQuitting` stays on the session, which answers `.cancel` at once while the app quits.

`DevToolsDockSettings` (new, in `DevToolsDock.swift`)

```swift
/// The side and sizes of docked developer tools, shared by every window's dock and saved under today's keys.
public final class DevToolsDockSettings: ObservableObject {
    public static let shared: DevToolsDockSettings
    @Published public var side: DevToolsSide      // ARCHDevToolsSide
    @Published var width: CGFloat                 // ARCHDevToolsWidth
    @Published var height: CGFloat                // ARCHDevToolsHeight
}
```

- `DevToolsDock` keeps `side` as a forwarding property, places its window again whenever the shared side changes, and reads the sizes from the settings. `DevToolsDockSpace` observes the settings for the sizes.
- `setDocked(true, _:)` also sets `isExcludedFromWindowsMenu`, so the Window menu lists only browser windows. `setDocked(false, _:)` clears it.
- `track(_:)` removes and orders out the previous tools window only while that window's parent is the dock's own browser window.

`BrowserWindowController` (new, internal, `BrowserWindowController.swift`)

```swift
/// The AppKit window of one BrowserWindowModel. Builds the main window as AppDelegate does today, or the small window; records the frame; reports becoming main and closing to the session.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    init(model: BrowserWindowModel, session: BrowserSession, frame: CGRect?)
}
```

- Only `BrowserSession.openWindow` creates one, so restore, ⌘N, a small window, and a main window created on demand take one path. It lives in `Browsing`, which already builds a window (`TabCloseLogWindowController`) and holds both window views.
- It hosts `BrowserWindowView(session:window:)` or `SmallWindowView(session:window:)`, sets `model.nsWindow`, and hides its own toolbar in full screen.
- It sets the window's hidden title, which the Window menu and Mission Control show: the selected tab's display title, or the space's name when no tab is selected; with two or more Personas, followed by " — <Persona name>".
- It sets `tabbingMode = .disallowed`, `isRestorable = false`, and `isReleasedWhenClosed = false`.
- Delegate: `windowDidBecomeMain` calls `session.windowDidBecomeMain(model)`. `windowDidMove` and `windowDidEndLiveResize` record `model.restorableFrame` and schedule a save, except in full screen; `windowWillEnterFullScreen` keeps the frame from before. For a small window, `windowShouldClose` asks to close its tab and returns false; the window closes when the tab does. `windowWillClose` calls `session.windowWillClose(model)`.

`BrowserSession` (changed; app-wide)

```swift
@Published public private(set) var personas: [Persona]
/// Open browser windows, the most recently main first.
@Published public private(set) var windows: [BrowserWindowModel]
/// The active window's selected tab. Now Playing and AppleScript's `active tab` follow it.
@Published public private(set) var focusedTabID: UUID?
public var focusedTab: Tab? { get }
/// Window rule 7.
public var activeWindow: BrowserWindowModel? { get }
public var lastMainWindow: BrowserWindowModel? { get }
/// Window rule 7. Creates a main window when none is open.
public func sidebarTarget() -> BrowserWindowModel
@discardableResult
public func openWindow(kind: BrowserWindowKind = .main, spaceID: UUID? = nil, frame: CGRect? = nil) -> BrowserWindowModel
/// Creates the windows of the loaded snapshot, back to front.
public func restoreWindows()
public func window(showing tab: Tab) -> BrowserWindowModel?
public func window(for nsWindow: NSWindow?) -> BrowserWindowModel?
func release(_ tabID: UUID?, except window: BrowserWindowModel)
func windowDidSelect(_ window: BrowserWindowModel, previous: UUID?)
func windowDidBecomeMain(_ window: BrowserWindowModel)
func windowWillClose(_ window: BrowserWindowModel)

public func persona(ofSpace id: UUID) -> Persona
public func spaces(in persona: Persona.ID) -> [Space]
public func favorites(in persona: Persona.ID) -> [Favorite]
/// The last main window's space when it belongs to the Persona, else the Persona's first space.
public func preferredSpace(in persona: Persona.ID) -> Space
/// The guard of Persona rule 3. Drop targets use it too.
public func canMoveTab(_ id: UUID, toSpace spaceID: UUID) -> Bool
@discardableResult public func addPersona(named name: String) -> Persona
public func renamePersona(_ id: Persona.ID, to name: String)
public func canDeletePersona(_ id: Persona.ID) -> Bool
public func deletePersona(_ id: Persona.ID)

// Step 11
@discardableResult public func openSmallWindow(url: URL) -> BrowserWindowModel
public func moveToMainWindow(_ smallWindow: BrowserWindowModel)
```

- Every existing app-wide mutator keeps its name. `openTab(url:in:pinned:select:engine:state:)` keeps its signature, so parallel tasks compile: a nil space means the sidebar target's current space, and `select: true` selects the tab in the sidebar target. The tab takes the space's Persona. Views and menus use `BrowserWindowModel.openTab` instead.
- `addFavorites(_:)` gains `to persona: Persona.ID? = nil`, where nil means the current space's Persona (from step 7, the last main window's), so `ImportController` compiles unchanged. `addFavorite(_ tab:)` uses the tab's Persona. Duplicate addresses are checked within one Persona.
- Engine section: `applications: [EngineKind: any EngineApplication]`, each started once (`makeApplication`, `delegate = self`, `run()`); `personaEngines: [Persona.ID: PersonaEngines]`; `retiredPersonaEngines: [PersonaEngines]` for deleted Personas, kept until quit; `runtime(for kind:, in persona:) -> EngineRuntime`, which creates the context from `contextAttributes` and its browser on first use and falls back to the primary engine within the same Persona; `runtime(of tab:) -> EngineRuntime?`; and `allRuntimes`.
- The session's implementation of `EngineBrowserDelegate.browser(_:didCreateNewWebContents:isActive:)` is deleted, and the protocol's default applies, because no adapter calls it.
- `validateMenuItem` and other checks read `lastMainWindow` and never create a window.

`SmallWindowView` (new, internal, step 11): `init(session: BrowserSession, window: BrowserWindowModel)`; its layout is under Small window.

`PageAreaView` (new, internal, step 11, extracted from `BrowserWindowView`): `init(window: BrowserWindowModel, margins: EdgeInsets)`, holding the page host and its background, the crash notice, the internal page, the region capture overlay, the frame stroke, the margins, and the developer tools space. Both window kinds show the page through it, so page fullscreen and the docked tools behave the same in each.

### Arch

- `AppDelegate` keeps the menu bar, link routing, the key monitors, the global shortcut, and the app's lifecycle. Window building moves to `BrowserWindowController`. Every action resolves `session.activeWindow` (page commands) or `session.sidebarTarget()` (sidebar commands). Selector names stay unchanged, because `ShortcutSettings` keys saved shortcuts by them.
- It adds `applicationShouldHandleReopen(_:hasVisibleWindows:)`: with no main window open, a Dock click opens one.
- It records the time of each `NSApplication.didBecomeActiveNotification` for the small-window decision (step 11).

### ARCHEngine

```swift
public extension EngineBrowserContextID {
    /// The engine's default profile, which keeps the data of builds before Personas: WebKit's default data store and CEF's global request context.
    static let `default` = EngineBrowserContextID(rawValue: "default")
}

public struct EngineBrowserContextAttributes {
    // id, userVisibleName, type: unchanged
    /// Where a regular context keeps its data. nil: the engine's default storage. A UUID: storage of its own, `WKWebsiteDataStore(forIdentifier:)` or a CEF request context whose profile is the `Persona-<UUID>` directory under the root cache path.
    public var storageIdentifier: UUID?
    public init(id: EngineBrowserContextID, userVisibleName: String, type: EngineBrowserContextType, storageIdentifier: UUID? = nil)
}

public protocol Engine: AnyObject {
    // existing members
    /// Removes what a context with `identifier` stored while no context of this process uses it, as at launch before `makeApplication`. Reports whether it is gone; false means try again at a later launch.
    func removeStoredData(forStorage identifier: UUID, configuration: EngineApplicationConfiguration, completion: @escaping (Bool) -> Void)
}
```

- The ID names the context within its application, and `storageIdentifier` picks the storage, so no adapter parses an ID string as a UUID. Existing callers compile unchanged because the new parameter has a default.
- `EngineBrowser`'s comment changes from "A container for one window" to "The web contents of one browser context in one engine." The session keeps one per Persona and engine with `window: nil`, because tabs move between windows. `EngineBrowser.window`, `deleteBrowserContext`, and `loadBrowserContext` stay as they are, unused.
- `createBrowserContext` keeps completing synchronously, because `startEngine` and `openTab` rely on it.

### WebKit adapter

- `WebKitBrowserContext.init(attributes:)` picks the store: `.nonPersistent()` for incognito; `.default()` without a storage identifier; `WKWebsiteDataStore(forIdentifier:)` with one. Each context keeps its store object for the app's lifetime.
- Tabs, popups, the downloads' hidden web view, and the cookie observer already use the context's store and need no change.
- `WebKitEngine.removeStoredData` calls `+removeDataStoreForIdentifier:completionHandler:` and reports success when the error is nil. It does not start the WebKit application.
- IV.12: one `WKWebExtensionController` per Persona, from `configurationWithIdentifier:` with the Persona's UUID (the default Persona's too) and `defaultWebsiteDataStore` set to the Persona's store.

### Chromium adapter

- `ChromiumApplication` keeps its `EngineApplicationConfiguration` to compute profile paths.
- `ChromiumBrowserContext` holds `let requestContext: ARCHCEFRequestContext`: `globalContext` without a storage identifier, otherwise one for `<cacheDirectory>/Chromium/Persona-<UUID>`, a direct child of the root beside `Default`.
- `ChromiumBrowser`'s cookie and site-data members and the context's `setRememberedPermission` call that object.
- `ChromiumWebContents` keeps its request context strongly, passes it to `ARCHCEFBrowser`, and gives it to its popups, so a popup never falls back to the global profile.
- `ChromiumEngine.removeStoredData` reports false while `ARCHCEFRuntime.isInitialized`. Otherwise it renames the profile's `Persona-<UUID>` directories, under the root cache path and under its counterpart in `~/Library/Caches`, to `Persona-<UUID>.removed`, which is fast. It then deletes every removed profile in both on a background queue and, once that finishes, reports whether no directory of the profile remains, so a quit before then leaves the ID for the next launch. A missing directory counts as removed. `makeApplication` also deletes leftover `Persona-*.removed` directories in both on a background queue before it initializes CEF, which covers a list lost with an unreadable `session.json`.

### CEFBridge

```objc
/// A Chromium profile: cookies, site storage, caches, and the permission answers it keeps. Browsers of different contexts never share a render process.
@interface ARCHCEFRequestContext : NSObject
/// The global context, whose profile is `Default` under the root cache path. Ready once the runtime initializes.
@property (class, nonatomic, readonly) ARCHCEFRequestContext *globalContext;
/// A context whose profile lives at `cachePath`, which must be a direct child of the root cache path. Nil for any other path or before the runtime initializes. Cookie, storage, and permission calls wait until Chromium reports the context initialized.
- (nullable instancetype)initWithCachePath:(NSString *)cachePath;
- (void)visitAllCookies:(void (^)(NSArray<ARCHCEFCookie *> *cookies))completion;
- (void)setCookie:(ARCHCEFCookie *)cookie forURL:(NSString *)url;
- (void)setCookies:(NSArray<ARCHCEFCookie *> *)cookies forURLs:(NSArray<NSString *> *)urls completion:(void (^)(void))completion;
- (void)deleteCookiesForURL:(NSString *)url name:(NSString *)name;
- (void)deleteCookiesPassingTest:(BOOL (^)(ARCHCEFCookie *cookie))test completion:(void (^)(void))completion;
- (void)clearStorageForOrigins:(NSArray<NSString *> *)origins completion:(void (^)(void))completion;
- (void)setPermissionSetting:(ARCHCEFPermissionSetting)setting forPermissions:(ARCHCEFPermission)permissions origin:(NSString *)origin;
@end

// ARCHCEFBrowser
- (instancetype)initWithParentView:(NSView *)parentView url:(NSString *)url
                    requestContext:(ARCHCEFRequestContext *)requestContext
                          delegate:(id<ARCHCEFBrowserDelegate>)delegate;
```

- Creation: `CefRequestContext::CreateContext` with `cache_path` set and every other `CefRequestContextSettings` value left empty or zero, as `CefSettings` leaves them today. The bridge keeps the root cache path given to `initializeWithFrameworkPath:…` and refuses other paths.
- Readiness: a `CefRequestContextHandler` subclass marks `OnRequestContextInitialized`, and the callback of `GetCookieManager(callback)` marks the cookie store. Calls made before both arrive wait in a queue and run in order on the main queue. The global context counts as ready once `CefInitialize` succeeds.
- Every global path moves to the instance: the cookie calls (:437, :445, :453, :469); `CookieDeleter`, which keeps the manager it visited and flushes that one (:504); `deleteCookiesPassingTest` (:622); the permission settings (:743); and both `CreateBrowser` calls, for the hidden storage-clearing browser (:641) and for tabs (:1459), which pass the context.
- Shutdown: a weak table like `gBrowsers` tracks the context objects. `+shutdown` closes the browsers and runs CEF's work as today, then releases every object's `CefRefPtr`s (context, handler, cookie manager) and runs its queued completions, then calls `CefShutdown`. Calls after that do nothing.
- Transition within step 4: the class methods `ARCHCEFCookieStore`, `ARCHCEFSiteData`, and `ARCHCEFPermissionStore` first become thin wrappers over `globalContext`, then are deleted once the adapter calls the instance methods, so no global path survives.
- Developer tools open from the inspected browser and need no change (checked in step 13).
- Cost: each Persona with Chromium tabs has its own render processes.
- This is bridge work, not a CEF patch, so the plan's patch list does not change.

## session.json

```swift
struct SessionSnapshot: Codable {
    /// Each step that adds fields takes the next free number when it lands, as folders (III.3) do. The doc comment lists what each version adds.
    static let currentVersion: Int

    struct TabRecord: Codable {
        var id: UUID?            // step 1; nil in older files
        var spaceID: UUID        // unchanged; for a small-window tab, its destination space
        // url, title, customTitle, isPinned, lastActivatedAt, engine, state: unchanged
        var personaID: UUID?     // step 2; nil in older files
    }
    struct WindowRecord: Codable {   // step 10
        var id: UUID
        var frame: CGRect?           // screen coordinates, the frame outside full screen
        var currentSpaceID: UUID
        var selectedTabID: UUID?
        var isSidebarVisible: Bool
    }

    var version: Int?
    var personas: [Persona]?                // step 2; nil in older files
    var removedPersonaIDs: [UUID]?          // step 5; storage to remove at the next launch
    var spaces: [Space]                     // with Space.personaID
    var currentSpaceID: UUID                // the front main window's, for older builds
    var favorites: [Favorite]               // with Favorite.personaID
    var tabs: [TabRecord]
    var selectedTabIndex: Int?              // the front main window's, for older builds
    var closedTabs: [TabRecord]?
    var windows: [WindowRecord]?            // step 10; main windows, front to back

    /// Fills in what older files lack and repairs references. The only migration point.
    func normalized() -> SessionSnapshot
}
```

Loading (`SessionStore.load()` keeps its signature)
1. A file whose `version` is newer than `currentVersion` is first copied to `session-v<version>.json`, replacing an older copy. Unknown keys are then ignored, as today.
2. A file that fails to decode is moved to `session.unreadable.json`, replacing an older one, and `load()` returns nil. The session starts fresh without overwriting it.
3. A decoded snapshot is returned through `normalized()`. A missing file gives an empty snapshot, which the session also normalizes.

`normalized()` rules, in order
1. Tab records, open and closed, without an ID or with a duplicate ID get a new one.
2. A nil or empty `personas` becomes `[Persona(id: Persona.defaultID, name: "Default")]`. A list without the default Persona gets it at the front.
3. A space or favorite without `personaID` takes the default Persona. One whose Persona is unknown takes the first Persona, the orphan rule of `docs/sync.md`.
4. Spaces are stably sorted by Persona order, so each Persona's spaces are contiguous and keep their order.
5. A Persona without spaces gets a space named "Personal", as sync's orphan rule and the first launch do.
6. An open tab record takes its space's Persona. A closed record keeps its `personaID`, or takes its space's Persona, or the default Persona. Records whose space is missing are skipped at restore, as today.
7. A nil `windows` becomes one record from `currentSpaceID`, the ID of the record at `selectedTabIndex`, a visible sidebar, and no frame. A window whose space is missing takes the first space. A selected tab that is missing, or that an earlier window record already claims, becomes nil. A selected tab in another space moves the window to that space.
8. `removedPersonaIDs` drops the IDs that are still in `personas`, and the default ID.

Saving
- `windows` lists the open main windows in `NSApp.orderedWindows` order. While none is open, it holds the record of the last main window that closed, which `windowWillClose` keeps, so quitting by closing the last window restores that window.
- The top-level `currentSpaceID` and `selectedTabIndex` come from the front main window, so an older build still opens it.
- Small-window tabs are written as open tabs of their destination space. Small windows are not saved (open decision 4).
- Window records, frames, and `removedPersonaIDs` never sync. `docs/sync.md` already keeps window frames and the selection on each Mac.

Older builds
- They ignore the unknown keys and open the front window's state. When they save, they drop `personaID`, `personas`, and `removedPersonaIDs`, so every space comes back in the default Persona and the other Personas' stores stay on disk unused (open decision 13).

Tests
- Step 1 adds a `BrowsingTests` target (Swift Testing; one `.testTarget` line in `Package.swift`, path `Packages/ARCH/Tests/BrowsingTests`) whose tests call `normalized()` on files of each version. `swift test --filter BrowsingTests` runs them.

## Windows and menus (III.6)

AppKit
- `NSWindow.allowsAutomaticWindowTabbing = false` before the first window opens.
- The main window keeps today's style, empty unified toolbar, and minimum content size of 800×500. A small window's minimum is 480×360.
- Frames are saved on move and resize through the session's 0.5-second save. The frame from before full screen is kept, and full screen is not restored. At restore, a frame that does not overlap any screen's `visibleFrame` by at least 100×100 points is centered on the main screen at its saved size, clamped to that screen. A window without a frame is centered at 1200×800, as today. ⌘N cascades from the active window.
- Restore creates the windows back to front, so the front one becomes key last. Sheets that restored tabs asked for show as each window appears.

Menus
- File: New Tab (⌘T), New Window (⌘N), Close Tab (⌘W), Close Window (⇧⌘W, `performClose:` on the key window), and the existing items.
- New Window opens a main window on the active window's current space with no tab selected and shows the New Tab palette in it (open decision 8).
- ⌘W: another key window that is not a browser window closes, as today. In a small window, ⌘W closes the tab and with it the window. In a main window, it closes the internal page or the selected tab, as today; with no selected tab, it closes the window when another browser window is open.
- Window (new, set as `NSApp.windowsMenu`): Minimize (⌘M, `performMiniaturize:`), Zoom (`performZoom:`), a separator, Move to Main Window (⌥⌘N, step 11; enabled while the active window is small), a separator, and Bring All to Front (`arrangeInFront:`). AppKit appends the window list. `NSApp.windowsMenu` is set after `installShortcuts()`, so `ShortcutSettings` lists the app's items and none that AppKit adds.
- Page commands use `activeWindow`: Reload, Back, Forward, Home, the History menu's pages, find, zoom, print, export, capture, share, the developer tools and their side, Clear Site Data, Close Tab, Close Other Tabs, and Open Location (⌘L edits a small window's address).
- Sidebar commands use `sidebarTarget()`: New Tab, Reopen Last Closed Tab, the Tab menu, the Spaces menu, Toggle Sidebar, and Downloads. Add to Favorites adds the active window's tab. The global shortcut, History's Open, Import, and the default-browser prompt use the sidebar target's `nsWindow`.

Monitors
- Escape for page fullscreen: `session.window(for: event.window)` must have a `fullscreenTabID` and no region capture.
- ⌃Tab: the key-down must come from a main window. `flagsChanged` commits the window whose switcher is visible. Clicks and losing active status cancel every switcher.
- The ⌘Z click monitor forgets the undoable closes when the click lands in the page of the selected tab of `event.window`'s model. ⌘Z reopens into the sidebar target.
- `CommandKeyState` stays app-wide, so every window shows the ⌘-number badges.

Engine and tab events
- A popup opens in its opener's space and Persona, owned by the opener's runtime. When a window shows the opener, the popup is selected there; from step 11, a small window's popup opens in a new small window (open decision 11). Otherwise it opens unread in the background, as today.
- Open Link in New Tab opens unread in the background of the page's space, as today; for a small-window tab, that is its destination space.
- `requestSelection`, which a leave-page sheet uses on close, does nothing when a window shows the tab. Otherwise the sidebar target selects it.
- Page fullscreen goes to the window that shows the tab. A tab that no window shows exits fullscreen at once.
- Closing a tab that windows show makes each of them pick its fallback (window rule 3).
- `deleteSpace` moves the tabs to a neighbor space in the same Persona and switches every window on the deleted space there.
- Archiving treats every shown tab as active.
- Now Playing follows `focusedTabID`. AppleScript's `active tab` is `focusedTab`, and `tabs` lists sidebar order (spaces in Persona order), then small-window tabs.
- Closing a window runs, in order: dismiss the palette, hide find, cancel region capture, exit page fullscreen, defer the visible sheet, and `devToolsDock.track(nil)`. Then the session removes the model, keeps the last main window's record, and schedules a save. When code closes a window, as Persona deletion does, its sheet ends with the deferred response first, because AppKit closes the window anyway.

## Small window (III.7)

When
- `application(_:open:)` opens a link in a small window when three things hold: the preference is on, the first windows have been restored, and Arch was not active when the link arrived. Not active means `!NSApp.isActive`, or the app became active less than 0.5 seconds before; step 11 fixes the threshold from a log. Otherwise the link opens a tab in the sidebar target, as today. Links that arrive during launch open in the main window, so regression check 4's launch case holds. `open location` arrives the same way and follows the same rule. The global shortcut always uses the main window.

The tab
- Its destination space is the last main window's current space, or the last closed main window's, or the first space. Its Persona is that space's (open decision 6). It uses the default engine.
- `isInSmallWindow` is true. The tab stays in `session.tabs`, so sheets, permissions, downloads, zoom, crash notices, Now Playing, and the close log work.
- `isListedInSidebar` keeps it out of `tabs(in:pinned:)` (and with it the sidebar, ⌘-numbers, `orderedTabs`, `moveSelectedTab`, and AppleScript's space order), `closeOtherTabs`, the `closeTab` fallback, `recentTabs`, the `switchToSpace` candidates, `openFavorite`'s reuse, the palette's matching tabs, the restore fallback, and archiving. `deleteSpace` moves it with its space. `snapshot()` writes it as an open tab of its destination space.
- A main window never selects it. Selecting it explicitly runs Move to Main Window instead.

The window
- 900×640. The first is centered on the screen with the pointer, and later ones cascade from it. The window is made key and ordered front, then the app activates with `NSRunningApplication.current.activate(options: [])`. Without `.activateAllWindows`, only the key and main windows come forward (checked in step 11).
- `SmallWindowView`: one row on the traffic-light line with the site's icon and host, back, forward, reload or stop, share, and a Move to Main Window button (an SF Symbol, with its shortcut in the tooltip). Below it, `PageAreaView` over the window material with the destination space's tint. Find, sheets, page fullscreen, the developer tools (with this window's dock), and the ⌘L palette in edit mode work. Sidebar commands go to the main window.

Move to Main Window (the button, Window ▸ Move to Main Window, ⌥⌘N)
1. Clear `isInSmallWindow` and move the tab to the end of its destination space's open tabs, or of `preferredSpace(in: tab.personaID)` if that space is gone.
2. The sidebar target selects the tab, which applies window rule 2: the small window gives it up (its sheet is deferred, page fullscreen ends, its dock lets the tools go), then the main window shows the tab and its sheet. The view moves without a reload.
3. The small window closes without closing the tab, and the main window comes forward.

Closing
- Closing a small window asks to close its tab, so a Chromium page with a `beforeunload` handler can ask to stay. The tab goes to the closed list, and ⇧⌘T reopens it in the main window. A small window whose tab closes for any reason closes with it.

Preference
- Settings ▸ General: "Open links from other apps in a small window when Arch is in the background", stored under `ARCHOpensLinksInSmallWindow` (`BrowserSession.opensLinksInSmallWindowKey`), on by default. Off restores today's behavior exactly.

## Personas in the interface (III.12)

- With one Persona, nothing visible changes. That is the state after the migration.
- With two or more Personas:
  - The bottom bar's symbol strip groups the spaces in Persona order, with a 1-point divider and 6 points of extra space between groups. Dividers have a fixed width and do not count as items in the strip's sizing and shrinking.
  - `SpaceHeaderView` shows the Persona's name above the space name in small secondary text.
  - The favorites grid shows `favorites(in: windowModel.personaID)` and cross-fades when the window enters another Persona's space.
  - The window title adds the Persona's name.
  - Swipes and ⌃⌘←/→ cross group boundaries in strip order, which changes the window's Persona.
  - The Clear Site Data sheet names the Persona: "…removed from both engines in the Persona “Work”…".
- Commands, in the space menu (`SpaceMenuItems`) and the Spaces menu, with no Settings section: New Persona…, Rename Persona…, and Delete Persona…. New Persona and Rename ask for a name in an `NSAlert` sheet with a text field on the active window; an empty name changes nothing. New Persona appends a Persona with one space named "Personal" (with the next tint of the rotation) and switches the window to it. New Space, from the plus and ⌃⌘N, adds a space at the end of the window's Persona's group. III.12 has no reordering of Personas; a new Persona goes last.
- Restrictions: Move Left, Move Right, and dragging a space stay within its group. A tab dragged over another Persona's space symbol does not light it, and its drop does nothing (the target filter at BrowserWindowView.swift:1160 uses `canMoveTab`). Delete Space is disabled for a Persona's last space. The palette lists only tabs of the window's Persona.
- Delete Persona is disabled for the default Persona. For any other, a confirmation sheet says: "Its N spaces and M favorites are removed, and its K tabs close into the closed list. Its downloads in progress stop. Arch removes its cookies and website data from this Mac the next time it opens." Then `deletePersona`:
  1. Every window on its spaces switches to the first space of the first remaining Persona; window rule 3 picks the tab.
  2. Its small windows close, and their tabs close as in item 3.
  3. Its tabs close with reason `.user` into the closed list, without asking their pages, as `docs/sync.md` states for a deleted Persona. The undo count resets. The records keep `personaID`; reopening one whose space is gone uses the sidebar target's current space.
  4. Its unfinished downloads are cancelled, and its kept download pages close through their runtimes. Finished rows stay in the library.
  5. Its spaces and favorites are removed.
  6. Each of its browsers is asked to close, and its `PersonaEngines` moves to `retiredPersonaEngines` until quit, because download items hold their lists and contexts `unowned`.
  7. Its ID joins `removedPersonaIDs`, and the session saves at once.
  8. At the next launch, before any engine starts, the session calls each registered engine's `removeStoredData` for each listed ID. An ID leaves the list once both WebKit and Chromium have reported removal; while the Chromium framework is missing, it stays. Once V.11 exists, the same pass removes `Plugins/<id>/` and the Keychain items whose account starts with `<id>/`.

## Interactions with other features

Plugins (V.11)
- One `PluginManager` per Persona, at `Plugins/<Persona.id>/`; the default Persona's folder is `Plugins/D59DAF4B-E372-4AF9-890E-455B8B3860F3/`. `Persona.defaultID` exists from step 2, so V.11 uses Persona folders from its start, and the interim `Plugins/<plugin ID>/` folder in `docs/ai.md` is not needed.
- `PluginBrowserHost.tabs(in:)` filters `session.tabs` by `personaID`. `openTab(_:_:in:)` uses `preferredSpace(in:)`. `selectTab` goes to the window that shows the tab, else to the sidebar target. `present` uses the active window.
- Page scripts come from the tab's Persona's manager when its web contents is created; `openTab` knows the Persona.
- Download entries record their Persona, so a plugin sees only its Persona's downloads. History stays app-wide in this design, while `docs/plugins.md` says a plugin sees only its Persona's history (open decision 2).
- The half of III.12's done condition about separate plugins can be checked only once V.11 exists (open decision 15).

Sync (V.9)
- `Persona.defaultID` maps to the record name `default`; other Personas use their UUID string. Step 1's `TabRecord.id` supplies the stable tab record names that `docs/sync.md` asks for.
- `normalized()` uses sync's orphan rules: the first Persona, and a "Personal" space for a Persona without spaces.
- Sync applies changes through the session's Persona, space, favorite, and tab mutators, which select nothing. An incoming Persona deletion calls `deletePersona`.
- Window records, frames, small windows, and `removedPersonaIDs` never sync.

AI (VII)
- `ai.json`, its routes, exclusions, limits, and usage stay app-wide, as `docs/ai.md` states.
- The page reader panel (VII.4) and the question popovers (VII.5) are window state on `BrowserWindowModel` and act on the active window's selected tab. Hook events (VII.6) carry the tab's Persona, so they reach that Persona's plugin manager. AI-written plugins (VII.7) install into the active window's Persona.

Live favorites (III.13)
- A favorite and its live tab belong to one Persona. The live tab follows window rule 1: selecting a favorite whose tab another window shows moves the tab here. It stays alive, hidden, while its window shows another Persona's space. Whether the live tab keeps a `spaceID` is III.13's choice; if it leaves space lists, III.13 extends `isListedInSidebar`.

Split view (III.5)
- `shownTabIDs` covers the panes, and window rule 1 covers every pane. A layout saved per space is app-wide, so a second window on the same space shows a placeholder with Show Here in each pane whose tab another window shows; Show Here applies rule 2. The pane under the pointer sets the window's `selectedTabID`. If III.5 lands before step 11, `PageAreaView` takes the pane layout.

Previews (III.11)
- A preview's secondary web contents comes from the runtime of the window's Persona, so it carries that Persona's cookies. The window model owns the panel, which closes with the window.

Folders (III.3)
- A folder belongs to a space and so to the space's Persona. Moving a folder to another Persona's space goes through the same guard. Its snapshot fields are optional and take the next free version number.

Downloads
- One app-wide list. Each entry records its Persona, from the runtime that owns its list, so a WebKit download resumes in its own store and plugins see their own downloads. The downloads folder comes from `UserDefaults` directly, through the helper that `followDownloadSettings` already uses.

Coordination
- Until step 6 lands, parallel tasks keep any new window-scoped state in one `// MARK: Window state` block of `BrowserSession`. After it, they add such state to `BrowserWindowModel`.
- New code reaches a tab's engine through `runtime(of: tab)`, never through an engine kind alone, and reaches a tab's window through `window(showing:)` or `nsWindow`, never through `NSApp.mainWindow`.
- New snapshot fields are optional, and their migration goes into `normalized()`.

## Implementation order

- Every step builds, keeps the app working, and is one commit with the subject `Task(<ID>): …`. Every step runs `swift build`, `git diff --check`, and `git status --short`.
- Steps marked "bundle" also run `./scripts/bundle_app.sh` and launch with `open build/Arch.app`, on the Chromium engine with a fresh Application Support folder unless a check says otherwise. Checks marked for WebKit first set the default engine to WebKit in Settings ▸ General.
- Inspect `session.json` with `python3 -m json.tool`. Before step 1, keep a copy of a current version 4 file outside Application Support for the migration checks: `cp ~/Library/Application\ Support/Arch/session.json ~/arch-session-v4.json`.
- Regression numbers refer to the checklist in `docs/plan.md`. A step that finishes a queue task updates `docs/plan.md` and `docs/features.md` as the Working Rules require (see Documents), and the batch ends with the Codex prose pass.
- Dependencies: step 2 needs 1; 3 needs 2; 4 needs nothing; 5 needs 3 and 4; 6 needs nothing; 7 to 10 follow in order after 6, and 10 also needs 1; 11 needs 9; 12 needs 11; 13 needs 5 and 10. The order below lands the Persona model and the engine contexts first, so that V.11 and V.9 can use `Persona.defaultID` early. Steps 6 and 7 can move ahead of steps 2 to 5 when parallel interface work makes conflicts in `BrowserSession` worse.

1. III.6.1 Safe load and stable tab IDs (bundle)
   - Files: `Tab.swift`, `SessionStore.swift`, `BrowserSession.swift`, `Package.swift` (`BrowsingTests`), new `Packages/ARCH/Tests/BrowsingTests/SessionSnapshotTests.swift`.
   - Changes: `Tab.init(id:)`; `TabRecord.id` written and restored; `normalized()` with rule 1; the newer-version copy and the unreadable move in `load()`; version +1.
   - Re-check: 10 (a renamed tab keeps its name after relaunch), 18 (`id of active tab`), 22 (the home page persists), 31 (orders persist).
   - New checks: `swift test --filter BrowsingTests` passes. Every record in `tabs` and `closedTabs` has an `id`. `osascript -e 'tell application "Arch" to get id of active tab'` returns the same value before and after a relaunch. The kept v4 file loads with its spaces, tabs, favorites, selection, and closed list. A `session.json` made unreadable (`echo x >> session.json`) reappears as `session.unreadable.json`, and the app starts with one space. A file with `"version": 99` leaves `session-v99.json` beside the new file.

2. III.12.1 Persona model with only the default Persona (bundle)
   - Files: new `Persona.swift`; `Space.swift`, `Tab.swift`, `SessionStore.swift`, `BrowserSession.swift`, `SessionSnapshotTests.swift`.
   - Changes: `personas` published and saved; `normalized()` rules 2 to 6; `Tab.personaID` from the space; `addSpace` gives the new space the current space's Persona and puts it at the end of that Persona's group, and both `moveSpace` methods keep a space within its group, so the order matches what `normalized()` restores; `addFavorite` and `addFavorites` set the Persona and check duplicates within it; closed records carry `personaID`; version +1. No view changes.
   - Re-check: 24, 26 (Import adds favorites), 31; signed-in sites stay signed in on both engines after relaunch.
   - New checks: the tests cover v4 files and step 1 files. The kept v4 file loads into one default Persona, and the new file has `personas` with `D59DAF4B-…` and `personaID` on spaces, favorites, and tab records.

3. III.12.2 Runtimes per Persona and engine (bundle)
   - Files: new `PersonaEngines.swift`; `BrowserSession.swift` (the engine section, every runtime call site, `downloadPages`, `retire`), `DownloadsView.swift` (`DownloadEntry.personaID`), `Persona.swift` (`contextAttributes` with IDs only), `EngineApplication.swift` (`EngineBrowserContextID.default`). `CookieSync.swift` does not change.
   - Changes: `applications`, `personaEngines`, `runtime(for:in:)`, and `runtime(of:)`; adoption per runtime (downloads delegate, download settings, permissions, `cookiesDidChange` to its Persona's sync, and the first copy from the Persona's other runtime); popups owned by the opener's runtime; `switchEngine`, `applyRememberedPermissions`, and `clearSiteData` scoped to the tab's Persona; `downloadsDirectory` from `UserDefaults`.
   - Re-check: 2 (also: closing a Chromium tab during a download keeps the download running, and its page closes once the download finishes), 6, 7, 20, 24, 29. A site signed in on Chromium stays signed in after switching the tab to WebKit and back. A popup opens in its opener's space. With Chromium as the default engine, the first WebKit tab after launch already has the Chromium cookies.

4. III.12.3 Bridge request context objects, global context only (bundle)
   - Files: `CEFBridge.h`, `CEFBridge.mm`, `ChromiumEngine.swift`.
   - Changes: `ARCHCEFRequestContext` with `globalContext` and the instance methods; `ARCHCEFBrowser` takes a context; `CookieDeleter` flushes its own manager; the storage-clearing browser takes the context; the release at shutdown; the adapter uses `globalContext` throughout; the old class methods are deleted at the end of the step. `initWithCachePath:` is not added yet.
   - Re-check: 2, 6, 12 (quitting with the developer tools open, and after closing them, leaves no crash report), 24, 29; cookie copies in both directions, as in step 3.
   - New checks: `ls ~/Library/Application\ Support/Arch/Cache/Chromium` shows no new entries. A build with DCHECKs on for the bridge quits without "Object reference incorrectly held at CefShutdown".

5. III.12.4 Separate storage per Persona and the launch removal pass (bundle)
   - Files: `EngineApplication.swift` (`storageIdentifier`), `Engine.swift` (`removeStoredData`), `EngineBrowser.swift` (comment), `WebKitEngine.swift`, `ChromiumEngine.swift`, `CEFBridge.h` and `CEFBridge.mm` (`initWithCachePath:` and readiness), `Persona.swift` (`storageIdentifier` in `contextAttributes`), `SessionStore.swift` (`removedPersonaIDs`, rule 8, version +1), `BrowserSession.swift` (init order: load the snapshot, run the removal pass, then start the engines; `startEngine` does not depend on the snapshot).
   - Changes: as in the adapter and bridge sections. Personas still have no interface.
   - Re-check: 6, 24, and 29 with only the default Persona; logins from before the step survive on both engines.
   - New checks, with a Persona added by hand: quit, add `{"id": "<new UUID>", "name": "Work"}` to `personas`, set one space's `personaID` to that UUID, and launch.
     - In that space, `https://httpbin.org/cookies/set?persona=work` on Chromium, then `https://httpbin.org/cookies` on WebKit, shows the cookie, copied within the Persona. The same page in a default space shows no `persona` cookie on either engine.
     - `localStorage.x = 1` on example.org in Work leaves it undefined in the default Persona on both engines.
     - `Cache/Chromium/Persona-<UUID>` appears after Work's first Chromium tab, and its caches appear in `~/Library/Caches/Arch/Cache/Chromium/Persona-<UUID>`.
     - `navigator.languages` matches between the two Personas on Chromium. If it does not, `initWithCachePath:` sets `accept_language_list` from the global context's `intl.accept_languages` preference.
     - A new Work Chromium tab loads on its first try after launch. Record whether CEF waited for the context or the browser had to be created after `OnRequestContextInitialized`.
     - Quit, add the Work UUID to `removedPersonaIDs`, remove Work from `personas` and its space's `personaID`, and launch: both directories are gone, or renamed and then gone; `WKWebsiteDataStore.allDataStoreIdentifiers`, logged once in a debug build, no longer lists the UUID; `removedPersonaIDs` is empty. Record where WebKit kept the store.

6. III.6.2 Window model with one window and forwarding shims (bundle)
   - Files: new `BrowserWindowModel.swift`; `BrowserSession.swift`. No view, `AppDelegate`, `NowPlaying`, or `Scripting` change.
   - Changes: every window member and command moves into the model, and the session creates one main model at init. The session's `didCreateNewWebContents` is deleted. Temporary shims on the session:
     - `selectedTabID` and `currentSpaceID` stay `@Published` stored properties that mirror the model in both directions. A flag keeps a write from the model from coming back, and an assignment of the tab already selected still reaches the model, so it leaves an internal page as today.
     - Every other moved member becomes a computed property or a method that forwards to the model.
     - The session forwards the model's `objectWillChange`.
   - Sheets keep today's single slot. `docs/plan.md` Decisions gains the placement rule.
   - Re-check: 1, 2, 9, 10, 11, 12, 13 (both engines), 14, 17, 21, 22, 23, 27, 28, 31; a `session.json` written by this build has the same keys as before.

7. III.6.3 Views and menus take the window; shims removed (bundle)
   - Files: `BrowserWindowView.swift`, `CommandPaletteView.swift`, `FindBarView.swift`, `LibraryView.swift`, `TabSwitcherView.swift`, `CaptureRegionOverlay.swift`, `FlagsPageView.swift`, `SidebarDragAndDrop.swift`, `SplitView.swift`, `TabFolderRowView.swift`, `PagePreview.swift`, `PageReaderPanel.swift`, `PageQuestionPopover.swift`, `PageAssistant.swift` (the reader's visibility and the question popover move to the window model, as Interactions ▸ AI states; the conversations stay per tab), `NowPlaying.swift` (`$focusedTabID` and `focusedTab`), `BrowserSession.swift` (shims deleted; `focusedTabID`, `activeWindow`, `lastMainWindow`, `sidebarTarget()`, the `openTab` semantics), `AppDelegate.swift` (targets; it still builds the one window and sets `nsWindow`), `Scripting.swift`.
   - Changes: `BrowserWindowView(session:window:)` adds `.environmentObject(window)`, and subviews read window state from `@EnvironmentObject var windowModel: BrowserWindowModel`. Drops onto the tab list open in this window's space. Each `session.<window member>` is replaced mechanically.
   - Re-check: 1, 2, 3, 9, 10, 11, 12, 13, 14, 15, 17, 18, 21, 22, 23, 25, 27, 28, 31. With Settings key, ⌘W closes Settings; with History key, ⌘R reloads the tab.
   - New check: `grep -rn "session\.\(selectedTabID\|currentSpaceID\|isSidebarVisible\|isLibraryVisible\|internalPage\|commandPalette\|isFindBarVisible\|findText\|renaming\|fullscreenTabID\|devToolsDock\)" Packages` finds nothing.

8. III.6.4 Rules for several windows, still with one window on screen (bundle)
   - Files: new `TabSheetQueue.swift`; `BrowserWindowModel.swift` (the rule 2 order, the fallback, the activation order per window), `BrowserSession.swift` (`release`, automatic selection that skips shown tabs, the archive exemption, routing of popups, `requestSelection`, and fullscreen, `window(for:)`), `DevToolsDock.swift` (`DevToolsDockSettings`, the `track` guard, `isExcludedFromWindowsMenu`), `AppDelegate.swift` (monitors by `event.window`; the side menu sets the shared settings).
   - Re-check: 6, 7, 12 (a side change applies at once), 13, 15, 21, 29; Clear Site Data's sheet (24) and a capture failure sheet still show.
   - New checks: a JavaScript `alert` in a background tab waits until the tab is selected, then shows on the window. Closing a background Chromium tab with a `beforeunload` handler through Close Other Tabs brings it forward with its sheet. A popup from the selected tab is selected; one from a background tab opens unread.

9. III.6.5 Window controller and multiple windows (bundle)
   - Files: new `BrowserWindowController.swift`; `BrowserSession.swift` (`openWindow`, `restoreWindows`, `windowDidBecomeMain`, `windowWillClose`, the teardown order, the last main window's record in memory), `AppDelegate.swift` (window building removed; New Window, Close Window, and the Window menu after `installShortcuts()`; tabbing off; reopen handling; the targets of the global shortcut, History, Import, and the prompt), `Scripting.swift`.
   - Launch order in `AppDelegate`: register the engines, create the session, set `NSWindow.allowsAutomaticWindowTabbing = false`, build the menus, install the monitors and shortcuts, set `NSApp.windowsMenu`, call `session.restoreWindows()`, open pending links, `ARCH_START_URL`, or a new tab in the sidebar target, activate, and prompt for the default browser on the front main window.
   - Re-check: 4, 5, 9, 12, 16, 18, 20, 26, 28.
   - New checks:
     - ⌘N opens a second window, cascaded, on the current space, with the palette and no tab; window 1 keeps its tab.
     - Clicking in window 2 a tab that window 1 shows moves it, and window 1 falls back to its previous tab. On both engines the page keeps its state. A Chromium video keeps playing; typing and Korean IME input work in a field afterwards; the page is sharp after moving the window to a display with another scale.
     - Docked tools of a Chromium tab hide in window 1 and dock in window 2 when the tab moves. Developer ▸ Dock to Bottom moves the tools of both windows.
     - Page fullscreen in window 2 ends with Escape. ⌃Tab works in each window with its own order. An `alert` in window 2 shows while window 1 shows its own sheet. Renaming a tab in window 1 shows no field in window 2. A link dragged onto window 2's tab list opens in its space. A two-finger swipe over an inactive window switches that window's space.
     - ⇧⌘W on window 2 keeps its tabs in window 1's sidebar.
     - The Window menu lists both windows by tab title and not the docked tools; Minimize, Zoom, and Bring All to Front work; no tab bar items appear.
     - Settings ▸ Shortcuts lists New Window, Close Window, Minimize, Zoom, Move to Main Window, and Bring All to Front, and no window names or system items.
     - ⌘Q with two windows and an open sheet quits without a crash report.
     - ⌥Space brings the last main window forward with the palette.
     - With Settings open, closing every browser window keeps the app running, and a Dock click opens a main window.

10. III.6.6 Windows persist (bundle); finishes III.6
    - Files: `SessionStore.swift` (`WindowRecord`, `windows`, rule 7, version +1), `BrowserSession.swift` (save and restore), `BrowserWindowController.swift` (frames, clamping), `SessionSnapshotTests.swift`.
    - Re-check: 9 (the width persists and is app-wide), 10, 22, 31.
    - New checks: two windows with different frames, spaces, selected tabs, and sidebar visibility return after a relaunch, with the same window in front. A window in full screen returns windowed at its earlier frame. A window left on an external display returns on the main screen after that display is disconnected. Closing the last window quits, and the relaunch restores it. The kept v4 file opens one window centered at 1200×800 with its selection.

11. III.7.1 Small window (bundle)
    - Files: `Tab.swift`, `BrowserSession.swift` (`openSmallWindow`, `moveToMainWindow`, the `isListedInSidebar` filters), `BrowserWindowModel.swift`, new `SmallWindowView.swift`, `PageAreaView` (extracted from `BrowserWindowView.swift`), `BrowserWindowController.swift` (`.small`), `AppDelegate.swift` (routing, Move to Main Window), `Scripting.swift`.
    - First, without changing behavior, log the arrival times of `didBecomeActiveNotification` and `application(_:open:)`, and `NSApp.isActive` during the call, for: `open https://example.org` from Terminal with Arch in the background, `open -g https://example.org`, a link clicked in Mail and one in Notes, `osascript -e 'tell application "Arch" to open location "example.org"'`, and a link that launches Arch. Set the threshold from the log, then remove the logging.
    - Re-check: 1, 4 and 18 as updated below, 6, 12, 13, 21, 27.
    - New checks:
      - With Arch in the background, each link opens a small window in front with no sidebar, and only that window comes forward.
      - The button and ⌥⌘N move the tab into the last main window's current space, selected, and the small window closes. Text typed into a form field there survives on both engines.
      - An `alert` shows on the small window. ⌘F and ⌘L work there. ⌘T opens the palette in the main window.
      - Closing the small window puts its tab in the closed list, and ⇧⌘T reopens it in the main window.
      - A popup from it opens a second small window. Open Link in New Tab adds an unread row to the destination space.
      - The main window's sidebar, ⌃Tab, ⌘-numbers, the palette, and Close Other Tabs ignore it. The archive timer does not close it. `get URL of every tab` includes it.
      - Quitting with it open brings its page back as an open tab of its destination space.
      - With Arch active, links open tabs in the main window.
    - Update checks 4 and 18 in `docs/plan.md`: a link at launch or while Arch is active opens a tab; while Arch is not active and the preference is on, it opens a small window.

12. III.7.2 Preference (bundle); finishes III.7
    - Files: `PreferencesSections.swift`, `BrowserSession.swift` (the key constant), `AppDelegate.swift`.
    - Re-check: 19.
    - New check: with the toggle off, links behave exactly as before step 11; turning it on applies to the next link.

13. III.12.5 Persona management and interface (bundle); finishes III.12
    - Files: `BrowserWindowView.swift` (strip grouping, the header caption, favorites per Persona, the drop and drag guards, `SpaceMenuItems`), `SidebarDragAndDrop.swift`, `CommandPaletteView.swift`, `BrowserSession.swift` (the Persona mutators, `deletePersona`, the guard on space changes, the `deleteSpace` destination, the `reopenLastClosedTab` fallback), `BrowserWindowController.swift` (title), `AppDelegate.swift` (Spaces menu items).
    - Re-check: 24, 26, 30, 31.
    - New checks, which make up the done condition:
      - Create "Work". Sign in to a site in a Chromium tab and a WebKit tab of the default Persona; in Work, the site is signed out on both engines and after an engine switch. Sign in to another account in Work; both Personas keep their accounts after a relaunch.
      - Clear Site Data in Work leaves the default Persona signed in.
      - Window 2 on Work shows Work's favorites while window 1 shows the default Persona's; a favorite added in Work does not appear in the default Persona.
      - Dragging a default-Persona tab onto a Work space symbol neither lights the symbol nor moves the tab. Move Left on Work's first space does not cross into the default group.
      - Delete Work: its tabs are in the closed list, its spaces and favorites are gone, and the windows on it moved to the default Persona. After a relaunch, its `Persona-<UUID>` directories, under Application Support and under `~/Library/Caches`, and its WebKit store are gone, and `removedPersonaIDs` is empty. The default Persona has no Delete Persona item.
      - The developer tools of a Work Chromium tab show Work's cookies under Application ▸ Cookies.
      - Separate plugins per Persona are checked when V.11 lands.

## Documents

- `docs/plan.md`'s Documentation row and the docs list of `resources/README.preset.md` list this note.
- Step 6: `docs/plan.md` Decisions gains the placement rule and window rules 1 to 3.
- Step 10, which finishes III.6: remove the III.6 row; update Current State for the Browsing module (windows, the one-tab-one-window rule, window state in `session.json`) and the App shell (the File and Window menus); add the window checks to the regression checklist; mark row 7 of `docs/features.md` complete.
- Step 12, which finishes III.7: remove the III.7 row; update Current State; update checks 4 and 18 and the Preferences module's General list; mark row 6 complete.
- Step 13, which finishes III.12:
  - `docs/plan.md`: remove the III.12 row. Update Current State for the Browsing module, the WebKit adapter (a store per Persona), the Chromium adapter ("Cookies go through each Persona's request context" in place of "CEF's global cookie manager"), and the Build Procedure's state list (`Cache/Chromium/Persona-<UUID>`; Chromium's caches in `~/Library/Caches/Arch/Cache/Chromium`, where the removal pass also deletes a Persona's directory; and the WebKit stores in `~/Library/WebKit/local.arch.browser/WebsiteDataStore`). Add to Decisions: the default Persona keeps the engines' default storage, cookies copy only within a Persona, and stored data goes at the next launch.
  - `docs/features.md`: row 9 complete; row 3 (favorites per Persona), row 44 (an extension controller per Persona), and row 48 (cookies shared within a Persona).
  - `docs/engine-protocol.md`: `EngineBrowserContextID.default`, `storageIdentifier`, `removeStoredData`, `EngineBrowser` per Persona, the cookies capability row, and the Engine switching section.
  - `docs/sync.md`: the default Persona's UUID maps to the record name `default`. `docs/plugins.md`: the default Persona's folder. `docs/ai.md`: the interim plugin folder note.
- If open decision 1 raises the deployment target, `Package.swift`, the Requirements and open decision 7 of `docs/sync.md`, and this note change in the same commit.

## Open decisions

Until the user decides otherwise, the implementation takes the recommended option of each decision, or the option this note describes.

1. Deployment target: macOS 14 (decided), which `WKWebsiteDataStore(forIdentifier:)` and `CKSyncEngine` both need. This also settles sync's open decision 7.
2. History per Persona: V.11 adds a nullable `persona` column to visits, recorded from `Tab.personaID`, and filters plugin access and palette suggestions by it (recommended), or `docs/plugins.md` drops "a plugin sees only its Persona's … history".
3. Remembered permissions: app-wide and copied into every Persona's contexts (this note), or per Persona.
4. Small-window tabs at quit: saved as open tabs of their destination space (this note), moved to the closed list, or restored as small windows.
5. Selecting a tab that another window shows: move it here (this note), or bring the other window forward.
6. The Persona of a link from another app: the last main window's (this note), or a choice in Settings.
7. When a deleted Persona's data goes: at the next launch (this note), or an immediate attempt with a retry at launch.
8. What a new window shows: no tab and the New Tab palette (this note), or the space's most recent free tab.
9. Sidebar width: one app-wide width (this note, as today), or one per window.
10. Move to Main Window's shortcut: ⌥⌘N (proposed); users can change it in Settings ▸ Shortcuts.
11. Popups from a small window: another small window (this note), or the main window.
12. Moving a tab or space to another Persona: refused (this note), or allowed by reloading in the target Persona, which loses the back-forward list and the sign-in.
13. Downgrade: accept that an older build merges every Persona into the default storage (this note), or add a minimum reader version, which only builds made after it can honor.
14. The default Persona's name, "Default". It cannot be deleted (this note).
15. III.12's done condition: move "separate plugins" to V.11's done condition.
16. Deleting a Persona with downloads in progress: cancel them after the confirmation (this note), or refuse until they finish.
17. Closing the last main window: quit (this note, as today), or keep running for small windows and reopen from the Dock.
18. Window full screen across launches: not restored (this note).
19. Reordering Personas: not in III.12 (this note); sync carries the order once a later task adds the interface.
