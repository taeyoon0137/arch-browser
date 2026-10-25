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

A folder with `plugin.json` is a script plugin. A folder with a `manifest.json` that has `manifest_version` 3 is a web extension. Arch refuses other folders, manifests with an `apiVersion` higher than the app supports, and manifest keys it does not read (see Keys the script runtime reads).

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
      { "id": "panel", "title": "Reading", "symbol": "book", "panel": "panel.html" }
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
| `id` | Reverse-DNS identifier, at most 128 characters of letters, digits, `-`, and `.`. Arch lowercases it, so identifiers that differ only in case name one plugin and one folder. A later install with the same `id` in the same Persona is an update |
| `apiVersion` | The plugin API version the package targets. The app supports versions up to `PluginManifest.apiVersion` |
| `permissions` | Capabilities from the permission table below |
| `sites` | Match patterns (see below) for the pages the plugin's page scripts and page calls may reach |
| `siteAccess` | `listedSites` (every page that matches `sites`) or `whenInvoked` (only the selected tab's site after the user runs one of the plugin's commands there) |
| `network` | Hosts the plugin may fetch from through `arch.net.fetch` |
| `events` | Events that start the plugin's background code |
| `background` | The background script. A plugin without one can still add page scripts, settings, and panels |
| `contributes` | Commands, menu items, sidebar items, settings, a settings page, and page scripts |

Symbols use SF Symbols names, so plugins need no image files. A package may still carry an `icon` image for its Settings row.

### Keys the script runtime reads

The runtime reads `id`, `name`, `version`, `apiVersion`, `summary`, `permissions`, `sites`, and `background`, and these contributions:

| Key | Fields |
|---|---|
| `commands` | `id`, `title`, `symbol`, `keywords`, `shortcut` |
| `menus` | `command`, `location` (`pluginsMenu`, `pageContextMenu` with its `contexts`, `tabContextMenu`, or `spaceMenu`), `title` |
| `sidebarItems` | `id`, `title`, `symbol`, `command` |
| `settings` | `key`, `title`, `help`, `type` (`toggle`, `text`, `number` with optional `min` and `max`, `choice` with its `options`, or `secret`), `default` (false, empty text, the minimum or 0, or the first option when missing; none for a secret) |
| `pageScripts` | `matches`, `excludes`, `js`, `runAt` (`documentStart`, or `documentEnd` by default), `allFrames` |

- Arch refuses every other key until the step that builds it reads it, such as `siteAccess`, `network`, `events`, a sidebar item's `panel`, `settingsPage`, a command's `takesArgument`, a page script's `css`, and `icon`, so that a plugin never runs without a field it relies on. A key with `null` counts as missing. `permissions` takes the permissions that `PluginPermission` has.
- Commands need a background script. Menu items and sidebar items name listed commands. Command and sidebar item identifiers and setting keys are unique.
- A path names a regular file of the package: names separated by `/`, none of them empty, `.`, or `..`, and no link that leads out of the package. Each file in a page script's `js` becomes a page script of its own with the entry's patterns and timing; it must be UTF-8 text that parses as a function body on its own, which the review checks as the index does.
- A refusal throws `PluginError.invalidPackage` with a sentence that names the field, such as `plugin.json: contributes.menus[0].command names “b”, which contributes.commands does not list.`

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

### Shortcuts

A command's `shortcut` joins modifiers and a key with `+`, such as `ctrl+opt+r`.

| Part | Rule |
|---|---|
| Modifiers | `ctrl`, `opt`, `shift`, and `cmd`, each at most once and in any order |
| Key | Last: one printable ASCII character other than `+`, such as `r` or `/`, or `plus`, `space`, `up`, `down`, `left`, `right`, or `f1` to `f20` |

- Case does not matter, so `R` names the same key as `r`; Shift counts only as `shift`.
- A shortcut needs `cmd` or `ctrl` unless its key is a function key, so that typing never runs a command, as the app's own menu commands require.
- Text that breaks these rules throws `PluginError.invalidShortcut` with the text.

## Contributions

Each contribution names its plugin wherever it appears: in the palette row's subtitle, in the menu item's section, in the sidebar item's tooltip, and in the Settings section. Identifiers belong to the plugin, so two plugins can use the same command `id`.

| Contribution | Where it appears | Notes |
|---|---|---|
| Command | The command palette, after the primary row and before history suggestions, when the typed text matches the title or a keyword; Settings ▸ Shortcuts, through its Plugins menu item | Menu items and sidebar items run commands too. A command with `takesArgument` shows its title as a token in the palette field and receives the text the user types after it |
| Shortcut | The command's item in the Plugins menu, which a command with a shortcut gets after the plugin's own items when its manifest lists none, or the first of its items there | Settings ▸ Shortcuts lists the item under Plugins with the plugin's name, and the user can change the shortcut there. App shortcuts take priority over plugin shortcuts, and between plugins the first installed keeps a shortcut: a command goes without its default shortcut while an app command, a command the user gave it, or an earlier plugin's command has it, and without the shortcut the user gave it while an app command or an earlier plugin's command the user gave it has it, since the user may have chosen the two while the menu, such as another Persona's, showed only one of them. Its row in Settings ▸ Shortcuts names that command |
| Menu item | A Plugins menu in the menu bar, before the Window menu, for the active window's Persona; the page context menu, after the app's items, when the click is on one of the listed contexts (page, link, image, selection, editable); a tab row's context menu and the space menu, after their items | In each menu, a plugin's items form a section under the plugin's name. A click is on `page` when it is on no link, image, media, selection, or field. Page context menu items run app-side, so they work alike on both engines, as row 49 requires. The command runs on the active window's selected tab from the Plugins menu, on the page's tab with the link, image, and selected text from the page context menu, on the row's tab from a tab row, and on the window's selected tab with the space from the space menu. The window's selected tab reaches a command only while it belongs to the plugin's Persona and no internal page or preview panel covers its page |
| Sidebar item | A row below the favorites with a symbol, a title, and the badge the plugin sets | It runs a command on the window's selected tab or opens a panel. A script plugin's item runs a command until script plugin panels exist |
| Panel | A popover beside the sidebar item | A built-in plugin's panel is the view controller that `Plugin.panel(for:)` returns, which the manager asks for each time the item opens it. The popover lets it go when it closes, and a click on the item while the panel shows closes it. A script plugin's panel will use one of its HTML files in a sandboxed web view. A panel that takes the sidebar's place, as the library does, can follow once a plugin needs one |
| Settings | Settings ▸ Plugins ▸ the plugin's name, rendered by Arch as a native form | Toggle, text, number, choice, and secret fields. Values go to the plugin's storage and secrets to the Keychain (see Storage). A script plugin will be able to add an HTML settings page below the form |
| Page script | Pages that match the plugin's grant, on both engines | See Page scripts |
| Event | Not shown | `tabOpened`, `tabClosed`, `tabSelected`, `pageLoaded`, `downloadFinished`, `spaceChanged`, `settingChanged` |

## Page scripts

A page script is a JavaScript or CSS file from the plugin's package, or JavaScript in a built-in plugin's manifest, that runs in the pages its grant covers. Arch wraps each script in a guard that checks the frame's address against the script's patterns and the plugin's granted sites, then runs the script as the body of a function with its world's channel as `arch`. The guard reads the document's `location`, whose properties a page cannot replace, and applies the rules of Match patterns through a JavaScript copy of `MatchPattern.matches(_:)`. The copy calls no built-in function and reads only own properties, so a page that replaced built-ins before the guard runs cannot change its answer. A script's source must parse as a function body on its own, as the `Function` constructor reads one. JavaScriptCore checks this without running the source, and Arch leaves out a script that fails, so no source can close the function it runs in and run outside the guard. Engines only need to inject scripts; they do not need to match addresses. Each plugin has its own world name, `ARCHPlugin.<plugin id>`.

- WebKit: each script becomes a `WKUserScript` in the plugin's `WKContentWorld.world(name:)`, so the page and other plugins cannot see its globals. Messages from the script go through a `WKScriptMessageHandlerWithReply` added only to that world. Arch reaches the script with `evaluateJavaScript(_:in:in:)` in the same world. Style files go through the existing `insertStylesheet`. A page that a tab opens uses the tab's content controller, so the two share one script list.
- Chromium: CEF 156's public API has no isolated worlds (needs verification). The app passes the scripts to the renderer in `extra_info` when it creates the browser, and in a process message to each frame when they change and to each frame created after a change. CEF does not order that message before the frame's first document. In a renderer process that had none of the browser's frames, such as after a cross-site navigation, the first document may therefore still run the scripts the browser was created with, such as a disabled plugin's (needs verification). The helper's `CefRenderProcessHandler::OnContextCreated` runs them in the page's main world before the page's own scripts. A native function made with `CefV8Value::CreateFunction` carries messages to the browser process as `CefProcessMessage`s. The helper passes it to each world's channel script as an argument, so it never reaches `window`. The channel keeps it, its delivery functions, and the built-ins it calls in a closure. The helper makes each document's channel opener before the page's scripts run, so a channel that `executeJavaScript(_:inWorld:completion:)` opens after the page has run still calls the built-ins as they were before the page ran. Document-end scripts wait for `DOMContentLoaded`.
- The Chromium difference: the page can see what a plugin's script changes in the DOM and can replace built-ins and DOM methods the script calls later. Through them the page can also see the values the script sends and receives. For example, a `then` getter on `Object.prototype` receives each object or array reply, because a promise reads `then` when it settles with one. A plugin therefore sends a Chromium page script only what the page may see. The channel's closure stays private, so the page cannot send through the channel unless the script hands it over. Plugins treat pages as untrusted on both engines. The app treats every page script message as page input. The difference therefore affects plugin reliability and what a plugin can keep from the page, not app safety. A CEF patch that adds isolated worlds can join Phase VI if a plugin needs one.
- With `listedSites`, the scripts join every matching tab's script list. With `whenInvoked`, the host runs them in the selected tab's current page through `executeJavaScript(_:inWorld:completion:)` when the user runs one of that plugin's commands there. They stay in that tab's list until it leaves the site.
- Scripts change from the next document a tab loads. Enabling a plugin does not reload open pages; Settings offers Reload Matching Tabs. Disabling a plugin closes its message channel at once. Running scripts cannot reach it and stop at the next load.
- The session gives each web contents it creates for a tab the page scripts of its Persona's enabled plugins, because Chromium receives them only with the browser it creates. A tab also takes its Persona's scripts when it joins the session, since a page that another page opens, such as one the preview panel opens, starts with that page's scripts. When the scripts change, every tab of the Persona takes them. Values the scripts send reach `PluginManager.receive(_:from:)` through their tab, which counts as selected while a window selects it.
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

- Installation shows a sheet that states each permission in a plain sentence, such as "Read the titles and addresses of your tabs" or "Run scripts on pages from example.com", with a switch for each site, so the user can leave sites out before installing. Once site access modes exist, the user can also switch `siteAccess` to `whenInvoked`, and a manifest that asks for all sites starts with `whenInvoked`; until then an installed plugin's page scripts run in every page its granted sites cover. The result is the plugin's `PluginGrant`, which never exceeds what the manifest asks for.
- Granting access to all sites or `nativeMessaging` asks for Touch ID through LocalAuthentication, following the Platform integration table.
- Settings ▸ Plugins lists each grant and revokes any part of it. Calls that need a revoked permission get `permissionDenied`. Contributions that need it are hidden.
- An update shows the sheet again, with the permissions and sites that the installed version did not ask for marked New. A site that the installed version asked for starts as the user left it, and a new site starts on. The new grant keeps only what the new manifest asks for, so an update that asks for less narrows it.
- Built-in plugins declare permissions the same way. The app does not sandbox their code, but `PluginContext` checks their grant like any other. Settings shows the grant, and the user can switch the plugin off.
- A plugin never sees cookies, passwords, or API keys. Its fetches carry no Persona cookies, so a plugin cannot act as the user on a site. Site data stays in the engines.

## Sandboxing

- Built-in plugins run in the app process. They are trusted, reviewed with the app, and limited to `PluginContext` by convention.
- Script plugins run their background script in a hidden `WKWebView` owned by the `Plugins` module. The code runs in a separate WebKit web content process, regardless of the tabs' engine:
  - Its documents load from `arch-plugin://<plugin id>/` through a `WKURLSchemeHandler` that serves only the installed package. The root of that origin is a document the handler writes, which runs the background script as a classic script; every other path is a package path, and other hosts and paths that name no file of the package get 404.
  - Every response carries the content security policy `default-src 'self'`, which limits scripts, styles, and connections to the package and allows neither inline code nor `eval`. Network access goes through `arch.net.fetch`, which the host checks against the grant's hosts.
  - A `WKContentRuleList` blocks every load outside the plugin's scheme as a second layer.
  - Neither the policy nor the rule list covers WebRTC, whose connections would reach any host. The web view runs in Lockdown Mode (`WKWebpagePreferences.isLockdownModeEnabled`), which takes WebRTC away from its documents and their frames, and with it other web technologies such as JIT compilation, WebAssembly, and WebGL. Whether DNS prefetching and `preconnect` links can still reach a host outside the scheme needs verification.
  - Each plugin uses its own `WKWebsiteDataStore.nonPersistent()`, so it shares no cookies or site storage with any Persona or plugin. Its lasting state goes through `arch.storage`.
  - The bridge is a `WKScriptMessageHandlerWithReply` on that web view only. A user script defines `arch` in the page's world at the start of each document, and the app hands the background script commands and page script values through `callAsyncJavaScript`. The host identifies the calling plugin by the sending web view, never by the message.
  - Panels and HTML settings pages use the same configuration and bridge.
- Web extensions run in the engines' own extension sandboxes: WebKit's for `WKWebExtensionController`, Chromium's for CEF's extension runtime.
- Hangs and crashes: a background is hung if it leaves its start (the load of its document), an event, a command, or a page message unanswered for 10 seconds. The host releases its web view (whether WebKit then ends the process at once needs verification), fails the calls that wait for it, and starts it again at the next event. `webViewWebContentProcessDidTerminate` reports crashes the same way. WebKit fails at once a call whose promise nothing can settle any more, so only a promise that stays pending or a script that keeps running counts as hung. After three failures within five minutes, the host disables the plugin. Its Settings row says why until the user switches it on again, during that run.
- Resources: a background starts at its first event, command, or page message and stops after 30 seconds without work. Its badges stay. A panel's web view lives only while the panel is open.

## Lifecycle

| State | Meaning |
|---|---|
| `disabled` | Installed; no contributions show and no code runs |
| `idle` | Enabled; contributions show, page scripts inject, no background runs |
| `running` | Enabled with its background or panel running |
| `failed` | Disabled by the host after repeated failures, with the reason |
| `unavailable` | Cannot run on this system or engine, with the reason, such as a web extension below macOS 15.4 |

1. Stage: the user chooses a folder or archive with `NSOpenPanel` in Settings ▸ Plugins, or the composer (VII.7) hands over the files that AI wrote. Arch copies the folder, or writes the files, to `Staging/<UUID>/` in the Persona's folder, off the main thread, reads and validates the manifest, and lists the files. `ditto` extracts an archive and keeps every entry inside the destination; the package is the archive's top level or its only folder. A package that is or holds a symbolic link is refused, since a link could lead to files outside it, and so is one with a built-in plugin's identifier, or with `plugins.json` or `plugins.unreadable.json` as its identifier, since its folder would take that file's name in the Persona's folder. Nothing in the package runs before the user installs it. The manager clears `Staging/` when it starts.
2. Review: the install sheet shows the name, version, origin, permissions, sites, and files. For a plugin that AI wrote it also shows the requests it came from and every file's source, and offers Ask for Changes (`docs/ai.md`, Features that AI adds at run time).
3. Install: Arch moves the staged package into the Persona's plugin folder and records it in `plugins.json`. It is disabled unless the user chose Install and Enable. Cancel deletes the staged package.
4. Enable: Arch registers the contributions, adds the page scripts to the Persona's tabs from their next load, and sends `activate` when the background first starts.
5. Update: installing the same `id` again replaces the package after review and keeps the plugin's place, storage, and secrets. A running background stops, and the next use starts the new code.
6. Disable: Arch removes the contributions, closes page message channels, ends the plugin's context, sends `deactivate`, and stops the background.
7. Remove: after a confirmation, Arch stops the plugin and deletes its package, storage, and the Persona's Keychain items for it. Built-in plugins cannot be removed, only disabled.
8. Launch: each Persona's manager reads `plugins.json`, registers the built-in types, reads each installed plugin's manifest from its package, and shows enabled contributions. A package that no longer reads stays recorded but out of the list. Installed plugin code runs only when needed.

## Storage

```
~/Library/Application Support/Arch/Plugins/<persona id>/
  plugins.json                  Which plugins the user switched on or off, and the installed plugins with their origin, grant, and install date
  Staging/<UUID>/               A package under review
  <plugin id>/package/          The installed package (script and web extension plugins), which holds the manifest
  <plugin id>/storage.json      Key-value storage, written atomically after changes settle
  <plugin id>/storage.unreadable.json  The last storage.json that did not decode
```

- `<persona id>` is the Persona's UUID as `UUID.uuidString` writes it, so the default Persona's folder is `Plugins/D59DAF4B-E372-4AF9-890E-455B8B3860F3/`. The app gives `PluginManager` its Application Support folder, and the manager derives the Persona's folder from it.
- `storage.json` is a JSON object of the plugin's keys and `PluginValue`s, up to 5 MB (5,000,000 bytes) per plugin, counted as the UTF-8 bytes of each key plus the JSON of its value. A write that grows the storage past the limit throws `quotaExceeded`; the limit never refuses removals and writes that do not grow it. A value JSON cannot hold, such as infinity or arrays and objects nested more than 510 levels deep, throws an encoding error, so every value the storage accepts reaches the file. Settings values live in the same file under keys that start with `arch.setting:`, which the plugin's own keys cannot use: `PluginStorage` throws `PluginError.reservedKey` for them, reads none, and leaves them out of `allKeys()`. A stored setting value that does not suit its field, such as an option a newer version no longer offers, reads as the default.
- `plugins.json` is `{"choices": [{"id": "<plugin id>", "isEnabled": false}], "installed": [{"id": "<plugin id>", "source": "file:///…/Sample.zip", "grant": {"permissions": ["clipboard"], "sites": ["https://example.org/*"]}, "installedAt": 814595493.0}]}`. A plugin that AI wrote has `"generated": {"requests": ["…"], "model": "…"}` in place of `source`: the request and each change the user asked for, and the model that wrote its last version as Settings ▸ AI named it. The choices are in the order the user made them; a new choice for a plugin replaces its old one. A built-in plugin without a choice follows `BuiltInPlugin.isOnByDefault`, and an installed one is off. The installs are in the order the user installed the plugins; an update keeps its place. `installedAt` is the default `Date` encoding, seconds since 2001. The manifest stays in the package, so the grant cannot drift from it: the manager limits the recorded grant to what the package's manifest asks for. Each choice, install, and removal writes the file at once. An install entry that this build cannot read, such as one whose grant holds a permission that a newer build added, stays in the file as it is and out of the list; installing a plugin with its identifier replaces it. A file that does not decode moves to `plugins.unreadable.json`, as `storage.json` does.
- Changes reach `storage.json` together 0.5 seconds after the last one, and at quit. A missing file counts as empty. A file that does not decode moves to `storage.unreadable.json`, replacing an older one, and the plugin starts empty, so its first change does not overwrite the old data. The manager keeps one storage per plugin while it runs, so a plugin that starts again after a failed activation finds the changes that have not reached the file.
- Secret settings and `arch.secrets` use Keychain Services: generic password items with the service `local.arch.browser.plugin.<plugin id>` and the account `<persona id>/<key>`, accessible when unlocked and not synchronizable, in the login keychain as the AI module's keys are. Settings ▸ Plugins shows only whether a secret is saved, which it reads without the secret, so macOS does not ask for the keychain password. Removing a plugin deletes the service's items whose accounts start with `<persona id>/`, which it finds by their attributes alone. A deleted Persona's items go at the next launch (see Personas).
- Web extensions keep their own extension storage in the engine: WebKit under the Persona's `WKWebExtensionController` configuration identifier, Chromium in the Persona's CEF cache path.
- Sync (V.9) does not cover plugins. A later task can sync `plugins.json` without packages or secrets.

## Personas

- Each Persona has one `PluginManager`. A plugin sees only its Persona's spaces, tabs, history, and downloads. It gets events only from them. A command therefore gets the window's selected tab only when the tab belongs to the plugin's Persona, so neither a favorite's tab of another Persona nor the selected tab under the menu of a space whose Persona differs from the tab's reaches it.
- The session creates a Persona's manager when a tab or window of the Persona first needs it (`BrowserSession.plugins(in:)`) and keeps it in the Persona's `PersonaEngines`. A window shows the contributions of its Persona, its current space's, which for a small window is its tab's, and runs its palette commands and sidebar items through that Persona's manager. A tab's page scripts and the plugin items of its page's and its row's context menus come from the tab's Persona, and those of a space's menu from the space's. The Plugins menu follows the active window's Persona, or the default one while no window is open. Settings ▸ Plugins shows one Persona's plugins, with a picker once there are two Personas, and installs plugins into that Persona. A review sheet still open when the user deletes its Persona closes without installing.
- Installing a plugin in two Personas creates two installations with separate grants, storage, secrets, and background processes. Once there are two Personas, Settings will offer Install in Another Persona, which copies the package and asks for a new grant; it is not built yet.
- Built-in plugins exist in every Persona. A new Persona enables the built-in plugins that are on by default.
- Deleting a Persona closes its manager (`close()`): its plugins leave the list, so their contributions go and nothing starts them again, their running instances stop, a script plugin's background web view with them, and their contexts stop acting, and storage changes that have not reached the files are dropped. The session then stops passing the manager's page scripts to tabs and drops it. At the next launch, before any engine starts, the removal pass calls `PluginManager.removeData(ofPersona:in:)`, which deletes the Keychain items of every plugin whose account starts with `<persona id>/` and then the Persona's `Plugins/<persona id>/` folder, with its installed packages and the packages left in `Staging/`. The Persona stays in `removedPersonaIDs`, and the engines keep its storage, until both are gone.

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
- 1Password's desktop app accepts a browser it does not list only when the browser is signed and installed in `/Applications`. The iCloud Passwords helper starts only for browsers on Apple's `apple/password-manager-resources` list. On Chromium both remain blocked on VI.1, as IV.13 records.
- Universal Autofill (⌘\\) reads the page's accessibility tree and is not a plugin matter; it needs II.13 on Chromium.
- Each plugin's Settings row shows whether its helper answered. A missing allow-list entry shows as a status instead of failing silently.

## AI hooks and plugins that AI writes

- The built-in AI hooks (VII.6) live in `Browsing`, not in plugins, because plugins have no events or `ai` permission yet: they subscribe to `pageLoaded` and `downloadFinished` at the AI interface's hook center directly. Naming a tab uses `renameTab`; renaming a download uses `renameDownload`. Once plugins have `ai`, a plugin with `ai` that declares hooks will register with the same center under its own feature.
- The plugin API has no other AI-specific part. A plugin with `ai` sends requests through the AI interface (VII.1), which applies the routing table and page data rules. The plugin never sees a provider or a key.
- The composer (VII.7, `docs/ai.md`) writes a script plugin only, never a built-in plugin or a web extension, with no sites or page scripts and with its background script as its only file, and stages its files with `PluginManager.stage(_:writtenBy:)` under an identifier that Arch gives it.
- A plugin that AI wrote uses the same review sheet, which also shows the requests it came from and every file's full source. Install installs it switched off and Install and Enable switched on, with the origin `generated`, and Settings says that AI wrote it.
- Ask for Changes in the review has AI write a new version with the same identifier, which replaces the one under review. Changing an installed plugin with AI, with a review of what changed, is not built yet. Removing a plugin that AI wrote works like removing any plugin.
- Script plugins load code only from their package, so only reviewed files run. A plugin can still act on data it fetches, so its `network` hosts will be part of the review.
- The composer gives the model a reference of the manifest keys that plugins AI writes may use and of the JavaScript API below, in `PluginComposerInstructions.swift`.

## Swift API

The `Plugins` module lives in `Packages/ARCH/Sources/Plugins` and depends on `ARCHEngine` and on `AI`, through which the composer writes plugins. `Browsing` and `Preferences` depend on it to show contributions. `Plugins` reaches tabs through `PluginBrowserHost`, which `Browsing` implements. This avoids a dependency loop. `Extensions` (IV.12) depends on `Plugins` and supplies the web extension runtime. All types below are public.

### Identity and manifest

```swift
public typealias PersonaID = UUID

public struct PluginID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    /// Fails for anything but letters, digits, `-`, and `.`, or more than 128 characters. Lowercases the letters.
    public init?(rawValue: String)
}

public enum PluginKind: String, Codable, Sendable {
    case builtIn, script, webExtension
}

public enum PluginOrigin: Hashable, Codable, Sendable {
    case bundled
    case file(URL)
    /// Written by AI through the composer (VII.7).
    case generated(PluginComposition)
}

public struct PluginComposition: Hashable, Codable, Sendable {
    /// The request, then each change the user asked for in the review.
    public var requests: [String]
    /// The model that wrote the last version, as Settings ▸ AI names it.
    public var model: String
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
    /// The permission as a plain sentence, such as "Read the titles and addresses of your tabs".
    public var summary: String { get }
}

public struct MatchPattern: Hashable, Codable, Sendable, CustomStringConvertible {
    public static var allSites: MatchPattern { get }
    /// `scheme://host/path` with `*` wildcards, or `<all_urls>`, under the rules in Match patterns. Throws `PluginError.invalidMatchPattern`.
    public init(_ pattern: String) throws
    public func matches(_ url: URL) -> Bool
    public var description: String { get }
    /// The sites in words, such as `example.com and its subdomains` or `every website`.
    public var siteName: String { get }
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
    /// What the review of an update to `manifest` offers at first: everything it asks for, except the sites that the installed version asked for and the user left out.
    public init(updating installed: InstalledPlugin, to manifest: PluginManifest)
    /// One plain sentence for each permission and site, as Settings and the install sheet state the grant.
    public var summaries: [String] { get }
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
    /// The shortcut of the command's first item in the Plugins menu. The user can change it in Settings ▸ Shortcuts.
    public var shortcut: PluginShortcut?
}

/// Written as Shortcuts describes, such as `ctrl+opt+r`.
public struct PluginShortcut: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Modifier: String, CaseIterable, Sendable {
        case ctrl, opt, shift, cmd
    }
    public let modifiers: Set<Modifier>
    public let key: String
    /// Throws `PluginError.invalidShortcut`.
    public init(_ text: String) throws
    public var description: String { get }
    /// The key equivalent and modifier mask of the command's menu item.
    public var keyEquivalent: String { get }
    public var modifierFlags: NSEvent.ModifierFlags { get }
}

public enum PluginPageContext: String, Hashable, Codable, Sendable {
    case page, link, image, selection, editable
}

extension Set where Element == PluginPageContext {
    /// The contexts of a click: its link, image, selected text, and field, or `page` where it has none of those and no media.
    public init(_ element: EngineContextMenuElement)
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

public struct PluginSidebarItem: Identifiable, Hashable, Codable, Sendable {
    public enum Action: Hashable, Codable, Sendable {
        /// Runs on the window's selected tab.
        case command(String)
        /// The panel that `Plugin.panel(for:)` returns, in a popover beside the row. Script plugin panels, a later step, add the package path of an HTML file.
        case panel
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
    public var matches: [MatchPattern]
    public var excludes: [MatchPattern]
    /// JavaScript, run as the body of a function with the plugin's page API as `arch`. The script runtime reads it from the package files that the manifest's `js` lists.
    public var source: String
    /// Package paths of style files.
    public var styles: [String]
    public var runAt: EnginePageScriptInjectionTime
    public var allFrames: Bool
}
```

### Plugins and the context

```swift
/// A running plugin in one Persona. Built-in plugins implement it in Swift; the runtimes implement it for installed plugins.
@MainActor
public protocol Plugin: AnyObject {
    /// Called when the plugin starts. The context acts until the plugin stops, before `deactivate()`; from then on its storage and secrets only read, its other actions throw `stopped`, and its badges do nothing.
    func activate(in context: any PluginContext) async throws
    func deactivate() async
    func run(_ command: String, _ invocation: PluginInvocation) async throws
    /// Receives only the events the manifest lists.
    func handle(_ event: PluginEvent) async
    /// A message from one of the plugin's page scripts. The returned value is the script's reply.
    func receive(_ message: PluginPageMessage) async throws -> PluginValue?
    /// The panel for a sidebar item whose action is `.panel`. The manager asks each time the item opens it.
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

/// The plugin's handle on the browser, scoped to one plugin instance in one Persona. Each call checks the plugin's grant and throws `PluginError.permissionDenied` or `.siteNotGranted` when it does not cover the call. Once the instance stops, the storage and secrets only read, the other calls that act throw `.stopped`, and badges do nothing.
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
    /// Set for space menu items: the space whose menu holds the item.
    public var spaceID: UUID?
    /// Set for page context menu items: what the user clicked on, which the plugin receives whatever its grant, since the user chose the item there.
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
    /// nil removes the key. Throws `quotaExceeded` past 5 MB, and `reservedKey` for a key of the plugin's settings.
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
    /// The plugin instance whose context the call went through has stopped.
    case stopped
    case invalidMatchPattern(String)
    case invalidShortcut(String)
    /// A storage key that starts with `arch.setting:`, the prefix of the plugin's settings.
    case reservedKey(String)
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
    /// nil for a built-in plugin.
    public var installedAt: Date?
    /// Why the manager switched the plugin off after repeated failures in this run, which Settings shows. IV.12 adds why a web extension is unavailable.
    public var failure: String?
}

/// A validated package, staged for the review sheet or installed.
public struct PluginPackage: Identifiable, Sendable {
    public let manifest: PluginManifest
    public let rootURL: URL
    /// The folder or archive the user chose, or how AI wrote the package.
    public let origin: PluginOrigin
    /// Package-relative paths, shown in the review.
    public let files: [String]
    /// A file's text, which the review of a plugin that AI wrote shows.
    public func text(of path: String) -> String?
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

/// A menu item as a menu shows it: its command, the item's title or the command's, and the command's shortcut, which the Plugins menu gives the item.
public struct PluginMenuEntry: Hashable, Sendable {
    public let command: PluginCommandRef
    public let title: String
    public let shortcut: PluginShortcut?
}

/// One plugin's items at a menu location, which the menu shows under the plugin's name.
public struct PluginMenuSection: Hashable, Sendable {
    public let pluginName: String
    public let items: [PluginMenuEntry]
}

/// The contributions of the enabled plugins, in the order the manager registered them. Menu items and sidebar items whose commands the manifest does not list are left out.
public struct PluginContributionIndex: Sendable {
    public func paletteCommands(matching text: String) -> [Attributed<PluginCommand>]
    public var sidebarItems: [Attributed<PluginSidebarItem>] { get }
    /// For the page context menu, `location` names the contexts of the click, and an item shows when it lists one of them.
    public func menuSections(at location: PluginMenuLocation) -> [PluginMenuSection]
    /// The page scripts, wrapped with their address guards, for every tab of the Persona.
    public var pageScripts: [EnginePageScript] { get }
}

/// Runs installed plugins of one kind in one Persona. `Plugins` provides the script runtime; `Extensions` provides the web extension runtime. While the script runtime is the only one, the manager makes script plugins itself; IV.12 adds this protocol with the second runtime.
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
    /// Writes the files of a plugin that AI wrote, by package path, into staging and validates them.
    public func stage(_ files: [String: String], writtenBy composition: PluginComposition) async throws -> PluginPackage
    /// Deletes a staged package the user did not install.
    public func discard(_ package: PluginPackage)
    /// Records the package's origin with the install.
    public func install(_ package: PluginPackage, grant: PluginGrant, isEnabled: Bool) throws
    /// Records the choice in `plugins.json`. Switching a plugin off drops its contributions and badges and deactivates its running instance.
    public func setEnabled(_ isEnabled: Bool, for id: PluginID)
    public func setGrant(_ grant: PluginGrant, for id: PluginID) async throws
    public func remove(_ id: PluginID) throws

    public func run(_ command: PluginCommandRef, _ invocation: PluginInvocation) async
    /// Starts the plugin if needed and asks it for the item's panel. Nil, with a beep, when it offers none.
    public func panel(for item: Attributed<PluginSidebarItem>) async -> NSViewController?
    public func badge(on item: Attributed<PluginSidebarItem>) -> String?
    public func post(_ event: PluginEvent)
    /// Whether one of the enabled plugin's page scripts runs at `url`, for Reload Matching Tabs.
    public func pageScriptsCover(_ url: URL, of id: PluginID) -> Bool
    /// A message from a page script in `tab`, which the session describes in full; the manager removes what the grant does not cover. Returns the JSON reply, or nil.
    public func receive(_ message: EnginePageScriptMessage, from tab: PluginTab) async -> String?

    /// Stops the plugins for good when the user deletes the Persona, dropping storage changes that have not reached the files.
    public func close()
    /// At launch, deletes a deleted Persona's plugin secrets and folder. Reports whether all of it is gone.
    nonisolated public static func removeData(ofPersona persona: PersonaID, in directory: URL) -> Bool

    // Settings ▸ Plugins.
    /// The user's value or the default; nil for a secret setting.
    public func value(of setting: PluginSetting, for id: PluginID) -> PluginValue?
    /// nil restores the default.
    public func setValue(_ value: PluginValue?, of setting: PluginSetting, for id: PluginID) throws
    /// Reads only whether the Keychain item exists.
    public func hasSecret(_ setting: PluginSetting, for id: PluginID) throws -> Bool
    /// nil deletes the Keychain item.
    public func setSecret(_ secret: String?, of setting: PluginSetting, for id: PluginID) throws
}
```

### JavaScript API for script plugins

The runtime adds a bridge script to every plugin document to define `arch`. Each call is a promise that resolves with the Swift call's result or rejects with an `Error` whose message is the `PluginError` case name, such as `permissionDenied`, or `invalidCall` for a call the bridge cannot read or a value the storage cannot hold. The background script sets its listeners when it runs; a command without a listener fails. So far the bridge has `commands.onRun`, `pages.onMessage`, `storage`, `secrets`, `settings.get`, `ui.setBadge`, and `ui.copy`; the rest of the table joins as `PluginContext` gains its members.

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

- A command's listener receives `{tab, spaceId, linkUrl, imageUrl, selection}`, and a page message listener `{tab, frameUrl, isMainFrame, body}`; a tab is `{id, spaceId, title, url, engine, isPinned, isSelected}` with its identifiers as text, without what the grant does not cover. Absent values are left out. A page message listener's return value, or the value its promise resolves with, is the page script's reply.
- `storage.set(key)` without a value, or with `undefined`, removes the key; `storage.set(key, null)` stores `null`. `secrets.set(key)` and `ui.setBadge(itemId)` without text, or with `null`, delete the secret and the badge.

Page scripts get a smaller `arch` in their world: `arch.send(message)` resolves with the plugin's reply, and `arch.onMessage((message) => …)` receives `postMessage(_:toTab:)`.

## Engine protocol additions

V.11 adds these Tier 1 members, which both adapters implement. `docs/engine-protocol.md` records them.

```swift
public enum EnginePageScriptInjectionTime: String, Hashable, Sendable {
    case documentStart, documentEnd
}

public struct EnginePageScript: Hashable, Sendable {
    /// Scripts in one world share globals and one channel. WebKit gives each world its own `WKContentWorld`; Chromium runs every world in the page's main world.
    public var world: String
    /// A function expression that the engine calls with the world's channel: `channel.send(value)` returns a promise of the delegate's reply, and `channel.onMessage(listener)` receives posted values.
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
    /// The first call to `reply` settles the script's promise; a reply dropped without a call counts as nil.
    func webContents(_ webContents: any EngineWebContents, didReceive message: EnginePageScriptMessage,
                     reply: @escaping (String?) -> Void)
}

// EngineWebContentsConfiguration
public var pageScripts: [EnginePageScript]

// EngineWebContents
var pageScriptDelegate: (any EnginePageScriptDelegate)? { get set }
/// Replaces the scripts that run in each new document, from the next document on.
func setPageScripts(_ scripts: [EnginePageScript])
/// Calls a function expression with a world's channel in the main frame and returns the string it returns.
func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void)
/// Delivers a JSON message to the listeners of a world's channel in the main frame.
func postPageScriptMessage(_ json: String, toWorld world: String)
```

Chromium's `executeJavaScript(_:inWorld:completion:)` calls the function in the renderer and answers with a process message, like `readableContent`, because CEF's `ExecuteJavaScript` returns no value.

## Build order

1. `Plugins` module with the manifest, match patterns, storage, `PluginManager`, `BuiltInPlugin`, and a built-in sample plugin with one palette command; the palette shows plugin commands. This meets V.11's done condition.
2. Menus, shortcuts, sidebar items, panels for built-in plugins, and Settings ▸ Plugins in `Preferences`.
3. The engine page script members on both adapters, including the helper's renderer process handler on Chromium.
4. The script runtime with its sandboxed web view, scheme handler, bridge, install sheet, and lifecycle.
5. IV.12 builds the web extension runtime on WebKit as a `PluginRuntime`; VI.1 adds Chromium; IV.13 follows both.
6. VII.7 builds the composer on the staging and review path. The `ai` permission and plugin hooks on VII.6's hook center follow.

## Open decisions

- Isolation on Chromium: plugin page scripts share the page's main world until a CEF patch adds isolated worlds. The alternative is to run plugin page scripts on WebKit tabs only.
- Sandbox for script plugins: a hidden `WKWebView` per running plugin costs a web content process each. JavaScriptCore in the app process would cost less. It provides no process isolation, and its execution time limit is private API.
- One extension, two runtimes: each engine keeps its own copy of an extension's state and storage, so the user may unlock a password manager once per engine.
- Install sources: folders, `.zip`, and `.crx` files only. No direct installs from an online store.
- Plugin fetches carry no Persona cookies. A plugin that needs a signed-in site must use a page script on that site.
- Site access defaults to `whenInvoked` when a manifest asks for all sites.
- The 10-second hang limit, 30-second idle stop, and 5 MB storage limit are starting values.
