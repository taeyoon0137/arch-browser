# Engine protocol design

## Purpose and principles

- Protocols in `ARCHEngine` separate the Swift layer from the web engine. `ARCHEngineChromium` is the primary engine. It uses Chromium through the Chromium Embedded Framework (CEF). The `WKWebView` adapter serves as the secondary engine and the debug engine. The selection model allows each profile or tab to use a different engine.
- Feature code depends only on these protocols. It never depends directly on an engine framework. Add protocol members only when a feature needs them. Treat the current set as a starting point, not a checklist to complete. `docs/features.md` lists the features the protocols serve.
- Keep features lightweight. Delegate password, card, and address autofill to Apple Passwords (iCloud Keychain and passkeys) or a third-party provider such as 1Password. Both adapters route engine events to the system framework wherever macOS provides the user experience. The Chromium engine disables its own equivalent UI for these features. See the Platform integration table in `docs/features.md`. Prefer Apple APIs for picture-in-picture (PiP), CSS and JavaScript injection, and translation. These include WebKit's built-in PiP, `WKUserScript`, `WKUserContentController`, and the Translation framework.

## Module layout

| Module | Location | Role | Dependencies |
|---|---|---|---|
| `ARCHEngine` | `Packages/ARCHKit/Sources/ARCHEngine` | Protocols, value types, `EngineRegistry`, `EngineSelection` | AppKit, Foundation |
| `ARCHEngineWebKit` | `Packages/ARCHKit/Sources/ARCHEngineWebKit` | `WKWebView` adapter. Secondary and debug engine | `ARCHEngine`, WebKit |
| `ARCHEngineChromium` | `Packages/ARCHKit/Sources/ARCHEngineChromium` | Primary engine. Swift adapter over the `CEFBridge` Objective-C++ target. The embedded browser uses Alloy style, which CEF requires for embedding in a client view. Chrome style requires a CEF Views window. Support for Chrome style is evaluated separately. Chromium-format extensions depend on Chrome style. Build steps: `docs/plan.md` | `ARCHEngine`, `CEFBridge`, CEF framework |

- The engine modules and `CEFBridge` are declared manually in `Package.swift`.

## Tier 1: protocols implemented by both engines

| Protocol | Members | WebKit implementation |
|---|---|---|
| `Engine` | `kind`, `capabilities`, `makeApplication` | - |
| `EngineApplication` | `run`, `tryToTerminate`, create/load/delete/query browser contexts, `createBrowser`, `restoreBrowser`, `setBlockLists`, `setExcludedDomains` | `WKWebsiteDataStore`, `WKContentRuleListStore` |
| `EngineBrowserContext` | `id`, `type`, `userVisibleName`, `history`, `downloads`, `preferences`, optional `extensions`, `setRememberedPermission` (sets the engine's stored answer for an origin's permission; defaults to no action for engines that store none) | `WKWebsiteDataStore`. WebKit has no browsing history store; a custom store is required |
| `EngineHistory` | `query`, `mostVisited`, `delete`, `deleteAll` | Custom store, not implemented |
| `EnginePreferences` | `downloadFilePath`, `promptForDownloadPath`, `searchSuggestEnabled`, `notificationPermissionRequestsEnabled`. Password and card storage settings are excluded | Value types |
| `EngineBrowser` | `createWebContents`, `takeOwnership`, `tryToClose`, get/set/delete cookies, `removeCookies(where:)`, `removeSiteData(for:)` (origins' stored data other than cookies), `window` | Per-window container, `WKHTTPCookieStore`, `WKWebsiteDataStore.removeData` |
| `EngineWebContents` | `url`, `title`, `favicon`, `isLoading`, `loadProgress`, `canGoBack`, `canGoForward`, `themeColor`, `isAudible` (sound from media elements in the document), `restorableState` (opaque page state the same engine restores through `EngineWebContentsConfiguration.restorableState`; WebKit uses `interactionState`, Chromium has none), `selectedText`, `zoomFactor`, `visibility`, `isFullscreen`, `navigationController`, `mediaSession`, find, `executeJavaScript`, `readableContent` (the main frame's visible text, address, title, language, and selection outside fields and editable areas), page scripts (`EngineWebContentsConfiguration.pageScripts`, `setPageScripts`, `pageScriptDelegate`, `executeJavaScript(_:inWorld:completion:)`, `postPageScriptMessage`), insert/remove stylesheets, viewport/full-page capture, PDF, printing, exit fullscreen, `discard`, `tryToClose` (runs `beforeunload` handlers), optional `devTools`, optional `thumbnails` | `WKWebView`: `find(_:configuration:)`, `evaluateJavaScript`, `callAsyncJavaScript` in a content world, `WKUserScript`, a `WKContentWorld` and a `WKScriptMessageHandlerWithReply` for each page script world, `takeSnapshot`, `createPDF`, `pageZoom`, `themeColor`, `fullscreenState` |
| `EngineNavigationController`, `EngineBackForwardList` | `load`, `reload`, `reloadWithoutCache`, `stop`, `goBack`, `goForward`, `go(to:)`, list | `WKWebView`, `WKBackForwardList` |
| `EngineMediaSession` | `playbackState`, `position` (advanced at the playback rate since the last report), `metadata` (Media Session title, artist, album, largest artwork), `canGoToNextTrack`, `canGoToPreviousTrack`, `play` and `pause` (the page's handler, or the media itself), `nextTrack`, `previousTrack`, `seek`, `setMuted`, `requestPictureInPicture`, `exitPictureInPicture`; the delegate's `mediaSessionDidChange` reports any change | A script in its own content world reports each document's media. A page-world script records and runs the page's Media Session action handlers. `ScriptMediaSession` in `ARCHEngine` serves both adapters. Built-in video PiP and `closeAllMediaPresentations`; seeking, muting, and PiP calls are not implemented |
| `EngineDownloads`, `EngineDownloadItem` | List, create/update/remove callbacks, filename selection, `pause`, `resume`, `cancel`, `remove` | `WKDownload` (macOS 11.3+) |
| `EngineWebContentsUIDelegate` | Title/URL/loading/favicon/theme color/audible state changes, status text, new web contents, closing, activation requests, enter/exit fullscreen, JavaScript alert/confirm/prompt/beforeunload and their cancellation, permission requests, whether a download may start (with whether a page was ever shown), context menus (the engine's own spelling and editing items carry `EngineContextMenuItem` identifiers), external protocols, HTTP authentication, audio/mute state, blocked popup count, renderer termination, key event consumption | `WKUIDelegate`, `WKNavigationDelegate`, `willOpenMenu(_:with:)` |
| `EngineWebContentsNavigationDelegate`, `EngineWebContentsNavigationObserver` | Policy decisions, start, redirect, commit, finish, failure, same-document navigation | `WKNavigationDelegate` |
| `EngineBrowserDelegate`, `EngineBrowserContextDelegate`, `EngineApplicationDelegate` | Create web contents, fullscreen state, session restore start/end/skip, initialization, run loop exit, browser creation/termination, renderer crashes | Internal adapter events |

## Tier 2: optional engine capabilities

`Engine.capabilities` exposes optional features. The UI hides unavailable features. Chromium entries describe planned adapter support.

| Capability | Chromium | WebKit |
|---|---|---|
| `extensions` (Manifest V3 extensions) | Planned | None |
| `devTools` | CEF's developer tools in a window the adapter reports through `EngineDevTools.window`. The app places it beside the page. A panel cannot be chosen | WebKit's Web Inspector through the private `_inspector` object behind private API flags. It attaches inside the page view, so `window` is nil and `isPlacedByApp` is false. Without the flags, none; the adapter sets `isInspectable` |
| `pdfController` | Planned | Built-in PDF support |
| `importSources` | Planned | None |
| `notifications` | Chromium's own macOS notification service shows pages' notifications; the permission request reaches the delegate (needs verification) | None: no public API; `Notification.requestPermission()` resolves to `denied` |
| `accessibilityTree` | Planned | None |
| `tabGroups` | Planned | None |
| `translation` | Planned | Translation framework (macOS 15+, needs verification) |
| `pictureInPicture` | System PiP through AVKit using decoded video frames. Requires a patched CEF source build (needs verification) | System PiP through WebKit (AVKit). Users enter PiP from video controls. `closeAllMediaPresentations` exits PiP. No custom code |
| `sessionRestore`, `contentBlocking` | Planned | The platform supports these features; adapter methods are not yet implemented |
| `cookies` | CEF's global cookie manager: visit, set in batches, delete; no change reports | `WKHTTPCookieStore`, with change reports through `WKHTTPCookieStoreObserver` |

## Excluded from the protocols

- Autofill: saving or filling passwords, cards, and addresses. Apple Passwords and 1Password handle them; the extent of system password autofill in `WKWebView` needs verification.
- AI: models and ranking. `readableContent` reads page text for any feature and contains no AI code.
- Instrumentation: metrics, tracing, and crash reporting.
- Encryption keys for sync: sync uses CloudKit (`docs/plan.md`, V.9).

Chromium-specific UI callbacks, including translation bubbles, extension installation consent, and Web UI dialogs, remain outside the protocols.

## Engine switching

- `EngineKind` identifies `webKit` and `chromium`. `EngineRegistry` holds registered engines. `UserDefaults` stores the default engine under `ARCHDefaultEngine`.
- Engine selection uses a profile default (`EngineSelection.profileDefault`) and a per-tab override (`EngineWebContentsConfiguration.engineOverride`). `BrowserSession` runs one application, profile, and browser per engine, so tabs of both engines share a session: new tabs use the default engine and tabs a page opens use that page's engine. The address pill's site settings switch a tab's engine by loading its page in a web contents from the other engine; `CookieSync` in `Browsing` copies cookies between the engines through `allCookies`, `setCookies`, and `cookiesDidChange`.
- Each engine keeps profile data in its own directory. Cookies are shared by copying between the engines' stores (I.13); other site data stays per engine. Sidebar and tab models belong to the feature modules. These models are independent of the engine.

## Current state and next steps

Both adapters build and run in the app. `docs/plan.md` Current State lists each adapter's implemented members and remaining stubs. Its Work Queue lists engine gaps in Phase II and changes requiring a CEF source build in Phase VI.

These adapter rules supplement the member signatures:

- `go(to:)` loads an earlier or later page from the same controller's back-forward list. It ignores the current page and items from another tab's list, so an item kept after its menu closes cannot load a different page.
- The Chromium adapter calls the DevTools protocol only when CEF has no other route. An attached DevTools client stays until the browser closes and prevents Chromium from timing out a hung page (`docs/plan.md`, Decisions).
- `removeSiteData(for:)` removes WebKit's data records for each origin's site (registrable domain), the unit those records use. On Chromium, it calls `Storage.clearDataForOrigin` for each origin in a hidden browser that then closes, so no tab keeps a DevTools client. It leaves cookies to `removeCookies(where:)`, which the session runs on both engines together.
- Both adapters report media through a script in each document and share `ScriptMediaSession`, which shows the playing document, otherwise the one that reported last.
- Page scripts run in each new document, from the first one on or, after `setPageScripts`, from the next. Each `EnginePageScript` is a function expression that the engine calls with its world's channel: `channel.send(value)` passes the value as JSON to `pageScriptDelegate` and returns a promise of the reply, and `channel.onMessage(listener)` receives what `postPageScriptMessage(_:toWorld:)` delivers to the main frame. Both adapters hand the delegate an `EnginePageScriptReply`, so a reply the delegate drops counts as nil. WebKit gives each world a `WKContentWorld` of its own with a `WKScriptMessageHandlerWithReply` added only to that world. It removes user scripts only all at once, so `setPageScripts` adds the content controller's other scripts again. A WebKit popup uses its opener's content controller and so shares its page scripts. Chromium runs every world in the page's main world. The bridge passes the scripts to the renderer in the browser's extra info, in a process message to each frame when they change, and to each frame created after a change. CEF does not order that message before the frame's first document, so in a renderer process that had none of the browser's frames, such as after a cross-site navigation, the first document may still run the scripts the browser was created with (needs verification). The helper's `OnContextCreated` makes the document's channel opener before the page's scripts run, so every channel, also one that `executeJavaScript(_:inWorld:completion:)` opens later, calls the built-ins as they were then. It opens each world's channel with a native function that it passes to the channel script as an argument, so the function never reaches `window`, and runs the scripts before the page's own; document-end scripts wait for `DOMContentLoaded`. The page can still see the values a Chromium page script sends and receives through the built-ins it replaces, such as a `then` getter on `Object.prototype`, which a promise reads when it settles with an object reply. A Chromium popup's renderers start with its opener's scripts, which the bridge passes in the popup's extra info. `executeJavaScript(_:inWorld:completion:)` uses the same process message as `readableContent` on Chromium.
- A popup keeps its opener on both engines, so the page reaches it through the window `window.open` returns and it reaches the page through `window.opener`. Each adapter reports it through `webContents(_:didCreateNewWebContents:targetURL:disposition:)`. WebKit's `createWebViewWith` returns a web view made from the configuration WebKit hands over and reports `newForegroundTab`. Chromium's `OnBeforePopup` hands CEF a browser object of the bridge's own, with its own client and container view, and CEF creates the popup in the opener's browsing context and request context; once `OnAfterCreated` reports it, the adapter wraps it in a `ChromiumWebContents` and reports Chromium's disposition. A Chromium popup that nobody adopts closes, and one that CEF cannot create never reaches the delegate. On both engines, a popup for another app goes to `openExternally`, and a Shift-clicked link that the navigation delegate cancels opens no popup.
- `readableContent(limit:completion:)` runs `EngineReadableContent.script` in the main frame: WebKit in its own `WKContentWorld`, Chromium in the page's world through a process message to the helper's renderer, because `ExecuteJavaScript` returns no value and the DevTools protocol would attach a debugger.
- A link the user clicks with Shift and without Command reaches `EngineWebContentsNavigationDelegate` as a user-initiated `newWindow` action on both engines. WebKit reads the click's modifier flags in `decidePolicyFor`, and a link marked for download is not one; Chromium gives such a link the new window disposition and asks from `OnOpenURLFromTab` and `OnBeforePopup`. The WebKit adapter asks the navigation delegate about every navigation, the Chromium adapter about these links only. When the delegate cancels, the link neither loads nor opens a popup.
