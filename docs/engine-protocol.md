# Engine protocol design

## Purpose and principles

- Protocols in `ARCHEngine` separate the Swift layer from the web engine. `ARCHEngineChromium` is the primary engine. It uses Chromium through the Chromium Embedded Framework (CEF). The `WKWebView` adapter serves as the secondary engine and the debug engine. The selection model allows each profile or tab to use a different engine.
- Feature code depends only on these protocols. It never depends directly on an engine framework. Add protocol members only when a feature needs them. Treat the current set as a starting point, not a checklist to complete. `docs/features.md` lists the features the protocols serve.
- Keep features lightweight. Delegate password, card, and address autofill to Apple Passwords (iCloud Keychain and passkeys) or a third-party provider such as 1Password. Both adapters route engine events to the system framework wherever macOS provides the user experience. The Chromium engine disables its own equivalent UI for these features. See the Platform integration table in `docs/features.md`. Prefer Apple APIs for picture-in-picture (PiP), CSS and JavaScript injection, ad blocking, and translation. These include WebKit's built-in PiP, `WKUserScript`, `WKUserContentController`, `WKContentRuleList`, and the Translation framework.

## Module layout

| Module | Location | Role | Dependencies |
|---|---|---|---|
| `ARCHEngine` | `Packages/ARCHKit/Sources/ARCHEngine` | Protocols, value types, `EngineRegistry`, `EngineSelection` | AppKit, Foundation |
| `ARCHEngineWebKit` | `Packages/ARCHKit/Sources/ARCHEngineWebKit` | `WKWebView` adapter. Secondary and debug engine | `ARCHEngine`, WebKit |
| `ARCHEngineChromium` | `Packages/ARCHKit/Sources/ARCHEngineChromium` | Primary engine. Swift adapter over the `CEFBridge` Objective-C++ target. The embedded browser uses Alloy style, which CEF requires for embedding in a client view. Chrome style requires a CEF Views window. Support for Chrome style is evaluated separately. Chrome extensions depend on Chrome style. Build steps: `docs/plan.md` | `ARCHEngine`, `CEFBridge`, CEF framework |

- Both existing modules are maintained by hand and declared in `Package.swift`. Add `ARCHEngineChromium` when its bridge exists.

## Tier 1: protocols implemented by both engines

| Protocol | Members | WebKit implementation |
|---|---|---|
| `Engine` | `kind`, `capabilities`, `makeApplication` | - |
| `EngineApplication` | `run`, `tryToTerminate`, create/load/delete/query browser contexts, `createBrowser`, `restoreBrowser`, `setBlockLists`, `setExcludedDomains` | `WKWebsiteDataStore`, `WKContentRuleListStore` |
| `EngineBrowserContext` | `id`, `type`, `userVisibleName`, `history`, `downloads`, `preferences`, optional `extensions` | `WKWebsiteDataStore`. WebKit has no browsing history store; a custom store is required |
| `EngineHistory` | `query`, `mostVisited`, `delete`, `deleteAll` | Custom store, not implemented |
| `EnginePreferences` | `downloadFilePath`, `promptForDownloadPath`, `searchSuggestEnabled`, `notificationPermissionRequestsEnabled`. Password and card storage settings are excluded | Value types |
| `EngineBrowser` | `createWebContents`, `restoreWebContents`, `canRestoreWebContents`, `takeOwnership`, `tryToClose`, get/set/delete cookies, `window` | Per-window container, `WKHTTPCookieStore` |
| `EngineWebContents` | `url`, `title`, `favicon`, `isLoading`, `loadProgress`, `canGoBack`, `canGoForward`, `themeColor`, `selectedText`, `zoomFactor`, `visibility`, `isFullscreen`, `navigationController`, `mediaSession`, find, `executeJavaScript`, insert/remove stylesheets, viewport/full-page capture, PDF, printing, exit fullscreen, `discard`, `clearSiteDataAndReload`, optional `devTools`, optional `thumbnails` | `WKWebView`: `find(_:configuration:)`, `evaluateJavaScript`, `WKUserScript`, `takeSnapshot`, `createPDF`, `pageZoom`, `themeColor`, `fullscreenState` |
| `EngineNavigationController`, `EngineBackForwardList` | `load`, `reload`, `reloadWithoutCache`, `stop`, `goBack`, `goForward`, `go(to:)`, list | `WKWebView`, `WKBackForwardList` |
| `EngineMediaSession` | `play`, `pause`, `seek`, `setMuted`, `requestPictureInPicture`, `exitPictureInPicture`, `position`, `playbackState` | Built-in video PiP, `pauseAllMediaPlayback`, `closeAllMediaPresentations`. Media session state queries need verification |
| `EngineDownloads`, `EngineDownloadItem` | List, create/update/remove callbacks, filename selection, `pause`, `resume`, `cancel`, `remove` | `WKDownload` (macOS 11.3+) |
| `EngineWebContentsUIDelegate` | Title/URL/loading/favicon/theme color changes, status text, new web contents, closing, activation requests, enter/exit fullscreen, JavaScript alert/confirm/prompt/beforeunload, permission requests, whether a download may start (with whether a page was ever shown), context menus, external protocols, HTTP authentication, audio/mute state, blocked popup count, renderer termination, key event consumption | `WKUIDelegate`, `WKNavigationDelegate`, `willOpenMenu(_:with:)` |
| `EngineWebContentsNavigationDelegate`, `EngineWebContentsNavigationObserver` | Policy decisions, start, redirect, commit, finish, failure, same-document navigation | `WKNavigationDelegate` |
| `EngineBrowserDelegate`, `EngineBrowserContextDelegate`, `EngineApplicationDelegate` | Create/restore web contents, fullscreen state, session restore start/end/skip, initialization, run loop exit, browser creation/termination, renderer crashes | Internal adapter events |
| `EngineSessionWindow`, `EngineSessionTab` | Session restore models | `WKWebView.interactionState` (macOS 12+) |

## Tier 2: optional engine capabilities

`Engine.capabilities` exposes optional features. The UI hides unavailable features. Chromium entries describe planned adapter support.

| Capability | Chromium | WebKit |
|---|---|---|
| `extensions` (Chrome extensions) | Planned | None |
| `devTools` | Planned | Web Inspector (`isInspectable`); protocol not implemented |
| `pdfController` | Planned | Built-in PDF support |
| `importSources` | Planned | None |
| `notifications` | Planned | None |
| `accessibilityTree` | Planned | None |
| `tabGroups` | Planned | None |
| `translation` | Planned | Translation framework (macOS 15+, needs verification) |
| `pictureInPicture` | System PiP through AVKit using decoded video frames. Requires a patched CEF source build (needs verification) | System PiP through WebKit (AVKit). Users enter PiP from video controls. `closeAllMediaPresentations` exits PiP. No custom code |
| `sessionRestore`, `contentBlocking`, `cookies` | Planned | The platform supports these features; adapter methods are not yet implemented |

## Excluded from the protocols

- Autofill: saving or filling passwords, cards, and addresses. Apple Passwords and 1Password handle them; the extent of system password autofill in `WKWebView` needs verification.
- AI: models, ranking, and page content extraction.
- Instrumentation: metrics, tracing, and crash reporting.
- Encryption keys for sync: sync uses CloudKit (`docs/plan.md`, V.9).

Chromium-specific UI callbacks, including translation bubbles, extension installation consent, and Web UI dialogs, remain outside the protocols.

## Engine switching

- `EngineKind` identifies `webKit` and `chromium`. `EngineRegistry` holds registered engines. `UserDefaults` stores the default engine under `ARCHDefaultEngine`.
- Engine selection uses a profile default (`EngineSelection.profileDefault`) and a per-tab override (`EngineWebContentsConfiguration.engineOverride`). `BrowserSession` runs one application, profile, and browser per engine, so tabs of both engines share a session: new tabs use the default engine and tabs a page opens use that page's engine. Switching a tab's engine (I.12) and sharing cookies (I.13) are queued in `docs/plan.md`.
- Each engine keeps profile data in its own directory. Cookies are shared by copying between the engines' stores (I.13); other site data stays per engine. Sidebar and tab models belong to the feature modules. These models are independent of the engine.

## Current state and next steps

`ARCHEngine` and `ARCHEngineWebKit` build. `ARCHEngineWebKit` implements find, script execution, style injection, snapshots, PDF, and navigation through `WKWebView`. Media, downloads, and history remain stubs.

Next steps:

1. Design the Chromium adapter's Objective-C++ bridge.
2. Get the prebuilt CEF framework running on this Mac. Set up the patched CEF source build on another Mac when a gap requires it.
3. Check `WebKitDelegateBridge` against the delegate protocols and implement the missing callbacks.
4. Connect the first feature module to `EngineRegistry` for engine selection.
5. Implement the debug menu.
