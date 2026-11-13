# Plugin system design

## Purpose and scope

- This note designs Arch's plugin system for queue task V.11 and rows 44 and 50 of `docs/features.md`. It also covers how the parts that build on plugins fit: web extensions, which run on WebKit and, through VI.1, on Chromium, the password manager plugins (IV.13, row 39), Personas (III.12), AI hooks (VII.6), and plugins that AI writes (VII.7, row 55).
- A plugin can add sidebar items, palette commands, menu items, keyboard shortcuts, settings, panels, and page scripts that run on both engines. Plugins have more capabilities than browser extensions. Each capability uses the app's own interface.
- Built-in plugins ship with the app. Later features can ship as built-in plugins and reach the browser only through the plugin API.
- Installed plugins belong to one Persona. Manifest V3 web extensions are one kind of installed plugin.
- Plugins use public APIs only. Nothing in this note needs a private API or a flag on `flags://`.

## Principles

- All plugin kinds call one API. Built-in, installed, and AI-written plugins call the Swift API defined by `PluginContext`. Script plugins reach it through a JavaScript bridge, and web extensions reach it through a manifest mapping. A plugin gains a capability only when `PluginContext` gains a member. The engine protocols follow the same rule.
- Declare first. A plugin's manifest lists its contributions, permissions, and requested events. Arch shows the contributions and starts the plugin's code only when one of them is used.
- Only built-in Swift plugins, which are part of the app, run in the app process. Installed code runs in a WebKit web content process or in an engine's own extension runtime.
- Only code the user reviewed runs. Script plugins load scripts only from their own package, and page scripts come only from package files.
- Arch runs no servers of its own and makes no automatic updates. Plugins come from the app bundle, user-selected files, the Web Store for web extensions (`docs/web-store.md`), or the AI feature (VII.7). An update is a reviewed new install of the same identifier.

## Plugin kinds

| Kind | Code | Where it runs | Supplied by | Persona |
|---|---|---|---|---|
| `builtIn` | Swift type in an Arch module, conforming to `BuiltInPlugin` | App process, main actor | The app bundle | Present in every Persona; enabled or disabled per Persona |
| `script` | Arch package: `plugin.json`, HTML, JavaScript, CSS | A hidden `WKWebView` per running plugin; page scripts in the tab's engine | A folder or `.zip` the user chooses, or VII.7 | Installed in one Persona |
| `webExtension` | Manifest V3 web extension package | `WKWebExtensionController` on WebKit tabs; the extension runtime of Arch's engine on Chromium tabs (VI.1) | A folder, `.zip`, or `.crx` file the user chooses, or the Web Store (`docs/web-store.md`) | Installed in one Persona |

A folder with `plugin.json` is a script plugin. A folder with a `manifest.json` is a web extension, which must have `manifest_version` 3. Arch refuses other folders. For script plugins, it refuses manifests with an `apiVersion` higher than the app supports and keys it does not read (see Keys the script runtime reads). Arch reads a web extension's manifest for what it shows and grants (see Web extensions as plugins), and the engines read the rest.

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
| `id` | Reverse-DNS identifier: two or more nonempty dot-separated labels of ASCII letters, digits, and `-`, at most 128 characters in all. Arch lowercases it, so identifiers that differ only in case name one plugin and one folder. A later install with the same `id` in the same Persona is an update |
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

- Arch refuses every other key until its implementation reads it, such as `siteAccess`, `network`, `events`, a sidebar item's `panel`, `settingsPage`, a command's `takesArgument`, a page script's `css`, and `icon`, so a plugin never runs without a field it relies on. A key with `null` counts as missing. `permissions` takes the permissions that `PluginPermission` has.
- Commands need a background script. Menu items and sidebar items name listed commands. Command and sidebar item identifiers and setting keys are unique.
- A path names a regular file of the package: names separated by `/`, none empty, `.`, or `..`, and no link leading out of the package. Each file in a page script's `js` becomes a separate page script with the entry's patterns and timing. It must be UTF-8 text that parses as a function body on its own, which both the review and the index check.
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
- A shortcut needs `cmd` or `ctrl` unless its key is a function key, so typing never runs a command, as the app's own menu commands require.
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

- WebKit: each script becomes a `WKUserScript` in the plugin's `WKContentWorld.world(name:)`, so the page and other plugins cannot see its globals. Messages from the script go through a `WKScriptMessageHandlerWithReply` added only to that world. Arch reaches the script with `evaluateJavaScript(_:in:in:)` in the same world. A style file becomes a page script in the same world that adds the file's text, passed as a JSON string, in a `<style>` element, so it follows the plugin's script list and its text never runs as script. A page that a tab opens uses the tab's content controller, so the two share one script list.
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
- Granting access to all sites or `nativeMessaging` asks for Touch ID through LocalAuthentication, following the Platform integration table. `PluginGrant.confirmationReason(for:)` holds the rule for the install sheet and for a web extension's requests at run time.
- A web extension's `tabs`, `clipboardWrite`, and `nativeMessaging` are Arch's `tabs`, `clipboard`, and `nativeMessaging`. Its other API permissions, such as `storage` or `cookies`, come with the install, as in other browsers: the install sheet and Settings list them in one sentence (`PluginManifest.extensionPermissions`), and only its sites can be left out.
- Settings ▸ Plugins lists each grant. Revoking any part of it is not built yet; once it is, calls that need a revoked permission get `permissionDenied`, and contributions that need it are hidden.
- An update shows the sheet again, with the permissions and sites that the installed version did not ask for marked New. A site that the installed version asked for starts as the user left it, and a new site starts on. The new grant keeps only what the new manifest asks for, so an update that asks for less narrows it.
- Built-in plugins declare permissions the same way. The app does not sandbox their code, but `PluginContext` checks their grant like any other. Settings shows the grant, and the user can switch the plugin off.
- A plugin never sees cookies, passwords, or API keys. Its fetches carry no Persona cookies, so a plugin cannot act as the user on a site. Site data stays in the engines.

## Sandboxing

- Built-in plugins run in the app process. They are trusted, reviewed with the app, and limited to `PluginContext` by convention.
- Script plugins run their background script in a hidden `WKWebView` owned by the `Plugins` module. The code runs in a separate WebKit web content process, regardless of the tabs' engine:
  - Its documents load from `arch-plugin://<plugin id>/` through a `WKURLSchemeHandler` that serves only the installed package. The root of that origin is a document the handler writes, which runs the background script as a classic script; every other path is a package path, and other hosts and paths that name no file of the package get 404.
  - Every response carries the content security policy `default-src 'self'`, which limits scripts, styles, and connections to the package and allows neither inline code nor `eval`. Network access goes through `arch.net.fetch`, which the host checks against the grant's hosts.
  - A `WKContentRuleList` blocks every load outside the plugin's scheme as a second layer.
  - Neither the policy nor the rule list covers WebRTC, whose connections would reach any host. The web view runs in Lockdown Mode (`WKWebpagePreferences.isLockdownModeEnabled`), which removes WebRTC from its documents and their frames, along with other web technologies such as JIT compilation, WebAssembly, and WebGL. Whether DNS prefetching and `preconnect` links can still reach a host outside the scheme needs verification.
  - Each plugin uses its own `WKWebsiteDataStore.nonPersistent()`, so it shares no cookies or site storage with any Persona or plugin. Its lasting state goes through `arch.storage`.
  - The bridge is a `WKScriptMessageHandlerWithReply` on that web view only. A user script defines `arch` in the page's world at the start of each document, and the app hands the background script commands and page script values through `callAsyncJavaScript`. The host identifies the calling plugin by the sending web view, never by the message.
  - Panels and HTML settings pages use the same configuration and bridge.
- Web extensions run in the engines' own extension sandboxes: WebKit's for `WKWebExtensionController`, Chromium's for CEF's extension runtime.
- Hangs and crashes: a background is hung if it leaves its start (the load of its document), an event, a command, or a page message unanswered for 10 seconds. The host releases its web view (whether WebKit then ends the process at once needs verification), fails the calls that wait for it, and starts it again at the next event. `webViewWebContentProcessDidTerminate` reports crashes the same way. WebKit immediately fails a call whose promise can no longer settle, so only a promise that stays pending or a script that keeps running counts as hung. After three failures within five minutes, the host disables the plugin. Its Settings row says why for the rest of that run, unless the user switches it on again.
- Resources: a background starts at its first event, command, or page message and stops after 30 seconds without work. Its badges stay. A panel's web view lives only while the panel is open.

## Lifecycle

| State | Meaning |
|---|---|
| `disabled` | Installed; no contributions show and no code runs |
| `idle` | Enabled; contributions show, page scripts inject, no background runs |
| `running` | Enabled with its background or panel running |
| `failed` | Disabled by the host after repeated failures, with the reason |
| `unavailable` | Cannot run on this system or engine, with the reason, such as a web extension while no engine runs them, as below macOS 15.4 |

1. Stage: the user chooses a folder or archive with `NSOpenPanel` in Settings ▸ Plugins, Arch downloads a web extension's package from the Web Store for the identifier the user gives (`docs/web-store.md`), or the composer (VII.7) hands over the files that AI wrote. Arch copies the folder, or writes the files, to `Staging/<UUID>/` in the Persona's folder, off the main thread, tells its kind by its manifest file, reads and validates the manifest through the kind's runtime for a kind other than script plugins, has the engines that run a web extension check it (see Engine versions), and lists the files. An update of an installed plugin must be of the same kind. `ditto` extracts an archive and keeps every entry inside the destination; the package is the archive's top level or its only folder. A package that is or holds a symbolic link is refused, since a link could lead to files outside it, and so is one with a built-in plugin's identifier, with an identifier that starts with `xyz.taeyoon.arch.`, which Arch keeps for the plugins built into it, since a later build's built-in plugin with the identifier would take over the plugin's storage, settings, and secrets, other than one under `xyz.taeyoon.arch.generated.`, which the composer gives the plugins that AI writes, with an identifier that starts with `local.arch.browser.` or `local.arch.generated.`, which Arch renames at launch (see Storage), with the entry identifier of a version that joined under its counterpart's identifier, such as `extension.<identifier>.chromium`, which an install would otherwise replace (see Engine versions ▸ Counterparts), or with `plugins.json`, `plugins.unreadable.json`, or a runtime's file such as `webExtension.json` as its identifier, whatever its letter case, since its folder would take that file's name in the Persona's folder. Nothing in the package runs before the user installs it. The manager clears `Staging/` when it starts.
2. Review: the install sheet shows the name, version, origin, where a web extension runs, permissions, sites, and files. For a plugin that AI wrote it also shows the requests it came from and every file's source, and offers Ask for Changes (`docs/ai.md`, Features that AI adds at run time).
3. Install: Arch moves the staged package into the Persona's plugin folder and records it in `plugins.json`. When the file cannot record it, as on a full disk, Arch undoes the move, and the review shows why and can install again (see Storage). It is disabled unless the user chose Install and Enable. Cancel deletes the staged package.
4. Enable: Arch registers the contributions, adds the page scripts to the Persona's tabs from their next load, and sends `activate` when the background first starts.
5. Update: installing the same `id` again replaces the package after review and keeps the plugin's place, storage, and secrets. Only a `.crx` file's signatures prove an identifier (`docs/web-store.md`, Package proof), so a package from another place than the installed plugin's, such as a folder or archive for a plugin that AI wrote, may only claim its identifier: the sheet then warns that the package takes over the plugin's data, and the user decides. An unsigned package that updates a plugin whose package was signed adds "The installed version is signed by its developer; this package is not.", and the update records its own proof. A running background stops, and the next use starts the new code.
6. Disable: Arch removes the contributions, closes page message channels, ends the plugin's context, sends `deactivate`, and stops the background.
7. Remove: after a confirmation, Arch stops the plugin and deletes its package, storage, and the Persona's Keychain items for it. Built-in plugins cannot be removed, only disabled.
8. Launch: each Persona's manager reads `plugins.json`, registers the built-in types, reads each installed plugin's manifest from its package, and shows enabled contributions. A package that no longer reads stays recorded but out of the list. Installed plugin code runs only when needed.

## Storage

```
~/Library/Application Support/Arch/Plugins/<persona id>/
  plugins.json                  Which plugins the user switched on or off, and the installed plugins with their origin, grant, and install date
  webExtension.json             The web extension runtime's file: the removals that an engine missed, until it deletes their storage
  Staging/<UUID>/               A package under review
  <plugin id>/package/          The installed package (script and web extension plugins), which holds the manifest
  <plugin id>/storage.json      Key-value storage, written atomically after changes settle
  <plugin id>/storage.unreadable.json  The last storage.json that did not decode
```

- `<persona id>` is the Persona's UUID as `UUID.uuidString` writes it, so the default Persona's folder is `Plugins/D59DAF4B-E372-4AF9-890E-455B8B3860F3/`. The app gives `PluginManager` its Application Support folder, and the manager derives the Persona's folder from it.
- `storage.json` is a JSON object of the plugin's keys and `PluginValue`s, up to 5 MB (5,000,000 bytes) per plugin, counted as the UTF-8 bytes of each key plus the JSON of its value. A write that grows the storage past the limit throws `quotaExceeded`; the limit never refuses removals and writes that do not grow it. A value JSON cannot hold, such as infinity or arrays and objects nested more than 510 levels deep, throws an encoding error, so every value the storage accepts reaches the file. Settings values live in the same file under keys that start with `arch.setting:`, which the plugin's own keys cannot use: `PluginStorage` throws `PluginError.reservedKey` for them, reads none, and leaves them out of `allKeys()`. A stored setting value that does not suit its field, such as an option a newer version no longer offers, reads as the default.
- `plugins.json` is `{"choices": [{"id": "<plugin id>", "isEnabled": false}], "installed": [{"id": "<plugin id>", "source": "file:///…/Sample.zip", "grant": {"permissions": ["clipboard"], "sites": ["https://example.org/*"]}, "installedAt": 814595493.0}]}`. A plugin that AI wrote has `"generated": {"requests": ["…"], "model": "…"}` in place of `source`: the request and each change the user asked for, and the model that wrote its last version as named in Settings ▸ AI. From IV.26, an entry whose package signatures prove its identifier has `"proof"`, with `"signedSource"` for a `.crx` file or `"webStore": "<identifier>"` for a Web Store install in place of `source`, so that earlier builds keep it unchanged (`docs/web-store.md`, Package proof). The choices are in the order the user made them; a new choice for a plugin replaces its old one. A built-in plugin without a choice follows `BuiltInPlugin.isOnByDefault`, and an installed one is off. The installs are in installation order; an update keeps its place. `installedAt` is the default `Date` encoding, seconds since 2001. The manifest stays in the package, so the grant cannot drift from it: the manager limits the recorded grant to what the package's manifest asks for. Each choice, install, and removal writes the file at once, atomically. An install that the file cannot record, as on a full disk, throws and undoes itself: the staged package goes back to `Staging/`, the package it replaced, which stays beside the new one as `<plugin id>/package.replaced` until the file records the install, goes back to `package/`, and the manager's lists go back to how they were, so that the review can install the package again or discard it. Kept, such an install would leave the next launch without the entry: it would not list a new plugin, whose folder would stay, and would read an update's package with the old entry's grant and origin. The other changes, which Settings and the runtimes make without waiting for an answer (switches, joins, separations, dismissed notes, removals, and the engines' answers), keep their effect for the run: `PluginManager.listWriteFailure` says why the write failed, Settings ▸ Plugins shows it with Try Again, and the next write that succeeds saves them all, since each writes the whole file. Undoing them would make a switch that does not move and lose what an engine found, while keeping them loses at most the changes since the failure, and only at quit. A removal deletes the package first, so the entry that a failed write leaves stays out of the list at the next launch, and the record of a removed version's pair, which the file keeps too, is ignored (see Engine versions ▸ Types and `plugins.json`). A new install with the identifier takes nothing from them: its entry goes after the others without the old entry's dismissed notes, and the records that name it go, so that the plugin joins a pair only as the user chooses in the review or with Join With…. An install entry that this build cannot read, such as one whose grant holds a permission that a newer build added, stays unchanged in the file and out of the list; installing a plugin with its identifier replaces it. A file that does not read or decode moves to `plugins.unreadable.json`, as `storage.json` does.
- Changes reach `storage.json` together 0.5 seconds after the last one, or, while changes keep coming, 5 seconds after the first one that has not reached the file, so that a crash loses at most those 5 seconds, and at quit. A missing file counts as empty. A file that does not read, as for its permissions, or does not decode moves to `storage.unreadable.json`, replacing an older one, and the plugin starts empty, so its first change does not overwrite the old data. The manager keeps one storage per plugin while it runs, so a plugin that starts again after a failed activation finds the changes that have not reached the file.
- Secret settings and `arch.secrets` use Keychain Services: generic password items with the service `xyz.taeyoon.arch.plugin.<plugin id>` and the account `<persona id>/<key>`, accessible when unlocked and not synchronizable, in the login keychain as the AI module's keys are. A plugin keeps up to 64 secrets in a Persona, its secret settings among them, of up to 16 KB of UTF-8 each, so that it cannot fill the keychain: a longer secret, and a new key past the limit, throw `quotaExceeded`. Settings ▸ Plugins shows only whether a secret is saved, which it reads without the secret, so macOS does not ask for the keychain password. Removing a plugin deletes the service's items whose accounts start with `<persona id>/`, which it finds by their attributes alone. A deleted Persona's items go at the next launch (see Personas).
- Web extensions keep their own extension storage in the engine: WebKit under the Persona's `WKWebExtensionController` configuration, the default one for the default Persona and the one with the Persona's identifier for any other, in `~/Library/WebKit/<bundle identifier>/WebExtensions/`; Chromium keeps it in the Persona's profile under the CEF cache path, with the extension itself installed there. Removing an extension deletes its storage records in the engines that run in the Persona, which start for it, and on Chromium uninstalls it, and deleting a Persona deletes its extensions' records at the next launch. WebKit keeps a small state file for each extension it loaded, which no public API removes.
- An engine that does not run for the Persona when the user removes an extension, as when its application or the Persona's profile did not start in that launch, misses the removal and keeps the extension's storage, and Chromium keeps the extension installed, switched off, where an install with the same identifier would find its data. The runtime therefore keeps each such removal in `webExtension.json` in the Persona's folder, `{"missedRemovals": [{"engine": "chromium", "id": "<engine identifier>"}]}`: one entry per engine and engine identifier, for every engine that is not attached, or every engine while none runs extensions, except one where a counterpart with the same identifier keeps the storage, as at any removal. The first pass after that engine attaches in a later launch calls its `removeData(of:)` for each of its entries before it loads anything, so that an extension installed again with the same identifier starts without the removed one's storage, and then drops them; the file goes with its last entry. While an entry names an engine that the host lists, a pass attaches the engines even though no extension is enabled, as the removal itself starts them. An entry whose engine this build does not know stays in the file, and a file that does not decode counts as empty and is replaced at the next change, which leaves its storage until the Persona is deleted.
- The record is the runtime's own file rather than part of `plugins.json`, which the manager owns. `plugins.json` lists what the user installed and chose; the record names engine storage left behind after an install is gone, which only the runtime reads and changes, so the manager stays out of the engines and a failed write of `plugins.json` cannot lose it. The manager gives each runtime the file `<kind>.json` in the Persona's folder (`PluginRuntime.runtimeFile`) and refuses that name as a plugin identifier, as it refuses `plugins.json`; the file goes with the Persona's folder in the removal pass after the user deletes the Persona, when the engines' storage of the Persona goes too. Every engine that is not attached counts as missing a removal: the runtime cannot tell an engine whose application did not start from one that runs no extensions on this Mac, so below macOS 15.4, where WebKit keeps no extension storage, WebKit's entries stay until a macOS update lets WebKit attach, which then deletes nothing and drops them.
- Earlier builds gave the built-in plugins identifiers that start with `local.arch.browser.`, plugins that AI wrote identifiers that start with `local.arch.generated.`, and secrets the service prefix `local.arch.browser.plugin.`. At launch, before any manager exists, `PluginIdentifierMigration` moves that data to `xyz.taeyoon.arch.` (Page Address becomes `xyz.taeyoon.arch.page-address`) and `xyz.taeyoon.arch.generated.`: each Persona's plugin folders, with the identifier in a script plugin's `plugin.json`, the identifiers in `plugins.json`, the Keychain items, which move to `xyz.taeyoon.arch.plugin.<plugin id>`, and the user's shortcuts for plugin commands. An item moves only while its new name is free, and the old item goes only once the new one exists, so a run that stopped partway finishes at the next launch; a `plugins.json` entry, Keychain item, or shortcut that already exists under the new identifier wins, and a folder whose new name is taken stays. A folder whose `plugin.json` cannot take the new identifier, as on a full disk, keeps its name until a later launch writes it, since the manager reads a package only under the identifier its manifest names. A Keychain item that has not moved yet, as when the user refused the keychain prompt, counts by the service it moves to, so removing its plugin or deleting its Persona deletes it, and no later launch brings it back. Staging refuses the old identifiers, so nothing installs under them again, and no build saves secrets under the old prefix, so once every item has moved, `ARCHPluginSecretsMoved` keeps later launches from listing the Keychain's items again.
- Sync (V.9) does not cover plugins. A later task can sync `plugins.json` without packages or secrets.

## Personas

- Each Persona has one `PluginManager`. A plugin sees only its Persona's spaces, tabs, history, and downloads. It gets events only from them. A command therefore gets the window's selected tab only when the tab belongs to the plugin's Persona, so neither a favorite's tab of another Persona nor the selected tab under the menu of a space whose Persona differs from the tab's reaches it.
- The session creates a Persona's manager when a tab or window of the Persona first needs it (`BrowserSession.plugins(in:)`) and keeps it in the Persona's `PersonaEngines`. A window shows contributions from its current space's Persona, or its tab's Persona for a small window, and runs its palette commands and sidebar items through that Persona's manager. A tab's page scripts and the plugin items of its page's and its row's context menus come from the tab's Persona, and those of a space's menu from the space's. The Plugins menu follows the active window's Persona, or the default one while no window is open. Settings ▸ Plugins shows one Persona's plugins, with a picker once there are two Personas, and installs plugins into that Persona. A review sheet still open when the user deletes its Persona closes without installing, and an install that was waiting for Touch ID then throws `PluginError.closed`.
- Installing a plugin in two Personas creates two installations with separate grants, storage, secrets, and background processes. Once there are two Personas, Settings will offer Install in Another Persona, which copies the package and asks for a new grant; it is not built yet.
- Built-in plugins exist in every Persona. A new Persona enables the built-in plugins that are on by default.
- Deleting a Persona closes its manager (`close()`): its plugins leave the list, removing their contributions and preventing them from starting again. Their running instances stop, along with each script plugin's background web view, their contexts stop acting, and storage changes that have not reached the files are dropped. From then on the manager stages, installs, and stores nothing, and throws `PluginError.closed` for such calls; `isClosed` tells callers that fetch a package for it, such as the Web Store installer, to stop before they ask for or download one. The session then stops passing the manager's page scripts to tabs and drops it. At the next launch, before any engine starts, the removal pass calls `PluginManager.removeData(ofPersona:in:)`, which deletes the Keychain items of every plugin whose account starts with `<persona id>/` and then the Persona's `Plugins/<persona id>/` folder, with its installed packages and the packages left in `Staging/`. The Persona stays in `removedPersonaIDs`, and the engines keep its storage, until both are gone.

## Web extensions as plugins

The `Extensions` module turns a web extension into a plugin of the `webExtension` kind. `WebExtensionRuntime`, one per Persona, is the kind's `PluginRuntime`: it reads `manifest.json` into a `PluginManifest` without any engine, so that one install serves every engine, and loads each enabled extension into the Persona's profiles in the engines that run extensions and its package, through their `EngineExtensions` (`docs/engine-protocol.md`, Tier 2; see Engine versions).

| Extension feature | Plugin contribution or permission |
|---|---|
| `name`, `version`, `description` | The plugin's name, version, and summary. A whole `__MSG_<name>__` text comes from `_locales/<locale>/messages.json` in the user's preferred languages, then the default locale |
| `action` | An item in the site settings popover with the action's icon, label, and badge for the tab, and an `action` command, titled with its default title or the extension's name, which the palette lists. The popup shows in a popover from the site settings button. An extension without one has an item only while the tab's engine keeps it from the tab's site, for Allow on This Site |
| `permissions` | `tabs`, `clipboardWrite`, and `nativeMessaging` as Arch's permissions; the others as `extensionPermissions`, which come with the install. An entry that is an object with one key, a permission with arguments, counts by its key, as Chromium reads it |
| `host_permissions` and `content_scripts[].matches` | The install sheet's sites, each with a switch. Patterns that Arch's match patterns cannot hold, such as `file:///*` or one with a port, are left out; on Chromium, Arch's engine also loads extensions without access to file URLs |
| Requests at run time (`permissions.request` and the access WebKit asks about) | Arch's own sheet on the tab, in the install sheet's sentences on WebKit and in Chromium's own sentences on Chromium; sites other than web pages and `nativeMessaging`, which only the install grants, are never granted, and every website needs Touch ID or the login password, which on Chromium also counts the sites the install left out, since Chromium withholds them and lets `permissions.request()` ask for them again. On WebKit the answer lasts while the extension stays loaded; Chromium keeps it until the extension is removed, except sites: a grant that covers every site, such as `<all_urls>`, lasts until the extension next loads while its install grant leaves sites out, and every site granted at run time goes when the install grant moves from every site to some, as at an update review that switches a site off |
| `content_scripts`, `background` | Run by the engine's extension runtime, not by Arch's page scripts |
| `nativeMessaging` | Arch relays messages to the native app (see below) |
| `commands`, `options_ui` or `options_page` | Not built yet: commands with their suggested shortcuts, and a settings page entry that opens the options page in a sheet |

- Refusals: `PluginError.invalidPackage` with a sentence that names the field, for invalid JSON, a `manifest_version` other than 3, a missing `name` or `version`, a `key` that is not Base64 text, a message that the default locale lacks, and a `permissions` or `optional_permissions` value that is not a list of names and objects with one key, which Chromium refuses too.
- Identifier: Arch uses Chromium's identifier, the first 128 bits of the SHA-256 digest of the public key in the manifest's `key`, each hexadecimal digit written as a letter from `a` to `p`, so each engine knows the extension alike. Without a key, the digest is of the path the user installs from, as Chromium names an unpacked extension, so installing from the same place again is an update. Chromium loads the installed copy rather than that path, so before an engine checks or loads such a package, the runtime writes into the copy's manifest a `key` whose bytes are the path, whose digest is the same identifier; Chromium reads a key as Base64 bytes without checking that they hold a public key. A `.crx` file's identifier is that of the developer's key in its header, which staging writes into its manifest, over a `key` the manifest has, as Chromium does. Staging first checks the file's signatures as Chromium's verifier does and records the proof of its identifier, which a package from the Web Store must carry; a file whose proofs do not all hold is refused (`docs/web-store.md`, Package proof). The proof covers only that identifier, so the file's package must be the web extension with it: a `.crx` file whose package is a script plugin, with `plugin.json` at its top, is refused, since `plugin.json` would give the plugin an identifier that no signature proves. The plugin identifier is `extension.<identifier>`. WebKit receives the identifier as the context's `uniqueIdentifier` and the base URL `webkit-extension://<identifier>/`, so the extension's storage lasts across launches. Nothing but a `.crx` file's developer signature proves that a `key` belongs to the package that carries it, since the key is public: an update that claims an installed extension's identifier from another place gets the install sheet's warning (see Lifecycle).
- Loading: each change to the engines waits for the one before. An extension loads with the API permissions its grant covers, those that come with the install, and its granted sites, every web page as `<all_urls>`, which an extension checks for with `permissions.contains`; one whose install changed loads again; one switched off or removed unloads, and a removal also deletes its storage in the engines, where an engine that did not run for the Persona then deletes it at its first pass in a later launch (see Storage); an extension that an engine cannot start leaves that engine, and the manager switches it off with why once it has failed on every engine it ran on (see Engine versions). The plugin's instance runs the action on its invocation's tab and fails, so the manager beeps, without a tab whose engine runs the extension.
- WebKit: one `WKWebExtensionController` per Persona's profile, which every web view of the profile uses (macOS 15.4 and later). Its tabs are the profile's web contents and its windows the windows the app reports. Each space of the Persona is a window: its tabs in sidebar order, after the open favorites' tabs that a window shows on it (a favorite's tab that no window shows is in the Persona's first space); its active tab is the one a main window shows there, or else the one selected last. Each small window of the Persona is a window of its own with its one tab. The window that last became main is the focused window when it is the Persona's, as the small window itself or a main window's space. An extension's `tabs.update` with `active` selects a tab, in the window that shows it, or else in the front main window that shows its space, or else as a tab that no window shows is selected, which takes a favorite's tab to a window of its Persona, and `tabs.remove` closes it into the closed list. `tabs.create`, an options page, and a link that a popup opens open a tab of the asking engine in the space of the window it names, or of the Persona's focused window, before the tab at the asked index among that space's tabs of the engine while that one is an open tab outside folders, else after its active tab while that one is, else at the end of the space's open tabs; a tab asked for in a small window opens in that window's space. `windows.create` opens a small window with its page, or the new tab page for none, as its one tab, which belongs to the space of the Persona's focused window, or else to its preferred space, and extensions see a new window that lists only that tab; a request for several pages opens none, since a small window holds one tab. WebKit loads an extension's pages only in web views made for the extension, so a tab that navigates into or out of them, as with `tabs.update` to the extension's page or a link from its options page, loads the page in a new web view in the same place, which extensions see as a replaced tab, and a tab restored at an extension's page waits until the extension loads. A web page's own navigation reaches only the extension pages that the extension makes web-accessible to the site, as on Chromium. Content scripts run only in pages of a persistent store, since WebKit treats the web views of a non-persistent store as private.
- Chromium (VI.1): the extension runtime that Arch's engine adds to CEF loads the same installed package unpacked into the Persona's profile, in which every tab stays an Alloy style browser, and sees the same windows as WebKit, each over a hidden stand-in window of the adapter's, which answers with the frame and the minimized, zoomed, and full screen state of the window that shows it. A window that `windows.create` opens is answered once it lists its tab. The extension's sites apply on every site its manifest asks for when the grant has them all, with schemes and hosts compared in lowercase; the patterns for `file:` and `ftp:` pages, which no extension reaches on Arch's engine, are left out of that comparison. Otherwise, as also for a pattern with a port or one for another scheme, such as `wss:`, which the install sheet does not show, the extension runs without a click on the sites of its grant, as on WebKit, and waits for a click on the others: Chromium grants the manifest's sites that the grant covers as runtime host permissions, which the profile keeps across reloads and launches, never covering a `wss:` pattern and covering a pattern with a port only where a granted pattern covers its host, since a pattern covers every port of its host. Each load replaces the sites that the previous load granted, so an update whose review switches a site off makes it wait for a click again. The site settings popover offers Allow on This Site where Chromium kept the extension from the tab's site, also for an extension without an action, which Chromium gives one; it allows the origin of the tab's page next to the grant's sites, runs what Chromium kept from running there or asks to reload the tab, and lasts through later loads unless the grant moves from every site to some. The popup page shows in a popover of Arch's, sized as the page asks between 25 × 25 and 800 × 600 points. Reload prompts ask with Arch's sheet, and a store install prompt is refused; from a store page it opens Arch's own review of the store's package instead (`docs/web-store.md`, Chromium's store button). Chromium keeps extensions in the profile and starts them with it, so once the runtime's first pass of loads has ended, or as the profile starts while the Persona has no enabled extension, the adapter switches off each one that the app has not loaded in the run; a first load in the run keeps Chromium's copy only of a package installed before the engine started, and loads any other package again. Chromium's own windows, as `identity.launchWebAuthFlow` opens, are logged and closed at once, so such a flow fails on Chromium tabs. A switched-off extension stays installed there, off, until the user removes it. Arch's engine loads extensions without access to file URLs, also when Chromium reloads them or keeps them from an earlier launch, so on Chromium tabs, as the Match patterns rule above requires, an extension whose sites apply everywhere runs on no `file:` page, and `tabs.create` and `tabs.update` refuse `file:` addresses.
- One install, two runtimes: each engine runs its own copy of the extension with its own background and storage. An extension's state, such as a password manager's lock, is not shared between engines. Each copy lists its own engine's tabs only. A package that only one engine runs, and an extension whose developer ships a package per engine, follow Engine versions below.
- Native messaging: Arch answers `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)` and `webExtensionController(_:connectUsing:for:completionHandler:)` on WebKit for an extension whose grant has `nativeMessaging`, which only the install gives, since requests at run time never grant it. It finds the app through its host manifest in Chromium's format, `<name>.json` in `~/Library/Application Support/Arch/NativeMessagingHosts/`, whose `name` matches, whose `type` is `stdio`, whose `path` is absolute, and whose `allowed_origins` lists `chrome-extension://<identifier>/`; a name is dot-separated runs of lowercase letters, digits, and `_`, so it cannot lead out of the folder. Arch starts the app with that origin as its argument and exchanges messages over its standard input and output, each a 32-bit length in the Mac's byte order followed by UTF-8 JSON, up to 1 MB from the app. A single message ends the app after its first reply; a port lasts until the extension or the app ends it. On Chromium, Chromium's own native messaging finds the host manifests through `NativeMessagingHosts` under its root cache path, which the engine links to this folder while nothing else is at that path (whether Chromium follows the link needs verification), and needs the extension's `nativeMessaging` permission, which Chromium grants from the manifest as the install does; a run-time request of an extension that lists `nativeMessaging` among its optional permissions without the install's grant, or whose optional lists do not read, is refused without a sheet, since Chromium's sentences do not say which permissions a request covers. Vendors install host manifests only for browsers they know. In IV.21, Arch links the manifests it finds in other browsers' host folders into this folder, read-only, and allows access only to extensions whose identifiers it can prove (`docs/password-managers.md`, Host discovery and Proof gate).
- Not built yet: `commands`, an options page entry in Settings, and on WebKit grants made at run time that last across launches. Options pages open as tabs.

### Engine versions

Many developers ship a separate package for each engine, and some packages load only in one engine's runtime. Arch therefore records which engines run each web extension's package and shows two packages of one extension in a Persona as one plugin with a version per engine. The user can add the other engine's version to any web extension plugin, and Arch asks for it where a plugin does not run on an engine that runs extensions. Both steps at the end of this section are built: Coverage, then Counterparts and Guidance. Every rule here treats the engines alike, and the tests use a recording engine in place of Chromium, whose extension runtime VI.1 supplies.

#### Coverage

- Each web extension plugin records which engines run its package, as each engine's runtime finds when it checks the package: WebKit runs it when `WKWebExtension(resourceBaseURL:)` reads it, and Chromium when the adapter finds in its files nothing that keeps Chromium's loader from running it: a manifest that reads, a background as `background.service_worker` rather than `background.scripts` or `background.page` alone, which Chromium leaves out of Manifest V3, and the files that its service worker, content scripts, icons, and default locale name. CEF's extension runtime has no call that reads a package without installing it, so whatever else Chromium refuses shows when the package loads, as a failure to start. A check reads the package without running any of it, through `EngineExtensions.check(_:)`, and starts the Persona's profile in the engine as loading does. `WKWebExtension(resourceBaseURL:)` throws only for a missing or unreadable manifest and collects other problems in its `errors`, so WebKit runs nearly every package that Arch's manifest reader accepts, packages built for Chromium among them. Whether some of those `errors`, such as one about the background, should count as a refusal needs verification. A check therefore tells where a package can run, not which engine its developer built it for, and no rule below waits for an engine to refuse the other engine's package.
- At staging, the kind's runtime checks the package in each engine that runs web extensions on this Mac: WebKit from macOS 15.4 and Chromium. It also checks the installed plugins that the package could update or join (see Counterparts), on or off, in each such engine that has no current answer for them. The manager records those answers for the plugins with the package's identifier, which the package updates, and the match it could join. A package refused by every engine that checks it is refused with the first engine's reason, WebKit's before Chromium's, such as `WebKit cannot run this extension: …`. Without such an engine nothing is checked, and the package installs as an unavailable plugin, as now. The review sheet says where the package runs, such as "Runs on WebKit tabs.", and gives each engine's refusal, such as "Chromium cannot run this extension: …".
- Each answer records the version of the engine's extension runtime that gave it: WebKit's framework version, or the CEF version. An answer is current while the engine has that version. An engine without a current answer for an installed package checks it, whether the plugin is on or off: at the first launch of a build with this step for packages installed before it, for every package once Chromium runs extensions (VI.1), and whenever a macOS update or a newer CEF changes the engine's version. The runtime does so in each pass over the engines, before it starts an enabled plugin's package in any engine, and the manager records each answer; a switched-off plugin's package does not load. A pass starts the Persona's profiles only for an enabled plugin or a removal that an engine missed (see Storage), so switched-off plugins alone start no engine. Their packages are checked once the profiles run for an enabled plugin, staging, or such a removal. An enabled plugin whose package no engine that runs extensions still accepts is switched off with the first engine's reason. `plugins.json` keeps answers without reasons, so switching such a plugin on again has every engine check its package again, and the plugin goes off again with the reason.
- `plugins.json` keeps the answers in each web extension's install entry as `engineChecks`, an object from engine name to the answer and the version that gave it: `"engineChecks": {"webKit": {"runs": true, "version": "22625.2.5.11.1"}}`. An engine missing from it has not checked the package. An engine name this build does not know stays in the file and counts as no check. An update records its own answers.
- A package that passed an engine's check but fails to start there leaves that engine only: the runtime unloads it there, and the manager keeps the reason by engine in `InstalledPlugin.engineFailures` for the run, not in `plugins.json`. The plugin's row says it, such as "Arch could not start it on Chromium tabs: …", and its other engines keep their copies running. The engine counts as one the plugin does not run on until the user switches the plugin on again or it updates, so Guidance asks for that engine's version. The manager switches the plugin off only when it has failed on every engine it ran on, with each engine's reason; meanwhile Settings lists the failures under the plugin.
- An entry without `engineChecks`, as builds before this step write it, reads as checked by no engine, so it runs as it does now: WebKit checks it before loading it at the next launch, a package it runs keeps running, and one it refuses is switched off with WebKit's reason, as its failed load is now. A build before this step drops the keys that this step adds whenever it writes the file, and lists no version whose identifier ends in an engine (see Counterparts). The next newer build checks the packages again and pairs each such version again with the plugin of its identifier, for the engine its identifier names; the user joins the other pairs again.
- The runtime loads each enabled extension only into the engines it runs on, `InstalledPlugin.engines`: those whose current answer runs its package and where it has not failed to start, and in a pair only the engine that the pair's record gives it (see Counterparts). An engine loads one installed plugin per engine identifier: two plugins share an identifier only as the versions of a pair, which gives each engine to one of them, and joining, separating, updating, and removing keep it so. The runtime loads and unloads per engine, so recording an answer, joining, or separating leaves an engine's copy running while its version on that engine stays the same.
- The engines that run web extensions on this Mac (`PluginRuntime.engines`) are the registered engines with the `extensions` capability, each with its extension runtime's version, excluding those whose application did not start when the session last tried. Once the runtime has started the Persona's profiles, it also excludes those whose profile did not start and tells the manager (`onEnginesChange`). The manager reads each plugin's current answers again, so such an engine's answers count for nothing in the run. An engine that does not start never lends another engine's profile, as a tab's runtime falls back to the primary engine's, so that no engine runs an extension twice and no engine's answer stands for another's.
- The `webExtension` kind is unavailable only while no engine runs web extensions on this Mac, so that a Mac below macOS 15.4 runs them on Chromium tabs. Its reason is "Web extensions need macOS 15.4 or later." below macOS 15.4, and otherwise "No engine on this Mac runs web extensions." Settings and the review sheet say "A web extension." and then where the plugin runs, such as "Runs on WebKit and Chromium tabs."; Settings says it once an engine has checked the package, and "No engine on this Mac runs it." for a package that every engine refuses now. A plugin that is off because it failed to start on every engine that runs it has no such sentence; its failures say why.

#### Counterparts

- Two web extension plugins of one Persona are counterparts, versions of one extension, when the Persona's `plugins.json` records them as a pair. Arch shows a pair as one plugin with a version per engine: one Settings section with a row for each version, one row in the site settings popover, and one palette command. The pair takes the name and list position of the version installed first.
- At staging, a package matches an installed web extension plugin that is not in a pair when they name one extension: they have the same identifier, from the same `key`, or the same `name` as Arch shows it, compared without case and spaces at either end, with at least one developer field that both manifests give and that matches, and no such field that differs. The developer fields are `author`, as text or as the `email` of an author object, compared without case, and `homepage_url` without its scheme, a leading `www.`, and a trailing `/`, compared without case, so that two projects on one hosting site differ. While a plugin has the package's identifier, which the package would otherwise update, it is the only plugin the package can match, and only while it is the one plugin with that identifier and is not in a pair; otherwise, of several matching plugins, the one installed first is the match.
- The package can join the match for each engine that runs the package while the match runs on another engine, by the answers at staging. The review then asks how to install it, for example "This may be the Chromium version of “Reader”, which runs on WebKit tabs. Arch can show the two as one plugin.", with Install as the Chromium Version, one such choice for each engine the package can join for, and Update “Reader” for a package with the match's identifier or Install as a Separate Plugin for another. The choice starts on the version when the two complement each other, each package running on an engine that refused the other. Otherwise it starts on Update or the separate plugin, since a package that runs where the match runs may be the match's next release or another extension, and the user can still choose the version, as for two packages with one `key` that both engines run. Without an engine to join for, as with WebKit alone, a package with the match's identifier updates it and another installs as its own plugin, as now. A version installs on or off as the match is, so for it the review has one Install button instead of Install and Install and Enable.
- Identifiers: a version that joins a plugin whose version has the same identifier gets the plugin identifier `extension.<identifier>.<engine>`, with `webkit` or `chromium` for the engine it joins for. A plugin identifier is its install entry's `id`, which names its folder, choice, storage, and Keychain items, and which `InstalledPlugin.id` gives, while `manifest.id` stays what the package names. The manager therefore lists an entry whose package names `extension.<identifier>` under that `id` or under it followed by `.webkit` or `.chromium`, and the runtime gives the engines a plugin's identifier without that ending. Both engines know both versions as `<identifier>`, since each loads only its own, so a native app's host manifest that lists the identifier serves both. The runtime finds a version by the calling engine and the identifier. No package may have such a version's entry identifier as its own, as a script plugin's `plugin.json` could, since installing it would replace the version. On its engine, such a version takes over the extension storage that its counterpart's copy kept there, since the engine knows both by the one identifier. While the counterpart's package runs on that engine and the package comes from another place than the counterpart's, the review therefore warns, as an update from another place does: "“Reader”, which you installed from Reader, has this package's identifier, so as its Chromium version the package takes over the data that “Reader” keeps on Chromium tabs. Join only if both come from the same developer."
- Updates: a package with an installed plugin's identifier updates it, as now, unless it joins it as above. Of two versions with that identifier, it updates the one installed from the same source, else the one whose answers the package's checks equal, else the one the user chooses in the review. `PluginPackage.updates` names it, and the review's title names the version, such as "Update the Chromium Version of “Reader”?". An update review that would take a plugin off an engine it runs on says so, such as "WebKit tabs lose “Reader”." An update that would leave a version of a pair on no engine cannot install while the pair lasts: its review says why, such as "WebKit cannot run this package, and the other version of “Reader” runs on Chromium tabs.", and offers Cancel only. An update keeps the plugin's pair and `dismissedVersionNotes`.
- By hand: while every engine that a pair divides runs web extensions on this Mac, which needs Chromium's runtime (VI.1), an unpaired web extension plugin's section in Settings ▸ Plugins has Join With…, which lists the Persona's other unpaired web extension plugins (`PluginManager.joinCandidates(of:)`). Its sheet gives each engine to the version whose package runs there. Where both run, the user chooses, starting with the version installed first on WebKit. A join that leaves a version without an engine is refused: one that gives a version an engine that runs no web extensions on this Mac, or whose current answer for the version's package refuses it or is missing, as before the engine has checked it. The pair takes the switch of the version installed first. A pair's section has Separate Versions, which drops the record: both versions stay installed as two plugins, each on every engine its package runs on, with their switches as they were. A pair whose versions share an identifier has no Separate Versions, since an engine loads one plugin per identifier; Remove Version… takes a version out instead.
- What a pair does:
  - Switching: the plugin's switch turns both versions on or off, and a version that joins takes the pair's switch, so both are on or both off. A version that the manager switched off after a failure says why in its row and comes back on with the switch; meanwhile its counterpart keeps running.
  - Removal: Remove… removes both versions after one confirmation. Each version's row has Remove Version…, which removes that version alone. The other version stays installed in the pair's place with its grant, storage, and switch, and Guidance applies to it again. Removing a version unloads it and deletes its extension storage in every engine except the one that the pair's record gives a counterpart with the same engine identifier, whether or not the counterpart is on, so such a counterpart keeps running and keeps its storage.
  - Updates: each version updates on its own (see Updates above), through the review sheet, with the permissions and sites it did not ask for before marked New.
  - Permissions: each version keeps its own grant. A version's review asks for its own permissions and sites. The sites that the other version asked for and the user left out start off, as in an update. Touch ID applies to each version's grant. Settings lists each version's access in its row. A request at run time names the pair and the version, such as "Allow the Chromium version of “Reader” more access?", and grants only that version.
  - Storage: each version keeps its own `<plugin id>/` folder and its own extension storage in the engine it runs on. Nothing moves between versions, so the user sets up each version once, as with one package's copies on two engines. The one exception is a version under its counterpart's identifier, which starts on its engine with what the counterpart's copy left there (see Identifiers above).
  - The action: the site settings popover lists the pair once, under the identifier and name of the version installed first, whichever version has the action, with the action of the version that runs on the tab's engine, and a click runs that version's action. The palette lists the pair's `action` command once, under the identifier and name of the version installed first while that one is on, whichever version has the action, and runs it with the version for the invocation tab's engine, through the plugin instance of the version installed first, as a click in the popover does. The contributing version brings, after its own commands, those of the other version whose identifiers its own lacks (`InstalledPlugin.commands(among:)`), with the titles and keywords of the other version's manifest, and `PluginManager.run(_:_:)` accepts the same commands. It does so only while the other version is on, as the popover counts only the actions of versions that are on, so while the version that has the action is off after failing to start, the palette lists no action for the pair; while the version installed first is off, the other contributes alone. The pair's other contributions also appear once: from the version installed first while it is on, otherwise from the other version; a menu item or sidebar item among them shows when its command is one of the pair's commands.
  - Native messaging: each version reaches native apps under its own identifier, so a host manifest's `allowed_origins` must list the identifier of each version that the helper should answer.
  - Personas: a pair belongs to one Persona. Install in Another Persona, once built, copies both versions and the pair.

#### Guidance

- A web extension plugin that is not in a pair asks for a version for an engine when that engine's runtime runs web extensions on this Mac (`PluginRuntime.engines`), the engine has a current answer for the plugin's package, the plugin runs on another engine but not on this one (`InstalledPlugin.engines`, so a failure to start there counts), and the user has not dismissed the note for that engine. The rule runs both ways: a plugin that only Chromium runs asks for a WebKit version on a Mac where WebKit runs extensions. While one engine alone runs extensions, as below macOS 15.4 or when Chromium's application does not start, nothing asks for a version and no section offers Join With…. A pair asks for no version: a version that does not run on the engine its record gives it says why in its row, such as "Chromium does not run this version.", or "Chromium runs no web extensions on this Mac." while that engine runs none, as when its application did not start, with Remove Version…, after which the other version asks as a plugin alone does.
- Install \<Engine> Version… does not wait for a refusal: every unpaired web extension plugin's Settings section offers it for each engine that runs web extensions on this Mac while the plugin runs on another engine, whatever the checks found, since an engine may run a package built for the other engine. Only a plugin that asks for a version also shows the notes below.
- The install sheet's last step: after Install or Install and Enable of a new plugin, not an update, that asks for a version, the sheet stays open and says, for example, "“Reader” is installed. It runs on WebKit tabs. Its developer may offer a separate version for Chromium; install it to use “Reader” on Chromium tabs too." It offers Install Chromium Version…; Don't Ask Again, which dismisses the note for that engine; and Done, the default button, which leaves the note in Settings and on that engine's tabs.
- Install \<Engine> Version… is a menu in the install sheet's last step, a plugin's Settings section, and its footer note: From the Web Store… opens the store sheet (`docs/web-store.md`, Entry points), whose package then becomes the engine's version as a file's does, and From a File… opens the open panel over the sheet, or over the Settings window from a Settings row, with the engine's package types (`PluginRuntime.packageTypes(for:)`) and a message that names both, such as "Choose the Chromium version of “Reader”." For both engines these are a folder or a `.zip` archive, and for Chromium also a `.crx` file; whether WebKit's take app extension bundles, which `WKWebExtension(appExtensionBundle:)` reads, is open. The package's review takes the sheet's place, titled "Install the Chromium Version of “Reader”?". It installs the package as the plugin's version for that engine, on or off as the plugin is. A package that the engine refused cannot join: the review says why, such as "Chromium cannot run this extension: …", and offers Cancel only. A package whose name or developer fields differ from the plugin's joins with the warning "Its name or developer differs from “Reader”. Join only if both come from the same developer." A package with the identifier of an installed plugin that is not a version of this one cannot join here; Join With… joins installed plugins.
- Settings ▸ Plugins: while a plugin asks for a version, its section's footer gives the last step's note with Install \<Engine> Version… and Dismiss. Dismiss adds the engine to the plugin's `dismissedVersionNotes` in `plugins.json`; the footer then says only where the plugin runs, and the section keeps Install \<Engine> Version…. The note goes once the plugin runs on both engines, and comes back when removing a version leaves an engine without one, unless the user dismissed it before. An update keeps the dismissals. Installing a package that could have joined as a separate plugin, and Separate Versions, dismiss each plugin's note for the engines the other runs on, since the user chose to keep the two apart.
- Tabs: on a tab whose engine runs extensions but none of the plugin's versions, the plugin's row in the site settings popover is dimmed and says where it runs, such as "Runs on WebKit tabs.". While the plugin asks for a version for the tab's engine, the row adds "Its developer may offer a separate version for Chromium.", Install Chromium Version…, and Dismiss, which dismisses the note as Settings does. Install Chromium Version… closes the popover and opens Settings ▸ Plugins at the plugin, in the tab's Persona, with the open panel, whose review names the Persona with the tab's space, or the window's current space for a favorite's tab (`docs/windows-personas.md`, Persona rule 7). It does so through a session callback that the app shell sets, `BrowserSession.installEngineVersion`, as it sets `showSettings`. The plugin's section there also offers From the Web Store…. The palette command beeps on such a tab, as now. On a tab whose engine runs no extensions, such as Chromium when its application does not start, the section keeps its note "Extensions run on WebKit tabs. Switch this tab to WebKit to use them."

#### Types and `plugins.json`

The members of both steps are in the Swift API section and in `docs/engine-protocol.md`: `EngineExtensions.check(_:)`, `Engine.extensionRuntimeVersion`, `PluginEngineCheck`, `PluginEngineVersions`, `InstalledPlugin.engineChecks`, `engineFailures`, `engines`, `enginesNote`, `counterpart`, `pairEngine`, `dismissedVersionNotes`, `versionEngines(among:)`, and `missingEngine(among:)`, `PluginPackage.engineChecks`, `engineNotes`, `counterpart`, `joinableEngines`, `suggestedEngine`, `updates`, and `updateChoices`, `PluginManifest.author` and `homepage`, `PluginRuntime.engines`, `check(packageAt:)`, `onCheck`, `onEngineFailure`, `onEnginesChange`, `packageTypes(for:)`, and `run(_:)` with the installed plugins on or off, the `PluginManager` members for engine versions, `PluginError.invalidVersions`, `WebExtensionHost.extensionRuntimeVersions`, the version of each engine's extension runtime that answers record, and `extensionEngines(in:)` by engine, `WebExtensionActionItem.engines` and `asksForVersion`, and `BrowserSession.installEngineVersion`. `PluginListFile`, as `plugins.json` holds it, keeps engine names as text, so that the names this build does not know survive its writes: `Install.engineChecks: [String: EngineCheck]?`, whose `EngineCheck` holds `runs` and `version`, `Install.dismissedVersionNotes: [String]?`, and `engineVersions: [[String: String]]?`, each pair as an object from engine name to plugin identifier.

`plugins.json` with a pair, whose WebKit version the user installed first and whose Chromium version both engines run, and a plugin whose note asking for a Chromium version the user dismissed:

```json
{
  "choices": [{"id": "extension.aaaa…", "isEnabled": true}, {"id": "extension.bbbb…", "isEnabled": true}],
  "installed": [
    {"id": "extension.aaaa…", "source": "file:///…/Reader/", "grant": {…}, "installedAt": 814595493.0,
     "engineChecks": {"webKit": {"runs": true, "version": "22625.2.5.11.1"},
                      "chromium": {"runs": false, "version": "156.0.7+g47dbc1d+chromium-156.0.8078.17"}}},
    {"id": "extension.bbbb…", "source": "file:///…/Reader-Chromium.zip", "grant": {…}, "installedAt": 814595612.0,
     "engineChecks": {"webKit": {"runs": true, "version": "22625.2.5.11.1"},
                      "chromium": {"runs": true, "version": "156.0.7+g47dbc1d+chromium-156.0.8078.17"}}},
    {"id": "extension.cccc…", "source": "file:///…/Notes/", "grant": {…}, "installedAt": 814596020.0,
     "engineChecks": {"webKit": {"runs": true, "version": "22625.2.5.11.1"},
                      "chromium": {"runs": false, "version": "156.0.7+g47dbc1d+chromium-156.0.8078.17"}},
     "dismissedVersionNotes": ["chromium"]}
  ],
  "engineVersions": [{"webKit": "extension.aaaa…", "chromium": "extension.bbbb…"}]
}
```

- `engineVersions` lists the pairs in the order the user made them. Each names an installed plugin at most once and gives each engine one version. A record whose versions are not both in the list, such as one whose package no longer reads, or that names an engine this build does not know, stays in the file and is ignored, so the pair returns when the version reads again. A join drops each ignored record that names one of its plugins, so that no plugin is in two records, and the install of a new plugin drops each one that names it, so that it joins only as the user chooses (see Storage). Files without the key have no pairs, and entries without `dismissedVersionNotes` have nothing dismissed.
- A version that joined under its counterpart's identifier has an entry such as `{"id": "extension.dddd….chromium", …}`, whose package names `extension.dddd…`.
- Engine names are `EngineKind` raw values. The file's types keep them as text, which the manager reads into `EngineKind` keys in memory. It preserves names this build does not know and writes them back unchanged, so an entry from a newer build stays readable.
- An update keeps the entry's `dismissedVersionNotes` and its record, and replaces its `engineChecks` with the update's answers.
- Each join, separation, and dismissal writes the file at once, as choices do, and keeps its effect for the run when the write fails (see Storage).

#### Tests

- Coverage (`EngineCoverageTests`, with a recording engine for each engine): staging records each engine's check, and installing writes `engineChecks` with each engine's version. A package that every engine refuses is refused with the first engine's reason, and its staged copy goes. An entry without `engineChecks`, or with an answer from another engine version, is checked again before the next load, only in the engines without a current answer, the answer is recorded, and the package loads where it runs. Staging checks the installed plugin that the package updates, switched off and never checked. A plugin that no engine accepts any more is switched off with the first engine's reason. A failure to start on one engine leaves the other engines running, stays out of `plugins.json`, is tried again when the plugin is switched on again, and switches the plugin off with each engine's reason only when every engine it ran on failed. The runtime loads each extension only into the engines it runs on, and recording an answer, or another change to the enabled plugins, does not load a running copy again. The kind is unavailable only without an engine, and Chromium alone makes it available. Once the engines run, switched-off plugins are checked where they have no current answer, and none of them loads. A plugin that every engine refused and that the user switches on again is checked again and goes off again with the reason. Only engines whose profiles start count: a listed engine whose profile does not start loses its answers for the run, so that the other engine's refusal or failure to start switches the plugin off, and with no profile started a package installs as unavailable. A removal that an engine misses, because its application or the Persona's profile does not start or no engine runs extensions, deletes the storage there once, at that engine's first pass in a later launch, also with no extension left, and before the engine loads an install with the same identifier; then it leaves `webExtension.json`, which goes with its last entry, while an entry for an engine this build does not know stays. A staged script plugin cannot take the name `webExtension.json`. A plugin that is off after failing to start on every engine that runs it does not say "No engine on this Mac runs it." An engine name this build does not know in `engineChecks` survives reading and writing the file and leaves the entry readable. The review sheet's and Settings' sentences say where the package and the plugin run. WebKit's `check(_:)` passes the sample extension and refuses a package that `WKWebExtension` cannot read, and WebKit names its extension runtime's version (macOS 15.4 and later).
- Pairing rule (`EngineVersionsTests`, with the pair, removal, and guidance tests): staging checks an installed plugin that the package could join, switched off and never checked, before matching it. Packages match by identifier and by name with a matching `author` or `homepage_url`. They do not match by name alone, with a developer field that differs, with `homepage_url`s on one host with different paths, or with a plugin that is in a pair. Complementary checks start the review's choice on the version. Overlapping checks, such as two packages with one `key` that both engines run, start it on Update or the separate plugin, and installing the package as the other engine's version still works. Without an engine to join for, as with WebKit alone, a package with an installed identifier updates as now. Of two matches, the one installed first wins. A version that shares its counterpart's identifier gets `extension.<identifier>.<engine>`, stays listed and paired when a new manager reads `plugins.json`, is paired again from its identifier when a build before this step dropped its record, receives the updates meant for it, and each engine's delegate calls reach that engine's version. Of two versions with one identifier, an update goes to the one from the same source, then the one with the same answers, then the one the review chooses. A package whose identifier is a version's entry identifier, such as a script plugin's, is refused. A version that joins from another place under the identifier of a plugin whose copy runs on the version's engine gets the takeover warning and takes over that copy's data; one from the plugin's own place, or for an engine that refuses the plugin, does not.
- Pairs: one switch turns both versions on or off, and a version that joins takes the pair's switch. One version's failure leaves the other running. The popover's actions and the palette list the pair once and run the version for the tab's engine, also when only the version installed second has the action, which the palette then lists and runs under the version installed first and leaves out while the second is off. Join With… gives each engine one version and refuses a join that leaves a version without one, and a join drops an ignored record that names one of its plugins. With WebKit alone, Join With… lists no plugin and a join that gives Chromium a version is refused; with both engines, a version that Chromium has not checked cannot join for it, the choice for two packages that both engines run starts with the version installed first on WebKit, and a version whose engine runs no extensions after a later launch says so. A request for access at run time names the pair and the asking version. Separate Versions keeps both installed, and a pair that shares an identifier cannot be separated. An update that would leave a version of a pair on no engine is refused.
- Removal of one version: the other keeps its grant, storage, switch, and place, and the record goes. The removed version is unloaded and its engine storage deleted only in engines where no counterpart with the same identifier runs, on or off, also in a later launch for an engine that missed the removal. Remove… removes both. A record whose versions are not both listed stays in the file and is ignored. A version installed again as a new plugin after a removal that `plugins.json` missed pairs with nothing and takes neither the old entry's place nor its dismissed notes. An engine name this build does not know in `dismissedVersionNotes` or `engineVersions` survives reading and writing the file and leaves the entry readable.
- Guidance conditions: a plugin asks for a Chromium version only while a Chromium engine runs extensions and has a current answer, the plugin runs on another engine but not on Chromium, and the note is not dismissed. A failure to start on Chromium makes the plugin ask for a Chromium version. Nothing asks with WebKit alone, for a pair, or while Chromium has not checked the package. Install \<Engine> Version… shows for every unpaired plugin that runs on another engine, whatever the checks found. A dismissal, which Don't Ask Again and Dismiss in Settings and in the popover record and Done does not, survives a new manager reading `plugins.json` and an update. Installing a package that could have joined as a separate plugin, and Separate Versions, dismiss each plugin's note for the other's engines. A Chromium-only plugin asks for a WebKit version. Removing a version brings the request back.

#### Build steps

1. Coverage, built: `EngineExtensions.check(_:)` on WebKit, the host's engines by kind with their versions, only those whose application and the Persona's profile start, checks at staging, of the installed plugin a package updates, before loads without a current answer, of switched-off plugins once the engines run, and of a plugin switched on again after every engine refused it, `engineChecks` in `plugins.json` in the file's text-keyed types, failures to start per engine, loading per engine, the kind unavailable only without an engine, and the review sheet and Settings saying where a plugin runs, with the coverage tests.
2. Counterparts and guidance, built: staging's check of the match a package could join, `engineVersions`, entry identifiers for versions that share an identifier, the pairing rule, the review's choice between the version, Update, and a separate plugin, update targets, Join With… while both engines run extensions and Separate Versions, the warning that a version under its counterpart's identifier takes over its copy's data, the pair's switch, removal, actions, and contributions, Install \<Engine> Version… in every unpaired plugin's section, the install sheet's last step, the Settings note, and the popover row's note, with the pairing, pair, removal, and guidance tests.

VI.1 then added Chromium's `EngineExtensions` with `check(_:)` and lists `extensions` among Chromium's capabilities, so Arch checks the installed packages on Chromium, on or off, once the Persona's profiles start, offers Install Chromium Version… in the section of every unpaired plugin that runs on WebKit, and asks for the Chromium versions that WebKit-only plugins lack.

## Password manager plugins

`docs/password-managers.md` describes their design (IV.21, IV.22, and IV.13).

- The user installs the 1Password and iCloud Passwords extensions from the Web Store in each Persona that needs them, so Arch can prove their identifiers. Arch bundles no third-party code.
- Both need `nativeMessaging` to reach their native apps, so installation asks for Touch ID. Arch finds the apps' host manifests in other browsers' host folders and links them into its own.
- A vendor may ship a separate package for each engine. The user then installs each engine's package as that engine's version of one plugin (see Engine versions); each version reaches the native app under its own identifier.
- 1Password accepts an unlisted browser only when it is signed and runs from `/Applications`, which `scripts/install_app.sh` provides, and the user allows it. The iCloud Passwords helper starts only for a browser with Apple's browser passkey entitlement (IV.14) or for one in the launch constraints that macOS signs into it from Apple's list, which requires a pull request and a macOS update (IV.24).
- Universal Autofill (⌘\\) reads the page's accessibility tree and is not a plugin matter; it needs II.13 on Chromium.
- Each plugin's Settings section lists the native apps that accept it, the conditions Arch does not meet, the user's required step for each of the two vendors, and on WebKit tabs whether the app answered.

## AI hooks and plugins that AI writes

- The built-in AI hooks (VII.6) live in `Browsing`, not in plugins, because plugins have no events or `ai` permission yet: they subscribe to `pageLoaded` and `downloadFinished` at the AI interface's hook center directly. Naming a tab uses `renameTab`; renaming a download uses `renameDownload`. Once plugins have `ai`, a plugin with `ai` that declares hooks will register with the same center under its own feature.
- The plugin API has no other AI-specific part. A plugin with `ai` sends requests through the AI interface (VII.1), which applies the routing table and page data rules. The plugin never sees a provider or a key.
- The composer (VII.7, `docs/ai.md`) writes a script plugin only, never a built-in plugin or a web extension, with no sites or page scripts and with its background script as its only file, and stages its files with `PluginManager.stage(_:writtenBy:)` under an identifier that Arch gives it.
- A plugin that AI wrote uses the same review sheet, which also shows the requests it came from and every file's full source. Install installs it switched off and Install and Enable switched on, with the origin `generated`, and Settings says that AI wrote it.
- Ask for Changes in the review has AI write a new version with the same identifier, which replaces the one under review. Changing an installed plugin with AI, with a review of what changed, is not built yet. Removing a plugin that AI wrote works like removing any plugin.
- Script plugins load code only from their package, so only reviewed files run. A plugin can still act on data it fetches, so its `network` hosts will be part of the review.
- The composer gives the model a reference in `PluginComposerInstructions.swift` for the manifest keys that plugins AI writes may use and the JavaScript API below.

## Swift API

The `Plugins` module lives in `Packages/ARCH/Sources/Plugins` and depends on `ARCHEngine` and on `AI`, through which the composer writes plugins. `Browsing` and `Preferences` depend on it to show contributions. So far `Browsing` hands the manager each tab that a call carries, such as an invocation's; the tab and download members of `PluginContext` will reach the browser through `PluginBrowserHost`, which `Browsing` will implement, so that `Plugins` does not depend on `Browsing`. `Extensions` depends on `ARCHEngine` and `Plugins` and supplies the web extension runtime, which `Browsing` makes for each Persona; it reaches the Persona's engines, tabs, and windows through `WebExtensionHost`, which `Browsing` implements. All types below are public. The listings design the whole API: a member whose comment, or the comment above its group, says `Not built yet` has no code so far, and the Plugins module in `docs/plan.md` Current State describes what is built.

### Identity and manifest

```swift
public typealias PersonaID = UUID

public struct PluginID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    /// Fails for anything but dot-separated labels of letters, digits, and `-`, fewer than two labels, or more than 128 characters. Empty labels fail. Lowercases the letters.
    public init?(rawValue: String)
}

public enum PluginKind: String, Hashable, Sendable {
    case builtIn, script, webExtension
}

public enum PluginOrigin: Hashable, Codable, Sendable {
    case bundled
    case file(URL)
    /// Written by AI through the composer (VII.7).
    case generated(PluginComposition)
    /// Downloaded from the Web Store for the extension identifier (`docs/web-store.md`).
    case webStore(String)
}

/// What a `.crx` file's signatures prove: its developer's key, or also the Web Store's publisher key (`docs/web-store.md`, Package proof).
public enum PluginProof: String, Hashable, Sendable {
    case developer, webStore
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
    public var permissions: Set<PluginPermission>
    public var sites: [MatchPattern]
    /// A web extension's API permissions that no `PluginPermission` stands for, such as `storage`, which come with its install. The package and the installed plugin carry the kind.
    public var extensionPermissions: [String]
    public var contributions: PluginContributions
    /// A web extension's `author`, as text or the email of an author object, lowercased, and its `homepage_url` without scheme, leading `www.`, and trailing `/`, lowercased, by which a package matches an installed plugin as a version of one extension. Nil for other kinds.
    public var author: String?
    public var homepage: String?
    // Not built yet: the version a script plugin's `plugin.json` names, which staging checks against `apiVersion` and keeps nowhere so far, and the fields of site access modes, network hosts, and events.
    public var apiVersion: Int
    public var siteAccess: SiteAccess
    public var network: [String]
    public var events: Set<PluginEventKind>
}

public enum PluginPermission: String, Hashable, Codable, Sendable, CaseIterable {
    case tabs, clipboard, nativeMessaging
    // Not built yet.
    case manageTabs = "tabs.manage"
    case history, downloads, notifications, ai
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

// Not built yet.
public enum SiteAccess: String, Codable, Sendable {
    case none, listedSites, whenInvoked
}

/// What the user granted: a subset of what the manifest asks for.
public struct PluginGrant: Hashable, Codable, Sendable {
    public var permissions: Set<PluginPermission>
    public var sites: [MatchPattern]
    public init(permissions: Set<PluginPermission>, sites: [MatchPattern])
    /// Everything the manifest asks for.
    public init(requestedBy manifest: PluginManifest)
    /// What the review of an update to `manifest` offers at first: everything it asks for, except the sites that the installed version asked for and the user left out.
    public init(updating installed: InstalledPlugin, to manifest: PluginManifest)
    /// One plain sentence for each permission and site, as Settings and the install sheet state the grant.
    public var summaries: [String] { get }
    /// What Touch ID or the login password states before the grant is given, or nil when it needs no confirmation: every website and native apps need it.
    public func confirmationReason(for pluginName: String) -> String?
    // Not built yet, with `siteAccess` and `network` in the initializer.
    public var siteAccess: SiteAccess
    public var network: [String]
}
```

### Contributions

```swift
public struct PluginContributions: Hashable, Codable, Sendable {
    public var commands: [PluginCommand]
    public var menuItems: [PluginMenuItem]
    public var sidebarItems: [PluginSidebarItem]
    public var settings: [PluginSetting]
    public var pageScripts: [PluginPageScript]
    /// Not built yet: a package path to an HTML page shown below the settings form. Script plugins only.
    public var settingsPage: String?
}

public struct PluginCommand: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String?
    public var keywords: [String]
    /// The shortcut of the command's first item in the Plugins menu. The user can change it in Settings ▸ Shortcuts.
    public var shortcut: PluginShortcut?
    /// Not built yet.
    public var takesArgument: Bool
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
    /// Not built yet: package paths of style files.
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
    /// A message from one of the plugin's page scripts. The returned value is the script's reply.
    func receive(_ message: PluginPageMessage) async throws -> PluginValue?
    /// The panel for a sidebar item whose action is `.panel`. The manager asks each time the item opens it.
    func panel(for sidebarItemID: String) -> NSViewController?
    // Not built yet.
    /// Receives only the events the manifest lists.
    func handle(_ event: PluginEvent) async
    func settingsPage() -> NSViewController?
}

extension Plugin {
    public func deactivate() async {}
    public func receive(_ message: PluginPageMessage) async throws -> PluginValue? { nil }
    public func panel(for sidebarItemID: String) -> NSViewController? { nil }
    // Not built yet.
    public func handle(_ event: PluginEvent) async {}
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

/// The plugin's handle on the browser, scoped to one plugin instance in one Persona. Each call checks the plugin's grant and throws `PluginError.permissionDenied` when it does not cover the call, or, once the page members exist, `.siteNotGranted` for a page outside its sites. Once the instance stops, the storage and secrets only read, the other calls that act throw `.stopped`, and badges do nothing.
@MainActor
public protocol PluginContext: AnyObject {
    var pluginID: PluginID { get }
    var personaID: PersonaID { get }
    var grant: PluginGrant { get }
    var storage: any PluginStorage { get }
    var secrets: any PluginSecrets { get }
    func setting(_ key: String) -> PluginValue?
    func setBadge(_ text: String?, onSidebarItem id: String)
    func copyToClipboard(_ text: String) throws

    // Not built yet.
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
    func setEnabled(_ isEnabled: Bool, command id: String)
    func showPanel(_ sidebarItemID: String)
    func notify(title: String, body: String) throws
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
    /// nil for a favorite's tab, which belongs to no space.
    public var spaceID: UUID?
    /// nil unless the grant has `tabs` or covers the page.
    public var title: String?
    public var url: URL?
    public var engine: EngineKind
    public var isPinned: Bool
    public var isSelected: Bool
}

// Not built yet, with the tab, page, and data members of `PluginContext`.
public struct PluginOpenTabOptions: Hashable, Sendable {
    public var spaceID: UUID?
    public var select: Bool
    public var engine: EngineKind?
    public init(spaceID: UUID? = nil, select: Bool = true, engine: EngineKind? = nil)
}

// Not built yet.
public struct PluginDownload: Identifiable, Hashable, Sendable {
    public let id: String
    public var fileURL: URL
    public var sourceURL: URL?
    public var tabID: UUID?
}

// Not built yet.
public struct PluginHistoryEntry: Hashable, Sendable {
    public var url: URL
    public var title: String
    public var lastVisit: Date
    public var visitCount: Int
}

// Not built yet.
public enum PluginScript: Hashable, Sendable {
    /// A file from the plugin's package.
    case file(String)
    /// Script text. Built-in plugins only; other kinds get `PluginError.permissionDenied`.
    case source(String)
}

public struct PluginInvocation: Sendable {
    public var tab: PluginTab?
    /// Set for space menu items: the space whose menu holds the item.
    public var spaceID: UUID?
    /// Set for page context menu items: what the user clicked on, which the plugin receives whatever its grant, since the user chose the item there.
    public var linkURL: URL?
    public var imageURL: URL?
    public var selection: String?
    // Not built yet.
    public enum Source: String, Sendable { case palette, menu, contextMenu, shortcut, sidebar }
    public var source: Source
    public var argument: String?
}

public struct PluginPageMessage: Sendable {
    public var tab: PluginTab
    public var frameURL: URL
    public var isMainFrame: Bool
    public var body: PluginValue
}

// Not built yet.
public enum PluginEventKind: String, Hashable, Codable, Sendable, CaseIterable {
    case tabOpened, tabClosed, tabSelected, pageLoaded, downloadFinished, spaceChanged, settingChanged
}

// Not built yet.
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
    /// nil deletes the Keychain item. Throws `quotaExceeded` for a secret of more than 16 KB, and for a new key once the plugin keeps 64 secrets in the Persona.
    func setSecret(_ secret: String?, forKey key: String) throws
}

public enum PluginError: Error, Hashable, Sendable {
    case permissionDenied(PluginPermission)
    /// The plugin instance whose context the call went through has stopped.
    case stopped
    /// The command acts on a page, and the invocation has none.
    case noPage
    case invalidMatchPattern(String)
    case invalidShortcut(String)
    /// A storage key that starts with `arch.setting:`, the prefix of the plugin's settings.
    case reservedKey(String)
    /// A write would take the plugin's storage, or its secrets, past their limits.
    case quotaExceeded
    case invalidPackage(String)
    case unsupportedAPIVersion(Int)
    case timedOut
    /// Two plugins cannot become, or stop being, versions of one plugin, for the reason the text gives.
    case invalidVersions(String)
    /// The manager's Persona was deleted, so it stages, installs, and stores nothing.
    case closed
    // Not built yet: a page outside the plugin's sites, and a host outside its `network`.
    case siteNotGranted(URL)
    case networkHostNotGranted(String)
}
```

### Manager, runtimes, and the browser host

```swift
public struct InstalledPlugin: Identifiable, Hashable, Sendable {
    /// The install entry's identifier, which names the plugin's folder, choice, storage, and Keychain items: the manifest's, or, for a version that joined a plugin whose version has the same identifier, that followed by `.webkit` or `.chromium`. A built-in plugin's is its manifest's.
    public var id: PluginID { get }
    public var kind: PluginKind
    public var manifest: PluginManifest
    public var origin: PluginOrigin
    /// The proof that the install entry records; nil without one.
    public var proof: PluginProof?
    /// The folder of the installed package; nil for a built-in plugin.
    public var packageURL: URL?
    public var grant: PluginGrant
    public var isEnabled: Bool
    /// nil for a built-in plugin.
    public var installedAt: Date?
    /// Why the manager switched the plugin off in this run, after repeated failures, because it could not start on any engine it ran on, or because no engine runs its package any more, which Settings shows.
    public var failure: String?
    /// Why the plugin's runtime cannot run it on this Mac, such as a web extension while no engine runs them. Its contributions stay out meanwhile.
    public var unavailability: String?
    /// The current answers: whether each engine that runs extensions and checked the package at the engine's present version runs it. Empty for kinds that Arch runs alike on every engine.
    public var engineChecks: [EngineKind: Bool]
    /// Why the package failed to start in this run on engines whose check it passed, until the plugin is switched on again or updates.
    public var engineFailures: [EngineKind: String]
    /// The other version of the plugin, and the engine that the pair's record gives the plugin, in a pair.
    public var counterpart: PluginID?
    public var pairEngine: EngineKind?
    /// The engines whose note asking for a version the user dismissed.
    public var dismissedVersionNotes: Set<EngineKind>
    /// The engines a web extension runs on: those whose current answer runs it, less those where it failed to start, and in a pair only the engine that the pair's record gives it.
    public var engines: Set<EngineKind> { get }
    /// "Runs on WebKit tabs.", "Chromium does not run this version." for a version of a pair whose engine refuses its package, or "No engine on this Mac runs it." when every engine that checked the package refuses it, once an engine has checked the package; nil before, and while it starts on none of the engines that run it. `PluginManager.enginesNote(of:)` adds the version whose engine runs no extensions.
    public var enginesNote: String? { get }
    /// The engines that a pair divides among `running`, those that run the kind on this Mac, for which Settings offers Install <Engine> Version…: each while the plugin runs on another engine. None in a pair.
    public func versionEngines(among running: Set<EngineKind>) -> [EngineKind]
    /// The engine whose version the plugin asks for, by the rule in Guidance, or nil.
    public func missingEngine(among running: Set<EngineKind>) -> EngineKind?
    /// The grant's sentences, then a web extension's other API permissions.
    public var accessSummaries: [String] { get }
}

/// What one engine's runtime found when it checked a package.
public enum PluginEngineCheck: Hashable, Sendable {
    case runs
    /// With why, as a sentence that names the engine, such as `WebKit cannot run this extension: …`.
    case refused(String)
}

/// Two installed web extension plugins of one Persona that are versions of one extension, with the engine each runs on.
public struct PluginEngineVersions: Hashable, Sendable {
    /// WebKit and Chromium, which a pair divides between its versions.
    public static let engines: [EngineKind]
    public var versions: [EngineKind: PluginID]
    public init(_ versions: [EngineKind: PluginID])
    /// The versions in the order of `engines`.
    public var plugins: [PluginID] { get }
}

/// A validated package, staged for the review sheet or installed.
public struct PluginPackage: Identifiable, Sendable {
    public let kind: PluginKind
    public let manifest: PluginManifest
    public let rootURL: URL
    /// The folder or archive the user chose, the Web Store, or how AI wrote the package.
    public let origin: PluginOrigin
    /// What the signatures of a `.crx` file proved at staging, or the install entry's proof for an installed package; nil for other packages.
    public let proof: PluginProof?
    /// Package-relative paths, shown in the review.
    public let files: [String]
    /// The checks of the engines that run the kind on this Mac, made at staging.
    public internal(set) var engineChecks: [EngineKind: PluginEngineCheck]
    /// The installed plugin that the package matches by the rule in Counterparts, the engines it can join it for, in the order of `EngineKind`, and the one of them that the review's choice starts on when the two complement each other.
    public internal(set) var counterpart: PluginID?
    public internal(set) var joinableEngines: [EngineKind]
    public internal(set) var suggestedEngine: EngineKind?
    /// The installed plugin that the package updates, by the rule in Counterparts, or nil for a new plugin. The review sets it to the version the user chooses from `updateChoices`, the two versions with the package's identifier where the rule leaves both.
    public var updates: PluginID?
    public internal(set) var updateChoices: [PluginID]
    /// The review's sentences: "Runs on WebKit tabs.", then each engine's refusal.
    public var engineNotes: [String] { get }
    /// "Runs on WebKit tabs." or "Runs on WebKit and Chromium tabs."; nil for no engine.
    public static func runsNote(on engines: Set<EngineKind>) -> String?
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

/// The contributions of the enabled plugins, in the order the manager registered them, a pair once, with the commands of its other version that its own lacks while that one is on. Menu items and sidebar items whose commands the plugin does not contribute are left out.
public struct PluginContributionIndex: Sendable {
    public func paletteCommands(matching text: String) -> [Attributed<PluginCommand>]
    public var sidebarItems: [Attributed<PluginSidebarItem>] { get }
    /// For the page context menu, `location` names the contexts of the click, and an item shows when it lists one of them.
    public func menuSections(at location: PluginMenuLocation) -> [PluginMenuSection]
    /// The page scripts, wrapped with their address guards, for every tab of the Persona.
    public var pageScripts: [EnginePageScript] { get }
}

/// Runs the installed plugins of one kind that the manager does not run itself in one Persona; the manager runs built-in and script plugins. `Extensions` provides the web extension runtime.
@MainActor
public protocol PluginRuntime: AnyObject, Sendable {
    nonisolated var kind: PluginKind { get }
    /// The file at the top of a package of the kind, such as `manifest.json`, by which staging tells a package's kind.
    nonisolated var manifestFileName: String { get }
    /// Reads a staged or installed package of this kind into a manifest, off the main thread, without running any of it.
    nonisolated func manifest(forPackageAt root: URL, source: URL) throws -> PluginManifest
    /// Why plugins of the kind cannot run on this Mac, or nil.
    var unavailability: String? { get }
    /// The engines that run plugins of the kind on this Mac now, which check its packages, each with the version of its runtime that answers record. Empty for kinds that Arch runs alike on every engine.
    var engines: [EngineKind: String] { get }
    /// Checks the package in each engine of `engines` without running any of it: at staging, for the package and the installed plugin it updates.
    func check(packageAt root: URL) async -> [EngineKind: PluginEngineCheck]
    /// Set by the manager, which records each answer with the engine's version: engines without a current answer checked an installed plugin's package, on or off, and every engine an enabled plugin's that no engine ran by its current answers.
    var onCheck: ((PluginID, [EngineKind: PluginEngineCheck]) -> Void)? { get set }
    /// Set by the manager, which keeps a plugin's failure to start on an engine for the run and switches the plugin off once it has failed on every engine it ran on.
    var onEngineFailure: ((PluginID, EngineKind, String) -> Void)? { get set }
    /// Set by the manager, which reads each plugin's current answers and the kind's unavailability again once `engines` lost an engine, as one whose profile did not start for the Persona.
    var onEnginesChange: (() -> Void)? { get set }
    /// Set by the manager: the runtime's own file in the Persona's folder, `<kind>.json`, whose name no plugin identifier may take, such as `webExtension.json` with the removals that engines missed.
    var runtimeFile: URL? { get set }
    /// The installed plugins of the kind, on or off, each time they change, so that the runtime runs what the enabled ones run without a command and has the others' packages checked; none while the kind is unavailable.
    func run(_ installed: [InstalledPlugin])
    /// A new instance, which the manager starts at the plugin's first command, panel, or page script value.
    func makePlugin(_ installed: InstalledPlugin) -> any Plugin
    /// Deletes what the runtime keeps of a removed plugin, except in an engine where the other version of its pair runs under the same engine identifier; an engine that does not run in this launch deletes it in a later one.
    func remove(_ installed: InstalledPlugin)
    /// The types the open panel accepts for a package of the kind that `engine` runs: a folder or a `.zip` archive for both engines.
    func packageTypes(for engine: EngineKind) -> [UTType]
}

/// Not built yet: what `Browsing` will provide so that plugins can act on tabs without `Plugins` depending on `Browsing`.
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
    /// In install order, where the remaining version of a pair takes the pair's place.
    @Published public private(set) var plugins: [InstalledPlugin]
    @Published public private(set) var contributions: PluginContributionIndex
    /// The pairs whose versions are both listed, in the order the user made them.
    @Published public private(set) var engineVersions: [PluginEngineVersions]
    /// Why the last write of `plugins.json` failed while the file lacks changes of the run, which Settings shows with Try Again; nil once a write succeeds (see Storage).
    @Published public private(set) var listWriteFailure: String?

    /// `directory` is the app's Application Support folder; the Persona's plugins live in `Plugins/<persona id>/` inside it. Reads `plugins.json`, registers the built-in plugins and reads the installed ones' packages, and tells each runtime the installed plugins of its kind, which runs what the enabled ones run without a command, such as a web extension's content scripts. Starts no plugin's instance.
    public init(persona: PersonaID, directory: URL, builtIns: [any BuiltInPlugin.Type], runtimes: [any PluginRuntime] = [])
    /// Copies a folder or archive into staging and validates it, refusing a `.crx` file whose signatures do not hold; the engines that run its kind check it, and the installed plugins it could update or join where they have no current answer, and the package names what the review offers. Throws, with the first engine's reason, for a package that every engine refuses.
    public func stage(_ url: URL) async throws -> PluginPackage
    /// Stages a `.crx` file that Arch downloaded with the origin `file` or `webStore`; a store package must carry the store's proof for that identifier and not be a theme (`docs/web-store.md`, Install flow).
    public func stage(_ file: URL, origin: PluginOrigin) async throws -> PluginPackage
    /// Writes the files of a plugin that AI wrote, by package path, into staging and validates them.
    public func stage(_ files: [String: String], writtenBy composition: PluginComposition) async throws -> PluginPackage
    /// Deletes a staged package the user did not install.
    public func discard(_ package: PluginPackage)
    /// Records the package's origin with the install. With `asVersionOf` and `engine`, installs the package as that plugin's version for the engine, on or off as the plugin is; otherwise updates `package.updates` or installs a new plugin, and a new plugin that could have joined its counterpart dismisses both plugins' notes for each other's engines. Throws for a version that cannot join and an update that would leave a version of a pair on no engine, and, having undone the move, when `plugins.json` cannot record the install. Returns the plugin's identifier.
    @discardableResult
    public func install(_ package: PluginPackage, grant: PluginGrant, isEnabled: Bool, asVersionOf plugin: PluginID? = nil, for engine: EngineKind? = nil) throws -> PluginID
    /// Records the choice in `plugins.json`. Switching a plugin off drops its contributions and badges and deactivates its running instance. Either version of a pair switches both.
    public func setEnabled(_ isEnabled: Bool, for id: PluginID)
    /// Not built yet.
    public func setGrant(_ grant: PluginGrant, for id: PluginID) async throws
    /// Removes one plugin, or one version of a pair, whose other version takes the pair's place and whose record goes.
    public func remove(_ id: PluginID) throws
    /// Writes `plugins.json` again after a write failed, for Settings' Try Again.
    public func writeListAgain()

    // Engine versions.
    /// Why the package cannot join `id` as its version for `engine`, or update a version of a pair, as the review states it; nil when it can.
    public func versionRefusal(for package: PluginPackage, joining id: PluginID, for engine: EngineKind) -> String?
    public func updateRefusal(for package: PluginPackage, updating id: PluginID? = nil) -> String?
    /// The review's warning that a version under the plugin's identifier, from another place, takes over the data of the plugin's copy on the engine; nil without one.
    public func versionTakeover(for package: PluginPackage, joining id: PluginID, for engine: EngineKind) -> String?
    /// The plugin, or for a version of a pair the version installed first, whose name and place the pair takes.
    public func leadVersion(of id: PluginID) -> InstalledPlugin?
    /// The engine whose version the plugin asks for (see Guidance), or nil, and the engines for which its section offers Install <Engine> Version….
    public func missingEngine(of id: PluginID) -> EngineKind?
    public func versionEngines(of id: PluginID) -> [EngineKind]
    /// Where the plugin runs, as Settings says it, with "Chromium runs no web extensions on this Mac." for a version whose engine runs none.
    public func enginesNote(of id: PluginID) -> String?
    /// The unpaired web extension plugins that Join With… lists for the plugin; none while an engine that a pair divides runs no web extensions on this Mac.
    public func joinCandidates(of id: PluginID) -> [InstalledPlugin]
    /// The open panel's types for the plugin's version for the engine, from its kind's runtime.
    public func packageTypes(forVersionOf id: PluginID, for engine: EngineKind) -> [UTType]
    /// The pair Join With… starts on: each engine to the plugin whose answer alone runs it there, else to the one installed first unless it refuses the engine; where both would go to one plugin, the other takes the engine where its answer is best, so that, of two that both engines run, the one installed first keeps WebKit.
    public func proposedJoin(of id: PluginID, with other: PluginID) -> PluginEngineVersions?
    /// Throws `PluginError.invalidVersions` for a pair that does not give each engine one of two unpaired installed web extensions, that gives a version an engine that runs no web extensions on this Mac, or whose version's current answer for its engine refuses it or is missing. The pair takes the switch of the version installed first, and the join drops each ignored record that names one of its plugins.
    public func join(_ versions: PluginEngineVersions) throws
    /// Throws `PluginError.invalidVersions` for a pair whose versions share an engine identifier. Dismisses each version's note for the engines the other runs on.
    public func separate(_ id: PluginID) throws
    public func dismissVersionNote(of id: PluginID, for engine: EngineKind)

    /// Runs a command that the enabled plugin contributes, in a pair also one of its other version's that its own lacks while that one is on.
    public func run(_ command: PluginCommandRef, _ invocation: PluginInvocation) async
    /// Starts the plugin if needed and asks it for the item's panel. Nil, with a beep, when it offers none.
    public func panel(for item: Attributed<PluginSidebarItem>) async -> NSViewController?
    public func badge(on item: Attributed<PluginSidebarItem>) -> String?
    /// Not built yet.
    public func post(_ event: PluginEvent)
    /// Whether one of the enabled plugin's page scripts runs at `url`, for Reload Matching Tabs.
    public func pageScriptsCover(_ url: URL, of id: PluginID) -> Bool
    /// A message from a page script in `tab`, which the session describes in full; the manager removes what the grant does not cover. Returns the JSON reply, or nil.
    public func receive(_ message: EnginePageScriptMessage, from tab: PluginTab) async -> String?

    /// Stops the plugins for good when the user deletes the Persona, dropping storage changes that have not reached the files. From then on staging, installs, and setting values throw `PluginError.closed`.
    public func close()
    /// Whether `close()` ran.
    public private(set) var isClosed: Bool
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

### Web extension runtime

```swift
/// What `Browsing` provides so that a Persona's web extensions reach its engines, tabs, and windows.
@MainActor
public protocol WebExtensionHost: AnyObject {
    /// The engines whose runtime runs web extensions on this Mac, each with its extension runtime's version (`Engine.extensionRuntimeVersion`), WebKit's framework version or the CEF version, which engine checks record, without starting any profile. An engine whose application did not start is not one of them.
    var extensionRuntimeVersions: [EngineKind: String] { get }
    /// The Persona's profiles in those engines, by engine, which the host starts if they have not started. An engine whose application or profile does not start is left out, and no engine's profile stands in for another's.
    func extensionEngines(in persona: PersonaID) -> [EngineKind: any EngineExtensions]
    func webContents(ofTab id: UUID) -> (any EngineWebContents)?
    func activate(_ tab: any EngineWebContents)
    func close(_ tab: any EngineWebContents)
    /// Shows an action's popup from the site settings button of the window that shows the tab through `ExtensionPopupPresenter`: an engine's popover as it is, or a popup page's view in a popover of the presenter's. False when no window shows it.
    func present(_ popup: EngineExtensionPopup, for tab: (any EngineWebContents)?) -> Bool
    /// Opens a tab of the Persona in the engine, in the window, as the host reports windows, or in the Persona's focused one, at the index among that window's tabs of the engine or after its active tab, and completes with its web contents once the window reports it.
    func openTab(_ url: URL?, in engine: EngineKind, persona: PersonaID, window windowID: UUID?, active: Bool, index: Int?, completion: @escaping ((any EngineWebContents)?) -> Void)
    /// Opens a small window of the Persona whose one tab, in the engine, loads the address, or the new tab page for none, which extensions see with only that tab; several addresses open nothing. Completes with its identity once it is reported, or with nil when it opens none.
    func openWindow(with urls: [URL], in engine: EngineKind, persona: PersonaID, focused: Bool, completion: @escaping (UUID?) -> Void)
    func presentSheet(_ alert: NSAlert, for tab: (any EngineWebContents)?, completion: @escaping (NSApplication.ModalResponse) -> Void)
}

/// The web extensions of one Persona: the `webExtension` kind's runtime and the engines' extension delegate.
@MainActor
public final class WebExtensionRuntime: ObservableObject, PluginRuntime, EngineExtensionsDelegate {
    /// `nativeMessagingHosts` is the folder of the host manifests that name the native apps extensions may reach.
    public init(persona: PersonaID, host: any WebExtensionHost, nativeMessagingHosts: URL)
    /// The Persona's windows and the focused one, each time they change.
    public func setWindows(_ windows: [EngineExtensionWindow], focusedWindowID: UUID?)
    /// The actions of the enabled extensions that have one, for the site settings popover, a pair once, and of those without one while the tab's engine keeps them from the tab's site.
    public func actions(for tab: any EngineWebContents) -> [WebExtensionActionItem]
    /// Runs the action of the extension, or of the version of its pair that the tab's engine runs. False when no engine runs it for the tab.
    @discardableResult public func performAction(of id: PluginID, for tab: any EngineWebContents) -> Bool
    /// Allows that version on the tab's site, where its engine kept it from running.
    public func grantSiteAccess(of id: PluginID, for tab: any EngineWebContents)
}

/// One for each plugin, and one for a pair, whose identifier and name are its version installed first's, whichever version has the action.
public struct WebExtensionActionItem: Identifiable {
    public let id: PluginID
    public let name: String
    /// The action of the version that the tab's engine runs. Nil while it runs none, as when it refused the package, or before it loaded.
    public let action: EngineExtensionAction?
    /// The engines the plugin's enabled versions run on, for the note on another engine's tab, and whether the plugin asks for the tab's engine's version.
    public let engines: Set<EngineKind>
    public let asksForVersion: Bool
    /// Whether the engine kept the extension from the tab's site, for Allow on This Site.
    public var wantsSiteAccess: Bool { get }
}

// Browsing, BrowserSession
/// Set by the app shell: opens Settings ▸ Plugins at the plugin in the Persona with the open panel for the engine's version, for Install <Engine> Version… in the site settings popover, with the tab's space, which the review names with the Persona.
public var installEngineVersion: ((Persona.ID, Space.ID?, PluginID, EngineKind) -> Void)?
```

### JavaScript API for script plugins

The runtime adds a bridge script to every plugin document to define `arch`. Each call is a promise that resolves with the Swift call's result or rejects with an `Error` whose message is the `PluginError` case name, such as `permissionDenied`, or `invalidCall` for a call the bridge cannot read or a value the storage cannot hold. The background script sets its listeners when it runs; a command without a listener fails. The bridge currently has `commands.onRun`, `pages.onMessage`, `storage`, `secrets`, `settings.get`, `ui.setBadge`, and `ui.copy`; the rest of the table follows as `PluginContext` gains its members.

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
5. The web extension runtime on WebKit as a `PluginRuntime` (`Extensions`), built; then engine versions in the two steps of Engine versions, both built; VI.1 added Chromium; IV.26 added package proof, IV.17 the Web Store's client and staging, IV.18 its entry points, IV.19 Chromium's store button, and IV.20 its updates; the rest of the store installs (IV.27 and IV.17's page hosts) and the password managers (IV.21, IV.22, and IV.13) follow.
6. VII.7 builds the composer on the staging and review path. The `ai` permission and plugin hooks on VII.6's hook center follow.

## Open decisions

- Isolation on Chromium: plugin page scripts share the page's main world until a CEF patch adds isolated worlds. The alternative is to run plugin page scripts on WebKit tabs only.
- Sandbox for script plugins: a hidden `WKWebView` per running plugin costs a web content process each. JavaScriptCore in the app process would cost less. It provides no process isolation, and its execution time limit is private API.
- One extension, two runtimes: each engine keeps its own copy of an extension's state and storage, so the user may unlock a password manager once per engine.
- Engine versions by name: without a shared `key`, two packages match only by name and a matching developer field, which a package can copy, as it can copy a `key`. The review's choice, which starts on joining only for packages whose checks complement each other, and Separate Versions are the safeguards. Whether a matching name alone should pair two packages whose manifests name no developer is open; until then the user joins them with Join With… or Install \<Engine> Version….
- Plugin fetches carry no Persona cookies. A plugin that needs a signed-in site must use a page script on that site.
- Site access defaults to `whenInvoked` when a manifest asks for all sites.
- The 10-second hang limit, 30-second idle stop, and 5 MB storage limit are starting values.
