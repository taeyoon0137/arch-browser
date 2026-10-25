# Importing from other browsers design

## Purpose and scope

- This note describes importing from Chrome, Dia, Arc, and Safari, row 57 of `docs/features.md`. Queue task V.13 in `docs/plan.md` follows the steps under Implementation order.
- File ▸ Import from Browser… finds those browsers and their profiles on the Mac, reads their files in place, and adds the user's selections to the session, history store, and site search in one step. File ▸ Import Bookmarks and History… (row 33) remains unchanged for exported files.
- Arch reads the other browsers' files and never writes to them. It reads SQLite databases from copies, as the file import does.
- Passwords, passkeys, cards, and addresses are excluded: Arch stores none and leaves them to the Passwords app and 1Password, which have their own imports. Cookies are excluded: each browser encrypts them with its own key in the Keychain, and a copied session cookie would sign the user in where they had not signed in. Extensions are excluded until Arch runs them (rows 44 and 50). Open and unpinned tabs, windows, reading lists, downloads, and site permissions are also excluded.
- No private API is used. One undocumented System Settings link is listed under Open decisions.

## Facts this design relies on

Checked on 2026-10-25 on macOS 27.2 with the installed Chrome, Arc, and Safari. Only structure was read: key paths, table and column names, value types, and counts. Dia is not installed.

### Chromium-family profiles

- Data folders: `~/Library/Application Support/Google/Chrome` for Chrome and `~/Library/Application Support/Arc/User Data` for Arc. Profile folders are `Default` and `Profile <n>`.
- `Local State` (JSON) lists the profiles under `profile.info_cache.<folder>`, each with `name` (string) and account fields. `profile.profiles_order` (array) orders them, and `profile.last_used` (string) names the last one used.
- `Bookmarks` (JSON) has `roots.bookmark_bar`, `roots.other`, and `roots.synced`, each a `folder` node, plus `version` (1), `checksum`, and `sync_metadata`. Nodes have `type` (`url` or `folder`), `name`, `url`, `children`, `id`, `guid`, `date_added` (string), `date_last_used`, `date_modified`, and `meta_info`. Arc's profiles have no `Bookmarks` file.
- `History` (SQLite, schema version 70) is the format the file import reads: `urls(id, url, title, visit_count, typed_count, last_visit_time, hidden)`, with times in microseconds since 1601.
- `Web Data` (SQLite, schema versions 147 to 158 in the installed profiles) stores search engines in `keywords`: `short_name`, `keyword`, `url` with `{searchTerms}`, `safe_for_autoreplace`, `prepopulate_id`, `starter_pack_id`, `is_active`, `created_by_policy`, `sync_guid`, `usage_count`, `last_visited`, and others. There are four kinds of rows:

  | Kind | Test | Chrome | Arc |
  |---|---|---|---|
  | Built-in engines | `prepopulate_id > 0` | 5 | 6 |
  | Built-in shortcuts with non-web templates | `starter_pack_id > 0` | 6 | 2 |
  | Engines offered by sites but never used as shortcuts | `safe_for_autoreplace = 1`, `is_active = 0` | 40 | 23 |
  | Shortcuts the user created or edited | `safe_for_autoreplace = 0`, both IDs 0 | 4 | 19 |

  Some templates use placeholders other than `{searchTerms}`, such as `{google:baseURL}` and `{inputEncoding}`.
- `Preferences` (JSON): `default_search_provider.guid` names the default engine's `keywords.sync_guid`. It is empty in Chrome, which then uses its built-in default. Arc also copies the default engine to `default_search_provider_data.mirrored_template_url_data`. `homepage`, `homepage_is_newtabpage`, and `session.startup_urls` are absent in both browsers. Arc keeps `partition.per_host_zoom_levels.x.<host>` with `zoom_level` and `last_modified`. On macOS, `Secure Preferences` holds only signatures for these values (`protection.macs`).
- Chrome keeps open and pinned tabs and tab groups in binary `Sessions/Session_<n>` and `Tabs_<n>` files. Its `pinned_tabs` preference is an empty array.

### Arc's sidebar

- `~/Library/Application Support/Arc/StorableSidebar.json` has `version` (1), `sidebar`, `sidebarSyncState`, and `firebaseSyncState`. Only `sidebar` matches the sidebar on screen: the two sync copies list other spaces and items.
- `sidebar.containers` has two elements: `{ "global": {} }` and one with `items`, `spaces`, and `topAppsContainerIDs`.
- `items` and `spaces` are flat arrays alternating ID strings and their objects.
- An item has `id`, `parentID` (null for containers), `childrenIds` in sidebar order, `title` (a folder's name or the user's tab name, often absent), `createdAt`, `originatingDevice`, and `data` with one key:
  - `tab`: `savedURL`, `savedTitle`, `timeLastActiveAt`, `savedMuteStatus`, `referrerID`, `activeTabBeforeCreationID`, and sometimes `customInfo.iconType`.
  - `list`: a folder, sometimes with `customInfo.iconType.icon`.
  - `itemContainer.containerType`: `spaceItems._0` with a space ID, or `topApps._0` with a profile reference.
  - The sync copies also contain `splitView` (`layoutOrientation`) and `welcomeToArc` items.
- A space has `id`, `title`, `containerIDs` (`["pinned", <id>, "unpinned", <id>]`), `newContainerIDs` (the same IDs keyed by objects such as `{"pinned": {}}`), `profile`, and `customInfo`. `customInfo.windowTheme` holds the theme as colors with `red`, `green`, `blue`, `alpha` (numbers), and `colorSpace` (string): `primaryColorPalette` (`midTone`, `shaded`, `shadedDark`, `tintedLight`), `semanticColorPalette`, and `background`. `customInfo.iconType` holds `icon` (a string from Arc's own icon set, not SF Symbol names), `emoji_v2` (string), or `emoji` (number).
- A profile reference is `{ "default": true }` or `{ "custom": { "_0": { "directoryBasename": …, "machineID": … } } }`. The installed custom reference names an existing folder in `User Data`.
- `topAppsContainerIDs` alternates a profile reference and the ID of that profile's favorites container.
- Installed: two spaces, one on the default profile and one on a custom profile, and 31 items: 6 containers, 3 folders, and 22 tabs. Folders were directly in pinned containers; tabs were in containers or folders. Arc allows nested folders; none were present.

### Safari

- `~/Library/Safari/Bookmarks.plist` (binary) is the WebKit-format file the file import reads. Its root's `Children` holds a `WebBookmarkTypeProxy` for history, `BookmarksBar` (the Favorites bar), `BookmarksMenu`, `com.apple.ReadingList`, the user's folders, and bookmarks outside folders. Leaves have `URLString`, `URIDictionary.title`, and `WebBookmarkUUID`; lists have `Title` and `Children`.
- `~/Library/Safari/History.db` (SQLite in WAL mode) has `history_items(id, url UNIQUE, visit_count, …)` and `history_visits(id, history_item, visit_time, title, load_successful, redirect_source, redirect_destination, synthesized, …)`. `visit_time` is a real number of seconds since 2001-01-01. Some visits have no title, failed to load, or redirected elsewhere.
- No `~/Library/Safari/Profiles` folder exists, so the location of Safari's non-default profiles is unknown. The import reads the default profile.

### Permissions

- A probe app launched through `open` without Full Disk Access failed to read `~/Library/Safari` in under 30 ms: listing the folder and `Data(contentsOf:)` failed with `NSCocoaErrorDomain` 257, and `FileHandle(forReadingFrom:)` with 513. Each had the underlying POSIX error 1 (`EPERM`). `fileExists(atPath:)` returned true and `isReadableFile(atPath:)` false.
- Chrome's `Local State`, `Bookmarks`, `History`, and `Web Data` failed the same way, so Chrome also needs Full Disk Access on this macOS version. Arc's `StorableSidebar.json`, `Local State`, and `History` were readable. The reason for this difference is unknown, so the import treats every source alike.
- No call waited for an answer, so macOS showed no blocking prompt. Whether it showed any notice was not checked on screen.
- A process started from a shell runs with the shell's access. Permission checks use the bundle launched through `open`, as specified in the Build Procedure in `docs/plan.md`.

### Dia

- Dia is not installed, and its documentation does not specify its data location. The design assumes `~/Library/Application Support/Dia/User Data` with Chromium-family profiles, like Arc's `User Data`. Unconfirmed: the folder, whether its profiles have a `Bookmarks` file, and whether Dia stores sidebar or pinned tab state outside the profiles. The import reads only Chromium-family files. If it finds none, it omits Dia from the sheet.

## What each source brings

| Source | Item | Arch |
|---|---|---|
| Chrome, Dia | Bookmarks in the bookmarks bar | Favorites of the destination Persona |
| Chrome, Dia | The bookmarks bar's folders, other bookmarks, mobile bookmarks | Pinned folders in a space named after the browser in the destination Persona |
| Chrome, Dia, Arc | History | The history store |
| Chrome, Dia, Arc | Shortcuts the user created | Site search shortcuts |
| Chrome, Dia, Arc | Default search engine | The search engine in Settings ▸ General, if Arch offers it |
| Arc | Spaces with their pinned tabs and folders | Spaces of the destination Persona with pinned tabs and folders |
| Arc | Favorites of a profile | Favorites of the destination Persona |
| Safari | Bookmarks in the Favorites bar | Favorites of the destination Persona |
| Safari | The Favorites bar's folders, the bookmarks menu, other folders and bookmarks | Pinned folders in a space named Safari in the destination Persona |
| Safari | History | The history store |

- Each Chromium-family profile and each Arc profile has one row in the sheet with its own destination Persona. Safari has one row.
- Only web addresses are imported, following `ImportedFile.webURL`. Titles fall back to the host, as in `ImportedFile.favorite`.
- Favorites have no folders, so only bookmarks directly in the bars become favorites, in bar order; the bars' folders go to the space.
- Arch's folders do not nest. Each source folder directly containing bookmarks becomes one pinned folder named by its path below the root, joined with " / ", such as "Work / Docs". Bookmarks directly under a root go into a folder named after it: Other Bookmarks, Mobile Bookmarks, Bookmarks Menu, or Bookmarks for Safari's top level. Empty folders are skipped.
- Arc spaces:
  - The name is the space's `title`. A space without one gets the next free "Space <n>" name, as new spaces do.
  - The tint is the `SpaceTint` whose system color's hue is nearest to `primaryColorPalette.midTone`, or gray when that color's saturation is below 20%. A space without a theme takes the next tint of the rotation, as new spaces do.
  - The default symbol is used because Arc's icon names and emoji have no SF Symbol counterpart.
  - The pinned container's tabs become pinned tabs, and its folders pinned folders, in sidebar order. A tab's `title` becomes the tab's name (`customTitle`). Nested folders follow the path rule above, and a split view's tabs become separate pinned tabs.
  - The unpinned container is excluded. It holds the day's tabs, which Arc archives automatically.
- Arc favorites: each profile reference's `topApps` container supplies that profile's favorites, titled with the item's `title` or `savedTitle` as a fallback.
- A space or favorites container whose profile reference names a folder missing from `User Data`, such as a profile from another Mac through Arc's sync, gets its own row named after that folder. It supplies only sidebar items.
- History, Chromium-family: the existing `HistoryDatabase`. Safari: one entry per `history_items` row with at least one visit that loaded (`load_successful = 1`) and did not redirect (`redirect_destination IS NULL`). It uses the item's `visit_count`, the latest such visit as the last visit, and that visit's non-empty title. History belongs to no Persona.
- Site search: rows with `safe_for_autoreplace = 0`, `prepopulate_id = 0`, `starter_pack_id = 0`, and `created_by_policy = 0`. `{searchTerms}` becomes `%s` and `{inputEncoding}` becomes `UTF-8`. A row with any other placeholder, a keyword with a space, or a template that is not a web address is skipped and counted. `short_name` becomes the name.
- Default search engine: the `keywords` row that `default_search_provider.guid` names, or Arc's mirrored copy. Arch's three engines are recognized by `prepopulate_id` (Google 1, Bing 3, DuckDuckGo 92; to check against the Chromium source when building) or by the template's host. An empty `guid` gives no choice. The sheet offers the engine of each browser's last used profile (`profile.last_used`), unchecked, when it differs from Arch's.
- Not carried over: the home page, because Arch's belongs to a space and none was set in the installed profiles; zoom levels, which Chromium keeps per storage partition and Arch keeps per host for all Personas; Chrome's pinned tabs and tab groups, in binary session files.

## Personas

- Each row's destination menu lists the current Persona (the last main window's), the other Personas, and New Persona "<profile name>". The profile name comes from `Local State`, and Safari's row uses "Safari".
- Defaults: the browser's first profile in `profiles_order` goes to the current Persona; the others, including rows for missing profile folders, go to new Personas. If a Persona already has the profile's name, the menu selects it, so repeat imports use the same Persona.
- A new Persona gets the row's imported spaces. If there are none, it gets one space named Personal, as New Persona does, so every Persona has a space.
- Several rows may share a destination; they merge into it in row order.
- A Persona created by the import starts with empty storage and is signed out of every site because cookies are excluded.
- A destination Persona deleted while the sheet is open becomes a new Persona with the row's profile name.

## Duplicates

Importing the same source again adds nothing.

- Favorites: an address already among the destination Persona's favorites is skipped (`addFavorites(_:in:)`).
- Spaces: an imported space merges into a space with the same name in the destination Persona. The bookmarks space named after the browser merges the same way.
- Folders: an imported folder merges into a pinned folder with the same name in that space.
- Pinned tabs: an address already pinned in the space, inside or outside a folder, is skipped.
- Site search: a keyword already in use, compared as `SiteSearchStore.isKeywordInUse` does, is skipped, so the first profile's shortcut wins.
- History: `HistoryStore.importEntries` already merges by address.

## Interface

- File ▸ Import from Browser… sits above Import Bookmarks and History…. It follows the same rules: one import at a time, a main window opens when none is open, and the item is disabled while the window shows a sheet.
- A sheet on the last main window shows "Looking for browsers…" while a background queue finds the sources and reads their data. The sheet shows each item's full count; the summary reports additions after skipping duplicates.
- One section per browser found, with the app's icon from `NSWorkspace` by bundle identifier, then one row per profile:
  - A checkbox and the profile's name, with a destination menu (see Personas).
  - A checkbox per item with its count: Favorites (12), Spaces (3) with 24 pinned tabs, Bookmark Folders (6) with 40 bookmarks, History (5,210 pages), Search Shortcuts (3). Missing items are hidden. Unreadable items show the reason and are unchecked and disabled.
  - Bookmark folders say that each bookmark becomes a pinned tab, which loads whenever Arch opens. The box starts unchecked above 50 bookmarks.
- Below the sections, "Use <engine> as the search engine, as in <browser>" for each browser that offers one (see What each source brings), unchecked. Checking one unchecks the others.
- A browser that needs Full Disk Access shows "Arch needs Full Disk Access to read <browser>'s bookmarks and history." with:
  - Open System Settings, which opens Privacy & Security ▸ Full Disk Access. When Arch becomes active again, the sheet reads that browser again.
  - Choose Exported File…, which closes the sheet and opens the file import's panel for a bookmarks file exported by the browser.
- No browser found: "No other browsers were found on this Mac." with Choose Exported File… and Close.
- Import is enabled while any item is checked. Cancel closes the sheet without changes.
- After import, an alert sheet summarizes the results with one line per kind, as the file import does: Personas created, spaces and pinned tabs added, favorites added and already present, history pages, search shortcuts added and skipped, the search engine, and unreadable rows.

## Applying the import

- Data is read once, off the main thread, before the sheet shows its rows. The sheet keeps the result, so Import does not reread it.
- Import runs on the main thread in one turn of the run loop: for each checked row in order, `BrowserSession.addImport(_:to:)`, then `SiteSearchStore.add(_:)` once with every row's shortcuts, then `HistoryStore.importEntries` with every row's history, then the search engine. The session saves once after the turn through its usual debounce.
- `addImport` first computes a `SidebarImport.Plan`, a value that resolves the destination and duplicates against the session's Personas, spaces, folders, favorites, and pinned tab addresses. It applies the plan by adding the Persona, spaces, folders, and favorites, and opening each pinned tab in the default engine without selecting it. Like a restored tab, a new tab's first load does not count as a visit. The plan is pure, so tests check it without engines.
- `session.json` needs no additions: imported items are ordinary Personas, spaces, folders, tabs, and favorites.
- There is no undo. ⌘Z reopens closed tabs, and the import touches three stores whose merges cannot be reversed exactly; history, for example, keeps the larger visit count. Instead, the step is well defined: everything is read before anything changes, a row's items arrive together, and importing again adds nothing. Delete Persona removes an entire import into a new Persona.
- Each imported pinned tab gets a web contents that loads immediately and at every launch, as restored tabs do. This explains the bookmark threshold above and Open decision 1.

## Errors and permissions

- Detection per source: omit sources with no data folder. Full Disk Access is needed if the key file (`Local State`, `StorableSidebar.json`, or `Bookmarks.plist`) exists but is unreadable, or reading fails with `EPERM` or `EACCES`. Arch tests readability without opening the file, so detection triggers nothing.
- If a file is missing, its item is omitted. If a file does not parse, a database copy does not open, or a table lacks the expected columns, the item is marked unreadable with the file's name. The profile's other items still import.
- A running browser may lock its databases; copying them with their `-wal` and `-journal` files handles this, as in `HistoryDatabase`.
- Unknown `StorableSidebar.json` versions are still read; unknown item kinds are skipped. Without a container holding `items` and `spaces`, Arc's sidebar items are unreadable, but its profiles still offer history and search shortcuts.
- macOS records a Full Disk Access grant with the app's code signature requirement, so a bundle signed with the stable identity should keep it across rebuilds (not checked). Whether a grant applies to the running app or only after relaunch was not checked. The sheet reads again on activation; if access is still denied, it says to quit and reopen Arch.

## Files

- `Packages/ARCH/Sources/Import`:
  - New `BrowserSource.swift`: the source definitions (display names, bundle identifiers, and data locations), detection, and the permission check.
  - New `ChromiumProfile.swift`: the profiles from `Local State` and each profile's files.
  - New `SearchKeywords.swift`: `keywords` rows to `SiteSearchShortcut`s and the default engine.
  - New `SidebarFile.swift`: `StorableSidebar.json` to spaces, pinned items, and favorites per profile folder.
  - `BookmarkFile.swift`: bookmark trees for Chromium-format JSON and WebKit-format property lists, split into bar bookmarks and folders by the path rule. The file import's flattened favorites use the same trees in the same order.
  - `HistoryDatabase.swift`: the copy step shared with a second query for `history_items` databases.
  - New `BrowserImportSheet.swift`: the SwiftUI sheet and its model (detection state, choices).
  - `ImportController.swift`: `importFromBrowser(in:)` beside `chooseFiles(in:)`, sharing `isImporting` and `canImport(in:)`, and the summary lines shared by both imports.
- `Packages/ARCH/Sources/Browsing`:
  - New `SidebarImport.swift`: what a row brings (favorites, spaces with pinned tabs and folders), the destination, the `Plan`, and the counts it returns.
  - `BrowserSession.swift`: `addImport(_:to:)`; `addFavorites(_:in:)` with a Persona parameter, which the file import calls with the current Persona; a Persona created with given spaces.
  - `SiteSearch.swift`: `add(_:)` adds shortcuts accepted by `canSave`, writes the file once, and returns the number added.
  - `SpaceTheme.swift`: `SpaceTint.nearest(red:green:blue:)`.
- `Packages/ARCHApp/Sources/Arch/AppDelegate.swift`: the menu item and its validation.
- `Package.swift`: an `ImportTests` test target that depends on `Import` and links `sqlite3`.
- `docs/plan.md` and `docs/features.md` as the Working Rules require.

## Tests

Every fixture is synthetic and built by the tests: JSON and property lists from literals, SQLite databases with the columns listed above. Tests refer to sources only through their definitions.

- `ImportTests`:
  - Profiles: a `Local State` with two profiles in `profiles_order` gives their names and folders in order; a folder without `Local State` gives `Default` alone.
  - Bookmark trees: nested folders become path-named folders; the bar's bookmarks become favorites in order; scripts, files, and internal pages are skipped; the file import's flattened favorites are unchanged.
  - WebKit-format trees: the Favorites bar, the bookmarks menu, top-level bookmarks, and the reading list, which stays out.
  - Keywords: rows of all four kinds; only shortcuts the user created with web templates are imported, `{searchTerms}` and `{inputEncoding}` are replaced, and other placeholders are skipped; the default engine is recognized by `prepopulate_id` and by host, and an empty `guid` gives none.
  - Safari-format history: last visits converted from 2001-based seconds, titles from the latest titled visit, and items whose visits all failed or redirected left out.
  - Sidebar file: two spaces on two profile references with themes, folders, a nested folder, a split view, unpinned tabs, and non-web addresses; favorites per profile; a reference to a missing folder; an unknown item kind; a file without the container.
  - Detection: a data folder without the key file is not listed; a key file without read permission (mode 000) is reported as needing Full Disk Access.
- `BrowsingTests`, new `SidebarImportTests.swift`:
  - The plan merges spaces and folders by name, skips favorites and pinned addresses already present, gives a new Persona its imported spaces or Personal, and is empty for a second identical import.
  - `SpaceTint.nearest`: each system tint's own color maps to it, and a color below 20% saturation maps to gray.

## Implementation order

Each step builds, keeps the app working, passes `swift test`, and forms one commit with the subject `Task(V.13): …`.

1. Readers. The `Import` files above except the sheet and the controller, and the `ImportTests` target. Nothing calls the new readers yet; the file import keeps its behavior on the shared bookmark trees and copy step.
2. Session entry point. `SidebarImport.swift`, `addImport(_:to:)`, `addFavorites(_:in:)` (the file import passes the current Persona), `SiteSearchStore.add(_:)`, `SpaceTint.nearest`, and `SidebarImportTests`. Nothing in the interface calls `addImport` yet.
3. Interface. `BrowserImportSheet.swift`, `importFromBrowser(in:)`, the menu item, and the shared summary; then the checks below from the bundle; then `docs/plan.md` (remove V.13, update Current State) and row 57.

## Checks with the app

Run from the bundle launched through `open`, on a test Persona or a fresh Application Support folder:

1. Without Full Disk Access, the Chrome and Safari sections ask for it, and Open System Settings opens Privacy & Security ▸ Full Disk Access. After the grant, returning to Arch lists their profiles, or the sheet says to quit and reopen.
2. An Arc profile imported into a new Persona brings its spaces with their names and tints, their pinned tabs and folders in order, and its favorites. Importing again adds nothing.
3. A Chrome profile brings the bar's bookmarks as favorites, its folders as pinned folders in a space named Chrome, history in the History window, and its shortcuts in Settings ▸ Site Search.
4. With Full Disk Access, Safari brings the Favorites bar, its folders in a space named Safari, and history, without the reading list.
5. The search engine choice changes Settings ▸ General.
6. Every imported item survives relaunch, and File ▸ Import Bookmarks and History… still imports an exported HTML file.

## Open decisions

1. Tabs that load when first shown. Without them, every imported pinned tab loads at every launch, limiting bookmark folders to small sets. Deferred loading would also speed up launch with many pinned tabs; it needs a separate session change.
2. The Open System Settings link, `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`, is undocumented. It is a URL opened by `NSWorkspace`, not a framework API, so it is not listed under Private APIs. If the anchor stops working, System Settings opens at Privacy & Security. Confirm that it needs no flag.
3. Safari's own export of browsing data, which could bring history without Full Disk Access. Its format was not checked.
4. Dia's actual layout, once it is installed.
5. Zoom levels and site permissions, which Chromium keeps in `Preferences` per profile, could come later.
