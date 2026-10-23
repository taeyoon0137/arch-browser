# Features

This document lists the features Arch plans to provide and tracks the status of each. Arch uses macOS system frameworks wherever macOS provides the user experience.

Status values are not started, in progress, and complete. The Implementation column describes the intended approach. Code is written anew for each feature.

## Platform integration

Arch uses system frameworks on both engines wherever macOS already provides the user experience. The Chromium engine retains its existing native integrations. It routes the remaining engine events to these frameworks. It disables its own equivalent user interface.

| Area | macOS facility |
|---|---|
| Video picture-in-picture | AVKit `AVPictureInPictureController` |
| Now Playing, media keys, AirPlay | MediaPlayer `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`; AVKit `AVRoutePickerView` (needs verification) |
| Sharing | AppKit `NSSharingServicePicker` |
| Notifications | UserNotifications |
| Translation | Translation framework (macOS 15+, needs verification) |
| Passwords and passkeys | Apple Passwords through AuthenticationServices; no browser-side store |
| Printing and PDF | AppKit `NSPrintOperation`, PDFKit |
| File dialogs and downloads | AppKit `NSOpenPanel` and `NSSavePanel`; Quick Look previews |
| Handoff | `NSUserActivity` for the current page |
| Spelling and text input | AppKit `NSSpellChecker`, system text replacement, system fonts |
| Confirmation for sensitive settings | LocalAuthentication (Touch ID) |
| Sync | CloudKit |
| Automation | AppleScript; App Intents (needs verification) |
| Appearance | System appearance and accent color |

## 1. Windows, Sidebar, and Tabs

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 1 | Sidebar (collapse, expand, show on hover) | Custom AppKit and SwiftUI implementation | None | in progress |
| 2 | Spaces (create, switch, swipe, color themes) | Custom implementation with SwiftUI gradients for themes | None | in progress |
| 3 | Pinned tabs, favorites, tabs, automatic archiving | Custom implementation with local storage | Session restoration | in progress |
| 4 | Folders and tab groups | Custom implementation | None | not started |
| 5 | Split View | Custom implementation | None | not started |
| 6 | Small browser window | Custom implementation | None | not started |
| 7 | Multiple windows and window restoration | Custom implementation using `WKWebView.interactionState` | Session restoration | not started |
| 8 | Tab switcher and tab close log | Custom implementation | None | not started |
| 9 | Profile isolation | `WKWebsiteDataStore(forIdentifier:)` | Profiles | not started |
| 10 | Window themes and appearance (light, dark, automatic) | SwiftUI and AppKit appearance APIs | None | in progress |
| 48 | Engine per tab: WebKit or Chromium, switchable from the address bar's site settings, inherited by tabs a page opens, with cookies shared between the engines | Both engine adapters in one session; cookies copied between `WKHTTPCookieStore` and the Chromium cookie manager | Cookies | in progress |

## 2. Navigation and Input

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 11 | Command bar (URLs, search, commands, tab switching) | Custom implementation. AppKit text completion shows suggestions from local history and bookmarks, plus public search engine endpoints. No engine autocomplete is used | None | in progress |
| 12 | Site Search | Custom implementation with a local search engine list | None | not started |
| 13 | Keyboard shortcuts and global shortcuts | AppKit events, `NSEvent.addGlobalMonitorForEvents` | None | in progress |
| 14 | Back, forward, reload, zoom | `WKWebView` | Navigation | in progress |
| 15 | Find in page | `WKWebView.find(_:configuration:)` | Find | in progress |
| 16 | Link routing, universal links, opening external apps | `NSWorkspace`, `WKNavigationDelegate` policies | Policy decisions | in progress |
| 17 | Default browser setup and prompts | `NSWorkspace.setDefaultApplication` | None | in progress |
| 18 | Drag and drop (tabs, links, files) | AppKit drag APIs | None | not started |

## 3. Content and Media

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 19 | Previews (link previews on hover) | Custom implementation with a secondary `WKWebView` window | Navigation | not started |
| 20 | Media controls and picture-in-picture (PiP) | Both engines use system PiP. WebKit has it built in. The Chromium engine routes PiP to AVKit through a patched CEF build so it matches the macOS experience (needs verification). `MPNowPlayingInfoCenter` for media controls (needs verification) | Media sessions | not started |
| 21 | Download management | `WKDownload`, `NSSavePanel` | Downloads | in progress |
| 22 | Capture (region, full page) and screenshot storage | `WKWebView.takeSnapshot`, `createPDF`, ScreenCaptureKit | Capture | in progress |
| 23 | Ad and tracker blocking | `WKContentRuleList` with converted EasyList rules, CSS injection to hide elements | Content blocking | not started |
| 24 | Translation | Translation framework (macOS 15+, needs verification) | Translation | not started |
| 25 | PDF viewing and printing | Built-in WebKit PDF support, `NSPrintOperation` | PDF | in progress |
| 26 | Site permissions | `WKUIDelegate` permission callbacks, custom storage | Permissions | in progress |
| 27 | Fullscreen and sad tabs (crash recovery) | `WKWebView` fullscreen APIs, `webViewWebContentProcessDidTerminate` | Renderer termination | in progress |
| 28 | Favicons and theme colors | Custom favicon collection, `WKWebView.themeColor` | None | in progress |
| 29 | Cookies, site data, browsing history | `WKHTTPCookieStore` and `WKWebsiteDataStore`. Browsing history uses custom storage | Cookies and history | in progress |

## 4. Creation and Sharing

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 30 | Site customizations (per-site CSS, JavaScript, and color changes) | Inject through `WKUserScript` and `WKUserContentController` | Script and style injection | not started |
| 31 | Notes and documents | Custom implementation with local storage | None | not started |
| 32 | Share menu and sharing settings | `NSSharingServicePicker` | None | not started |
| 33 | Import (bookmarks, history, passwords) | Custom parsing of browser files. Apple Passwords handles password imports | None | not started |
| 34 | Home button, badges, tooltips | Custom implementation | None | not started |

## 5. Accounts, Sync, and Settings

| # | Feature | Implementation | Engine dependency | Status |
|---|---|---|---|---|
| 35 | Sidebar and settings sync | CloudKit private database | None | not started |
| 36 | Preferences window | Custom implementation using the `Settings` package | None | in progress |
| 37 | Automatic updates | Omitted. Builds are manual. Reconsider later | None | not started |
| 38 | Accounts | None. Arch needs no account | None | not started |
| 39 | Autofill (passwords, cards, addresses) | No browser implementation. Delegate to Apple Passwords (iCloud Keychain, passkeys) and the 1Password extension. WKWebView support needs verification | None | not started |
| 40 | Web notifications and push | `UserNotifications` for local notifications only. Remote push is omitted | None | not started |
| 41 | AppleScript | Custom `NSScriptCommand` implementation | None | not started |
| 42 | App icon changes and sound effects | `NSApplication.applicationIconImage`, `NSSound` | None | not started |

## 6. Exclusions

| # | Feature | Handling |
|---|---|---|
| 43 | AI features | Excluded entirely from this implementation. No AI code or extension point for AI |
| 44 | Chrome extensions | Available through the Chromium engine (CEF Chrome style, needs verification). Unavailable on the WebKit engine |
| 45 | DevTools | Use DevTools directly from the Chromium engine. The secondary WebKit engine uses Web Inspector (`isInspectable`) |
| 46 | Telemetry, crash reports, feature flags | None. Arch collects no usage data and has no remote flags |
| 47 | Prompts to switch browsers | None. Import (row 33) covers moving from another browser |
