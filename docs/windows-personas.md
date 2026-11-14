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
- WebKit keeps an identifier store, caches included, in `~/Library/WebKit/xyz.taeyoon.arch/WebsiteDataStore/<UUID in lowercase>`, and `+removeDataStoreForIdentifier:completionHandler:` deletes that directory.
- Chromium's `Local State` lists every profile it has loaded in `profile.info_cache` and `profile.profiles_order` and keeps the entry after the removal pass deletes the profile's directories. Chromium starts normally with such entries. An entry holds the default name and avatar and empty account fields, no site data, so the removal pass leaves the file alone.

Checked at runtime for step 11, with the bundled app, temporary logging in `AppDelegate`, and the Mac's screen locked
- A link that launches Arch (`open -a build/Arch.app <url>`) reaches `application(_:open:)` after `applicationWillFinishLaunching` and before `applicationDidFinishLaunching`, while the session does not exist yet, so it waits in `pendingURLs` and opens as a tab of the main window.
- With Arch running, `open -a build/Arch.app <url>`, `open -g -a build/Arch.app <url>`, `open <url>` with Arch as the default browser, and `osascript -e 'tell application id "xyz.taeyoon.arch" to open location "example.org"'` all reach `application(_:open:)`, the last one as text without a scheme. No automation prompt appeared for `open location`.
- While the screen is locked, the login window stays in front: `lsappinfo front` names it, `osascript … activate` returns without effect, `NSApp.isActive` is false at every call, and no `didBecomeActiveNotification` arrives. The log therefore cannot order activation against the URL event, and the threshold stays at the proposed 0.5 seconds.

Checked at runtime for step 11, with the screen locked and temporary code in `AppDelegate` that drove the windows and logged their state
- Links sent while Arch was in the background, by `open -a` and by `open location`, opened small windows, the first 900×640 and centered on the screen, the second cascaded from it. A link that launched Arch opened as a tab of the main window.
- `NSWindow.endSheet(_:returnCode:)` calls the sheet's completion handler at once and only then animates the sheet out, running the run loop for about 0.27 seconds before it returns. A sheet that the handler begins on another window stays on the first window, and that window's model no longer knows it. A deferred sheet therefore shows again only after `endSheet` returns (`TabSheetQueue`). With that, an `alert` moved with its tab between two main windows and from a small window to the main window, and OK there answered the page.
- Move to Main Window put the tab last among its space's open tabs and selected it in the main window, which then held its page's view, and the small window closed. `performClose` on a small window closed its tab into the closed list, Reopen Last Closed Tab brought it back as a listed tab of the main window, and Close Tab closed both tab and window. Archiving left a small window's tab open. Quitting with a small window open saved its tab as an open tab of its space and only the main window in `windows`.
- `window.open` without a user gesture opened no popup on Chromium, so popups from a small window remain a check for the screen.

Checked at runtime for step 12, with the bundled app, the screen unlocked, and Arch driven through accessibility while another app was in front
- Settings ▸ General shows the toggle on while nothing is saved. Turned off, it saved `ARCHOpensLinksInSmallWindow` as false, and the next link that `open -g -a` sent while another app was active opened a selected tab in the main window. Turned on again, it applied to the next link, from `open location`, which opened a small window. With Arch active, `open -g -a` opened a tab in the main window.
- Settings ▸ Shortcuts lists Move to Main Window with ⌥⌘N in the Window section, with Minimize, Zoom, and Bring All to Front, and none of the items that AppKit adds.
- An `alert` showed on a small window on both engines. On WebKit, Window ▸ Move to Main Window with the alert open moved the tab and the alert to the main window, where OK answered the page. On Chromium, text typed into a field survived the button's Move to Main Window, the tab became the last open tab of its space, and the small window closed. In a small window, Edit ▸ Find… found text in its page and File ▸ Open Location opened the palette with its address; File ▸ New Tab brought the main window forward with the New Tab palette.
- A link with `target=_blank` and a `window.open` from a click in a small window each opened another small window, cascaded by 29 points. The popup kept `window.opener`, and its `postMessage` reached the page on both engines. The main window's sidebar listed none of the small windows' tabs. A small window's close button closed its tab, and quitting saved the small windows' tabs as open tabs of their destination space, with one window record.
- A popup that calls `window.close()` closed at once on WebKit and, as a tab of the main window, on Chromium. In a Chromium small window, its page went blank but the window stayed open until another window became key, so something tied to the key window keeps CEF's view until then (Facts for plan task I.14).

Checked at runtime for step 13, with the bundled app on the Chromium engine, test Personas added to `session.json` by hand, and Arch driven through accessibility while another app was in front
- A Persona listed in `removedPersonaIDs` with a `Plugins/<UUID>` folder and `Persona-<UUID>` directories under both Chromium roots: at launch the folder and both directories went and the list emptied. WebKit reports removal for an identifier that has no store, so a Persona that never used WebKit leaves the list too.
- With a Work Persona and the window on its space, a link that launched Arch opened in Work's Chromium profile, which appeared in `Cache/Chromium/Persona-<UUID>` and its `~/Library/Caches` counterpart. The window title read "Example Domain — Work", Work showed above the space's name, a divider separated Work's symbol from the default group, and typing `copy` in the palette listed Copy Page Address from Work's plugin manager. A cookie that httpbin.org set in Work showed on its page; Clear Site Data's sheet said "removed from both engines in the Persona “Work”", and Clear left the page with no cookies. Clicking a default space's symbol retitled the window "Space 7 — Default", and the palette there offered no Work tab to switch to. Clear Site Data had started WebKit for Work, which created its store in `~/Library/WebKit/xyz.taeyoon.arch/WebsiteDataStore`; with Work removed from `session.json` and listed in `removedPersonaIDs`, the next launch removed both Chromium directories and the WebKit store and emptied the list. With the default Persona alone, the title and the space header named no Persona and the bottom bar showed no divider.
- On Chromium in a main window, a sign-in popup that a button opened became the selected tab with `window.opener`, its `postMessage` reached the page, and its `window.close()` returned the window to the page's tab.
- Through accessibility in the background, every item of the menu bar reported itself disabled, and the space menu and web content in WebKit pages could not be pressed, so the checks below that need them stay open.

Read for plan task I.14 in the code, in the CEF and Chromium sources of `arch-8078-4`, and in the macOS 27 SDK, and checked with stand-in views in a test program outside Arch while the Mac's screen was locked
- A windowed CEF browser on macOS closes only when its view, `CefBrowserHostView`, which `GetWindowHandle` returns, is deallocated: its `dealloc` calls `AlloyBrowserHostImpl::WindowDestroyed`, which closes the browser and so reaches `OnBeforeClose` (`browser_platform_delegate_native_mac.mm`, `alloy_browser_host_impl.cc`). After `DoClose` returns true, CEF waits for that. The session closes a Chromium tab, and a small window with its tab, at `OnBeforeClose` (`cefBrowserDidClose`).
- `CefBrowserHostView` is a plain `NSView`, which takes no focus. Chromium's page view inside it, `RenderWidgetHostViewCocoa` within `WebContentsViewCocoa`, takes focus, and CEF focuses that view (`CefBrowserPlatformDelegateNativeMac::SetFocus`), as it does after each address the app loads (`LoadMainFrameURL`).
- Chromium adds each page's view to `WebContentsViewCocoa` below its other views (`WebContentsViewMac::CreateViewForWidget`, `RenderWidgetHostNSViewBridge::SetParentWebContentsNSView`). A navigation to another site hides the view of the page it leaves without removing it (`RenderFrameHostManager::CommitPending`), and while that page is in the back-forward cache, which CEF's Alloy style allows (`IsBackForwardCacheSupported`), its view, which still takes focus, stays above the current page's view. CEF focuses the current page's view (`GetContentNativeView`). A window made a hidden stand-in for the older view above the current one the first responder when asked.
- `-[NSWindow makeFirstResponder:]` makes a view that takes no focus the first responder. A key event sent to a window whose first responder was a stand-in for CEF's view reached no view (`noResponderFor:`); with the stand-in for Chromium's page view inside it focused, the event reached that view.
- In step 12's run, `focusPage` gave the focus to the topmost subview of an engine view that takes none, which on Chromium is CEF's view. `openSmallWindow` focuses the new window's page, and a main window's selection of a tab does not, so only the small window's popup had the focus when its page closed itself.
- Chromium's page view, when it is deallocated, gives up the focus and calls `[NSApp updateWindows]`, because `[NSTextInputContext currentInputContext]` might otherwise keep its context (`render_widget_host_view_cocoa.mm`, crbug.com/684388). AppKit updates its windows after each event, and a page's `window.close()` reaches `DoClose` through CEF's work, not through an event.
- In a window that was not key, of an app that was not active, the stand-in for CEF's view was released as soon as it left its parent, whether it, the view inside it, or neither had the focus, also inside SwiftUI's hosting view. So whatever holds the view needs something the test program lacked, most likely a key window, which it could not get with the screen locked.

Not verified; the implementation order checks each
- That a CEF Alloy browser keeps input, IME, focus, accessibility, and backing scale when its parent view moves to another `NSWindow`.
- The order in which app activation and the URL event arrive when Terminal, Mail, or Notes opens a link while the screen is unlocked, which sets the 0.5-second threshold, and whether activation brings only the small window forward. Step 12's run had the screen unlocked but took no log, clicked no link in Mail or Notes, and recorded no window order, so plan task I.15 makes these checks.
- On WebKit, that text typed into a form field survives Move to Main Window: typing did not reach a WebKit page in the background. With a print or Export as PDF panel on a small window, that ⌥⌘N and ⌘W end the panel with Cancel; that a download-only small window's save panel opens as a panel of its own and saves; and the palette's width in a 480-point small window. Step 12's run drove Arch through accessibility while another app was in front and did not cover these; plan task I.15 makes them with Arch in front.
- That a Chromium popup's small window closes at once when its page calls `window.close()`, with `focusPage` giving the focus to Chromium's page view and a closing page that has the focus updating the windows (Small window ▸ Closing). Which object AppKit holds the view with was not seen, since the stand-ins could not reproduce it without a key window; plan task I.14 runs regression check 42 for it.
- That Chromium's developer tools for a tab use that tab's request context, and the Persona commands and guards through the interface: New Persona…, Rename Persona…, and Delete Persona… from the space menu and the Spaces menu with their sheets, Delete Persona's teardown in a running session, a tab dragged onto another Persona's space symbol, and Move Left on a Persona's first space. Step 13's run reached Arch only through accessibility in the background, where the menus and the space menu do not respond, so plan task I.16 makes these checks with Arch in front.

## Decisions

### Placement rule

Every piece of state has exactly one owner. Parallel tasks follow the same table; step 6 copies it into `docs/plan.md` Decisions.

| State that… | Owner | Lifetime |
|---|---|---|
| can differ between two windows open at once: what is shown, focused, or being edited | `BrowserWindowModel` | One window |
| is bound to one Persona's engine storage: contexts, browsers, cookie copying, plugin manager, and web extension runtime | `PersonaEngines` | One Persona, from first use until quit |
| belongs to an engine process: the engine applications, CEF initialization, crash totals, the primary engine | `BrowserSession`, engine section | The app |
| is anything else the user owns: Personas, spaces, favorites, tabs, the closed list, downloads and the pages kept open for them (each with its runtime), permissions, zoom, persistence | `BrowserSession` | The app |

### Window rules

1. At most one window shows a tab. An engine view is one `NSView` with one superview. `BrowserWindowModel.shownTabIDs` lists what a window shows: its selected tab, and with split view (III.5) the panes that no other window shows.
2. Explicit selection moves the tab: a sidebar click, a palette tab row, the tab switcher, ⌘-numbers, Next and Previous Tab, a favorite's tab, a tab's `requestSelection`, and selection by sync or a plugin. The window that shows the tab gives it up first: through its own selection change to a fallback when the tab is its selected tab, or by leaving the pane when the tab is another pane of its split view. Only then does the selecting window run its own side effects. This order lets the losing window undock the developer tools before the gaining window docks them.
3. Automatic selection never takes a tab that another window shows: `switchToSpace`, the `closeTab` fallback, the pane that a pane's close control selects, restore, a new window, and the fallback in rule 2. When no tab is free, the window shows the empty page state that exists today.
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
7. Naming: wherever the interface names a Persona, it shows "Persona / Space": the Persona's name and the surface's space name, such as "Work / Research". This is a window's current space, a tab's space, or a space menu's space. A sheet about the whole Persona that starts from such a place names it the same way, as "the Persona of “Work / Research”": Clear Site Data, Delete Persona, and a plugin's review that starts from a tab or a window. Only a surface without a space names the Persona alone: the Persona pickers of Settings ▸ Plugins and the import sheet, and a review started in Settings ▸ Plugins. A field that edits a Persona's name holds the name alone, and New Persona names no existing Persona. With one Persona, nothing names it, as now. The user set this rule on 2026-11-13.

## Risks and mitigations

| # | What breaks | Mitigation | Step |
|---|---|---|---|
| R1 | One visible-sheet slot lets a sheet in one window block every other window, and the `NSApp.mainWindow` fallback can put a tab's sheet on the wrong window | `TabSheetQueue` keeps the queues per tab and one visible sheet per window. A window with no visible sheet shows the oldest sheet of the tabs on its screen, its selected tab's first, on its own `nsWindow`, which exists from the window's creation, so a sheet requested at selection time shows at once. When a tab leaves a window, that window's sheet is deferred and shows again in the next window that shows the tab | 8 |
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
| R14 | One dock holds one browser window; per-window docks drift apart because each reads `UserDefaults` only at `init`; a dock can undock tools another window just docked | One dock per window; one shared `DevToolsDockSettings` that every dock observes; the rule 2 order; `track(_:)` hides the previous tools window only while no other browser window has docked it | 8 |
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

    /// The Persona that holds everything from builds before Personas. It keeps each engine's default storage and cannot be deleted. Sync names its record `default`, and its plugins live in `Plugins/<id>/`.
    public static let defaultID = UUID(uuidString: "D59DAF4B-E372-4AF9-890E-455B8B3860F3")!
    public var isDefault: Bool { id == Self.defaultID }

    /// The storage of the Persona's profile in each engine: nil, the engines' default storage, for the default Persona, and the Persona's UUID for any other.
    var storageIdentifier: UUID? { get }
}
```

- `Browsing` exports no `PersonaID` alias. `docs/plugins.md` declares `public typealias PersonaID = UUID` in `Plugins`, which `Browsing` will import, and a second public alias of that name would make lookups ambiguous. Browsing code writes `Persona.ID`.

`Space` and `Favorite` (changed)
- Each gains `public var personaID: UUID?`. It is optional so that synthesized `Codable` reads older files and so that fields other tasks add need no hand-written decoder. `normalized()` sets it on every item, and code reads `resolvedPersonaID` (`personaID ?? Persona.defaultID`). Their initializers gain `personaID: UUID? = nil`.

`Tab` (changed)
- `public let id: UUID`, set by `init(id: UUID = UUID(), webContents:spaceID:isPinned:personaID:)`.
- `public let personaID: UUID`.
- From step 11: `@Published public internal(set) var isInSmallWindow = false` and `var isListedInSidebar: Bool { !isInSmallWindow }`. III.13 extends the predicate if live favorite tabs leave space lists.
- From III.14: `var isLoaded: Bool`, false while an `UnloadedWebContents` stands in for a restored tab's page, and `loadPage(_:)`, which puts the engine's page in its place at the saved address, engine, and state. The window calls it through the session as it first shows the tab (`updateShownTabs()`).

`BrowserWindowModel` (new, `BrowserWindowModel.swift`)

```swift
/// Small windows are not saved, so the kind needs no coding.
public enum BrowserWindowKind { case main, small }

/// The state of one browser window: what it shows and what the user is doing in it. Everything else belongs to the session.
public final class BrowserWindowModel: ObservableObject {
    /// The window's identity in `session.json`, which it keeps across launches.
    let id: UUID
    public let kind: BrowserWindowKind
    unowned let session: BrowserSession

    @Published public var currentSpaceID: UUID
    /// Only `selectTab(_:)` changes it, which applies window rule 2: another window that shows the tab gives it up first.
    @Published public private(set) var selectedTabID: UUID?
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
    /// The saved frame, where the window opens, then the frame outside full screen that the window controller records.
    var restorableFrame: CGRect?

    /// Window rule 1: the selected tab and the panes of its split view that no other window shows, left to right.
    @Published private(set) var shownTabIDs: [UUID]
    /// The selected tab, then the other shown panes, or the selected tab alone while its page fills the window. Their sheets can show here. Empty once the window has let go of its tabs as it closes.
    var tabsOnScreen: [Tab] { get }
    /// The sheet the window shows, which `TabSheetQueue` sets and clears.
    var visibleSheet: TabSheet?
    public var selectedTab: Tab? { get }
    /// Selects the tab, or the empty page for nil, in the steps below.
    public func selectTab(_ id: UUID?)
    public var currentSpace: Space { get }
    /// The current space's Persona, which for a small window is its tab's. The window offers its favorites, tabs, and plugins.
    public var personaID: Persona.ID { get }
    /// Step 13: New Persona…, Rename Persona…, and Delete Persona…, each with a sheet on this window (Personas in the interface).
    public func promptForNewPersona()
    public func promptToRenamePersona(_ id: Persona.ID)
    /// The space menu's space or the window's current space, which the sheet names with its Persona (Persona rule 7).
    public func confirmDeletePersona(ofSpace space: Space)
    /// Whether those three can ask: the window shows no other sheet. The menu bar disables them otherwise.
    public var canShowPersonaSheet: Bool { get }
    public var recentTabs: [Tab] { get }
    /// Whether the selected tab's page fills the window, without margins or the controls around the page.
    var isPageFullscreen: Bool { get }
    /// A window of `kind` as `record` describes it: its ID, space, sidebar, and frame. The session selects its tab once the window exists. A small window's record has a new ID, no frame, and its tab's space.
    init(session: BrowserSession, record: SessionSnapshot.WindowRecord, kind: BrowserWindowKind)
    /// The window as `session.json` keeps it, which the session also keeps once the window closes.
    var record: SessionSnapshot.WindowRecord { get }
    /// Window rule 3 within a space: its first tab row that the sidebar shows and no other window shows, open tabs before pinned ones.
    func firstFreeTab(inSpace id: UUID) -> Tab?
    /// Lets go of what the window shows as it closes (Windows and menus ▸ Engine and tab events).
    @MainActor func prepareToClose()
    /// Closes the window from code, first ending with Cancel a sheet that `TabSheetQueue` does not show (Small window ▸ Closing).
    func close()
    /// Step 11: a page that one of the window's pages or its preview opened becomes a selected tab of a main window's current space, or opens in a small window of its own beside a small window (open decision 11).
    func showOpenedPage(_ webContents: any EngineWebContents, personaID: Persona.ID)
}
```

- These commands move here from the session with the same names and bodies, reading the user's data through `session`: `switchToSpace`, `switchToAdjacentSpace`, `addSpace` (adds a space to this window's Persona and switches to it), `selectTab(at:)`, `selectLastTab`, `selectAdjacentTab`, `moveSelectedTab`, `shortcutNumber(for:)`, `openTab(url:engine:)` (in the current space, selected here), `openFavorite`, `navigate(to:)`, `goHome`, `canGoHome`, `setCurrentPageAsHome(ofSpace:)`, `canSetCurrentPageAsHome`, `showCommandPalette`, `dismissCommandPalette`, `submitCommandPalette`, `focusCommandBar`, `closeInternalPage`, `exitPageFullscreen`, `focusPage`, `showFindBar`, `hideFindBar`, `findNext`, `findPrevious`, `toggleLibrary`, `toggleSidebar`, `goBack`, `goForward`, `go(to:inTab:)`, `recentBackItems`, `reload`, `stopLoading`, `toggleDeveloperTools` with the developer tools properties, zoom in, out, and reset with `canZoom`, `printPage`, `exportPageAsPDF`, `canPrint`, the capture commands with `canCapture`, `shareSelectedPage`, `canShareSelectedPage`, the tab switcher, `closeSelectedTab`, `closeOtherTabs`, `confirmClearSiteData`, `canClearSiteData`, `renameSpace`, `renameTab`, and `endRenaming`.
- `selectTab(_:)` sets `selectedTabID` and runs these in order. Steps 1 and 3 can end a sheet and run the run loop (Facts for step 11), allowing a click to select another tab meanwhile. Each step reads the selection when it runs.
  1. `updateShownTabs()`, then `session.release(selectedTab, except: self)`, which makes every other window that shows the tab give it up first and then lets every window show the panes that no window shows any longer.
  2. The window's side effects: leave the internal page, end another tab's page fullscreen, stamp the tab's activation date, record this window's activation, clear the unread dot, and follow the tab's space (main windows only). Only when the tab changed: close the command palette, stop find on the old tab, and close the question popover.
  3. `session.sheets.deferSheet(of: self)` and `session.sheets.showNext()`.
  4. `session.windowDidSelect(self)`, which updates the focused tab while this is the active window. The session's change observer saves the selection.
  5. `devToolsDock.track(selectedTab?.webContents.devTools)`.
  6. Subscribe to the selected tab's `objectWillChange` so that views reading the tab through the window refresh, and move keyboard focus from another pane of the split view to the selected page.
- `shows(_:)` reads `shownTabIDs`, and `isShownInAnotherWindow(_:)` asks the other windows. `updateShownTabs()` runs after the selection or a split view changes and after another window closes: the window keeps its selected tab and the panes it shows already, and takes each other pane of `paneTabs` that no other window shows. Before it publishes them, a restored tab among them that has no page yet gets it (`BrowserSession.loadPage(of:)`, `docs/plan.md` Decisions), so a tab's page exists from the moment a window shows it. `PageAreaView` fills each pane of `paneTabs` outside `shownTabIDs` with a placeholder (Interactions ▸ Split view).
- `giveUp(_:)` is rule 2 in the window that loses a tab. It drops the tab from `shownTabIDs`, then selects `fallbackTab(excluding:)` when the tab is its selected tab, or else keeps its selection, ends the pane's page fullscreen, and defers its sheet. A small window that loses its tab closes instead, and `prepareToClose()` lets go of the page's fullscreen, sheet, and docked tools.
- `fallbackTab(excluding:)` returns the first tab of `recentTabs` that is listed in the sidebar, is not `excluding`, and is not shown by another window, or nil. It can be another pane of the same split view; the window then shows a placeholder in the pane of the tab it gave up.
- `isLibraryVisible.didSet` asks the session to mark finished downloads seen.
- `focusPage` moves keyboard focus only while the selected page is in the window's own `nsWindow`, so a page that another window took in the meantime keeps that window's focus. It gives the focus to the view of the page's engine view that takes the keys, `viewTakingFocus(in:)` (Small window ▸ Closing).
- `closeSelectedTab()` closes the preview panel, the internal page, or the selected tab, and with none of them, the window itself while another browser window is open.

`PersonaEngines` (new, internal, `PersonaEngines.swift`)

```swift
/// One Persona's engine contexts: a context and browser per engine, started on first use, the CookieSync that copies cookies between them, and the Persona's plugin manager.
final class PersonaEngines {
    let personaID: Persona.ID
    var runtimes: [EngineKind: EngineRuntime] = [:]
    let cookieSync = CookieSync()
    /// Created when a tab or window of the Persona first needs it; deleting the Persona closes it and drops it.
    var plugins: PluginManager?
    init(personaID: Persona.ID)
}
```

- `EngineRuntime` gains `let personaID: Persona.ID`. `CookieSync.swift` does not change: within one Persona, each engine kind has one runtime.

`TabSheetQueue` (new, internal, `TabSheetQueue.swift`, moved out of the session)

```swift
/// A sheet a tab asked for.
struct TabSheet {
    let tabID: UUID
    let alert: NSAlert
    let isPageDialog: Bool
    let completion: (NSApplication.ModalResponse) -> Void
}

/// Sheets that tabs asked for, oldest first per tab. A window shows one of them at a time (`BrowserWindowModel.visibleSheet`), for a tab on its screen.
final class TabSheetQueue {
    /// The open browser windows, which the session supplies.
    var windows: () -> [BrowserWindowModel] = { [] }
    func enqueue(_ alert: NSAlert, for tab: Tab, isPageDialog: Bool, completion: @escaping (NSApplication.ModalResponse) -> Void)
    /// Each window that has an AppKit window and shows no sheet, a tab's or another such as a Persona prompt, shows the oldest waiting sheet of its `tabsOnScreen`, the selected tab's first. The window controller calls it again once a sheet has left the window.
    func showNext()
    /// Puts away the window's sheet once its tab has left the window's screen. It shows again first when a window shows its tab.
    func deferSheet(of window: BrowserWindowModel)
    func cancel(for tab: Tab, pageDialogsOnly: Bool = false)
    func cancelAll()
}
```

- The deferral response, the page-dialog flag, and the permission waiters keep today's rules. AppKit calls a sheet's completion handler before `endSheet` takes the sheet off its window, so the handler of a deferred sheet only puts it back in its queue, and the code that deferred it calls `showNext()` once `deferSheet(of:)` has returned. `isQuitting` stays on the session, whose `enqueueSheet` answers `.cancel` at once while the app quits.
- `canPrint` and `canClearSiteData` read the window's `nsWindow?.attachedSheet`, so the queue needs no query of its own.

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

- `DevToolsDock` has no side of its own. It observes `DevToolsDockSettings.shared.side`, places its window again whenever the side changes, and reads the sizes from the settings. `DevToolsDockSpace` observes the settings for the sizes. The Developer menu sets and checks `DevToolsDockSettings.shared.side`.
- `setDocked(true, _:)` also sets `isExcludedFromWindowsMenu`, so the Window menu lists only browser windows. `setDocked(false, _:)` clears it.
- `track(_:)` hides the previous tools window only while no other browser window has docked it: while its parent is the dock's own browser window or none. It undocks the window as it hides it, so the window comes back as a window of its own if the tools float by then.

`BrowserWindowController` (new, internal, `BrowserWindowController.swift`)

```swift
/// The AppKit window of one BrowserWindowModel: the main window, or from step 11 the small window. It reports becoming main and closing to the session and, from step 10, records the frame.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: BrowserWindowModel
    /// Builds the window hidden: at the model's saved frame, kept on a screen; without one, at `source`'s size and cascaded from it, or centered at 1200×800 without a source or while the source is in full screen.
    init(model: BrowserWindowModel, cascadingFrom source: NSWindow?)
    /// Where a window with a saved frame opens, given the screens' visible frames with the main screen first (Windows and menus ▸ AppKit).
    static func restoredFrame(_ frame: CGRect, screens: [CGRect]) -> CGRect
}
```

- Only the session's `makeWindow(from:kind:)` creates one, from a `SessionSnapshot.WindowRecord`: `openWindow()` (⌘N) passes a record with a new ID, no frame, and no tab, restore and `sidebarTarget()`, which also serves the Dock's reopen, pass saved records, and `openSmallWindow` passes a record of its own with the kind `.small`. So all of them take one path. A window without a frame cascades from the window of its kind that last became main. The session keeps the controllers in `windowControllers` and releases each on the turn of the run loop after its window closes, because AppKit is still closing the window then. It lives in `Browsing`, which already builds a window (`TabCloseLogWindowController`) and holds both window views.
- It hosts `BrowserWindowView(session:window:)`, or `SmallWindowView(session:window:)` for a small window, reaching the session through `model.session`, sets `model.nsWindow`, and hides its own toolbar in full screen. A main window keeps the empty unified toolbar and a small window takes an empty compact one (`.unifiedCompact`), so the small window's title bar is thinner while its row still sits on the traffic lights' line as the sidebar's top row does; the page sits half the page margin below that row. `static func centeredFrame(size:pointer:screens:)` places a small window that has no other small window to cascade from.
- It sets the window's hidden title, which the Window menu and Mission Control show: the selected tab's display title, the internal page's name while one is open, or the space's name when neither shows; from step 13, with two or more Personas, followed by " — \<Persona name>". It reads the title on the run loop turn after the model or the spaces change, because `objectWillChange` comes before the change.
- It sets `tabbingMode = .disallowed`, `isRestorable = false`, and `isReleasedWhenClosed = false`.
- Delegate: `windowDidBecomeMain` calls `session.windowDidBecomeMain(model)`. `windowWillClose` calls `session.windowWillClose(model)`. `windowDidMove` and `windowDidResize` record `model.restorableFrame` and schedule a save; resizing covers Zoom and window tiling, which are not live resizes. From `windowWillEnterFullScreen` until `windowDidExitFullScreen` or `windowDidFailToEnterFullScreen`, nothing is recorded, so the frame from before stays, and `windowDidExitFullScreen` records the frame again. From step 11, for a small window, `windowShouldClose` asks to close its tab and returns false; the window closes when the tab does.

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
/// Window rule 7. While no main window is open, reopens the windows of `windowsToReopen` and returns the front one.
public func sidebarTarget() -> BrowserWindowModel
/// New Window: a main window on the active window's space, or the last main window's while none is open, with no tab selected (open decision 8).
@discardableResult
public func openWindow() -> BrowserWindowModel
/// Creates the windows of the loaded snapshot, back to front (Windows and menus ▸ AppKit).
public func restoreWindows()
/// The main windows that open while none is open, front to back: the snapshot's until they open, then the last main window that closed. `snapshot()` saves them while no main window is open. Never empty.
private var windowsToReopen: [SessionSnapshot.WindowRecord]
/// The window whose `shownTabIDs` has the tab.
func window(showing tab: Tab) -> BrowserWindowModel?
public func window(for nsWindow: NSWindow?) -> BrowserWindowModel?
/// Window rule 2 for `window`'s new selection: every other window that shows the tab gives it up, then every window updates its shown tabs.
func release(_ tab: Tab?, except window: BrowserWindowModel)
/// Updates the focused tab when `window` is the active window.
func windowDidSelect(_ window: BrowserWindowModel)
/// Moves `window` to the front of `windows` and updates the focused tab.
func windowDidBecomeMain(_ window: BrowserWindowModel)
/// The teardown under Windows and menus ▸ Engine and tab events.
@MainActor func windowWillClose(_ window: BrowserWindowModel)
/// Stops the reader's replies about the tabs `window` shows while another window shows the reader, or every reply once no other window does.
@MainActor func pageReaderDidHide(in window: BrowserWindowModel)

// Step 13
public func spaces(in persona: Persona.ID) -> [Space]
public func favorites(in persona: Persona.ID) -> [Favorite]
func persona(withID id: Persona.ID) -> Persona?
/// The Persona's name alone, as the space header's prefix before the space's name, or nil while the default Persona is the only one. The Persona pickers of Settings ▸ Plugins and the import sheet list `Persona.name`.
func displayedName(ofPersona id: Persona.ID) -> String?
/// Persona rule 7: "Work / Research", the Persona's name alone without a space, or nil while the default Persona is the only one. A static variant takes the Personas, for callers that hold them, such as the sheets' texts and tests.
func displayedPlace(ofPersona id: Persona.ID, space: Space?) -> String?
/// The last main window's space when it belongs to the Persona, else the Persona's first space.
func preferredSpace(in persona: Persona.ID) -> Space
/// The guard of Persona rule 3. Drop targets use it too.
func canMoveTab(_ id: UUID, toSpace spaceID: UUID) -> Bool
/// Every Persona keeps a space.
func canDeleteSpace(_ id: UUID) -> Bool
func addPersona(named name: String) -> Persona
func renamePersona(_ id: Persona.ID, to name: String)
public func canDeletePersona(_ id: Persona.ID) -> Bool
func deletePersona(_ id: Persona.ID)
/// The Persona's plugin manager, created on first use with the built-in plugins that the app passes to `init(registry:userDataDirectory:builtInPlugins:)`. Settings ▸ Plugins reaches it too.
@MainActor public func plugins(in persona: Persona.ID) -> PluginManager

// Step 11
/// Whether a link from another app opens in a small window, judged by timing alone; the caller checks the preference first: Arch was not active, or became active less than `smallWindowActivationGrace` (0.5 seconds) before the link arrived.
public static func opensLinkInSmallWindow(isAppActive: Bool, becameActiveAt: Date?, now: Date) -> Bool
/// The app sets it to name Move to Main Window's shortcut, which Settings ▸ Shortcuts can change, in the small window's button.
public var moveToMainWindowShortcut: () -> String?
@discardableResult public func openSmallWindow(url: URL) -> BrowserWindowModel
/// A small window on a new tab for a page that a small window's page or preview opened.
@discardableResult func openSmallWindow(_ webContents: any EngineWebContents, spaceID: UUID, personaID: Persona.ID) -> BrowserWindowModel
public func moveToMainWindow(_ smallWindow: BrowserWindowModel)

// Step 12
/// Settings ▸ General saves under this key whether links from other apps may open in small windows.
public static let opensLinksInSmallWindowKey: String
/// The preference's value while nothing is saved, which the toggle and the link routing share: true.
public static let opensLinksInSmallWindowByDefault: Bool
```

- Every existing app-wide mutator keeps its name. `openTab(url:in:pinned:select:engine:state:)` keeps its signature, so parallel tasks compile: a nil space means the sidebar target's current space, and `select: true` selects the tab in the sidebar target. The tab takes the space's Persona. Views and menus use `BrowserWindowModel.openTab` instead.
- `addFavorites(_:in:)` adds to the given Persona: the file import (`ImportController`) passes the Persona of the sidebar target's current space, and the browser import passes the destination Persona. `addFavorite(_ tab:)` uses the tab's Persona. Duplicate addresses are checked within one Persona.
- The Persona mutators stay internal: the app reaches them through the window's sheets, and Sync (V.9) makes public what it needs. The only public path for creating a Persona and its spaces is the browser import's `addImport(_:to:record:)` (`docs/import-browsers.md`). A page's tab joins a space of the page's Persona through one helper that `adopt` and `openSmallWindow` share: the given space while it belongs to that Persona, else `preferredSpace(in:)`.
- Engine section: `applications: [EngineKind: any EngineApplication]`, each started once (`makeApplication`, `delegate = self`); `personaEngines: [Persona.ID: PersonaEngines]`; `retiredPersonaEngines: [PersonaEngines]` for deleted Personas, kept until quit; `runtime(for kind:, in persona:) -> EngineRuntime`, which creates the context for the Persona's `storageIdentifier` and its browser on first use and falls back to the primary engine within the same Persona; `runtime(of tab:) -> EngineRuntime?`; and `allRuntimes`.
- The session implements no browser delegate: popups reach it through their opener's `Tab.openNewTab`.
- `validateMenuItem` and other checks read `lastMainWindow` and never create a window.

`SmallWindowView` (new, internal, step 11, `SmallWindowView.swift`): `init(session: BrowserSession, window: BrowserWindowModel)`; its layout is under Small window.

`PageAreaView` (internal, in `SplitView.swift`, where split view (III.5) put it before step 11): `init(session: BrowserSession, sidebarDrag: SidebarDragState?, margins: EdgeInsets)`, holding the panes with the page host and its background, the crash notice, the internal page, the region capture overlay, and the frame stroke, and around them the preview panel, the margins, the developer tools space, and the window's full screen for page fullscreen. Both window kinds show the page through it, so page fullscreen and the docked tools behave the same in each. A window without a sidebar passes no `sidebarDrag`.

`CommandPaletteLayer` (internal, step 11, in `CommandPaletteView.swift`, extracted from `BrowserWindowView`): the palette, its dimming, the warm-up copy, and their motion, which both window kinds show. The main window passes its address pill's frame and pull; the small window passes none.

### Arch

- `AppDelegate` keeps the menu bar, link routing, the key monitors, the global shortcut, and the app's lifecycle. Window building moves to `BrowserWindowController`. Every action resolves `session.activeWindow` (page commands) or `session.sidebarTarget()` (sidebar commands). Selector names stay unchanged, because `ShortcutSettings` keys saved shortcuts by them.
- It adds `applicationShouldHandleReopen(_:hasVisibleWindows:)`: with no main window open, a Dock click opens one.
- It records the time of each `NSApplication.didBecomeActiveNotification` for the small-window decision (step 11) and reads the preference under `opensLinksInSmallWindowKey` as each link arrives (step 12).
- Sidebar commands go through `frontSidebarTarget()`, which brings the sidebar target forward while a small window is the active window (window rule 7).

### ARCHEngine

```swift
public protocol EngineApplication: AnyObject {
    // other members
    /// Makes a profile whose data lives in the storage `storageIdentifier` names. nil: the engine's default storage, which keeps the data of builds before Personas, WebKit's default data store and CEF's global request context. A UUID: storage of its own, `WKWebsiteDataStore(forIdentifier:)` or a CEF request context whose profile is the `Persona-<UUID>` directory under the root cache path.
    func createBrowserContext(storageIdentifier: UUID?, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void)
}

public protocol Engine: AnyObject {
    // existing members
    /// Removes what a context with `identifier` stored while no context of this process uses it, as at launch before `makeApplication`. Reports whether it is gone; false means try again at a later launch.
    func removeStoredData(forStorage identifier: UUID, configuration: EngineApplicationConfiguration, completion: @escaping (Bool) -> Void)
}
```

- The storage identifier alone names a profile's storage, so no adapter parses a string as a UUID. `Persona.storageIdentifier` is nil for the default Persona and the Persona's UUID for any other.
- `EngineBrowser` is the web contents of one browser context in one engine. The session keeps one per Persona and engine, tied to no window, because tabs move between windows.
- `createBrowserContext` keeps completing synchronously, because `startEngine` and `openTab` rely on it.

### WebKit adapter

- `WebKitApplication.createBrowserContext(storageIdentifier:)` picks the store: `.default()` without a storage identifier and `WKWebsiteDataStore(forIdentifier:)` with one. The adapter's tests make a profile over `.nonPersistent()` through the internal `makeBrowserContext(storageIdentifier:dataStore:)`. Each context keeps its store object for the app's lifetime.
- Tabs, popups, the downloads' hidden web view, and the cookie observer already use the context's store and need no change.
- `WebKitEngine.removeStoredData` calls `+removeDataStoreForIdentifier:completionHandler:` and reports success when the error is nil. It does not start the WebKit application.
- Web extensions: one `WKWebExtensionController` per context, and thus per Persona. Its configuration follows the store: `.nonPersistent()` for a store that keeps nothing on disk, as in the adapter's tests, `.default()` without a storage identifier because the default Persona keeps WebKit's default store, and `configurationWithIdentifier:` with one. Its `defaultWebsiteDataStore` is the context's store.

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
7. A nil or empty `windows` becomes one record from `currentSpaceID`, the ID of the favorite tab record of `selectedFavoriteID` or else of the record at `selectedTabIndex`, a visible sidebar, and no frame. A window whose space is missing takes the first space. A selected tab that does not reopen (an open tab record of a missing space, or no record of a listed favorite), or that an earlier window record already claims, becomes nil. A selected tab in another space moves the window to that space.
8. `removedPersonaIDs` drops the IDs that are still in `personas`, and the default ID.

Saving
- `windows` lists the open main windows in the session's order, most recently main first, which is front to back and, unlike `NSApp.orderedWindows`, keeps minimized windows. While none is open, it holds the record of the last main window that closed, which `windowWillClose` keeps, so quitting by closing the last window restores that window.
- The top-level `currentSpaceID`, `selectedTabIndex`, and `selectedFavoriteID` come from the front main window, so an older build still opens it.
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
- Frames are saved on move and resize through the session's 0.5-second save. The frame from before full screen is kept, and full screen is not restored. At restore, a frame that does not overlap any screen's `visibleFrame` by at least 100×100 points is centered on the main screen, the one with the menu bar, at its saved size, clamped to that screen. A window without a frame is centered at 1200×800, as today. ⌘N cascades from the last main window at its size, or centers at 1200×800 while that window is in full screen; a small window in front is not the source, so a new main window keeps the main windows' size.
- Restore creates the windows back to front, so that `windows` lists them front to back, then selects their tabs: every window takes its saved tab, which a window in front of it gives up when it shows the tab as a split view pane, before any window falls back to its space's first free tab, so that no window falls back to a tab another one saved. The windows then come forward back to front, so the front one becomes key last. Sheets that restored tabs asked for show as each window appears. A restored tab has an `UnloadedWebContents` in place of its page until a window first shows it, so only the tabs these selections and their split views show create pages at launch. The favorites' tabs that windows selected open at launch.

Menus
- File: New Tab (⌘T), New Window (⌘N), Close Tab (⌘W), Close Window (⇧⌘W, `performClose:` on the key window), and the existing items.
- New Window opens a main window on the active window's current space with no tab selected and shows the New Tab palette in it (open decision 8).
- ⌘W: another key window that is not a browser window closes, as today. While a sheet shows on such a window, Close Tab is disabled, so ⌘W closes neither the sheet, its window, nor a tab behind them. In a small window, ⌘W closes the tab and with it the window. In a main window, it closes the internal page or the selected tab, as today; with no selected tab, it closes the window when another browser window is open.
- Window (new, set as `NSApp.windowsMenu`): Minimize (⌘M, `performMiniaturize:`), Zoom (`performZoom:`), a separator, Move to Main Window (⌥⌘N, step 11; enabled while the active window is small), a separator, and Bring All to Front (`arrangeInFront:`). AppKit appends the window list. `NSApp.windowsMenu` is set after `installShortcuts()`, so `ShortcutSettings` lists the app's items and none that AppKit adds.
- Page commands use `activeWindow`: Reload, Back, Forward, Home, the History menu's pages, find, zoom, print, export, capture, share, the developer tools and their side, Clear Site Data, Close Tab, Close Other Tabs, and Open Location (⌘L edits a small window's address).
- Sidebar commands use `sidebarTarget()`: New Tab, Reopen Last Closed Tab, the Tab menu, the Spaces menu, Toggle Sidebar, and Downloads. Add to Favorites adds the active window's tab. The global shortcut, History's Open, Import, and the default-browser prompt use the sidebar target's `nsWindow`.

Monitors
- Escape for page fullscreen: `session.window(for: event.window)` must have a `fullscreenTabID` and no region capture.
- ⌃Tab: the key-down must come from a main window. `flagsChanged` commits the window whose switcher is visible. Clicks and losing active status cancel every switcher.
- The ⌘Z click monitor forgets the undoable closes when the click lands in the page of the selected tab of `event.window`'s model. ⌘Z reopens into the sidebar target. The key monitor compares each key with the current shortcuts of Edit ▸ Undo, Close Tab, Close Other Tabs, and Reopen Last Closed Tab, which Settings ▸ Shortcuts can change.
- `CommandKeyState` stays app-wide, so every window shows the ⌘-number badges.

Engine and tab events
- A popup opens in its opener's space and Persona, owned by the opener's runtime. When a window shows the opener, the popup is selected there; from step 11, a small window's popup opens in a new small window (open decision 11). Otherwise it opens unread in the background, as today.
- Open Link in New Tab opens unread in the background of the page's space, as today; for a small-window tab, that is its destination space.
- `requestSelection`, which a leave-page sheet uses on close, shows the page the sheet asks about. The window that shows the tab selects it when it is another pane there, or closes the internal page over it when it is selected already. Otherwise the sidebar target selects it. A favorite's tab keeps a window's current space, so it goes to the front main window of its Persona instead, or to the sidebar target moved to the Persona's preferred space.
- Page fullscreen goes to the window that shows the tab. A tab that no window shows exits fullscreen at once.
- Closing a tab that windows show makes each of them pick its fallback (window rule 3).
- `deleteSpace` moves the tabs to a neighbor space in the same Persona and switches every window on the deleted space there.
- Archiving treats every shown tab as active.
- Now Playing follows `focusedTabID`. AppleScript's `active tab` is `focusedTab`, and `tabs` lists sidebar order (spaces in Persona order), then small-window tabs.
- Closing a window runs `prepareToClose()`, in order: stop the page reader's replies about its tabs, dismiss the palette, hide find, cancel region capture, exit page fullscreen, close the preview panel and the question popover, empty `shownTabIDs` and defer the visible sheet, and `devToolsDock.track(nil)`. Then the session keeps the window's record, removes the model, lets the other windows take the panes it showed and show their sheets, and updates the focused tab; the change of `windows` schedules a save. When code closes a window, as Move to Main Window does, `close()` first ends a sheet that `TabSheetQueue` does not show with Cancel, and `prepareToClose()` defers the queue's sheet before AppKit takes it away, so that the sheet waits for a window that shows its tab. Persona deletion closes its small windows through `closeTab`, which first cancels the tab's sheets.

## Small window (III.7)

When
- `application(_:open:)` opens a link in a small window when three things hold: the preference is on, the first windows have been restored, and Arch was not active when the link arrived. Not active means `!NSApp.isActive`, or the app became active less than 0.5 seconds before. Step 11's log was taken with the screen locked, when Arch never became active, so it could not set the threshold, which stays at the proposed value (Facts) until plan task I.15 sets it. Otherwise the link opens a tab in the sidebar target, as today, and the sidebar target comes forward from behind a small window. Links that arrive during launch reach `application(_:open:)` before the session exists and open in the main window, so regression check 4's launch case holds. `open location` arrives the same way and follows the same rule. The global shortcut always uses the main window.

The tab
- Its destination space is the last main window's current space when the small window opens, or the last closed main window's, or the first space. Its Persona is that space's (open decision 6). It uses the default engine.
- `isInSmallWindow` is true. The tab stays in `session.tabs`, so sheets, permissions, downloads, zoom, crash notices, Now Playing, and the close log work.
- `isListedInSidebar` keeps it out of `tabs(in:pinned:)` (and with it the sidebar, ⌘-numbers, `orderedTabs`, `moveSelectedTab`, and AppleScript's space order), `closeOtherTabs`, the `closeTab` fallback, `recentTabs`, the `switchToSpace` candidates, `openFavorite`'s reuse, the palette's matching tabs, the restore fallback, and archiving. `deleteSpace` moves it with its space. `snapshot()` writes it as an open tab of its destination space.
- A main window never selects it. Selecting it explicitly runs Move to Main Window instead.

The window
- 900×640. The first is centered on the screen with the pointer, and later ones cascade from it. The window is made key and ordered front, then the app activates with `NSRunningApplication.current.activate(options: [])`. Without `.activateAllWindows`, only the key and main windows come forward (checked in step 11).
- `SmallWindowView`: one row on the traffic-light line with the site's icon, the address pill's symbol for the page, and host, which opens the palette like ⌘L, back, forward, reload or stop, share, and a Move to Main Window button (`arrow.up.left.and.arrow.down.right`, with its shortcut in the tooltip). Below it, `PageAreaView` over the window material with the destination space's tint, which is the window's current space. Find, sheets, page fullscreen, the developer tools (with this window's dock), the page reader, the question popover, the preview panel, and the ⌘L palette in edit mode work. The palette lists no tabs to switch to, because the window shows only its own. Sidebar commands go to the main window, which comes forward. ⌃Tab passes to the page, and Close Other Tabs is disabled.
- A page that the small window's page or its preview opens, and the preview's Open in Tab, open in another small window (`showOpenedPage`, open decision 11).

Move to Main Window (the button, Window ▸ Move to Main Window, ⌥⌘N)
1. Clear `isInSmallWindow` and move the tab to the end of its destination space's open tabs. That space is still there, because `deleteSpace` moves a small window's tab with its space, so `preferredSpace(in:)` is not needed.
2. The sidebar target selects the tab, which applies window rule 2: the small window gives it up by closing (its sheet is deferred, page fullscreen ends, its dock lets the tools go), then the main window shows the tab and its sheet. The view moves without a reload.
3. The main window comes forward with the page focused.
- Main windows reach no small window's tab: every explicit selection in a main window goes through lists that `isListedInSidebar` filters, so the rule that selecting it runs Move to Main Window needs no code of its own.

Closing
- Closing a small window asks to close its tab, so a Chromium page with a `beforeunload` handler can ask to stay. The tab goes to the closed list, and ⇧⌘T reopens it in the main window. A small window whose tab closes for any reason closes with it.
- A page that closes itself with `window.close()` closes its small window at once on both engines. A Chromium tab closes only at `OnBeforeClose`, once CEF's view is released (Facts for plan task I.14), so the window's focus must not keep that view. `focusPage` gives the focus to the view that takes the keys, `viewTakingFocus(in:)`: the engine view when it takes focus, as WebKit's page view does, or else the topmost visible view inside it that does, which on Chromium is the current page's view within CEF's view, the view CEF focuses itself. Visible first, because a page that a tab left for another site keeps its hidden view above the current one while it is in the back-forward cache; while every such view is hidden, as before Chromium shows a new page's view, the topmost one. Keys then reach the page, and the app never makes CEF's view the first responder. The bridge's `DetachBrowserView` makes a closing page that has the focus give it up and, once its view has left the window, updates the windows at once, as Chromium's page view does when it goes, so AppKit does not wait for the app's next event to let go of it. Both apply to every Chromium page in every window. Reporting a page's own close to the session at `DoClose`, before CEF has closed the browser, would hide the wait instead: the session would release the bridge's browser object before `OnBeforeClose`, which takes the browser out of the extensions' windows, and the browser would stay open, unseen, until AppKit let go of its view.
- AppKit would take a sheet away unanswered when code closes its window, so `BrowserWindowModel.close()` first ends a sheet that `TabSheetQueue` does not show, the print panel or Export as PDF's save panel, with Cancel. A download's save panel therefore never opens as a sheet on a small window, which a download-only tab closes on the next turn of the run loop; it opens as a panel of its own.

Preference
- Settings ▸ General: "Open links from other apps in a small window when Arch is in the background", stored under `ARCHOpensLinksInSmallWindow` (`BrowserSession.opensLinksInSmallWindowKey`), on while nothing is saved. `application(_:open:)` reads it as each link arrives, so a change applies to the next link. Off restores the behavior from before step 11: every link opens a tab in the sidebar target, which comes forward from behind a small window that is still open.

## Personas in the interface (III.12)

- With one Persona, nothing visible changes. That is the state after the migration.
- With two or more Personas:
  - The bottom bar's symbol strip groups the spaces in Persona order, with a 1-point divider and 6 points of extra space between groups. Dividers have a fixed width and do not count as items in the strip's sizing and shrinking. Each symbol's tooltip and VoiceOver label name its place, "Work / Personal" (Persona rule 7), since every new Persona's space is named Personal and spaces of different Personas can share a symbol.
  - `SpaceHeaderView` shows the Persona and the space on one line, "Work / Research" (Persona rule 7), at one size: the Persona's name in regular secondary text, the slash in tertiary, and the space's name in semibold primary, with the Persona's name truncating before the space name in a narrow sidebar, down to its first 36 points, and only the space's name editable.
  - The favorites grid shows `favorites(in: windowModel.personaID)` and cross-fades when the window enters another Persona's space.
  - The window title adds the Persona and the space, as "Example Domain — Work / Research" (Persona rule 7), and with no tab selected is "Work / Research" alone, which already holds the space's name.
  - Swipes and ⌃⌘←/→ cross group boundaries in strip order, which changes the window's Persona.
  - The Clear Site Data sheet names the Persona of the tab's place, whose data is removed from every space: "…removed from both engines in the Persona of “Work / Research”…" (Persona rule 7). A favorite's tab has no space and shows in the window's current space, so for it the sheet names that space, as the window title does: "…in the Persona of “Work / Research”…".
  - A plugin's review in Settings ▸ Plugins names the Persona it installs in (Persona rule 7): "Installs in the Persona of “Work / Research” for all its spaces." for an install that starts from a tab, with the tab's space or for a favorite's tab the window's current space, or from the palette, with the window's current space, and "Installs in “Work” for all its spaces." for one that starts in Settings ▸ Plugins (`docs/web-store.md`, Decision 7).
- Commands, in the space menu (`SpaceMenuItems`) and the Spaces menu, with no Settings section: New Persona…, Rename Persona…, and Delete Persona…. New Persona and Rename ask for a name in an `NSAlert` sheet with a text field on the window the command acts on: the window of the space menu, or for the Spaces menu the sidebar target, which comes forward from behind a small window; an empty name changes nothing. The Spaces menu's items act on the sidebar target's Persona. New Persona appends a Persona with one space named "Personal" (with the next tint of the rotation) and switches the window to it. New Space, from the plus and ⌃⌘N, adds a space at the end of the window's Persona's group. III.12 has no reordering of Personas; a new Persona goes last.
- Restrictions: Move Left, Move Right, and dragging a space stay within its group. A tab dragged over another Persona's space symbol does not light it, and its drop does nothing (the drop target filter in `SpaceTabsView` uses `canMoveTab`). Delete Space is disabled for a Persona's last space. The palette and the tab switcher list only tabs of the window's Persona, and palette commands run through its plugins. A page that a page or a preview opens joins a space of its own Persona, the window's current space or else `preferredSpace(in:)`, as does Open Link in New Tab from a favorite's page.
- Delete Persona is disabled for the default Persona. For any other, a confirmation sheet asks "Delete the Persona of “Work / Research”?" with the space menu's space or the sidebar target's current space (Persona rule 7), and says: "Its N spaces and M favorites are removed, and its K tabs close into the closed list. Its downloads in progress stop. Arch removes its cookies and website data from this Mac the next time it opens." Then `deletePersona`:
  1. Previews of its pages close, and every main window on its spaces switches to the first space of the first remaining Persona; window rule 3 picks the tab.
  2. Its small windows close, and their tabs close as in item 3.
  3. Its tabs close with reason `.user` into the closed list, without asking their pages, as `docs/sync.md` states for a deleted Persona. The undo count resets. The records keep `personaID`; reopening one whose space is gone uses its Persona's preferred space, or the sidebar target's current space once its Persona is gone.
  4. Its unfinished downloads are cancelled, and its kept download pages close through their runtimes. Finished rows stay in the library.
  5. Its spaces are removed with their folders and split views, and its favorites with the tabs saved for them.
  6. Each of its browsers closes every web contents it still owns (`closeAllWebContents`), its plugin manager closes and goes (`docs/plugins.md`, Personas), so its plugins stop and write nothing more, and its `PersonaEngines` moves to `retiredPersonaEngines` until quit, because download items hold their lists and contexts `unowned`.
  7. Its ID joins `removedPersonaIDs`, and the session saves at once.
  8. At the next launch, before any engine starts, the session calls each registered engine's `removeStoredData` for each listed ID. An ID leaves the list once both WebKit and Chromium have reported removal; while the Chromium framework is missing, it stays. The same pass first deletes the plugin data, which no engine holds open: `PluginManager.removeData(ofPersona:in:)` removes the Keychain items whose account starts with `<id>/` and `Plugins/<id>/`. If an ID's plugin data remains, the engines are asked at the next launch instead.

## Interactions with other features

Plugins (V.11)
- One `PluginManager` per Persona, at `Plugins/<Persona.id>/`; the default Persona's folder is `Plugins/D59DAF4B-E372-4AF9-890E-455B8B3860F3/`. `Persona.defaultID` exists from step 2, so V.11 uses Persona folders from its start, and the interim `Plugins/<plugin ID>/` folder in `docs/ai.md` is not needed.
- `PluginBrowserHost.tabs(in:)` filters `session.tabs` by `personaID`. `openTab(_:_:in:)` uses `preferredSpace(in:)`. `selectTab` goes to the window that shows the tab, else to the sidebar target. `present` uses the active window.
- Page scripts come from the tab's Persona's manager: `makeWebContents(url:engine:state:in:)` passes them to each web contents it creates. A tab receives them again when it joins the session, and every tab of the Persona receives updates when they change (`PluginPages`).
- Script plugins install into the Persona shown in Settings ▸ Plugins. Their packages, storage, and background web views belong to that Persona's manager. Deleting the Persona stops their backgrounds, and the next launch removes their packages with its folder.
- Download entries record their Persona, so a plugin sees only its Persona's downloads. History stays app-wide in this design, while `docs/plugins.md` says a plugin sees only its Persona's history (open decision 2).
- The half of III.12's done condition about separate plugins is part of V.11's done condition (open decision 15), which regression check 43 in `docs/plan.md` covers with the built-in Page Address plugin.

Sync (V.9)
- `Persona.defaultID` maps to the record name `default`; other Personas use their UUID string. Step 1's `TabRecord.id` supplies the stable tab record names that `docs/sync.md` asks for.
- `normalized()` uses sync's orphan rules: the first Persona, and a "Personal" space for a Persona without spaces.
- Sync applies changes through the session's Persona, space, favorite, and tab mutators, which select nothing. An incoming Persona deletion calls `deletePersona`.
- Window records, frames, small windows, and `removedPersonaIDs` never sync.

AI (VII)
- `ai.json`, its routes, exclusions, limits, and usage stay app-wide, as `docs/ai.md` states.
- The page reader panel (VII.4) and the question popovers (VII.5) are window state on `BrowserWindowModel` and act on the active window's selected tab; Ask About Selection opens the popover in the window that shows the tab. Hook events (VII.6) carry the tab's Persona, so they reach that Persona's plugin manager. AI-written plugins (VII.7) install into the active window's Persona.

Live favorites (III.13)
- A favorite and its live tab belong to one Persona. The live tab follows window rule 1: selecting a favorite whose tab another window shows moves the tab here. It stays alive, hidden, while its window shows another Persona's space. Whether the live tab keeps a `spaceID` is III.13's choice; if it leaves space lists, III.13 extends `isListedInSidebar`.

Split view (III.5)
- `shownTabIDs` covers the panes, and window rule 1 covers every pane. A layout saved per space is app-wide, so a second window on the same space shows a placeholder with Show Here in each pane whose tab another window shows, a pane of its `paneTabs` outside its `shownTabIDs`; Show Here selects the tab, which applies rule 2, and a click elsewhere in the placeholder leaves the tab where it is. The placeholder keeps the pane's close control, which takes the tab out of the split view. The pane under the pointer sets the window's `selectedTabID`. If III.5 lands before step 11, `PageAreaView` takes the pane layout.

Previews (III.11)
- A preview's secondary web contents comes from the runtime of the window's Persona, so it carries that Persona's cookies. The window model owns the panel, which closes with the window.

Folders (III.3)
- A folder belongs to a space and so to the space's Persona. Moving a folder to another Persona's space goes through the same guard. Its snapshot fields are optional and take the next free version number.

Downloads
- One app-wide list. Each entry records its Persona, from the runtime that owns its list, so a WebKit download resumes in its own store and plugins see their own downloads. Chromium numbers downloads within each request context, so item IDs repeat across Personas: an entry has an ID of its own, and the session finds the entry of an engine item by the item itself. The downloads folder comes from `UserDefaults` directly, through the helper that `followDownloadSettings` already uses.

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
   - Files: new `TabSheetQueue.swift`; `BrowserWindowModel.swift` (the rule 2 order, the fallback, the activation order per window), `BrowserSession.swift` (`release`, automatic selection that skips shown tabs, the archive exemption, routing of popups, `requestSelection`, and fullscreen through `window(showing:)`, which Ask About Selection already uses, `window(for:)`), `DevToolsDock.swift` (`DevToolsDockSettings`, the `track` guard, `isExcludedFromWindowsMenu`), `AppDelegate.swift` (monitors by `event.window`; the side menu sets the shared settings).
   - Re-check: 6, 7, 12 (a side change applies at once), 13, 15, 21, 29; Clear Site Data's sheet (24) and a capture failure sheet still show.
   - New checks: a JavaScript `alert` in a background tab waits until the tab is selected, then shows on the window. Closing a background Chromium tab with a `beforeunload` handler through Close Other Tabs brings it forward with its sheet. A popup from the selected tab is selected; one from a background tab opens unread.

9. III.6.5 Window controller and multiple windows (bundle)
   - Files: new `BrowserWindowController.swift`; `BrowserSession.swift` (`openWindow`, `restoreWindows`, `windowDidBecomeMain`, which also updates the focused tab, `windowWillClose`, the teardown order, the last main window's record in memory, `windows` as the published list of open windows in place of the one window that step 8's rules go through, and `pageReaderDidHide` over every window), `BrowserWindowModel.swift` (`prepareToClose`, `record`, `firstFreeTab(inSpace:)`, ⌘W without a tab), `PageAssistant.swift` (stopping one window's replies), `SplitView.swift` (the placeholder of Interactions ▸ Split view for a pane whose tab another window shows), `AppDelegate.swift` (window building removed; New Window, Close Window, and the Window menu after `installShortcuts()`; tabbing off; reopen handling; the targets of the global shortcut, History, Import, and the prompt), `Arch.sdef` (the `active tab` description). `Scripting.swift` already reads `focusedTab` and needs no change.
   - Launch order in `AppDelegate`: register the engines, create the session, set `NSWindow.allowsAutomaticWindowTabbing = false`, build the menus, install the monitors and shortcuts, set `NSApp.windowsMenu`, call `session.restoreWindows()`, open pending links, `ARCH_START_URL`, or a new tab in the sidebar target, activate, and prompt for the default browser on the front main window.
   - Re-check: 4, 5, 9, 12, 16, 18, 20, 26, 28.
   - New checks:
     - ⌘N opens a second window, cascaded, on the current space, with the palette and no tab; window 1 keeps its tab.
     - Clicking in window 2 a tab that window 1 shows moves it, and window 1 falls back to its previous tab. On both engines the page keeps its state. A Chromium video keeps playing; typing and Korean IME input work in a field afterwards; the page is sharp after moving the window to a display with another scale.
     - Docked tools of a Chromium tab hide in window 1 and dock in window 2 when the tab moves. Developer ▸ Dock to Bottom moves the tools of both windows.
     - Page fullscreen in window 2 ends with Escape. ⌃Tab works in each window with its own order. An `alert` in window 2 shows while window 1 shows its own sheet. Renaming a tab in window 1 shows no field in window 2. A link dragged onto window 2's tab list opens in its space. A two-finger swipe over an inactive window switches that window's space.
     - ⇧⌘W on window 2 keeps its tabs in window 1's sidebar.
     - The Window menu lists both windows by tab title and not the docked tools; Minimize, Zoom, and Bring All to Front work; no tab bar items appear.
     - Settings ▸ Shortcuts lists New Window, Close Window, Minimize, Zoom, and Bring All to Front, and no window names or system items.
     - ⌘Q with two windows and an open sheet quits without a crash report.
     - ⌥Space brings the last main window forward with the palette.
     - With Settings open, closing every browser window keeps the app running, and a Dock click opens a main window.

10. III.6.6 Windows persist (bundle); finishes III.6
    - Files: `SessionStore.swift` (`WindowRecord`, which moves from `BrowserWindowModel.swift`, `windows`, rule 7, version +1), `BrowserWindowModel.swift` (`id`, `restorableFrame`, the record), `BrowserSession.swift` (save and restore), `BrowserWindowController.swift` (frames, clamping), `SessionSnapshotTests.swift`, new `WindowFrameTests.swift` (`restoredFrame`).
    - Re-check: 9 (the width persists and is app-wide), 10, 22, 31.
    - New checks: two windows with different frames, spaces, selected tabs, and sidebar visibility return after a relaunch, with the same window in front. A window in full screen returns windowed at its earlier frame. A window left on an external display returns on the main screen after that display is disconnected. Closing the last window quits, and the relaunch restores it. The kept v4 file opens one window centered at 1200×800 with its selection.

11. III.7.1 Small window (bundle)
    - Files: `Tab.swift`, `BrowserSession.swift` (`openSmallWindow`, `moveToMainWindow`, the `isListedInSidebar` filters), `BrowserWindowModel.swift`, new `SmallWindowView.swift`, `PageAreaView` (extracted from `BrowserWindowView.swift`), `BrowserWindowController.swift` (`.small`), `AppDelegate.swift` (routing, Move to Main Window), `Scripting.swift`.
    - First, without changing behavior, log the arrival times of `didBecomeActiveNotification` and `application(_:open:)`, and `NSApp.isActive` during the call, for: `open https://example.org` from Terminal with Arch in the background, `open -g https://example.org`, a link clicked in Mail and one in Notes, `osascript -e 'tell application "Arch" to open location "example.org"'`, and a link that launches Arch. Set the threshold from the log, then remove the logging.
    - Re-check: 1, 4 and 18 as updated below, 6, 12, 13, 21, 27.
    - New checks:
      - With Arch in the background, each link opens a small window in front with no sidebar, and only that window comes forward.
      - The button and ⌥⌘N move the tab into its destination space, the last main window's current space when the small window opened, selected in the last main window, and the small window closes. Text typed into a form field there survives on both engines.
      - Settings ▸ Shortcuts lists Move to Main Window with ⌥⌘N.
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
      - Delete Work: its tabs are in the closed list, its spaces and favorites are gone, and the windows on it moved to the default Persona. After a relaunch, its `Persona-<UUID>` directories, under Application Support and under `~/Library/Caches`, and its WebKit store are gone, and `removedPersonaIDs` is empty. The default Persona's Delete Persona… is disabled.
      - The developer tools of a Work Chromium tab show Work's cookies under Application ▸ Cookies.
      - Separate plugins per Persona are checked with V.11 (regression check 43 in `docs/plan.md`).

## Documents

- `docs/plan.md`'s Documentation row and the docs list of `resources/README.preset.md` list this note.
- Step 6: `docs/plan.md` Decisions gains the placement rule and window rules 1 to 3.
- Steps 7 and 8: the placement rule in `docs/plan.md` stops listing the window state each step moves off the session: the reader's visibility and the question popover in step 7, the visible sheet in step 8.
- Step 10, which finishes III.6: remove the III.6 row; update Current State for the Browsing module (windows, the one-tab-one-window rule, window state in `session.json`) and the App shell (the File and Window menus); add the window checks to the regression checklist; mark row 7 of `docs/features.md` complete.
- Step 12, which finishes III.7: remove the III.7 row; update Current State; update checks 4 and 18 and the Preferences module's General list; mark row 6 complete.
- Step 13, which finishes III.12:
  - `docs/plan.md`: remove the III.12 row. Update Current State for the Browsing module, the WebKit adapter (a store per Persona), the Chromium adapter ("Cookies go through each Persona's request context" in place of "CEF's global cookie manager"), and the Build Procedure's state list (`Cache/Chromium/Persona-<UUID>`; Chromium's caches in `~/Library/Caches/Arch/Cache/Chromium`, where the removal pass also deletes a Persona's directory; and the WebKit stores in `~/Library/WebKit/xyz.taeyoon.arch/WebsiteDataStore`). Add to Decisions: the default Persona keeps the engines' default storage, cookies copy only within a Persona, and stored data goes at the next launch.
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
