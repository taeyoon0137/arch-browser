# Arch Browser Development Plan

This plan gives the context needed to continue work in another session, on another Mac, or with a less capable model. Progress lives only here and in `docs/features.md`; there is no external context store.

## Goals

- Build a sidebar-first macOS browser with its own implementation. `docs/features.md` lists every planned feature and its status.
- Run no servers of our own. Use alternatives such as iCloud for features that need servers, including sync (`docs/features.md`, sections 5 and 6).
- Keep features lightweight. Delegate autofill to Apple Passwords or 1Password. On both engines, use macOS system frameworks for every feature that is part of the platform user experience. Follow the Platform integration table in `docs/features.md`.
- Exclude all AI features. This implementation contains no AI code or extension point for AI.
- Use ARCH prefixes throughout: `ARCH*` for packages, `Arch` for the app module, and `ARCHKit` for the core layer.
- The browser is for internal use. No distribution is planned. Manage replacement names, images, fonts, and similar items outside this repository.

## Approach

- Write new code for each feature. Start from a row in `docs/features.md`. Design the smallest module that delivers the feature and add it to `Package.swift`.
- Design type names, module boundaries, method signatures, and file layout for Arch. A row in `docs/features.md` describes what a feature does, not how to build it.
- Add engine protocol members only when a feature needs them. The current protocols are a starting point, not a list of requirements to implement.
- AI is out of scope. For features that combine AI and non-AI capabilities, keep only the non-AI part.
- The sidebar holds navigation, the address field, favorites, and tabs grouped by space. The window background shows the current space's tint. Nothing sits above the page. Only the code is written anew.
- Use the system framework whenever macOS provides the user experience. Do not build or retain an engine-specific version. Keep Chromium's existing native integrations. Route the remaining engine events to these frameworks and disable the engine's equivalent user interface.

## Current State

| Area | Status |
|---|---|
| Engine abstraction | `ARCHEngine` protocols are complete. Both adapters route page events through `EngineWebContentsUIDelegate`; feature code implements only the callbacks it handles, and the defaults give the safe answer (dialogs dismiss, permissions deny). |
| WebKit adapter | `ARCHEngineWebKit` implements loading, reloading, stopping, back and forward navigation with the back-forward list, find (reports found or not found only), script execution, style injection, viewport and full-page snapshots, PDF export, printing through the system panel, downloads with `WKDownload` (pause, resume, cancel), popups, page-initiated closing, favicons, and cookies. It forwards JavaScript dialogs, HTTP authentication, media capture permission (after the system's own camera and microphone permission), and web content process termination to the delegate. History, media sessions, content blocking, site data clearing, and page state restore are stubs. |
| Chromium adapter | `ARCHEngineChromium` embeds a CEF browser (Alloy style) beside the sidebar through `CEFBridge`, with an external message pump on the main run loop and the `ArchHelper` subprocess. It implements loading, navigation, title, URL, and loading state, favicon URLs, zoom level, popups as new tabs, closing, script execution, style injection, find with match counts, printing through Chromium's dialog, PDF export, viewport and full-page capture through the DevTools protocol, downloads (pause, resume, cancel, refusal), media and permission prompts routed to the delegate (camera and microphone also ask the system), and renderer crash recovery (one reload, then a blank page). Closing a browser detaches its view in `DoClose`, so CEF never closes the app's window. JavaScript dialogs and context menus use Chromium's own user interface. The back-forward list, cookies, HTTP authentication, external protocols, DevTools, extensions, media sessions, theme color, audible state, content blocking, site data clearing, page fullscreen, and page state restore are stubs. Development builds use Chromium's mock keychain until the bundle is signed with a stable identity. |
| Browsing module | One window over the system's translucent sidebar material with a faint wash of the current space's tint, and a sidebar with a top row on the line of the window's traffic light buttons (the sidebar button, then back, forward, and reload, which becomes stop while a page loads; in full screen the sidebar button takes the traffic lights' place), the address pill, favorites, one page per space with its pinned and open tabs, and the space switcher with downloads and new-space buttons. A two-finger horizontal swipe over the sidebar drags the space pages with the fingers and settles on the nearest space with a spring and a haptic at the halfway point; the switcher and the Spaces menu slide the pages the same way. With no tab open, the controls stay, the address pill shows a placeholder and opens a new tab, and the page frame shows a blurred view of what lies behind the window. Tabs open, close, pin, reorder, switch, and reopen; unpinned tabs not activated for a configurable number of hours are archived to the closed list (100 entries) by a timer and at restore. Several spaces with a tint each. Favorites are shared by all spaces and reuse an open tab for the same host. The command palette (⌘L edits the current address, ⌘T opens a new tab) accepts URLs and search queries, lists matching open tabs, and lists history suggestions. The find bar floats over the page (⌘F, ⌘G, ⌘⇧G, Escape). The downloads popover opens from the sidebar (⌘⇧J) and on a new download; files save to the downloads folder with an unused name, or through a save panel when the profile asks for a location. Popups become tabs; `window.close()` closes the tab. A tab that opens straight onto a file closes once the file's download starts, without a closed-list entry or a history visit, and a restored tab like that does not download the file again. Spaces, favorites, tabs, the closed list, and the selection persist in `session.json`; quitting keeps the open tabs because the bridge does not report the browsers that close when the runtime shuts down. A sheet asks before a site gets a permission such as the camera; the system's own camera and microphone prompt follows. Permission and page dialog sheets wait in a queue per tab and show one at a time, only while their tab is selected; closing a tab gives its waiting sheets the safe answer. JavaScript `alert`, `confirm`, and `prompt` show sheets titled with the page's host on the WebKit engine; Chromium keeps its own dialogs until II.1. The leave-page sheet for `beforeunload` is in place, but WebKit has no public `beforeunload` callback, so it first appears with II.1. HTTP authentication and context menus have no user interface yet (see Phase II). |
| History module | `history.sqlite` records one visit per page change per tab and serves palette suggestions ordered by visit count. See Decisions. |
| Preferences module | A Settings window (⌘,) for the default engine, the appearance (system, light, dark), and the archive delay. |
| App shell | `Arch` registers both engines, starts the default engine and falls back to the other, gives the window an empty unified toolbar, which sets the title bar to the standard height of the system's apps and centers the traffic light buttons on the sidebar's top row, and hides it in full screen, builds the menu bar (File, Edit, View with an Appearance submenu, Tab, Spaces, History), opens links sent by other apps (`CFBundleURLTypes` for http and https), prompts once to become the default browser and offers a menu item for it, and saves the session at quit. Nothing implements `EngineApplicationDelegate` yet, so the renderer crash counts the engines report reach no one (I.10). `ARCH_START_URL` opens a page at launch. |
| Build | `scripts/setup_cef.sh` downloads the pinned CEF distribution; `swift build` builds every target (Xcode 27, Swift 6.4); `scripts/bundle_app.sh` assembles `build/Arch.app` with the CEF framework, the helper apps, the app icon from `resources/assets/sym_arch.png` (`scripts/opaque_icon.swift` fills its transparent corners so that macOS clips it to the system shape instead of placing it on a gray plate), usage descriptions, and URL types, then signs it with the first Apple Development identity on the Mac or ad hoc. The app is run from the bundle; a bare `.build/debug/Arch` can point at CEF through the environment variables under Build Procedure, which is unverified on the current Mac. There are no third-party Swift dependencies. |
| Documentation | Engine design in `docs/engine-protocol.md`, the feature list in `docs/features.md`, and `README.md` generated from `resources/README.preset.md` with the hero image from `resources/assets`. |

## Repository Layout

```
Package.swift                               Package manifest (maintained by hand)
Packages/ARCHKit/Sources/ARCHEngine         Engine protocols, value types, registry, selection, favicon loader
Packages/ARCHKit/Sources/ARCHEngineWebKit   WebKit adapter (secondary and debug engine)
Packages/ARCHKit/Sources/ARCHEngineChromium Chromium adapter using the Chromium Embedded Framework (CEF)
Packages/ARCHKit/Sources/CEFBridge          Objective-C++ bridge over the CEF C++ API; copied CEF wrapper sources are ignored by Git
Packages/ARCH/Sources/Browsing              Session, sidebar, command palette, find bar, downloads list, session store
Packages/ARCH/Sources/History               SQLite visit store and suggestions
Packages/ARCH/Sources/Preferences           Settings window and appearance setting
Packages/ARCHApp/Sources/Arch               App target with the application delegate and menu bar
Packages/ARCHApp/Sources/ArchHelper         Executable for CEF helper processes
Frameworks/                                 CEF distribution (not committed)
build/                                      Assembled app bundle (not committed)
docs/                                       Design documents
resources/assets/                           Hero images and the app icon source
resources/                                  README source and hero wrapper
scripts/readme_update.sh                    README generation
scripts/setup_cef.sh                        Downloads the pinned CEF distribution; copies wrapper sources into CEFBridge
scripts/bundle_app.sh                       Bundles the CEF framework, helper apps, and icon into build/Arch.app
scripts/opaque_icon.swift                   Makes the icon opaque for the system icon shape; run by bundle_app.sh
```

## Working Rules

1. Write new code for each feature, with interfaces, names, and layout designed for Arch.
2. Maintain `Package.swift` by hand. Add one target per new module.
3. Exclude all AI features. Do not add AI code or extension points for AI.
4. Write documentation, comments, and commit messages in English.
5. Document the current state only. Do not include a change history. When a queue task finishes, remove its row and fold the result into Current State and `docs/features.md` in the same commit.
6. Stage by path (`git add <paths>`) and keep one purpose per commit. Queue tasks use the `Task(<ID>):` subject; other work uses the prefixes in `.githooks/commit-msg`.
7. Work on `main`. Branches named `cloud/…` or `sync/…` move work between machines; delete them after use.
8. Never record the code-signing identity, its team identifier, or a signed bundle in the repository, the documents, or a report. `build/` stays ignored.
9. Before the final `Docs:` commit of a batch, run a prose pass over the comments and documents the batch added with the `prose-writing` skills (Codex without a model flag; confirm the model and reasoning level in its startup output), then review the result.
10. Report a check as passed only after running it.

## Build Procedure

```bash
./scripts/setup_cef.sh      # once per checkout
swift build
./scripts/bundle_app.sh     # writes build/Arch.app
open build/Arch.app
```

- `ARCH_SIGN_IDENTITY` overrides the signing identity; `ARCH_START_URL` opens a page at launch; `ARCH_CEF_FRAMEWORK_PATH` and `ARCH_CEF_HELPER_PATH` let a bare `.build/debug/Arch` find CEF.
- State lives in `~/Library/Application Support/Arch`: `session.json`, `history.sqlite`, and `Cache/Chromium`. Delete the folder for a first-launch test. `defaults delete local.arch.browser ARCHAskedDefaultBrowser` brings the default-browser prompt back.
- For a scripted check, run `build/Arch.app/Contents/MacOS/Arch 2> /tmp/arch.log &`, then inspect `session.json`, `sqlite3 … history.sqlite 'select * from visits'`, and the log. `open -a build/Arch.app https://example.org` sends a link to the running app. `pkill -9 -f "type=renderer"` crashes every page's renderer.
- Launch through `open` or the Finder for any check that involves a system permission prompt. A binary started from a shell is attributed to the shell's parent, so the camera prompt never appears and the page reports a denied request.

Regression checklist, run from the bundle on the Chromium engine with a fresh Application Support folder:

1. ⌘F opens the find bar focused; typing shows "n of m"; Return and ⇧Return move through matches; Escape closes the bar and the page keeps keyboard focus; switching tabs closes it.
2. ⌘⇧J toggles the downloads popover; a file download appears with progress; pause, resume, and cancel change the row; Clear removes finished rows. The save panel path (`promptForDownloadPath`) has no setting yet; V.8 adds one.
3. After visiting three pages, ⌘L lists them under the typed text; choosing one navigates; a reload does not raise its visit count.
4. `open -a build/Arch.app https://example.org` opens a tab in the running app and at launch.
5. The first launch asks to set the default browser; Set as Default shows the system confirmation; afterwards the menu item is disabled.
6. A page requesting the camera gets Arch's sheet, then the system prompt; Allow reaches the page, Don't Allow reports a denied request.
7. Killing the renderer helper reloads the page once; a second crash on the same page leaves it blank and the app keeps running.

## Engine Plan

| Engine | Role | Work location |
|---|---|---|
| Chromium through CEF (`ARCHEngineChromium`) | Primary engine, embedded beside the sidebar in Alloy style. Chrome style is needed for Chrome extensions and requires a CEF Views window; it is evaluated separately. Prebuilt macOS arm64 binaries track current Chromium (156.0.7 on Chromium 156.0.8078.17). Engine patches required by macOS integration need a source build. | This Mac for the prebuilt framework; another Mac with enough free disk space for the patched source build |
| WebKit (`ARCHEngineWebKit`) | Secondary and debugging engine. It uses the system framework and needs no source download. | This Mac |

- Remaining engine gaps are queued in Phase II. Gaps that need engine changes, such as picture-in-picture through AVKit for the Chromium engine, are queued in Phase VI: build CEF from source on a Mac with at least 150GB of free disk space and a full Xcode installation (32GB of memory recommended; the first build takes several hours on an M-series Mac, needs verification), apply the patches there, and replace the prebuilt framework with the patched build.
- Chromium's password, card, and address storage stay disabled. Apple Passwords handles passwords and passkeys; 1Password handles cards and addresses.
- `EngineHistory` is unused: browsing history is engine-independent and lives in the `History` module.

## Work Queue

### How to use the queue

Each task carries the reasoning it needs, so that work can be split across models by capability:

- `high`: a design choice, a change to the Objective-C++ bridge or the engine protocols, a change to the `session.json` schema, window architecture, or threading. Use the most capable model available.
- `medium`: a view or session method inside an existing module that follows an existing pattern (for example `DownloadsView` or `togglePinned`). A mid-tier model can take it with the files and the done condition below.
- `low`: a mechanical edit, a document update, or a verification by checklist. Any model.

Rules for every tier:

1. Take tasks at or below your tier. Read the files the task names before editing, and keep to them. If the task needs a file, a protocol member, or a decision it does not list, stop, write the blocker into the task row (`blocked: …`), and leave the code unchanged.
2. Respect the order within a phase and the dependencies in the task text. Phases I and II run before III to V; VI is independent.
3. One task per commit with the `Task(<ID>):` subject, staged by path. Run `swift build` for every code change and `scripts/bundle_app.sh` plus a launch when the task says "from the bundle".
4. Finish by updating this file (remove the row, update Current State) and the feature row in `docs/features.md` in the same commit, then go through the After each task list in `AGENTS.md`.
5. Verification steps use a fresh Application Support folder unless the step says otherwise.

### Phase I: Stabilize the current features

| ID | Task | Reasoning | Files | Done when |
|---|---|---|---|---|
| I.4 | Confirm the default-browser registration. The app registers only `http`; the claim that this also covers `https` is unverified. After choosing Set as Default from the bundle, check the `https` handler with `NSWorkspace.shared.urlForApplication(toOpen:)`. If it is not Arch, also call `setDefaultApplication(at:toOpenURLsWithScheme: "https")` and update the comment. | low | `AppDelegate.swift` | Both schemes resolve to the bundle; the menu item disables |
| I.6 | Prose pass over the comments added by the first feature batch (commits `3eb7953..c2a4a96`) with the `prose-writing` skills, then a `Docs:` commit after review. blocked: the `prose-writing` and `prose-writing-codex` skills are not installed on the current Mac. | low | Files in that range | Comments read as plain prose; build still passes |
| I.7 | Remove the `use-mock-keychain` switch once the bundle is signed with a stable personal identity. Blocked until that identity exists on the build Mac. | low | `CEFBridge.mm` | A login cookie survives two launches without a keychain prompt |
| I.10 | Renderer crash reports: implement `EngineApplicationDelegate` on `BrowserSession` and set it as `application.delegate` before `run()`. Show a notice with a Reload button on a tab whose page stays blank after the automatic reload, and keep the count for the tab close log in III.8. | medium | `BrowserSession.swift`, `BrowserWindowView.swift` | Two renderer kills on one page show the notice and Reload restores the page |
| I.11 | Both engines in one session: `BrowserSession` keeps one engine application, profile context, and browser per registered engine, created on first use, and each tab records its engine in `session.json` (snapshot version 2; a record without an engine uses the default engine). Tabs from the palette, favorites, and links sent by other apps use the default engine; tabs a page opens (popups and new-window links) use the opener's engine. The Settings default engine applies to new tabs at once instead of at the next launch. | high | `BrowserSession.swift`, `SessionStore.swift`, `Tab.swift`, `AppDelegate.swift`, `Preferences` | A session with one WebKit tab and one Chromium tab restores both; a popup opens in its opener's engine |
| I.12 | Switch a tab's engine: a site settings button at the right end of the address pill opens a popover with the tab's engine (WebKit or Chromium) and the default engine for new tabs. Switching replaces the tab's web contents with one from the other engine at the same address and keeps the tab's place, pin, space, and selection; the user can switch back at any time. Depends on I.11. | high | `Tab.swift`, `BrowserSession.swift`, `BrowserWindowView.swift` | A tab switches engines both ways from the popover and reloads its page in the chosen engine |
| II.6 | Moved here because I.13 needs it; see Phase II. | medium | | |
| I.13 | Shared cookies and sign-ins: copy cookies between the engines' stores so a site stays signed in across engines. Copy every cookie into the target engine before a tab switches engines and before the first tab of an engine loads; copy WebKit changes to Chromium as `WKHTTPCookieStoreObserver` reports them, and Chromium's cookies to WebKit after a Chromium page finishes loading. Local storage and IndexedDB stay per engine. Depends on I.11 and II.6. | high | `BrowserSession.swift`, a new cookie sync type in `Browsing`, `ChromiumEngine.swift`, `WebKitEngine.swift` | After signing in on one engine, the same site in a tab of the other engine is signed in |

### Phase II: Chromium engine gaps

These tasks extend `BridgeClient` in `CEFBridge.mm`, the `ARCHCEFBrowserDelegate` protocol in `CEFBridge.h`, and `ChromiumWebContents`. Add one bridge callback per feature and keep the C++ API inside the bridge.

| ID | Task | Reasoning | Files | Done when |
|---|---|---|---|---|
| II.1 | JavaScript dialogs: implement `CefJSDialogHandler` (`OnJSDialog`, `OnBeforeUnloadDialog`, `OnResetDialogState`) and forward to the UI delegate's dialog methods from I.3. Keep the callback alive until the sheet answers. Closing a tab runs its `beforeunload` handlers through `TryCloseBrowser` so the leave-page sheet can keep it open. | high | bridge, `ChromiumEngine.swift`, `BrowserSession.swift` | The page dialog sheets appear on the Chromium engine; a `beforeunload` page asks before its tab closes; a dialog cancelled by navigation closes |
| II.2 | HTTP authentication: implement `CefRequestHandler::GetAuthCredentials`, forward as a `URLAuthenticationChallenge`-shaped request (host, realm, scheme), and answer with the credential from a sheet (user name and password fields, no storage). | high | bridge, `ChromiumEngine.swift`, `Tab.swift` | A basic-auth test page prompts and loads |
| II.3 | External protocols and link routing: implement `CefRequestHandler::OnProtocolExecution` for schemes the engine cannot load, and in `WebKitDelegateBridge.decidePolicyFor` treat non-`http`, `https`, `file`, `about`, `data`, and `blob` schemes the same way. Route through `canNavigateExternallyTo` and `showExternalProtocolDialogFor` in `Tab`: a sheet "Open <app> for <scheme> links?" then `NSWorkspace.shared.open`. | high | bridge, `WebKitDelegateBridge.swift`, `Tab.swift` | `mailto:` opens Mail after confirmation on both engines; the page does not navigate |
| II.4 | Context menus: implement `CefContextMenuHandler::OnBeforeContextMenu` and `RunContextMenu` with an `NSMenu`; on WebKit override `willOpenMenu(_:with:)` on a `WKWebView` subclass. Build the menu in `Tab` through `willShowContextMenuFor`: Back, Forward, Reload; Open Link in New Tab, Copy Link; Open Image in New Tab, Copy Image Address; Copy; Inspect Element when DevTools exist (II.7). | high | bridge, `ChromiumEngine.swift`, `WebKitEngine.swift`, `Tab.swift` | Right-click shows the same menu on both engines |
| II.5 | Back-forward list on Chromium: visit `GetNavigationEntries` and expose it as `EngineBackForwardList`; `go(to:)` uses the entry index. Add the recent entries to the History menu for both engines. | medium | bridge, `ChromiumEngine.swift`, `AppDelegate.swift` | History menu lists the last ten entries and selecting one navigates |
| II.6 | Cookies on Chromium through the global `CefCookieManager` (visit, set, delete) so `allCookies`, `setCookie`, and `removeCookie` work. | medium | bridge, `ChromiumEngine.swift` | After a login, `allCookies` returns the site's cookies |
| II.7 | DevTools: `CefBrowserHost::ShowDevTools` in its own `NSWindow`, exposed as `EngineDevTools`; on WebKit set `isInspectable` and open Web Inspector. Add View ▸ Developer ▸ Show Developer Tools (⌥⌘I). | medium | bridge, `ChromiumEngine.swift`, `WebKitEngine.swift`, `AppDelegate.swift` | The shortcut opens tools on both engines |
| II.8 | Find counts on WebKit: `find(_:configuration:)` reports only whether a match exists. Count matches with an injected script (walk text nodes, case-insensitive) and keep the active ordinal in the adapter. | medium | `WebKitEngine.swift` | The find bar shows "n of m" on WebKit |
| II.9 | Page fullscreen: `CefDisplayHandler::OnFullscreenModeChange` → `didRequestEnterFullscreen`/`didRequestExitFullscreen`; on WebKit enable `isElementFullscreenEnabled` and observe `fullscreenState`. The session hides the sidebar and toggles the window's full screen. | medium | bridge, `WebKitEngine.swift`, `BrowserSession.swift`, `BrowserWindowView.swift` | A video's fullscreen button fills the screen and Escape returns |
| II.10 | Theme color on Chromium: no CEF API, and `executeJavaScript` returns no value on this engine. Evaluate the `meta[name=theme-color]` content through the DevTools `Runtime.evaluate` method with the message observer the bridge already uses for screenshots, then publish through `webContentsDidChangeThemeColor`. | medium | bridge, `ChromiumEngine.swift` | `themeColor` is set for a page that declares one |
| II.11 | Page state restore: store `WKWebView.interactionState` per tab in `session.json` and restore it; on Chromium store the navigation entry URLs and index from II.5 and restore by loading the current entry (CEF has no history injection). Version the snapshot. | high | `SessionStore.swift`, `Tab.swift`, `WebKitEngine.swift`, `ChromiumEngine.swift` | A restored WebKit tab keeps its back list; a restored Chromium tab opens its last URL |
| II.12 | Audible state: evaluate `CefAudioHandler` (it captures the stream, which is too heavy) against a Media Session script that reports `playing` through `CefMessageRouter`; WebKit has no public API. Record the outcome and implement the script route if it works. | high | bridge, `ChromiumEngine.swift` | The sidebar can show a speaker icon on a playing tab, or the row documents why not |

### Phase III: Sidebar and windows

| ID | Task | Reasoning | Files | Done when |
|---|---|---|---|---|
| III.1 | Sidebar hover reveal and width: when hidden, a hot zone at the left edge shows the sidebar as an overlay until the pointer leaves; ⌘S keeps toggling; the width is draggable between 200 and 400 points and saved in `UserDefaults`. | medium | `BrowserWindowView.swift`, `BrowserSession.swift` | Row 1 complete |
| III.2 | Space management: rename inline (double-click the name), choose tint and symbol from a popover, delete (its tabs move to the previous space), reorder in the switcher. | medium | `Space.swift`, `BrowserWindowView.swift`, `BrowserSession.swift` | Row 2 complete |
| III.3 | Folders: a folder groups open tabs inside a space, collapses, renames, and persists. Add a `folderID` to the tab record and a `folders` list to the snapshot with a schema version. | high | `Tab.swift`, `Space.swift`, `SessionStore.swift`, `BrowserSession.swift`, `BrowserWindowView.swift` | Row 4 complete; an old `session.json` still loads |
| III.4 | Drag and drop: reorder tabs, pinned tabs, and favorites by drag; drop a URL, text, or file onto the sidebar to open it; drag a tab onto a space symbol to move it. Use SwiftUI `onDrag`/`onDrop` with `NSItemProvider`. | medium | `BrowserWindowView.swift`, `BrowserSession.swift` | Row 18 complete |
| III.5 | Split view: two to four panes in the page area, each showing one tab; add a pane with ⌘⌥= or by dropping a tab on the page; the pane under the pointer is the selected tab for the address pill and find bar; the layout persists per space. | high | `Browsing` | Row 5 complete |
| III.6 | Multiple windows: make spaces, tabs, and favorites app-wide; a window owns only its selected tab, sidebar state, and frame; ⌘N opens a window; windows restore from `session.json`; add the Window menu. Do this before III.7. | high | `Arch`, `Browsing` | Row 7 complete |
| III.7 | Small window: a compact window without a sidebar for links sent by other apps while Arch is not active; "Move to Main Window" and a shortcut; preference to turn it off. | medium | `Arch`, `Browsing` | Row 6 complete |
| III.8 | Tab switcher overlay (⌃Tab) in most-recent order, and a tab close log (user, page, archive, crash) shown in a debug window. | medium | `BrowserSession.swift`, `BrowserWindowView.swift`, `AppDelegate.swift` | Row 8 complete |
| III.9 | Window appearance: an automatic theme that follows the system appearance and accent color; sidebar text contrast on strong tints; per-space theme choice. | low | `BrowserWindowView.swift`, `Preferences` | Row 10 complete |
| III.10 | Home, badges, tooltips: a per-space home page opened with ⌘⇧H, a badge on tab rows for audio (after II.12) and unread popups, and tooltips with the full title and URL. | low | `BrowserWindowView.swift`, `Space.swift` | Row 34 complete |
| III.11 | Previews: hold the pointer on a favorite or a link with ⇧ to show a floating preview panel backed by a secondary web contents, with Open in Tab. | medium | `Browsing` | Row 19 complete |
| III.12 | Profiles: one engine context per profile and a profile per space. WebKit uses `WKWebsiteDataStore(forIdentifier:)`; Chromium needs a `CefRequestContext` with its own cache path in the bridge. | high | engines, bridge, `Browsing` | Row 9 complete; two spaces with different profiles keep separate logins |

### Phase IV: Navigation and content

| ID | Task | Reasoning | Files | Done when |
|---|---|---|---|---|
| IV.1 | Site search: keyword shortcuts (for example `yt`) in a JSON file under Application Support, a "Search <site> for …" row in the palette, and a Settings list to edit them. | medium | `CommandPaletteView.swift`, `BrowserSession.swift`, `Preferences` | Row 12 complete |
| IV.2 | Zoom: ⌘+, ⌘-, and ⌘0 in the View menu with a zoom level remembered per host. | low | `AppDelegate.swift`, `BrowserSession.swift` | Row 14 complete |
| IV.3 | Shortcuts: a Settings list of commands with recorded shortcuts applied to the menu items from `UserDefaults`, and one global shortcut (default ⌥Space) that opens the new-tab palette from any app through `NSEvent.addGlobalMonitorForEvents` after the accessibility prompt. | medium | `AppDelegate.swift`, `Preferences` | Row 13 complete |
| IV.4 | Capture: View ▸ Capture Viewport and Capture Full Page save PNG files to a captures folder and reveal them; region capture crops the viewport capture through a drag overlay. | medium | `AppDelegate.swift`, `Browsing` | Row 22 complete |
| IV.5 | Printing through the system panel on both engines: `createPDF` → `PDFDocument` → `NSPrintOperation`; File ▸ Print (⌘P) and Export as PDF. | medium | `AppDelegate.swift`, `BrowserSession.swift` | Row 25 complete |
| IV.6 | Site permission store: remember allow and deny per origin and type in `permissions.json`, apply it before showing the sheet from I.2, and add Settings ▸ Websites to review and reset. | medium | `Browsing`, `Preferences` | Row 26 complete |
| IV.7 | History window (⌘Y): visits grouped by day with search, row deletion, and range clearing on top of `HistoryStore.entries(since:)`. | medium | `History`, `Arch` | Row 29 history part complete |
| IV.8 | Site data: Clear Site Data for the current site on both engines (`WKWebsiteDataStore.removeData`; Chromium through cookie deletion plus the DevTools `Storage.clearDataForOrigin` method). | medium | engines, `AppDelegate.swift` | Row 29 complete |
| IV.9 | Translation: on macOS 15, `TranslationSession` over the page's visible text, written back through an injected script that replaces text nodes; needs verification of the framework from AppKit. | high | `Browsing`, engines | Row 24 complete or documented as unsupported |
| IV.10 | Ad and tracker blocking: WebKit compiles a converted EasyList subset into `WKContentRuleList`; Chromium matches requests in `CefResourceRequestHandler::OnBeforeResourceLoad` with a domain and path-prefix matcher written in the bridge (no third-party library); a per-site toggle. | high | engines, bridge, `Preferences` | Row 23 complete |
| IV.11 | Media controls: Now Playing through `MPNowPlayingInfoCenter` fed by an injected Media Session script, media keys through `MPRemoteCommandCenter` that call play and pause in the page; picture-in-picture is built into WebKit and waits for Phase VI on Chromium. | high | engines, `Browsing` | Row 20 complete except Chromium PiP |

### Phase V: Creation, sharing, and settings

| ID | Task | Reasoning | Files | Done when |
|---|---|---|---|---|
| V.1 | Share: `NSSharingServicePicker` with the page URL from a sidebar button and File ▸ Share. | low | `BrowserWindowView.swift`, `AppDelegate.swift` | Row 32 complete |
| V.2 | Site customizations: per-host CSS and JavaScript files under Application Support, applied when a page of that host finishes loading, with an editor window and a per-site toggle. | medium | `Browsing`, new `Customizations` module | Row 30 complete |
| V.3 | Notes: a tab kind that edits a local Markdown file in a `TextEditor`, listed in the sidebar like a tab and saved in the snapshot as a `note:` URL. | medium | `Browsing`, new `Notes` module | Row 31 complete |
| V.4 | Import: bookmarks from Netscape HTML, Chrome JSON, and Safari plist into favorites; history from Chrome and Safari SQLite into `HistoryStore`; passwords are left to Apple Passwords. | medium | new `Import` module, `Preferences` | Row 33 complete |
| V.5 | Notifications: verify whether CEF Alloy delivers the Notification API; WebKit has no public API. Document the outcome, and post local notifications for finished downloads through `UserNotifications`. | low, `high` if engine work follows | `Browsing`, docs | Row 40 documented |
| V.6 | AppleScript: an `sdef` with `open location`, the current URL and title, and the tab list, backed by `NSScriptCommand`. | medium | `Arch` | Row 41 complete |
| V.7 | App icon and sounds: Settings ▸ Appearance icon choice from `resources/assets` alternatives through `NSApplication.applicationIconImage`; a sound on download completion through `NSSound`. | low | `Preferences`, `AppDelegate.swift` | Row 42 complete |
| V.8 | Preferences sections: General (default browser, search engine, downloads folder, ask where to save), Sidebar (archive delay), Shortcuts, Appearance, Websites. | medium | `Preferences` | Row 36 complete |
| V.9 | Sync: write a design note first (CloudKit private database, one record type each for spaces, favorites, tabs, and settings, last-writer-wins per record), then implement behind a toggle. | high | docs, new `Sync` module | Row 35 complete |
| V.10 | Document the omitted rows (37, 38, 43, 46, 47) as complete by omission and record the outcome for extensions (44) and DevTools (45). | low | `docs/features.md` | Rows updated |

### Phase VI: Engine source build

| ID | Task | Reasoning | Files | Done when |
|---|---|---|---|---|
| VI.1 | Build CEF from source on a Mac with enough disk space and evaluate Chrome style for extensions. | high | outside this repository | A patched framework builds and runs the app |
| VI.2 | Picture-in-picture through AVKit for the Chromium engine (`AVPictureInPictureController` fed from decoded video frames) in the patched build. | high | bridge, `ChromiumEngine.swift` | Row 20 complete |

## Decisions

- History visits: one visit per page change per tab. A reload, a repeated load of the same URL in the same tab, and the initial load of a restored tab do not add visits. The palette ranks by visit count, so pages that reload often would otherwise crowd out typed destinations. A hash change counts as a visit because its address is one the user may revisit.
- Permissions and dialogs default to the safe answer in the protocol: deny and dismiss. Feature code shows the user interface.
- Downloads save to the downloads folder with an unused name; a save panel appears only when the profile asks for a location.
- Chromium keeps its own JavaScript dialogs and context menus until Phase II replaces them.
- Engine choice is per tab. A tab opened by a page inherits that page's engine; other new tabs use the default engine; the user can switch a tab's engine at any time. Cookies are shared by copying between the engines' stores; site storage such as local storage stays per engine.
