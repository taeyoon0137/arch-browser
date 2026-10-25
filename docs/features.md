# Features

This document lists the features Arch plans to provide and tracks the status of each. Arch uses macOS system frameworks wherever macOS provides the user experience.

Status values are not started, in progress, and complete. The Implementation column describes the intended approach. Code is written anew for each feature. Every feature behaves the same on both engines and uses the app's own interface on each; a row notes any engine that cannot support it and why.

## Platform integration

Arch uses system frameworks on both engines wherever macOS already provides the user experience. The Chromium engine retains its existing native integrations. It routes the remaining engine events to these frameworks. It disables its own equivalent user interface.

| Area | macOS facility |
|---|---|
| Video picture-in-picture | AVKit `AVPictureInPictureController` |
| Now Playing, media keys, AirPlay | MediaPlayer `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`; AVKit `AVRoutePickerView` (needs verification) |
| Sharing | AppKit `NSSharingServicePicker` |
| Notifications | UserNotifications |
| Passwords and passkeys | Apple Passwords and 1Password through their official browser extensions running as plugins; passkeys through AuthenticationServices; no browser-side store |
| Printing and PDF | AppKit `NSPrintOperation`, PDFKit |
| File dialogs and downloads | AppKit `NSOpenPanel` and `NSSavePanel`; Quick Look previews |
| Handoff | `NSUserActivity` for the current page |
| Spelling and text input | AppKit `NSSpellChecker`, system text replacement, system fonts |
| Confirmation for sensitive settings | LocalAuthentication (Touch ID) |
| Sync | CloudKit |
| Automation | AppleScript; App Intents (needs verification) |
| Appearance | System appearance and accent color |
| API keys | Keychain Services |

## 1. Windows, Sidebar, and Tabs

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 1 | Sidebar (collapse, expand, resize, show on hover) | Custom AppKit and SwiftUI implementation | None | complete |
| 2 | Spaces (create, switch, swipe, color themes) | Custom implementation with SwiftUI gradients for themes | None | in progress |
| 3 | Pinned tabs, favorites, tabs, automatic archiving | Custom implementation with local storage. Once opened, each favorite keeps a tab of its own outside the spaces' lists, and every space selects that same tab, so its page keeps its state across space switches; `session.json` keeps it, and it loads on the favorite's next click after a relaunch. Favorites move under their Persona with row 9 | Session restoration | complete |
| 4 | Folders and tab groups for pinned and open tabs | Custom implementation: folders in each space's pinned and open lists that collapse, rename in place, take tabs by drag and drop or from the tab's context menu, and persist in `session.json` | None | complete |
| 5 | Split View | Custom implementation: two to four tabs of a space side by side in the page area, each in its own pane of equal width. Tab ▸ Open in Split View (⌥⌘=), a tab row's context menu, or a tab dropped on a pane adds a pane. The selected tab is the focused pane, which a click selects; each pane has a close control; `session.json` keeps each space's split view | None | complete |
| 6 | Small browser window | Custom implementation: a link from another app while Arch is in the background opens in a window without a sidebar, whose tab stays out of the sidebar until Move to Main Window (⌥⌘N) moves it into its destination space, the last main window's current space when the small window opened; closing the window closes the tab, and `session.json` keeps the tab in that space. Settings ▸ General turns it off, and such links then open as tabs of the main window | None | complete |
| 7 | Multiple windows and window restoration | Custom implementation: spaces, favorites, and tabs belong to the app, and each window has its own space, selected tab, sidebar, and frame. A tab shows in one window at a time and moves to the window that selects it. ⌘N opens a window, ⇧⌘W closes one and keeps its tabs, and the Window menu lists them. `session.json` restores each main window's frame, space, selected tab, and sidebar, and each tab's page through its engine's restorable state, such as `WKWebView.interactionState` | Session restoration | complete |
| 8 | Tab switcher and tab close log | Custom implementation: a ⌃Tab overlay lists the current space's tabs and the favorites' open tabs in most-recently-used order. Local key monitors make it work on both engines. An in-memory close log shows each close's reason and crash counts in a debug window under View ▸ Developer | None | complete |
| 9 | Personas: each has separate cookies, sessions, site data, and installed plugins; each space belongs to a Persona | `WKWebsiteDataStore(forIdentifier:)` on WebKit; one `CefRequestContext` with its own cache path per Persona on Chromium | Profiles | not started |
| 10 | Window themes and appearance (light, dark, automatic) | SwiftUI and AppKit appearance APIs: `NSApp.appearance` for system, light, or dark; each space's theme is a color or Automatic (`NSColor.controlAccentColor`, resolved again on `NSColor.systemColorsDidChangeNotification`); Settings sets the tint's strength. The sidebar switches its color scheme when the tint lowers text contrast below WCAG 4.5:1 | None | complete |
| 48 | Engine per tab: WebKit or Chromium, switchable from the address bar's site settings, inherited by tabs a page opens, with cookies shared between the engines | Both engine adapters in one session; cookies copied between `WKHTTPCookieStore` and the Chromium cookie manager. A tab a page opens keeps `window.opener`, so sign-in popups can report back: WebKit's `createWebViewWith` and CEF's `OnBeforePopup`, which has CEF create the popup in the page's browsing context. When such a tab closes itself, the window returns to the tab that opened it | Cookies | complete |

## 2. Navigation and Input

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 11 | Command bar (URLs, search, commands, tab switching) | Custom implementation. AppKit text completion shows suggestions from local history and bookmarks, plus public search engine endpoints. No engine autocomplete is used | None | in progress |
| 12 | Site Search | Keyword shortcuts with `%s` address templates in `site-search.json`. A keyword and a space in the command palette search that site. Settings ▸ Site Search adds, edits, and removes shortcuts | None | complete |
| 13 | Keyboard shortcuts and global shortcuts | Settings ▸ Shortcuts records a shortcut for any menu bar command, saves it in `UserDefaults`, and applies it to the menu item. It asks before taking another command's shortcut. One global shortcut (⌥Space by default) brings Arch forward with the new tab palette through the Carbon Event Manager's `RegisterEventHotKey`, a public API that needs no accessibility permission | None | complete |
| 14 | Back, forward, reload, zoom | `WKWebView` and CEF back-forward lists; the History menu lists the selected tab's previous ten pages; View ▸ Actual Size, Zoom In, and Zoom Out set `pageZoom` on WebKit and the CEF zoom level on Chromium. The factor is saved per host in `UserDefaults` | Navigation | complete |
| 15 | Find in page | `WKWebView.find(_:configuration:)` with match counts from a script on WebKit; CEF's find on Chromium | Find | complete |
| 16 | Link routing, universal links, opening external apps | `NSWorkspace`, `WKNavigationDelegate` policies | Policy decisions | in progress |
| 17 | Default browser setup and prompts | `NSWorkspace.setDefaultApplication` | None | complete |
| 18 | Drag and drop (tabs, links, files) | Sidebar items drag with SwiftUI gestures into a lifted layer above the window: tabs reorder, pin, join a folder's row, move to another space's symbol, and open as a split view pane when dropped on a pane; favorites and space symbols reorder. Links, files, and address text from other apps drop onto the tab list through SwiftUI `onDrop` with `NSItemProvider` and open in new tabs. Sidebar items cannot be dragged out to other apps | None | in progress |
| 49 | Page context menus | One menu built by the app on both engines: Chromium through `CefContextMenuHandler::RunContextMenu`, with spelling suggestions from `NSSpellChecker` in the system's preferred languages if the profile's spelling language has none, and WebKit through `willOpenMenu(_:with:)` with the engine's own spelling and editing items kept. WebKit keeps its own menu for menus a page element provides and for elements in closed shadow roots. Ask About Selection appears for selected text outside fields while a provider can answer (row 53). Inspect Element waits for DevTools (row 45) | Context menus | in progress |

## 3. Content and Media

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 19 | Previews (favorites and links) | Holding Shift over a favorite or Shift-clicking a link shows the page in a floating panel over the page area, backed by a web contents of its own in the default engine for a favorite or the page's engine for a link. The page never enters the tab list, the session, or history, cannot download, and is denied permissions, until it opens a page of its own, such as a sign-in popup: it then becomes a tab without loading again, and the page it opened becomes the selected tab after it, keeping it as its opener. Open in Tab opens it as a tab; Escape, ⌘W, or a click outside closes the panel and discards its web contents. Shift-clicks reach the app through the engines' navigation delegate as `newWindow`: WebKit's `decidePolicyFor` with the click's modifier flags, and CEF's `OnOpenURLFromTab` and `OnBeforePopup` | Navigation | complete |
| 20 | Media controls and picture-in-picture (PiP) | Now Playing through `MPNowPlayingInfoCenter` and the media keys through `MPRemoteCommandCenter` on both engines, fed by each engine's media script. They use the selected tab while it plays sound, otherwise the tab that played sound last, with the page's Media Session metadata or its title and site. Play and pause reach the page's handler or the media; next and previous track reach the page's handlers. Chromium's own media controls are off. Both engines use system PiP. WebKit has it built in. The Chromium engine routes PiP to AVKit through a patched CEF build so it matches the macOS experience (needs verification). Until then, `OnBeforePopup` stops a page's Document Picture-in-Picture window, which would open as a tab, so the page keeps its own interface | Media sessions | in progress |
| 21 | Download management | `WKDownload`, `NSSavePanel`; Settings ▸ General sets the downloads folder and whether to ask where to save | Downloads | in progress |
| 22 | Capture (region, full page) and screenshot storage | View ▸ Capture Viewport, Capture Full Page, and Capture Region… save PNG files to `~/Pictures/Arch Captures` and select them in the Finder. WebKit uses `takeSnapshot` for the viewport and `createPDF` drawn into a bitmap for the whole page. Chromium uses the DevTools protocol's `Page.captureScreenshot`. Region capture crops the viewport capture to a rectangle dragged over the page | Capture | complete |
| 25 | PDF viewing and printing | Built-in WebKit PDF support. Printing and Export as PDF go through `createPDF`, PDFKit's `printOperation(for:scalingMode:autoRotate:)` as a sheet, and `NSSavePanel` on both engines; PDF viewing remains | PDF | in progress |
| 26 | Site permissions | One app sheet on both engines, fed by `WKUIDelegate` media capture callbacks and CEF's permission handler. Allow and Don't Allow are saved per origin and type in `permissions.json` and answer later requests without the sheet. Settings ▸ Websites changes or removes each answer and updates Chromium's stored answers through `CefRequestContext::SetContentSetting`. Screen recording always asks | Permissions | complete |
| 27 | Fullscreen and sad tabs (crash recovery) | Element fullscreen in WebKit's own window; on Chromium, CEF's fullscreen requests with the window's full screen; a notice with Reload after a renderer quits | Renderer termination | complete |
| 28 | Favicons and theme colors | Custom favicon collection; `WKWebView.themeColor` on WebKit and the `theme-color` meta read in the renderer process on Chromium | None | complete |
| 29 | Cookies, site data, browsing history | `WKHTTPCookieStore` and `WKWebsiteDataStore`. Clear Site Data, from the History menu and the site settings popover, removes the current host's cookies from both engines together. It then removes WebKit's data records for its registrable domain and Chromium's storage for its origins through the DevTools protocol's `Storage.clearDataForOrigin` in a hidden browser. It reloads the site's tabs. Browsing history uses custom storage. A History window (an AppKit window hosting SwiftUI with `NSSearchToolbarItem`) shows it with search, row deletion, and range clearing | Cookies and history | complete |

## 4. Creation and Sharing

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 32 | Share menu and sharing settings | `NSSharingServicePicker` from the address pill's share button and File ▸ Share…, with the page's address, and its title and icon through `NSPreviewRepresentingActivityItem`; the title becomes the subject for services such as Mail. Sharing uses the system's settings | None | complete |
| 33 | Import (bookmarks, history, passwords) | File ▸ Import Bookmarks and History… reads files the user picks in `NSOpenPanel` and recognizes them by their contents. HTML bookmark files, Chromium-format Bookmarks JSON, and WebKit-format Bookmarks.plist become favorites (folders flattened, duplicate addresses skipped). A Chromium-format History SQLite database, read from a temporary copy, goes into the history store. A sheet summarizes the result. The Passwords app handles password imports | None | complete |
| 34 | Home button, badges, tooltips | A per-space home page set from the space menu, stored with the space in `session.json`, and opened in the selected tab with History ▸ Home (⇧⌘H); a speaker badge on tab rows while the page plays sound; a dot on tabs a page opened in the background until the user selects them; tab row tooltips with the full title and address. The sidebar has no home button | None | complete |

## 5. Accounts, Sync, and Settings

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 35 | Sidebar and settings sync | CloudKit private database through `CKSyncEngine` (macOS 14+); design in `docs/sync.md` | None | not started |
| 36 | Preferences window | An AppKit window with `NSTabViewController` toolbar sections in the `.preference` toolbar style, each a SwiftUI grouped form: General (default browser, small window for links from other apps, default engine, search engine, downloads folder, ask where to save), Site Search (keyword shortcuts), Sidebar (archive delay), Appearance (appearance and tint strength), Shortcuts (row 13), and Websites (remembered site permissions, row 26) | None | complete |
| 39 | Autofill (passwords, passkeys, cards, addresses) | No browser-side store. The official 1Password and iCloud Passwords extensions (row 44) fill forms on both engines as plugins (row 50); each needs Arch on its allow list (see IV.13). Passkeys go through AuthenticationServices on both engines, which needs Apple's restricted browser passkey entitlement (IV.14). On Chromium, 1Password's Universal Autofill can read a page once it asks for the accessibility tree (see Private APIs). The user has not checked it. A WebKit tab does not get Apple Passwords AutoFill without an extension; the user checked this on macOS 27 | Extensions, accessibility | not started |
| 40 | Web notifications and push | `UserNotifications` for local notifications: a download that finishes while Arch is not active posts one. Clicking it reveals the file in the Finder. The first finished download asks for permission. On Chromium, CEF 156 sends a page's permission request to `CefPermissionHandler::OnShowPermissionPrompt`, which Arch's permission sheet answers. CEF's public API has no callback to pass the notification itself to the app. The framework's own macOS notification service posts it through `UserNotifications` (needs verification). WebKit has no public API: `WKUIDelegate` has no notification callback. On macOS 27 a page sees `Notification`, but `Notification.requestPermission()` resolves to `denied` without asking the app and `PushManager` is undefined. Remote push is omitted | Permissions | in progress |
| 41 | AppleScript | `Arch.sdef` with the Cocoa Standard Suite, `open location`, and tabs with their identifier, name, and URL, read through key-value coding on the application; `open location` arrives through `application(_:open:)` | None | complete |
| 42 | Sound effects | `NSSound`. The user has not decided whether to offer sound effects. App icon choice is not offered for now | None | not started |

## 6. Extensions and Developer Tools

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 44 | Extensions | The same Manifest V3 extensions on both engines, installed once per Persona as plugins (row 50, `docs/plugins.md`), with each engine running its own copy and storage: `WKWebExtensionController` on WebKit (macOS 15.4+), CEF Chrome style on Chromium. On macOS, CEF uses Alloy style whenever the browser has a parent view, so Chrome style needs CEF-owned windows or a patched build (VI.1) | Extensions | not started |
| 45 | DevTools | Chromium DevTools behind one menu item and shortcut, beside the page to the right, below, or to the left, or in their own window. CEF 156's public API cannot place them inside the browser window: a CEF check stops `ShowDevTools` with child window info. So CEF's tools window becomes a child of the browser window over the space the page leaves. Docking inside the window needs a CEF patch (VI.3). WebKit's Web Inspector opens from the same menu item inside the page, beside the web view, through private APIs behind flags (see Private APIs). Its toolbar picks the side. With the flags off, the browser bundled with macOS inspects WebKit tabs (`isInspectable`) | DevTools | complete |
| 50 | Plugins | Arch's own plugin system, designed in `docs/plugins.md`: built-in Swift plugins, script plugins in a sandboxed WebKit web view, and web extensions (row 44). Plugins add sidebar items, palette commands, menus, shortcuts, settings, panels, and page scripts on both engines. Built-in plugins ship with the app and can provide future features. Installed plugins, their grants, storage, and Keychain items belong to one Persona. The first build step is built: built-in plugins with manifests, grants, match patterns for their sites, and palette commands through `PluginManager`, key-value storage for each plugin in its Persona's folder, and the built-in Page Address plugin's Copy Page Address command in the command palette. Page scripts run on both engines, each world in a `WKContentWorld` of its own on WebKit and in the page's main world through the helper's renderer process on Chromium, with a channel to the app; each plugin's scripts share a world and run only in documents that their match patterns and the plugin's granted sites cover. The session does not give them to its tabs yet | None | in progress |
| 51 | Flags page (`flags://`) | One flag for all private APIs, one for each private API, and one for each feature that uses one. Each API is checked quietly for availability at launch and before use | Private APIs | complete |

## 7. AI

Arch ships no model or provider account. All AI features use one AI interface. The user chooses a provider and model for each feature.

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 43 | AI interface and providers | One provider-neutral interface designed in `docs/ai.md`. Providers use API keys kept in the Keychain or command-line tools signed in through the built-in terminal (row 56). A provider and model are chosen per feature, with up to two fallbacks. Two HTTP message formats with API keys, command-line tools, routing with fallbacks, site exclusions, rate limits, budgets, usage, and Settings ▸ AI are built; the hook center comes with row 54 | None | in progress |
| 52 | Page reader | A panel beside the page that summarizes the selected tab's page and answers follow-up questions through the AI interface, streamed and cancelable, with the model, tokens, and estimated cost under each answer. The page's text comes from `readableContent` on both engines | Page text | complete |
| 53 | Questions in the page | Ask About This Page in the palette and Ask About Selection in the page context menu open a popover over the page that answers a question about the page or the selected text through the AI interface | Page text | complete |
| 54 | AI hooks | Features subscribe to events such as page loads, downloads, and new tabs; the first hooks name tabs and rename downloaded files | None | not started |
| 55 | Features that AI adds at run time | AI writes plugins (row 50) that the user reviews, enables, and removes | None | not started |
| 56 | Built-in terminal | A window from Settings ▸ AI that runs the user's login shell on a pseudo-terminal from `posix_openpt`, for installing and signing in to AI command-line tools, with a VT and xterm-style screen, input through the input method, selection, and scrollback. Command-line providers (row 43) then run those tools without a window | None | complete |

## 8. Exclusions

| # | Feature | Handling |
|---|---|---|
| 23 | Ad and tracker blocking | Excluded. An extension (row 44) can provide it |
| 46 | Telemetry, crash reports, remote feature flags | None. Arch collects no usage data and has no remote flags. Local flags for private APIs are on `flags://` (row 51) |
| 24 | Translation | Excluded. Neither engine offers page translation to embedding apps; translation can return if one does |
| 30 | Site customizations (per-site CSS, JavaScript, and color changes) | Excluded. Browsers do not commonly provide this feature |
| 31 | Notes and documents | Excluded. Browsers do not commonly provide this feature |
| 47 | Prompts to switch browsers | None. Import (row 33) covers moving from another browser |
| 37 | Automatic updates | None. Arch adds no update service; builds are made manually from the repository |
| 38 | Accounts | None. Arch needs no account of its own; sync uses the user's iCloud account (row 35) |

## Private APIs

Every private API has a row listing the API, its framework or engine, the features that use it, and its availability check. The `flags://` page lists the same entries.

| API | Framework or engine | Features | Availability check |
|---|---|---|---|
| `WKWebView._inspector` and its `_WKInspector` actions (`show`, `close`, `attach`, `showConsole`, `showResources`, `toggleElementSelection`, `isVisible`) | WebKit | Web Inspector inside WebKit pages (row 45) | The class and each selector respond, checked at first use |
| `WKPreferences._developerExtrasEnabled`, set through key-value coding | WebKit | Inspect Element in WebKit pages' context menu, with the Web Inspector | The setter responds |
| `AXEnhancedUserInterface` and `AXManualAccessibility`, attributes an assistive app sets on the application | macOS accessibility | Chromium pages for assistive apps: Chromium builds its accessibility tree only on request. Assistive apps other than VoiceOver request it through these attributes. VoiceOver needs no flag because `NSWorkspace.isVoiceOverEnabled` reports it | None: the assistive app sets the attribute, and Arch only reads it |
