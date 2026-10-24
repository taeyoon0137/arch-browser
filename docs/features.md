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
| 3 | Pinned tabs, favorites, tabs, automatic archiving | Custom implementation with local storage. Favorites keep their tabs alive across spaces within a Persona | Session restoration | in progress |
| 4 | Folders and tab groups for pinned and open tabs | Custom implementation | None | not started |
| 5 | Split View | Custom implementation | None | not started |
| 6 | Small browser window | Custom implementation | None | not started |
| 7 | Multiple windows and window restoration | Custom implementation using `WKWebView.interactionState` | Session restoration | not started |
| 8 | Tab switcher and tab close log | Custom implementation: a ⌃Tab overlay of the current space's tabs in most-recently-used order, driven by local key monitors so it works on both engines; an in-memory close log with each close's reason and crash counts in a debug window under View ▸ Developer | None | complete |
| 9 | Personas: each has separate cookies, sessions, site data, and installed plugins; each space belongs to a Persona | `WKWebsiteDataStore(forIdentifier:)` on WebKit; one `CefRequestContext` with its own cache path per Persona on Chromium | Profiles | not started |
| 10 | Window themes and appearance (light, dark, automatic) | SwiftUI and AppKit appearance APIs | None | in progress |
| 48 | Engine per tab: WebKit or Chromium, switchable from the address bar's site settings, inherited by tabs a page opens, with cookies shared between the engines | Both engine adapters in one session; cookies copied between `WKHTTPCookieStore` and the Chromium cookie manager | Cookies | complete |

## 2. Navigation and Input

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 11 | Command bar (URLs, search, commands, tab switching) | Custom implementation. AppKit text completion shows suggestions from local history and bookmarks, plus public search engine endpoints. No engine autocomplete is used | None | in progress |
| 12 | Site Search | Custom implementation with a local search engine list | None | not started |
| 13 | Keyboard shortcuts and global shortcuts | AppKit events, `NSEvent.addGlobalMonitorForEvents` | None | in progress |
| 14 | Back, forward, reload, zoom | `WKWebView` and CEF back-forward lists; the History menu lists the selected tab's previous ten pages; View ▸ Actual Size, Zoom In, and Zoom Out set `pageZoom` on WebKit and the CEF zoom level on Chromium, with the factor remembered per host in `UserDefaults` | Navigation | complete |
| 15 | Find in page | `WKWebView.find(_:configuration:)` with match counts from a script on WebKit; CEF's find on Chromium | Find | complete |
| 16 | Link routing, universal links, opening external apps | `NSWorkspace`, `WKNavigationDelegate` policies | Policy decisions | in progress |
| 17 | Default browser setup and prompts | `NSWorkspace.setDefaultApplication` | None | complete |
| 18 | Drag and drop (tabs, links, files) | AppKit drag APIs | None | in progress |
| 49 | Page context menus | One menu built by the app on both engines: Chromium through `CefContextMenuHandler::RunContextMenu`, with spelling suggestions from `NSSpellChecker` in the system's preferred languages if the profile's spelling language has none, and WebKit through `willOpenMenu(_:with:)` with the engine's own spelling and editing items kept. WebKit keeps its own menu for menus a page element provides and for elements in closed shadow roots. Inspect Element waits for DevTools (row 45) | Context menus | in progress |

## 3. Content and Media

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 19 | Previews (link previews on hover) | Custom implementation with a secondary `WKWebView` window | Navigation | not started |
| 20 | Media controls and picture-in-picture (PiP) | Both engines use system PiP. WebKit has it built in. The Chromium engine routes PiP to AVKit through a patched CEF build so it matches the macOS experience (needs verification). `MPNowPlayingInfoCenter` for media controls (needs verification) | Media sessions | not started |
| 21 | Download management | `WKDownload`, `NSSavePanel`; the downloads folder and whether to ask where to save come from Settings ▸ General | Downloads | in progress |
| 22 | Capture (region, full page) and screenshot storage | View ▸ Capture Viewport, Capture Full Page, and Capture Region… save PNG files to `~/Pictures/Arch Captures` and select them in the Finder. WebKit uses `takeSnapshot` for the viewport and `createPDF` drawn into a bitmap for the whole page; Chromium uses the DevTools protocol's `Page.captureScreenshot`. Region capture crops the viewport capture to a rectangle dragged over the page | Capture | complete |
| 25 | PDF viewing and printing | Built-in WebKit PDF support. Printing and Export as PDF go through `createPDF`, PDFKit's `printOperation(for:scalingMode:autoRotate:)` as a sheet, and `NSSavePanel` on both engines; PDF viewing remains | PDF | in progress |
| 26 | Site permissions | `WKUIDelegate` permission callbacks, custom storage | Permissions | in progress |
| 27 | Fullscreen and sad tabs (crash recovery) | Element fullscreen in WebKit's own window; on Chromium, CEF's fullscreen requests with the window's full screen; a notice with Reload after a renderer quits | Renderer termination | complete |
| 28 | Favicons and theme colors | Custom favicon collection; `WKWebView.themeColor` on WebKit and the `theme-color` meta read in the renderer process on Chromium | None | complete |
| 29 | Cookies, site data, browsing history | `WKHTTPCookieStore` and `WKWebsiteDataStore`. Clear Site Data, from the History menu and the site settings popover, removes the current host's cookies from both engines together, then WebKit's data records for its registrable domain and Chromium's storage for its origins through the DevTools protocol's `Storage.clearDataForOrigin` in a hidden browser, and reloads the site's tabs. Browsing history uses custom storage, shown in a History window (an AppKit window hosting SwiftUI with `NSSearchToolbarItem`) with search, row deletion, and range clearing | Cookies and history | complete |

## 4. Creation and Sharing

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 32 | Share menu and sharing settings | `NSSharingServicePicker` from the address pill's share button and File ▸ Share…, with the page's address, and its title and icon through `NSPreviewRepresentingActivityItem`; the title becomes the subject for services such as Mail. Sharing settings are the system's own | None | complete |
| 33 | Import (bookmarks, history, passwords) | Custom parsing of browser files. Apple Passwords handles password imports | None | not started |
| 34 | Home button, badges, tooltips | A per-space home page set from the space menu, stored with the space in `session.json`, and opened in the selected tab with History ▸ Home (⇧⌘H); a speaker badge on tab rows while the page plays sound; a dot on tabs a page opened in the background until the user selects them; tab row tooltips with the full title and address. The sidebar has no home button | None | complete |

## 5. Accounts, Sync, and Settings

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 35 | Sidebar and settings sync | CloudKit private database through `CKSyncEngine` (macOS 14+); design in `docs/sync.md` | None | not started |
| 36 | Preferences window | An AppKit window with `NSTabViewController` toolbar sections in the `.preference` toolbar style, each a SwiftUI grouped form: General (default browser, default engine, search engine, downloads folder, ask where to save), Sidebar (archive delay), and Appearance. Shortcuts (row 13) and Websites (row 26) add their sections | None | in progress |
| 39 | Autofill (passwords, passkeys, cards, addresses) | No browser-side store. The official 1Password and iCloud Passwords extensions (row 44) fill forms on both engines as plugins (row 50); each needs Arch on its allow list (see IV.13). Passkeys go through AuthenticationServices on both engines, which needs Apple's restricted browser passkey entitlement (IV.14). On Chromium, 1Password's Universal Autofill can read a page once it asks for the accessibility tree (see Private APIs); the user has yet to check it. A WebKit tab does not get Apple Passwords AutoFill without an extension; the user checked this on macOS 27 | Extensions, accessibility | not started |
| 40 | Web notifications and push | `UserNotifications` for local notifications: a download that finishes while Arch is not active posts one, and clicking it reveals the file in the Finder; the first finished download asks for permission. On Chromium, CEF 156 sends a page's permission request to `CefPermissionHandler::OnShowPermissionPrompt`, which Arch's permission sheet answers, but its public API has no callback that hands the notification itself to the app; the framework's own macOS notification service posts it through `UserNotifications` (needs verification). WebKit has no public API: `WKUIDelegate` has no notification callback, and on macOS 27 a page sees `Notification`, but `Notification.requestPermission()` resolves to `denied` without asking the app and `PushManager` is undefined. Remote push is omitted | Permissions | in progress |
| 41 | AppleScript | `Arch.sdef` with the Cocoa Standard Suite, `open location`, and tabs with their identifier, name, and URL, read through key-value coding on the application; `open location` arrives through `application(_:open:)` | None | complete |
| 42 | Sound effects | `NSSound`. The user has yet to decide whether to offer sound effects. App icon choice is not offered for now | None | not started |

## 6. Extensions and Developer Tools

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 44 | Extensions | The same Manifest V3 extensions on both engines, installed once per Persona as plugins (row 50, `docs/plugins.md`), with each engine running its own copy and storage: `WKWebExtensionController` on WebKit (macOS 15.4+), CEF Chrome style on Chromium. On macOS, CEF uses Alloy style whenever the browser has a parent view, so Chrome style needs CEF-owned windows or a patched build (VI.1) | Extensions | not started |
| 45 | DevTools | Chromium DevTools behind one menu item and shortcut, beside the page to the right, below, or to the left, or in a window of their own. CEF 156's public API cannot place them inside the browser window: a CEF check stops `ShowDevTools` with child window info. So CEF's tools window becomes a child window of the browser window over the space the page leaves; docking inside the window needs a CEF patch (VI.3). WebKit allows inspection from the browser bundled with macOS (`isInspectable`); its inspector inside the app needs private API behind flags (IV.16) | DevTools | complete |
| 50 | Plugins | Arch's own plugin system, designed in `docs/plugins.md`: built-in Swift plugins, script plugins that run in a sandboxed WebKit web view, and web extensions (row 44) as one kind. Plugins add sidebar items, palette commands, menus, shortcuts, settings, panels, and page scripts on both engines. Built-in plugins ship with the app, and future features can ship as built-in plugins. Installed plugins, their grants, storage, and Keychain items belong to one Persona | None | not started |
| 51 | Flags page (`flags://`) | One flag for all private APIs, one for each private API, and one for each feature that uses one. Each API's availability is checked quietly at launch and before use | Private APIs | complete |

## 7. AI

Arch ships no model or provider account. All AI features use one AI interface. The user chooses a provider and model for each feature.

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 43 | AI interface and providers | One provider-neutral interface designed in `docs/ai.md`. Providers use API keys kept in the Keychain or command-line tools signed in through the built-in terminal (row 56). The provider and model are chosen per feature, with up to two fallbacks | None | not started |
| 52 | Page reader | A side panel that summarizes the current page and answers follow-up questions | Page text | not started |
| 53 | Questions in the page | Questions about the page or a selection, with answers in a popover beside the page | Page text | not started |
| 54 | AI hooks | Features subscribe to events such as page loads, downloads, and new tabs; the first hooks name tabs and rename downloaded files | None | not started |
| 55 | Features that AI adds at run time | AI writes plugins (row 50) that the user reviews, enables, and removes | None | not started |
| 56 | Built-in terminal | A terminal panel backed by a pseudo-terminal for running and signing in to AI command-line tools | None | not started |

## 8. Exclusions

| # | Feature | Handling |
|---|---|---|
| 23 | Ad and tracker blocking | Excluded. An extension (row 44) can provide it |
| 46 | Telemetry, crash reports, remote feature flags | None. Arch collects no usage data and has no remote flags. Local flags for private APIs are on `flags://` (row 51) |
| 24 | Translation | Excluded. Neither engine offers page translation to embedding apps; translation can return if one does |
| 30 | Site customizations (per-site CSS, JavaScript, and color changes) | Excluded. Browsers do not commonly provide this feature |
| 31 | Notes and documents | Excluded. Browsers do not commonly provide this feature |
| 47 | Prompts to switch browsers | None. Import (row 33) covers moving from another browser |
| 37 | Automatic updates | None. Arch adds no update service; builds are made by hand from the repository |
| 38 | Accounts | None. Arch needs no account of its own; sync uses the user's iCloud account (row 35) |

## Private APIs

Each private API has a row with the API, its framework or engine, the features that use it, and its availability check. The `flags://` page lists the same entries.

| API | Framework or engine | Features | Availability check |
|---|---|---|---|
| `AXEnhancedUserInterface` and `AXManualAccessibility`, attributes that an assistive app sets on the application | macOS accessibility | Chromium pages for assistive apps: Chromium builds its accessibility tree only on request, and these attributes are how assistive apps other than VoiceOver ask for it. VoiceOver needs no flag, because `NSWorkspace.isVoiceOverEnabled` reports it | None: the assistive app sets the attribute, and Arch only reads it |
