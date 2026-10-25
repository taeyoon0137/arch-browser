# Plugin system design

## Purpose and scope

- This note designs Arch's plugin system for queue task V.11 and rows 44 and 50 of `docs/features.md`. It also covers how the parts that build on plugins fit: web extensions, which run on WebKit and later on Chromium (VI.1), the password manager plugins (IV.13, row 39), Personas (III.12), AI hooks (VII.6), and plugins that AI writes (VII.7, row 55).
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
| `webExtension` | Manifest V3 web extension package | `WKWebExtensionController` on WebKit tabs; CEF's extension runtime on Chromium tabs after VI.1 | A folder or `.zip` the user chooses; `.crx` files are not read yet | Installed in one Persona |

A folder with `plugin.json` is a script plugin. A folder with a `manifest.json` is a web extension, which must have `manifest_version` 3. Arch refuses other folders. For script plugins, it refuses manifests with an `apiVersion` higher than the app supports and keys it does not read (see Keys the script runtime reads); a web extension's manifest is read for what Arch shows and grants (see Web extensions as plugins), and the engines read the rest.

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
| `id` | Reverse-DNS identifier: two or more dot-separated labels of ASCII letters, digits, and `-`, none empty, at most 128 characters in all. Arch lowercases it, so identifiers that differ only in case name one plugin and one folder. A later install with the same `id` in the same Persona is an update |
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
- Granting access to all sites or `nativeMessaging` asks for Touch ID through LocalAuthentication, following the Platform integration table. `PluginGrant.confirmationReason(for:)` holds the rule for the install sheet and for a web extension's requests at run time.
- A web extension's `tabs`, `clipboardWrite`, and `nativeMessaging` are Arch's `tabs`, `clipboard`, and `nativeMessaging`. Its other API permissions, such as `storage` or `cookies`, come with the install, as in other browsers: the install sheet and Settings list them in one sentence (`PluginManifest.extensionPermissions`), and only its sites can be left out.
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
| `unavailable` | Cannot run on this system or engine, with the reason, such as a web extension while no engine runs them, as below macOS 15.4 |

1. Stage: the user chooses a folder or archive with `NSOpenPanel` in Settings ▸ Plugins, or the composer (VII.7) hands over the files that AI wrote. Arch copies the folder, or writes the files, to `Staging/<UUID>/` in the Persona's folder, off the main thread, tells its kind by its manifest file, reads and validates the manifest through the kind's runtime for a kind other than script plugins, has the engines that run a web extension check it (see Engine versions), and lists the files. An update of an installed plugin must be of the same kind. `ditto` extracts an archive and keeps every entry inside the destination; the package is the archive's top level or its only folder. A package that is or holds a symbolic link is refused, since a link could lead to files outside it, and so is one with a built-in plugin's identifier, with an identifier that starts with `local.arch.browser.` or `local.arch.generated.`, which Arch renames at launch (see Storage), or with `plugins.json` or `plugins.unreadable.json` as its identifier, since its folder would take that file's name in the Persona's folder. Nothing in the package runs before the user installs it. The manager clears `Staging/` when it starts.
2. Review: the install sheet shows the name, version, origin, where a web extension runs, permissions, sites, and files. For a plugin that AI wrote it also shows the requests it came from and every file's source, and offers Ask for Changes (`docs/ai.md`, Features that AI adds at run time).
3. Install: Arch moves the staged package into the Persona's plugin folder and records it in `plugins.json`. It is disabled unless the user chose Install and Enable. Cancel deletes the staged package.
4. Enable: Arch registers the contributions, adds the page scripts to the Persona's tabs from their next load, and sends `activate` when the background first starts.
5. Update: installing the same `id` again replaces the package after review and keeps the plugin's place, storage, and secrets. Identifiers are not signed, so a package from another place than the installed plugin's, such as a folder or archive for a plugin that AI wrote, may only claim its identifier: the sheet then warns that the package takes over the plugin's data, and the user decides. A running background stops, and the next use starts the new code.
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
- Secret settings and `arch.secrets` use Keychain Services: generic password items with the service `xyz.taeyoon.arch.plugin.<plugin id>` and the account `<persona id>/<key>`, accessible when unlocked and not synchronizable, in the login keychain as the AI module's keys are. Settings ▸ Plugins shows only whether a secret is saved, which it reads without the secret, so macOS does not ask for the keychain password. Removing a plugin deletes the service's items whose accounts start with `<persona id>/`, which it finds by their attributes alone. A deleted Persona's items go at the next launch (see Personas).
- Web extensions keep their own extension storage in the engine: WebKit under the Persona's `WKWebExtensionController` configuration, the default one for the default Persona and the one with the Persona's identifier for any other, in `~/Library/WebKit/<bundle identifier>/WebExtensions/`; Chromium will keep it in the Persona's CEF cache path. Removing an extension deletes its storage records in the engines that run in the Persona, which start for it, and deleting a Persona deletes its extensions' records at the next launch. WebKit keeps a small state file for each extension it loaded, which no public API removes.
- Earlier builds gave the built-in plugins identifiers that start with `local.arch.browser.`, plugins that AI wrote identifiers that start with `local.arch.generated.`, and secrets the service prefix `local.arch.browser.plugin.`. At launch, before any manager exists, `PluginIdentifierMigration` moves that data to `xyz.taeyoon.arch.` (Page Address becomes `xyz.taeyoon.arch.page-address`) and `xyz.taeyoon.arch.generated.`: each Persona's plugin folders, with the identifier in a script plugin's `plugin.json`, the identifiers in `plugins.json`, the Keychain items, which move to `xyz.taeyoon.arch.plugin.<plugin id>`, and the user's shortcuts for plugin commands. An item moves only while its new name is free, and the old item goes only once the new one exists, so a run that stopped partway finishes at the next launch; a `plugins.json` entry, Keychain item, or shortcut that already exists under the new identifier wins, and a folder whose new name is taken stays. A folder whose `plugin.json` cannot take the new identifier, as on a full disk, keeps its name until a later launch writes it, since the manager reads a package only under the identifier its manifest names. A Keychain item that has not moved yet, as when the user refused the keychain prompt, counts by the service it moves to, so removing its plugin or deleting its Persona deletes it, and no later launch brings it back. Staging refuses the old identifiers, so nothing installs under them again, and no build saves secrets under the old prefix, so once every item has moved, `ARCHPluginSecretsMoved` keeps later launches from listing the Keychain's items again.
- Sync (V.9) does not cover plugins. A later task can sync `plugins.json` without packages or secrets.

## Personas

- Each Persona has one `PluginManager`. A plugin sees only its Persona's spaces, tabs, history, and downloads. It gets events only from them. A command therefore gets the window's selected tab only when the tab belongs to the plugin's Persona, so neither a favorite's tab of another Persona nor the selected tab under the menu of a space whose Persona differs from the tab's reaches it.
- The session creates a Persona's manager when a tab or window of the Persona first needs it (`BrowserSession.plugins(in:)`) and keeps it in the Persona's `PersonaEngines`. A window shows the contributions of its Persona, its current space's, which for a small window is its tab's, and runs its palette commands and sidebar items through that Persona's manager. A tab's page scripts and the plugin items of its page's and its row's context menus come from the tab's Persona, and those of a space's menu from the space's. The Plugins menu follows the active window's Persona, or the default one while no window is open. Settings ▸ Plugins shows one Persona's plugins, with a picker once there are two Personas, and installs plugins into that Persona. A review sheet still open when the user deletes its Persona closes without installing.
- Installing a plugin in two Personas creates two installations with separate grants, storage, secrets, and background processes. Once there are two Personas, Settings will offer Install in Another Persona, which copies the package and asks for a new grant; it is not built yet.
- Built-in plugins exist in every Persona. A new Persona enables the built-in plugins that are on by default.
- Deleting a Persona closes its manager (`close()`): its plugins leave the list, so their contributions go and nothing starts them again, their running instances stop, a script plugin's background web view with them, and their contexts stop acting, and storage changes that have not reached the files are dropped. The session then stops passing the manager's page scripts to tabs and drops it. At the next launch, before any engine starts, the removal pass calls `PluginManager.removeData(ofPersona:in:)`, which deletes the Keychain items of every plugin whose account starts with `<persona id>/` and then the Persona's `Plugins/<persona id>/` folder, with its installed packages and the packages left in `Staging/`. The Persona stays in `removedPersonaIDs`, and the engines keep its storage, until both are gone.

## Web extensions as plugins

The `Extensions` module turns a web extension into a plugin of the `webExtension` kind. `WebExtensionRuntime`, one per Persona, is the kind's `PluginRuntime`: it reads `manifest.json` into a `PluginManifest` without any engine, so that one install serves every engine, and loads each enabled extension into the Persona's profiles in the engines that run extensions and its package, through their `EngineExtensions` (`docs/engine-protocol.md`, Tier 2; see Engine versions).

| Extension feature | Plugin contribution or permission |
|---|---|
| `name`, `version`, `description` | The plugin's name, version, and summary. A whole `__MSG_<name>__` text comes from `_locales/<locale>/messages.json` in the user's preferred languages, then the default locale |
| `action` | An item in the site settings popover with the action's icon, label, and badge for the tab, and an `action` command, titled with its default title or the extension's name, which the palette lists. The popup shows in a popover from the site settings button |
| `permissions` | `tabs`, `clipboardWrite`, and `nativeMessaging` as Arch's permissions; the others as `extensionPermissions`, which come with the install |
| `host_permissions` and `content_scripts[].matches` | The install sheet's sites, each with a switch. Patterns that Arch's match patterns cannot hold, such as `file:///*` or one with a port, are left out |
| Requests at run time (`permissions.request` and the access WebKit asks about) | Arch's own sheet on the tab, in the install sheet's sentences; sites other than web pages and `nativeMessaging`, which only the install grants, are never granted, and every website needs Touch ID or the login password. The answer lasts while the extension stays loaded |
| `content_scripts`, `background` | Run by the engine's extension runtime, not by Arch's page scripts |
| `nativeMessaging` | Arch relays messages to the native app (see below) |
| `commands`, `options_ui` or `options_page` | Not built yet: commands with their suggested shortcuts, and a settings page entry that opens the options page in a sheet |

- Refusals: `PluginError.invalidPackage` with a sentence that names the field, for invalid JSON, a `manifest_version` other than 3, a missing `name` or `version`, a `key` that is not Base64 text, and a message that the default locale lacks.
- Identifier: Arch uses Chromium's identifier, the first 128 bits of the SHA-256 digest of the public key in the manifest's `key`, each hexadecimal digit written as a letter from `a` to `p`, so each engine knows the extension alike. Without a key, the digest is of the path the user installs from, as Chromium names an unpacked extension, so installing from the same place again is an update. The plugin identifier is `extension.<identifier>`. WebKit receives the identifier as the context's `uniqueIdentifier` and the base URL `webkit-extension://<identifier>/`, so the extension's storage lasts across launches. Nothing proves that a `key` belongs to the package that carries it, since the key is public: an update that claims an installed extension's identifier from another place gets the install sheet's warning (see Lifecycle).
- Loading: each change to the engines waits for the one before. An extension loads with the API permissions its grant covers, those that come with the install, and its granted sites, every web page as `<all_urls>`, which an extension checks for with `permissions.contains`; one whose install changed loads again; one switched off or removed unloads, and a removal also deletes its storage in the engines; an extension that an engine cannot start leaves that engine, and the manager switches it off with why once it has failed on every engine it ran on (see Engine versions). The plugin's instance runs the action on its invocation's tab and fails, so the manager beeps, without a tab whose engine runs the extension.
- WebKit: one `WKWebExtensionController` per Persona's profile, which every web view of the profile uses (macOS 15.4 and later; below it, and until VI.1, no engine runs web extensions, and web extension plugins are `unavailable`). Its tabs are the profile's web contents and its windows the windows the app reports. Each space of the Persona is a window: its tabs in sidebar order, after the open favorites' tabs that a window shows on it (a favorite's tab that no window shows is in the Persona's first space), then the tabs of the space that small windows show; its active tab is the one a window shows there, or else the one selected last; and the space of the window that last became main is the focused window when it is the Persona's. An extension's `tabs.update` with `active` selects a tab, in the window that shows it or else as a tab that no window shows is selected, which takes a favorite's tab to a window of its Persona, and `tabs.remove` closes it into the closed list. Content scripts run only in pages of a persistent store, since WebKit treats the web views of a non-persistent store as private.
- Chromium: after VI.1, CEF's extension runtime loads the same package into the Persona's `CefRequestContext` (needs verification). Until then, an extension runs on WebKit tabs only: its row in the site settings popover is dimmed on a Chromium tab with a note that says so, and its palette command beeps there.
- One install, two runtimes: each engine runs its own copy of the extension with its own background and storage. An extension's state, such as a password manager's lock, is not shared between engines. Each copy lists its own engine's tabs only. A package that only one engine runs, and an extension whose developer ships a package per engine, follow Engine versions below.
- Native messaging: Arch answers `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)` and `webExtensionController(_:connectUsing:for:completionHandler:)` on WebKit for an extension whose grant has `nativeMessaging`, which only the install gives, since requests at run time never grant it. It finds the app through its host manifest in Chromium's format, `<name>.json` in `~/Library/Application Support/Arch/NativeMessagingHosts/`, whose `name` matches, whose `type` is `stdio`, whose `path` is absolute, and whose `allowed_origins` lists `chrome-extension://<identifier>/`; a name is dot-separated runs of lowercase letters, digits, and `_`, so it cannot lead out of the folder. Arch starts the app with that origin as its argument and exchanges messages over its standard input and output, each a 32-bit length in the Mac's byte order followed by UTF-8 JSON, up to 1 MB from the app. A single message ends the app after its first reply; a port lasts until the extension or the app ends it. Chromium's runtime does its own native messaging after VI.1. Whether the vendors' apps install host manifests for Arch needs verification in IV.13.
- Not built yet: options pages, `commands`, tabs and windows that extensions open with `tabs.create` or `windows.create`, extension pages in tabs, `.crx` files, and grants made at run time that last across launches.

### Engine versions

Many developers ship a separate package for each engine, and some packages load in one engine's runtime only. Arch therefore records which engines run each web extension's package, shows two packages of one extension in a Persona as one plugin with a version per engine, lets the user add the other engine's version to any web extension plugin, and asks for it where a plugin does not run on an engine that runs extensions. Coverage, the first of the two steps at the end of this section, is built; Counterparts and Guidance, the second, are not. Every rule here treats the engines alike, and the tests stand a recording engine in for Chromium, so that VI.1 only supplies Chromium's extension runtime.

#### Coverage

- Each web extension plugin records which engines run its package, as each engine's runtime finds when it checks the package: WebKit runs it when `WKWebExtension(resourceBaseURL:)` reads it, and Chromium when CEF's extension runtime accepts it, after VI.1 (needs verification). A check reads the package without running any of it, through `EngineExtensions.check(_:)`, and starts the Persona's profile in the engine as loading does. `WKWebExtension(resourceBaseURL:)` throws only for a missing or unreadable manifest and collects other problems in its `errors`, so WebKit runs nearly every package that Arch's manifest reader accepts, packages built for Chromium among them. Whether some of those `errors`, such as one about the background, should count as a refusal needs verification. A check therefore tells where a package can run, not which engine its developer built it for, and no rule below waits for an engine to refuse the other engine's package.
- At staging, the kind's runtime checks the package in each engine that runs web extensions on this Mac, which is WebKit from macOS 15.4 until VI.1. It also checks the installed plugins that the package could update or join (see Counterparts), on or off, in each such engine that has no current answer for them, and the manager records those answers; so far this is the plugin with the package's identifier, which the package updates, and the second step adds the match it could join. A package that every engine that checks it refuses is refused with the first engine's reason, WebKit's before Chromium's, such as `WebKit cannot run this extension: …`. Without such an engine nothing is checked, and the package installs as an unavailable plugin, as now. The review sheet says where the package runs, such as "Runs on WebKit tabs.", and gives each engine's refusal, such as "Chromium cannot run this extension: …".
- Each answer records the version of the engine's extension runtime that gave it: WebKit's framework version, or the CEF version. An answer is current while the engine has that version. An engine without a current answer for an installed package checks it, whether the plugin is on or off: at the first launch of a build with this step for packages installed before it, for every package once Chromium runs extensions (VI.1), and whenever a macOS update or a newer CEF changes the engine's version. The runtime does so in each pass over the engines, before it starts an enabled plugin's package in any engine, and the manager records each answer; a switched-off plugin's package does not load. A pass starts the Persona's profiles only for an enabled plugin, so switched-off plugins alone start no engine, and their packages are checked once the profiles run, for an enabled plugin or a staging. An enabled plugin whose package no engine that runs extensions accepts any more is switched off with the first engine's reason. `plugins.json` keeps answers without reasons, so switching such a plugin on again has every engine check its package again, and the plugin goes off again with the reason.
- `plugins.json` keeps the answers in each web extension's install entry as `engineChecks`, an object from engine name to the answer and the version that gave it: `"engineChecks": {"webKit": {"runs": true, "version": "22625.2.5.11.1"}}`. An engine missing from it has not checked the package. An engine name this build does not know stays in the file and counts as no check. An update records its own answers.
- A package that passed an engine's check but fails to start there leaves that engine only: the runtime unloads it there, and the manager keeps the reason by engine in `InstalledPlugin.engineFailures` for the run, not in `plugins.json`. The plugin's row says it, such as "Arch could not start it on Chromium tabs: …", and its other engines keep their copies running. The engine counts as one the plugin does not run on until the user switches the plugin on again or it updates, so Guidance asks for that engine's version. The manager switches the plugin off only when it has failed on every engine it ran on, with each engine's reason; meanwhile Settings lists the failures under the plugin.
- An entry without `engineChecks`, as builds before this step write it, reads as checked by no engine, so it runs as it does now: WebKit checks it before loading it at the next launch, a package it runs keeps running, and one it refuses is switched off with WebKit's reason, as its failed load is now. A build before this step drops the keys that this step adds whenever it writes the file, and lists no version whose identifier ends in an engine (see Counterparts). The next newer build checks the packages again and pairs each such version again with the plugin of its identifier, for the engine its identifier names; the user joins the other pairs again.
- The runtime loads each enabled extension only into the engines it runs on, `InstalledPlugin.engines`: those whose current answer runs its package and where it has not failed to start, and in a pair only the engine that the pair's record gives it (see Counterparts). An engine loads one installed plugin per engine identifier: two plugins share an identifier only as the versions of a pair, which gives each engine to one of them, and joining, separating, updating, and removing keep it so. The runtime loads and unloads per engine, so recording an answer, joining, or separating leaves an engine's copy running while its version on that engine stays the same.
- The engines that run web extensions on this Mac (`PluginRuntime.engines`) are the registered engines with the `extensions` capability, each with its extension runtime's version, less those whose application did not start when the session last tried. Once the runtime has started the Persona's profiles, they are also less those whose profile did not start, and the runtime tells the manager (`onEnginesChange`), which reads each plugin's current answers again, so that such an engine's answers count for nothing in the run. An engine that does not start never lends another engine's profile, as a tab's runtime falls back to the primary engine's, so that no engine runs an extension twice and no engine's answer stands for another's.
- The `webExtension` kind is unavailable only while no engine runs web extensions on this Mac, so that after VI.1 a Mac below macOS 15.4 runs them on Chromium tabs. Its reason is "Web extensions need macOS 15.4 or later." below macOS 15.4, and otherwise "No engine on this Mac runs web extensions." Settings and the review sheet say "A web extension." and then where the plugin runs, such as "Runs on WebKit and Chromium tabs."; Settings says it once an engine has checked the package, and "No engine on this Mac runs it." for a package that every engine refuses now. A plugin that is off because it failed to start on every engine that runs it has no such sentence; its failures say why.

#### Counterparts

- Two web extension plugins of one Persona are counterparts, versions of one extension, when the Persona's `plugins.json` records them as a pair. Arch shows a pair as one plugin with a version per engine: one Settings section with a row for each version, one row in the site settings popover, and one palette command. The pair takes the name and the place in the list of the version installed first.
- At staging, a package matches an installed web extension plugin that is not in a pair when they name one extension: they have the same identifier, from the same `key`, or the same `name` as Arch shows it, compared without case and spaces at either end, with at least one developer field that both manifests give and that matches, and no such field that differs. The developer fields are `author`, as text or as the `email` of an author object, compared without case, and `homepage_url` without its scheme, a leading `www.`, and a trailing `/`, compared without case, so that two projects on one hosting site differ. Of several matching plugins, the one installed first is the match.
- The package can join the match for each engine that runs the package while the match runs on another engine, by the answers at staging. The review then asks how to install it, for example "This may be the Chromium version of “Reader”, which runs on WebKit tabs. Arch can show the two as one plugin.", with Install as the Chromium Version, one such choice for each engine the package can join for, and Update “Reader” for a package with the match's identifier or Install as a Separate Plugin for another. The choice starts on the version when the two complement each other, each package running on an engine that refused the other. Otherwise it starts on Update or the separate plugin, since a package that runs where the match runs may be the match's next release or another extension, and the user can still choose the version, as for two packages with one `key` that both engines run. Without an engine to join for, as with WebKit alone before VI.1, a package with the match's identifier updates it and another installs as its own plugin, as now. A version installs on or off as the match is, so for it the review has one Install button instead of Install and Install and Enable.
- Identifiers: a version that joins a plugin whose version has the same identifier gets the plugin identifier `extension.<identifier>.<engine>`, with `webkit` or `chromium` for the engine it joins for. A plugin identifier is its install entry's `id`, which names its folder, choice, storage, and Keychain items, and which `InstalledPlugin.id` gives, while `manifest.id` stays what the package names. The manager therefore lists an entry whose package names `extension.<identifier>` under that `id` or under it followed by `.webkit` or `.chromium`, and the runtime gives the engines a plugin's identifier without that ending. Both engines know both versions as `<identifier>`, since each loads only its own, so a native app's host manifest that lists the identifier serves both. The runtime finds a version by the calling engine and the identifier.
- Updates: a package with an installed plugin's identifier updates it, as now, unless it joins it as above. Of two versions with that identifier, it updates the one installed from the same source, else the one whose answers the package's checks equal, else the one the user chooses in the review. `PluginPackage.updates` names it, and the review's title names the version, such as "Update the Chromium Version of “Reader”?". An update review that would take a plugin off an engine it runs on says so, such as "WebKit tabs lose “Reader”." An update that would leave a version of a pair on no engine cannot install while the pair lasts: its review says why, such as "WebKit cannot run this package, and the other version of “Reader” runs on Chromium tabs.", and offers Cancel only. An update keeps the plugin's pair and `dismissedVersionNotes`.
- By hand: an unpaired web extension plugin's section in Settings ▸ Plugins has Join With…, which lists the Persona's other unpaired web extension plugins. Its sheet gives each engine to the version whose package runs there. Where both run, the user chooses, starting with the version installed first. A join that leaves a version without an engine is refused. The pair takes the switch of the version installed first. A pair's section has Separate Versions, which drops the record: both versions stay installed as two plugins, each on every engine its package runs on, with their switches as they were. A pair whose versions share an identifier has no Separate Versions, since an engine loads one plugin per identifier; Remove Version… takes a version out instead.
- What a pair does:
  - Switching: the plugin's switch turns both versions on or off, and a version that joins takes the pair's switch, so both are on or both off. A version that the manager switched off after a failure says why in its row and comes back on with the switch; meanwhile its counterpart keeps running.
  - Removal: Remove… removes both versions after one confirmation. Each version's row has Remove Version…, which removes that version alone. The other version stays installed in the pair's place with its grant, storage, and switch, and Guidance applies to it again. Removing a version unloads it and deletes its extension storage in every engine except one where its counterpart runs under the same engine identifier, by the counterpart's `engines` before the removal and whether or not the counterpart is on, so such a counterpart keeps running and keeps its storage.
  - Updates: each version updates on its own (see Updates above), through the review sheet, with the permissions and sites it did not ask for before marked New.
  - Permissions: each version keeps its own grant. A version's review asks for its own permissions and sites. The sites that the other version asked for and the user left out start off, as in an update. Touch ID applies to each version's grant. Settings lists each version's access in its row. A request at run time names the version and grants only that version.
  - Storage: each version keeps its own `<plugin id>/` folder and its own extension storage in the engine it runs on. Nothing moves between versions, so the user sets up each version once, as with one package's copies on two engines.
  - The action: the site settings popover lists the pair once with the action of the version that runs on the tab's engine, and a click runs that version's action. The palette lists the pair's `action` command once and runs it with the version for the invocation tab's engine. The pair's other contributions also come once: from the version installed first while it is on, otherwise from the other version.
  - Native messaging: each version reaches native apps under its own identifier, so a host manifest's `allowed_origins` must list the identifier of each version that the helper should answer.
  - Personas: a pair belongs to one Persona. Install in Another Persona, once built, copies both versions and the pair.

#### Guidance

- A web extension plugin that is not in a pair asks for a version for an engine when that engine's runtime runs web extensions on this Mac (`PluginRuntime.engines`), the engine has a current answer for the plugin's package, the plugin runs on another engine but not on this one (`InstalledPlugin.engines`, so a failure to start there counts), and the user has not dismissed the note for that engine. Before VI.1, Chromium's runtime runs no extensions, so nothing asks for a Chromium version, and Chromium tabs keep the existing note that extensions run on WebKit tabs. After VI.1 the rule also runs the other way: a plugin that only Chromium runs asks for a WebKit version on a Mac where WebKit runs extensions. A pair asks for no version: a version that does not run on the engine its record gives it says why in its row, with Remove Version…, after which the other version asks as a plugin alone does.
- Install <Engine> Version… does not wait for a refusal: the Settings section of every web extension plugin that is not in a pair has it for each engine that runs web extensions on this Mac while the plugin runs on another engine, whatever the checks found, since an engine may run a package built for the other engine. Only a plugin that asks for a version also shows the notes below.
- The install sheet's last step: after Install or Install and Enable of a new plugin, not an update, that asks for a version, the sheet stays open instead of closing and says, for example, "“Reader” is installed. It runs on WebKit tabs. Its developer may offer a separate version for Chromium; install it to use “Reader” on Chromium tabs too." It offers Install Chromium Version…; Don't Ask Again, which dismisses the note for that engine; and Done, the default button, which leaves the note in Settings and on that engine's tabs.
- Install <Engine> Version… opens the open panel over the sheet, or over the Settings window from a Settings row, with the engine's package types (`PluginRuntime.packageTypes(for:)`) and a message that names both, such as "Choose the Chromium version of “Reader”." For both engines these are a folder or a `.zip` archive. `.crx` files join Chromium's types once Arch reads them; whether WebKit's take app extension bundles, which `WKWebExtension(appExtensionBundle:)` reads, is open. The package's review takes the sheet's place, titled "Install the Chromium Version of “Reader”?". It installs the package as the plugin's version for that engine, on or off as the plugin is. A package that the engine refused cannot join: the review says why, such as "Chromium cannot run this package: …", and offers Cancel only. A package whose name or developer fields differ from the plugin's joins with the warning "Its name or developer differs from “Reader”. Join only if both come from the same developer." A package with the identifier of an installed plugin that is not a version of this one cannot join here; Join With… joins installed plugins.
- Settings ▸ Plugins: while a plugin asks for a version, its section's footer gives the last step's note with Install <Engine> Version… and Dismiss. Dismiss adds the engine to the plugin's `dismissedVersionNotes` in `plugins.json`; the footer then says only where the plugin runs, and the section keeps Install <Engine> Version…. The note goes once the plugin runs on both engines, and comes back when removing a version leaves an engine without one, unless the user dismissed it before. An update keeps the dismissals. Installing a package that could have joined as a separate plugin, and Separate Versions, dismiss each plugin's note for the engines the other runs on, since the user chose to keep the two apart.
- Tabs: on a tab whose engine runs extensions but none of the plugin's versions, the plugin's row in the site settings popover is dimmed and says where it runs, such as "Runs on WebKit tabs.". While the plugin asks for a version for the tab's engine, the row adds "Its developer may offer a separate version for Chromium.", Install Chromium Version…, and Dismiss, which dismisses the note as Settings does. Install Chromium Version… closes the popover and opens Settings ▸ Plugins at the plugin, in the tab's Persona, with the open panel. It does so through a session callback that the app shell sets, `BrowserSession.installEngineVersion`, as it sets `showSettings`. The palette command beeps on such a tab, as now. On a tab whose engine runs no extensions, such as Chromium before VI.1, the section keeps its note "Extensions run on WebKit tabs. Switch this tab to WebKit to use them."

#### Types and `plugins.json`

Coverage's members are in the Swift API section and in `docs/engine-protocol.md`: `EngineExtensions.check(_:)`, `Engine.extensionRuntimeVersion`, `PluginEngineCheck`, `InstalledPlugin.engineChecks`, `engineFailures`, `engines`, and `enginesNote`, `PluginPackage.engineChecks` and `engineNotes`, `PluginRuntime.engines`, `check(packageAt:)`, `onCheck`, `onEngineFailure`, and `onEnginesChange`, and `run(_:)` with the installed plugins on or off, and `WebExtensionHost.extensionEngineVersions` and `extensionEngines(in:)` by engine. The members of the second step join the Swift API section as they are built.

```swift
// Plugins
/// Two installed web extension plugins of one Persona that are versions of one extension, with the engine each runs on. `plugins.json` holds it as an object from engine name to plugin identifier.
public struct PluginEngineVersions: Hashable, Sendable {
    public var versions: [EngineKind: PluginID]
}

// InstalledPlugin
/// The install entry's identifier, which replaces `manifest.id` as the plugin's identity: the manifest's, or, for a version that joined under its counterpart's identifier, that followed by `.webkit` or `.chromium`. A built-in plugin's is its manifest's.
public let id: PluginID
/// The other version of the plugin, in a pair.
public var counterpart: PluginID?
/// The engines whose note asking for a version the user dismissed.
public var dismissedVersionNotes: Set<EngineKind>
// `engines` also gives a version of a pair only the engine that the pair's record gives it.

// PluginPackage
/// The installed plugin that the package matches, by the rule in Counterparts, and the engines the package can join it for.
public let counterpart: PluginID?
public let joinableEngines: Set<EngineKind>
/// The installed plugin that the package updates, by the rule in Counterparts, or nil for a new plugin. The review sets it to the version the user chooses where the rule leaves two.
public var updates: PluginID?

// PluginManifest
/// A web extension's `author`, as text or the email of an author object, and its `homepage_url` without scheme, leading `www.`, and trailing `/`, lowercased. Nil for other kinds.
public var author: String?
public var homepage: String?

// PluginRuntime
/// The types the open panel accepts for a package of the kind for `engine`.
func packageTypes(for engine: EngineKind) -> [UTType]

// PluginManager
@Published public private(set) var engineVersions: [PluginEngineVersions]
/// With `asVersionOf` and `engine`, installs the package as that plugin's version for the engine, on or off as the plugin is; otherwise updates `package.updates` or installs a new plugin. Throws for an update that would leave a version of a pair on no engine.
public func install(_ package: PluginPackage, grant: PluginGrant, isEnabled: Bool, asVersionOf plugin: PluginID? = nil, for engine: EngineKind? = nil) throws
/// Throws for a pair that leaves a version without an engine. The pair takes the switch of the version installed first, and the join drops each ignored record that names one of its plugins.
public func join(_ versions: PluginEngineVersions) throws
/// Throws for a pair whose versions share an engine identifier.
public func separate(_ id: PluginID) throws
/// The engine whose version the plugin asks for (see Guidance), or nil.
public func missingEngine(of id: PluginID) -> EngineKind?
public func dismissVersionNote(of id: PluginID, for engine: EngineKind)
// `setEnabled(_:for:)` with either version switches the pair; `remove(_:)` removes one version.

// PluginListFile, as `plugins.json` holds it. Engine names stay text, so that the names this build does not know survive its writes, as they do in `Install.engineChecks: [String: EngineCheck]?`, whose `EngineCheck` holds `runs` and `version`.
/// Each pair as an object from engine name to plugin identifier.
var engineVersions: [[String: String]]?
// PluginListFile.Install
var dismissedVersionNotes: [String]?

// WebExtensionActionItem, one for each plugin and one for a pair, whose `id` is the version installed first
/// The engines the plugin's versions run on, for the note on another engine's tab.
public let engines: Set<EngineKind>
/// Whether the plugin asks for a version for the tab's engine.
public let asksForVersion: Bool

// Browsing, BrowserSession
/// Opens Settings ▸ Plugins at the plugin in the Persona with the open panel for the engine's version.
public var installEngineVersion: ((Persona.ID, PluginID, EngineKind) -> Void)?
```

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

- `engineVersions` lists the pairs in the order the user made them. Each names an installed plugin at most once and gives each engine one version. A record whose versions are not both in the list, such as one whose package no longer reads, or that names an engine this build does not know, stays in the file and is ignored, so the pair returns when the version reads again. A join drops each ignored record that names one of its plugins, so that no plugin is in two records. Files without the key have no pairs, and entries without `dismissedVersionNotes` have nothing dismissed.
- A version that joined under its counterpart's identifier has an entry such as `{"id": "extension.dddd….chromium", …}`, whose package names `extension.dddd…`.
- Engine names are `EngineKind` raw values. The file's types keep them as text, which the manager reads into `EngineKind` keys in memory; it keeps the names this build does not know and writes them back as they were, so an entry from a newer build stays readable rather than unreadable.
- An update keeps the entry's `dismissedVersionNotes` and its record, and replaces its `engineChecks` with the update's answers.
- Each join, separation, and dismissal writes the file at once, as choices do.

#### Tests

- Coverage (`EngineCoverageTests`, with a recording engine for each engine): staging records each engine's check, and installing writes `engineChecks` with each engine's version. A package that every engine refuses is refused with the first engine's reason, and its staged copy goes. An entry without `engineChecks`, or with an answer from another engine version, is checked again before the next load, only in the engines without a current answer, the answer is recorded, and the package loads where it runs. Staging checks the installed plugin that the package updates, switched off and never checked. A plugin that no engine accepts any more is switched off with the first engine's reason. A failure to start on one engine leaves the other engines running, stays out of `plugins.json`, is tried again when the plugin is switched on again, and switches the plugin off with each engine's reason only when every engine it ran on failed. The runtime loads each extension only into the engines it runs on, and recording an answer, or another change to the enabled plugins, does not load a running copy again. The kind is unavailable only without an engine, and Chromium alone makes it available. Once the engines run, switched-off plugins are checked where they have no current answer, and none of them loads. A plugin that every engine refused and that the user switches on again is checked again and goes off again with the reason. Only engines whose profiles start count: a listed engine whose profile does not start loses its answers for the run, so that the other engine's refusal or failure to start switches the plugin off, and with no profile started a package installs as unavailable. A plugin that is off after failing to start on every engine that runs it does not say "No engine on this Mac runs it." An engine name this build does not know in `engineChecks` survives reading and writing the file and leaves the entry readable. The review sheet's and Settings' sentences say where the package and the plugin run. WebKit's `check(_:)` passes the sample extension and refuses a package that `WKWebExtension` cannot read, and WebKit names its extension runtime's version (macOS 15.4 and later).
- Pairing rule: staging checks an installed plugin that the package could join, switched off and never checked, before matching it. Packages match by identifier and by name with a matching `author` or `homepage_url`. They do not match by name alone, with a developer field that differs, with `homepage_url`s on one host with different paths, or with a plugin that is in a pair. Complementary checks start the review's choice on the version. Overlapping checks, such as two packages with one `key` that both engines run, start it on Update or the separate plugin, and installing the package as the other engine's version still works. Without an engine to join for, as with WebKit alone, a package with an installed identifier updates as now. Of two matches, the one installed first wins. A version that shares its counterpart's identifier gets `extension.<identifier>.<engine>`, stays listed and paired when a new manager reads `plugins.json`, is paired again from its identifier when a build before this step dropped its record, receives the updates meant for it, and each engine's delegate calls reach that engine's version. Of two versions with one identifier, an update goes to the one from the same source, then the one with the same answers, then the one the review chooses.
- Pairs: one switch turns both versions on or off, and a version that joins takes the pair's switch. One version's failure leaves the other running. The popover's actions and the palette list the pair once and run the version for the tab's engine. Join With… gives each engine one version and refuses a join that leaves a version without one, and a join drops an ignored record that names one of its plugins. Separate Versions keeps both installed, and a pair that shares an identifier cannot be separated. An update that would leave a version of a pair on no engine is refused.
- Removal of one version: the other keeps its grant, storage, switch, and place, and the record goes. The removed version is unloaded and its engine storage deleted only in engines where no counterpart with the same identifier runs, on or off. Remove… removes both. A record whose versions are not both listed stays in the file and is ignored. An engine name this build does not know in `dismissedVersionNotes` or `engineVersions` survives reading and writing the file and leaves the entry readable.
- Guidance conditions: a plugin asks for a Chromium version only while a Chromium engine runs extensions and has a current answer, the plugin runs on another engine but not on Chromium, and the note is not dismissed. A failure to start on Chromium makes the plugin ask for a Chromium version. Nothing asks with WebKit alone, as before VI.1, for a pair, or while Chromium has not checked the package. Install <Engine> Version… shows for every unpaired plugin that runs on another engine, whatever the checks found. Don't Ask Again, Dismiss in Settings, and Dismiss in the popover record a dismissal, and Done does not. A dismissal survives a new manager reading `plugins.json` and an update. Installing a package that could have joined as a separate plugin, and Separate Versions, dismiss each plugin's note for the other's engines. A Chromium-only plugin asks for a WebKit version. Removing a version brings the request back.

#### Build steps

1. Coverage, built: `EngineExtensions.check(_:)` on WebKit, the host's engines by kind with their versions, only those whose application and the Persona's profile start, checks at staging, of the installed plugin a package updates, before loads without a current answer, of switched-off plugins once the engines run, and of a plugin switched on again after every engine refused it, `engineChecks` in `plugins.json` in the file's text-keyed types, failures to start per engine, loading per engine, the kind unavailable only without an engine, and the review sheet and Settings saying where a plugin runs, with the coverage tests.
2. Counterparts and guidance: staging's check of the match a package could join, `engineVersions`, entry identifiers for versions that share an identifier, the pairing rule, the review's choice between the version, Update, and a separate plugin, update targets, Join With… and Separate Versions, the pair's switch, removal, actions, and contributions, Install <Engine> Version… in every unpaired plugin's section, the install sheet's last step, the Settings note, and the popover row's note, with the pairing, pair, removal, and guidance tests.

Both steps come before VI.1, which then adds Chromium's `EngineExtensions` with `check(_:)` and lists `extensions` among Chromium's capabilities. Arch then checks the installed packages on Chromium, on or off, once the Persona's profiles start, offers Install Chromium Version… in the section of every unpaired plugin that runs on WebKit, and asks for the Chromium versions that WebKit-only plugins lack.

## Password manager plugins

- The user installs the 1Password and iCloud Passwords web extension plugins in each Persona that needs them. Arch bundles no third-party code.
- Both need `nativeMessaging` to reach their desktop helpers, so installing them asks for Touch ID.
- A vendor may ship a separate package for each engine, and a package built for WebKit may name its native app differently from the host manifest that its desktop helper installs (needs verification). The user then installs the package that each engine runs as that engine's version of one plugin (see Engine versions); each version reaches the helper under its own identifier.
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

The `Plugins` module lives in `Packages/ARCH/Sources/Plugins` and depends on `ARCHEngine` and on `AI`, through which the composer writes plugins. `Browsing` and `Preferences` depend on it to show contributions. `Plugins` reaches tabs through `PluginBrowserHost`, which `Browsing` implements. This avoids a dependency loop. `Extensions` depends on `ARCHEngine` and `Plugins` and supplies the web extension runtime, which `Browsing` makes for each Persona; it reaches the Persona's engines, tabs, and windows through `WebExtensionHost`, which `Browsing` implements. All types below are public.

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
    public var apiVersion: Int
    public var permissions: Set<PluginPermission>
    public var sites: [MatchPattern]
    /// A web extension's API permissions that no `PluginPermission` stands for, such as `storage`, which come with its install. The package and the installed plugin carry the kind.
    public var extensionPermissions: [String]
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
    /// What Touch ID or the login password states before the grant is given, or nil when it needs no confirmation: every website and native apps need it.
    public func confirmationReason(for pluginName: String) -> String?
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
    public var kind: PluginKind
    public var manifest: PluginManifest
    public var origin: PluginOrigin
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
    /// The engines a web extension runs on: those whose current answer runs it, less those where it failed to start.
    public var engines: Set<EngineKind> { get }
    /// "Runs on WebKit tabs.", or "No engine on this Mac runs it." when every engine that checked the package refuses it, once an engine has checked the package; nil before, and while it starts on none of the engines that run it.
    public var enginesNote: String? { get }
    /// The grant's sentences, then a web extension's other API permissions.
    public var accessSummaries: [String] { get }
}

/// What one engine's runtime found when it checked a package.
public enum PluginEngineCheck: Hashable, Sendable {
    case runs
    /// With why, as a sentence that names the engine, such as `WebKit cannot run this extension: …`.
    case refused(String)
}

/// A validated package, staged for the review sheet or installed.
public struct PluginPackage: Identifiable, Sendable {
    public let kind: PluginKind
    public let manifest: PluginManifest
    public let rootURL: URL
    /// The folder or archive the user chose, or how AI wrote the package.
    public let origin: PluginOrigin
    /// Package-relative paths, shown in the review.
    public let files: [String]
    /// The checks of the engines that run the kind on this Mac, made at staging.
    public internal(set) var engineChecks: [EngineKind: PluginEngineCheck]
    /// The review's sentences: "Runs on WebKit tabs.", then each engine's refusal.
    public var engineNotes: [String] { get }
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
    /// Set by the manager, which switches off a plugin that the runtime cannot start, with why.
    var onFailure: ((PluginID, String) -> Void)? { get set }
    /// Set by the manager, which records each answer with the engine's version: engines without a current answer checked an installed plugin's package, on or off, and every engine an enabled plugin's that no engine ran by its current answers.
    var onCheck: ((PluginID, [EngineKind: PluginEngineCheck]) -> Void)? { get set }
    /// Set by the manager, which keeps the failure for the run and switches the plugin off once it has failed on every engine it ran on. The web extension runtime reports failures to start through it instead of `onFailure`.
    var onEngineFailure: ((PluginID, EngineKind, String) -> Void)? { get set }
    /// Set by the manager, which reads each plugin's current answers and the kind's unavailability again once `engines` lost an engine, as one whose profile did not start for the Persona.
    var onEnginesChange: (() -> Void)? { get set }
    /// The installed plugins of the kind, on or off, each time they change, so that the runtime runs what the enabled ones run without a command and has the others' packages checked; none while the kind is unavailable.
    func run(_ installed: [InstalledPlugin])
    func makePlugin(_ installed: InstalledPlugin) -> any Plugin
    /// Deletes what the runtime keeps of a removed plugin.
    func remove(_ installed: InstalledPlugin)
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
                runtimes: [any PluginRuntime] = [], browser: any PluginBrowserHost)

    /// Reads `plugins.json` and registers built-in plugins. Starts no installed code.
    public func load() throws
    /// Copies a folder or archive into staging and validates it; the engines that run its kind check it, and the installed plugin it updates where they have no current answer. Throws, with the first engine's reason, for a package that every engine refuses.
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

### Web extension runtime

```swift
/// What `Browsing` provides so that a Persona's web extensions reach its engines, tabs, and windows.
@MainActor
public protocol WebExtensionHost: AnyObject {
    /// The engines whose runtime runs web extensions on this Mac, each with its runtime's version, WebKit's framework version or the CEF version, without starting any profile. An engine whose application did not start is not one of them.
    var extensionEngineVersions: [EngineKind: String] { get }
    /// The Persona's profiles in those engines, by engine, which the host starts if they have not started. An engine whose application or profile does not start is left out, and no engine's profile stands in for another's.
    func extensionEngines(in persona: PersonaID) -> [EngineKind: any EngineExtensions]
    func webContents(ofTab id: UUID) -> (any EngineWebContents)?
    func activate(_ tab: any EngineWebContents)
    func close(_ tab: any EngineWebContents)
    /// Shows an action's popover from the site settings button of the window that shows the tab. False when no window shows it.
    func present(_ popup: NSPopover, for tab: (any EngineWebContents)?) -> Bool
    func presentSheet(_ alert: NSAlert, for tab: (any EngineWebContents)?, completion: @escaping (NSApplication.ModalResponse) -> Void)
}

/// The web extensions of one Persona: the `webExtension` kind's runtime and the engines' extension delegate.
@MainActor
public final class WebExtensionRuntime: ObservableObject, PluginRuntime, EngineExtensionsDelegate {
    /// `nativeMessagingHosts` is the folder of the host manifests that name the native apps extensions may reach.
    public init(persona: PersonaID, host: any WebExtensionHost, nativeMessagingHosts: URL)
    /// The Persona's windows and the focused one, each time they change.
    public func setWindows(_ windows: [EngineExtensionWindow], focusedWindowID: UUID?)
    /// The actions of the enabled extensions that have one, for the site settings popover.
    public func actions(for tab: any EngineWebContents) -> [WebExtensionActionItem]
    /// False when no engine runs the extension for the tab.
    @discardableResult public func performAction(of id: PluginID, for tab: any EngineWebContents) -> Bool
}

public struct WebExtensionActionItem: Identifiable {
    public let id: PluginID
    public let name: String
    /// Nil while the tab's engine does not run the extension, as when it refused its package, or before it loaded.
    public let action: EngineExtensionAction?
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
5. The web extension runtime on WebKit as a `PluginRuntime` (`Extensions`), built; then engine versions in the two steps of Engine versions, of which the first, coverage, is built; VI.1 adds Chromium; IV.13 follows both.
6. VII.7 builds the composer on the staging and review path. The `ai` permission and plugin hooks on VII.6's hook center follow.

## Open decisions

- Isolation on Chromium: plugin page scripts share the page's main world until a CEF patch adds isolated worlds. The alternative is to run plugin page scripts on WebKit tabs only.
- Sandbox for script plugins: a hidden `WKWebView` per running plugin costs a web content process each. JavaScriptCore in the app process would cost less. It provides no process isolation, and its execution time limit is private API.
- One extension, two runtimes: each engine keeps its own copy of an extension's state and storage, so the user may unlock a password manager once per engine.
- Unsigned extension identifiers: a package can copy another extension's public `key` and so its identifier. Arch warns when an update comes from another place, but a host manifest's `allowed_origins` cannot tell such a package from the real extension. Before IV.13 relies on `allowed_origins` for the password managers, it decides how Arch tells them apart, such as by the place an extension was installed from or a signature that the vendor's package carries.
- Engine versions by name: without a shared `key`, two packages match only by name and a matching developer field, which a package can copy, as it can copy a `key`. The review's choice, which starts on joining only for packages whose checks complement each other, and Separate Versions are the safeguards. Whether a matching name alone should pair two packages whose manifests name no developer is open; until then the user joins them with Join With… or Install <Engine> Version….
- Install sources: folders, `.zip`, and `.crx` files only, of which `.crx` files are not read yet. No direct installs from an online store.
- Plugin fetches carry no Persona cookies. A plugin that needs a signed-in site must use a page script on that site.
- Site access defaults to `whenInvoked` when a manifest asks for all sites.
- The 10-second hang limit, 30-second idle stop, and 5 MB storage limit are starting values.
