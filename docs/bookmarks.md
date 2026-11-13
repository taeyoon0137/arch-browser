# Bookmarks and live folders design

## Purpose and scope

- This note designs rows 64 (bookmarks) and 65 (live folders) of `docs/features.md` and queue tasks III.16 to III.24 in `docs/plan.md`. Every label it adds follows Persona rule 7 of `docs/windows-personas.md`: a Persona named with one of its spaces shows as "Persona / Space", and III.15 applies that rule to the surfaces built before it.
- Bookmarks: pinned tabs, favorites, and the folders that hold pinned tabs become Arch's bookmarks. Each keeps a saved page to return to and can unload and reload its page. Folders nest, and a Bookmarks menu lists them.
- Live folders: pinned folders filled and kept up to date by a source: RSS and Atom feeds fetched directly, and GitHub pull requests, review requests, and issues through the user's `gh` command-line tool signed in through the built-in terminal. Each item is a tab with read and unread state.
- Excluded: a bookmarks bar, because nothing sits above the page (Approach in `docs/plan.md`); a bookmark manager window, because the sidebar, the Bookmarks menu, and the palette, which already lists pinned tabs, cover it; live sources that need a service's own sign-in and API, such as calendars, documents, and chats (open decision 1); custom icons for folders and tabs; and muting, which Arch's tabs do not have.
- Arch runs no server and no service of its own for any of this. Nothing here uses a private API or needs a flag on `flags://`.

## Facts this design relies on

### Arch today

- A pinned tab is a tab with `isPinned`. `session.json` keeps only its current address and title, so a pinned tab has no address of its own to return to. Closing it moves it to the closed list.
- A favorite's `url` and `title` already act as its saved page: Close ends the favorite's tab, and the next click opens the favorite's address. `savedFavoriteTabs` keeps the last session's tabs as records (address, engine, page state) until their favorites are clicked.
- A restored tab has an `UnloadedWebContents` stand-in until a window first shows it (III.14). A load on the stand-in replaces its saved page without loading. Nothing yet unloads a loaded tab's page.
- Folders are one level deep, in a space's pinned or open list. Browser import joins nested folder names into one level ("Work / Docs"). Folder rows do not drag.
- `Tab.isUnread` puts a dot on the row of a tab that a page opened in the background; selecting the tab clears it. It is not saved.
- `session.json` is at version 12. Each step that adds fields takes the next free version number when it lands and migrates through `normalized()`. VII.12 adds `TabFolder.agentSessionID`, which is not encoded, for agent folders among the open tabs.
- `AI` runs command-line tools through `CommandLineProcess` (`posix_spawn`, its own process group, pipes, a minimal environment) and finds them with `LoginShell.locateExecutable(named:)` in the login shell's PATH. Both are internal to `AI`. Settings opens the built-in terminal through a closure the app shell sets (`PreferencesWindowController.openTerminal`).
- `FaviconLoader` caches icons by address and shares concurrent downloads, so item tabs from one site load one icon.
- The app's Info.plist sets no App Transport Security exception, so the app's own `URLSession` refuses plain HTTP, as for site icons.

### Feeds

- RSS 2.0: `rss/channel/item` with `title`, `link`, `guid` (`isPermaLink`), and `pubDate` (RFC 822); `channel/ttl` is minutes between fetches. RSS 1.0: `rdf:RDF/item` with `rdf:about`, `title`, `link`, and `dc:date` (ISO 8601); the syndication module's `sy:updatePeriod` and `sy:updateFrequency` set an interval. Atom 1.0: `feed/entry` with `id`, `title` (`type` text, html, or xhtml), `link` (`rel="alternate"` or no `rel`), `updated`, and `published`.
- Foundation's `XMLParser` reads all three; it resolves no external entities unless asked.
- A server that sends `ETag` or `Last-Modified` answers `If-None-Match` or `If-Modified-Since` with 304 when the feed has not changed.
- A web page names its feeds in `<link rel="alternate" type="application/rss+xml">` or `type="application/atom+xml"` with an `href`.

### GitHub CLI

Checked on this Mac with `gh` 2.104.0, in an environment with only `HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`, `LANG`, `TMPDIR`, `TERM=dumb`, `GH_PROMPT_DISABLED`, `GH_NO_UPDATE_NOTIFIER`, and `NO_COLOR`:

- `gh api graphql --hostname github.com --input -` sends the JSON body `{"query": …, "variables": {…}}` from standard input and prints the response. `gh` read its sign-in from the Keychain itself and asked nothing.
- GitHub's search through GraphQL (`search(query: $q, type: ISSUE, first: $n)`) accepts `@me`, `archived:false`, and `sort:updated-desc`: `is:pr is:open author:@me`, `is:pr is:open user-review-requested:@me`, `is:pr is:open involves:@me`, and `is:issue is:open assignee:@me` all answered. An unknown qualifier is searched as text and gives no error.
- Pull request nodes gave `number`, `title`, `url`, `updatedAt`, `state` (`OPEN`), `isDraft`, `reviewDecision` (null and `REVIEW_REQUIRED` seen), `mergeable` (`UNKNOWN`, `MERGEABLE`, and `CONFLICTING` seen), `repository.nameWithOwner`, `author.login`, and `commits(last: 1).nodes[0].commit.statusCheckRollup.state` (`SUCCESS`, `FAILURE`, or null). Issue nodes gave the same fields without the pull request ones. `rateLimit { cost remaining resetAt }` reported a cost of 1 per query.
- Signed out (an empty `GH_CONFIG_DIR`), `gh auth status --hostname github.com` exits 1 and `gh api` exits 4. Signed in, `gh auth status` exits 0. A malformed GraphQL query exits 1.

## Decisions

Code comments and documents cite these rules by number, as in "bookmark rule 4".

### Bookmark rules

1. Pinned tabs, favorites, and the folders that hold pinned tabs are the bookmarks. Arch keeps no separate bookmark store, bar, or manager. Import, sync, and the palette already treat them as bookmarks; one place to organize them is enough.
2. Each pinned tab keeps a saved page: an address and a title. A tab saves the page it shows when pinned (Pin Tab, a drop among the pinned tabs or into a pinned folder), or the first address its page reports if it had none. Unpinning clears the saved page. A reopened pinned tab keeps the saved page from its record. Browser import gives an imported pinned tab its address, and a live folder gives each item's tab the item's address and title. Use Current Page as Saved Page and Edit Saved Address… change it. A favorite's address and title are its saved page.
3. A tab is on its saved page while its address equals the saved one, ignoring the fragment, `http` against `https`, the host's case, a leading `www.`, and a trailing slash. It is on its saved site while its host equals the saved host the same way. Go Back to Saved Page is offered whenever a pinned tab or a favorite's tab is off its saved page; the row offers it only while the tab is off its saved site. A pinned web app changes its address constantly, and redirects and returns from sign-in pages would otherwise mark the row.
4. Closing a pinned tab unloads it: once its page agrees to leave, the page closes and the tab keeps its place with a stand-in at its saved page, without page state. This applies to ⌘W, the row's button, Close Tab, and the page's `window.close()`. Unloading adds nothing to the closed list or the tab close log, and, as when a favorite's tab ends, ⌘Z then reopens none of the tabs closed before it. Delete Tab removes a pinned tab into the closed list. A favorite's Close ends its tab, as today. Closing a live folder's item tab dismisses the item (live folder rule 4). A bookmark outlasts its page, and returning to it starts at the saved page.
5. Pinned tabs and favorites' tabs that no window shows unload automatically and keep their place: the stand-in keeps the address, title, page state, and icon, so the tab comes back where it was. The archive timer unloads those inactive for the hours set in Settings ▸ Sidebar (Unload Pinned Tabs and Favorites After, 12 hours by default, 0 for never). While that setting is not 0, memory pressure reported by macOS (`DispatchSource.makeMemoryPressureSource`) also unloads every tab that no window shows, open tabs included: at a warning those inactive for 30 minutes, at critical all of them. A tab stays loaded while it plays sound or media, has a sheet waiting, has downloads that need its page, is in a small window, or sits in an agent folder (VII.12). An automatic unload answers the page's `beforeunload` question with Stay, without a sheet, which keeps the page.
6. Folders nest up to four levels in the pinned and open lists. A folder lists its folders first, then its tabs, as each list does. Live folders and agent folders hold no folders. Bookmark collections nest, and four levels at 12 points each leave the 240-point sidebar room for names. Browser import keeps joining nested names into one level, as `docs/import-browsers.md` describes: its record and merging by name use those names as keys, so nesting them would make a second import add the folders again.
7. The Bookmarks menu in the menu bar lists the window's Persona's favorites and every space's pinned folders and tabs, one submenu per space. With two or more Personas, the spaces group by Persona and each submenu is titled "Persona / Space", while the favorites, which belong to the whole Persona, are headed by the Persona's name alone (Persona rule 7).

### Live folder rules

1. A live folder is a pinned folder that a source fills and keeps up to date. Its source, item limit, and refresh interval belong to the folder in `session.json` (`TabFolder.live`) and can sync with it. The fetched items, read state, dismissed items, and fetch state belong to `live-folders.json`, since they change with every fetch and stay on each Mac. A live folder sits among a space's pinned tabs, at the top level or in an ordinary folder, and holds only its items.
2. Sources: an RSS (2.0 or 1.0) or Atom feed over HTTPS, and GitHub searches that the user's `gh` runs: My Pull Requests, Review Requests, Assigned Issues, or a search the user writes. A feed travels from its site to Arch, and GitHub's answers from GitHub through `gh` to Arch; no server of Arch's own takes part. An `http` feed address is tried as `https`, because the app's `URLSession` refuses plain HTTP.
3. `gh` keeps its own sign-in. The user installs it and signs in with `gh auth login` in the built-in terminal (row 56), as for the AI module's command-line tools. Arch finds it through the login shell's PATH, runs only `gh auth status` and `gh api graphql` with a fixed query, sends the search on standard input, and never runs `gh auth token` or reads gh's files or Keychain items.
4. Each item is a pinned tab in its folder, whose saved page is the item's address and title (bookmark rule 2); it has no page until a window shows it. Closing an item's tab dismisses the item: the tab is removed without joining the closed list, and the item stays out of the folder while the source lists it, until Show Dismissed Items. A tab moved out of its live folder becomes an ordinary tab, and the folder immediately gets a new tab for the item. Nothing else enters a live folder, and its tabs keep the source's order.
5. An item is unread when it appears after the folder's first fetch, or, for GitHub, when its `updatedAt` is later than the last time a window showed its tab. A dot marks an unread item's row, and the folder's row shows how many are unread. A window showing the tab marks it read; Mark as Read, Mark as Unread, and Mark All as Read change it manually.
6. A folder refreshes when it is created, on Refresh Now, and when its interval has passed since its last attempt: 15 minutes, 30 minutes, 1 hour, or 3 hours, by default 30 minutes for feeds and 15 for GitHub, checked every 5 minutes through `NSBackgroundActivityScheduler`. A GitHub folder also refreshes when Arch becomes active or a window shows its space, at most once every 5 minutes, since pull requests change while the user works. A feed's `ttl` or syndication interval lengthens its interval, up to 24 hours. After a failure, the wait doubles, up to 6 hours; a failure while the Mac is offline does not count. `Retry-After` and GitHub's rate limit reset postpone the next attempt, and Low Power Mode doubles every interval. At most four fetches and one `gh` process run at once.
7. Limits: 10, 25 (default), or 50 items per folder; 20 live folders in the app; 5 MB per feed response; 8 MB of `gh` output; 30 seconds per fetch; titles cut at 300 characters; item addresses only `http` and `https`; feed addresses without a user name or password, since `session.json` keeps them.

## Saved pages (III.16)

- `SavedPage` holds an address and a title. `Tab.savedPage` follows bookmark rule 2: `isPinned` turning on sets it from the tab's address and page title, turning off clears it, and a pinned tab without one takes the first address its page reports. `restore(_:folderID:)` takes the saved page from the record.
- `URL.isSamePage(as:)` and `URL.isSameSite(as:)` compare according to bookmark rule 3. `Tab.isOffSavedPage` and `Tab.isOffSavedSite` use them; a favorite's tab compares with its favorite's address, which the session supplies.
- Go Back to Saved Page loads the saved address in the tab, or the favorite's address in its tab. For a tab without its page, the stand-in takes the saved page without loading, as any load on it does.
- Use Current Page as Saved Page takes the tab's address and page title. For a favorite it changes the favorite's address and title; it is disabled while another favorite of the Persona has that address.
- Edit Saved Address… opens an `NSAlert` sheet on the window, as New Persona does, with a text field prefilled with the saved address. An address that `BrowserSession.url(forInput:)` rejects changes nothing. A tab without its page moves its stand-in to the new address. For a favorite, Edit Favorite… has Name and Address fields.
- Copy Address copies the tab's current address, or the favorite's, as a URL and as text. Duplicate opens and selects a copy after the tab, in the same list and folder, at its current address in its engine; a pinned copy keeps the original's saved page.
- Where: the tab row's context menu (Go Back to Saved Page, Use Current Page as Saved Page, Edit Saved Address…, Copy Address, Duplicate), the favorite tile's (Go Back to Saved Page, Use Current Page as Saved Page, Edit Favorite…, Copy Address), and the Tab menu (Go Back to Saved Page, Use Current Page as Saved Page, Edit Saved Address…, acting on the selected tab). They have no default shortcuts; Settings ▸ Shortcuts can assign one. Item tabs offer Go Back to Saved Page and Copy Address only, since the source owns their address.
- While a tab is off its saved site, its row shows a back button (`arrow.uturn.backward`) before the close button when under the pointer, with a tooltip naming the saved address.

## Unloading (III.17)

- Closing a pinned tab (bookmark rule 4) asks the page as closing does, then follows the closing steps without removing the tab: its sheets are removed, a window that shows its page in full screen leaves it, it leaves its split view, each window that selected it selects another tab as after a close (window rule 3), and `retire` closes the page, keeping it on a blank page while its downloads need it. The tab then holds `UnloadedWebContents(url:title:engine:state:)` at its saved page, without state.
- `TabCloseAction.of(_:)` decides what Close does: unload for a pinned tab, dismiss for an item tab, end for a favorite's tab, and close for any other tab. ⌘W, the row's button, Close Tab, and `window.close()` all go through it.
- Delete Tab, in a pinned tab's context menu, closes it into the closed list; ⌘Z reopens it pinned in its folder with its saved page.
- Automatic unloading (bookmark rule 5): `TabUnloading.tabsToUnload(_:now:after:pressure:)` picks from `UnloadCandidate` values (ID, kind, last activation, and the exclusions) without session state, so tests can drive it directly. The archive timer calls it with the hours from `ARCHUnloadAfterHours`; a memory pressure source on the main queue calls it with the event's level. A pinned or open tab unloads into a stand-in that keeps its address, title, page state, zoom, and icon. A favorite's tab unloads as at quit: the session keeps its record in `savedFavoriteTabs` and closes the tab without adding it to the closed list, so the tile keeps its dot.
- The automatic path sets `Tab.answersBeforeUnloadWithStay` for the call to `tryToClose`, so a page's leave-page question returns Stay without a sheet and the page stays.
- Rows of tabs without a page show their title in secondary text, so the sidebar shows which bookmarks have a page. A pinned row's close button, under the pointer, is a minus (`minus`) with the tooltip Unload, shown only while the tab has its page. Settings ▸ Sidebar gains the Unload Pinned Tabs and Favorites After stepper below the archive stepper.

## Nested folders (III.18 and III.19)

- `TabFolder.parentID` names a folder of the same space and list. `FolderTree`, built from a space's folders and tabs, provides each list's rows and levels, each folder's ancestors and descendants, and the allowed moves. The session and the views ask it instead of walking `parentID`.
- Rows: a folder's row is indented 12 points for each level above it, and its tabs one level further. A collapsed folder hides everything inside it but the selected tab, which shows one level in from the collapsed folder.
- Menus: a folder's context menu gains New Folder Inside (disabled at the fourth level and in live folders), Move to Folder, and Move Out of Folder. Move to Folder, for folders and tabs, is a submenu that mirrors the tree: a folder containing folders is a submenu whose first item moves into that folder. It offers only the moves `FolderTree` allows: not into itself or a folder inside it, not past the fourth level, not into a live or agent folder, and not to another space or list.
- Delete Folder keeps everything inside: its folders take its place in its parent, and its tabs go first among its parent's tabs, or among the list's tabs outside folders at the top level, as today.
- Deleting a space moves its folders and their tree to its neighbor. `isInCollapsedFolder` checks every ancestor.
- Dragging (III.19): `SidebarDragItem.folder` lifts a folder row like a tab row; its contents stay hidden until release. Released between rows, it takes that place at that level; over another folder's row, which lights up with a light haptic, it goes inside at the end of its folders; over another space's symbol of its Persona, it moves with its contents to the end of that space's folders in the same list. `FolderTree.dropTarget(for:at:)` decides, and a refused drop returns the row to its slot. A tab dropped on a nested folder's row joins that folder.

## Bookmarks menu (III.20)

- The menu sits between Spaces and History and is built each time it opens (`menuNeedsUpdate`), like the History menu, from `BookmarkMenu.entries(for:)`, a value tree without AppKit.
- Contents, for the last main window: the window's Persona's favorites by title, headed by the Persona's name with two or more Personas; then, for each Persona in order, each of its spaces that has pinned tabs as a submenu, titled with the space's name, or "Persona / Space" with two or more Personas. A space's submenu holds its pinned folders as nested submenus, then its pinned tabs. A live folder's submenu shows its unread count as an `NSMenuItemBadge` and marks unread items. Without bookmarks the menu shows a disabled No Bookmarks.
- Choosing a tab selects it in the last main window as a sidebar click does (window rule 2); choosing a favorite acts like a click on its tile.

## Live folders

### Sources

- `LiveFolderSource` is a feed address or a `GitHubSearch`: a host (`github.com` or a GitHub Enterprise Server host) and a kind with its search:
  - My Pull Requests: `is:pr is:open author:@me archived:false sort:updated-desc`.
  - Review Requests: `is:pr is:open user-review-requested:@me archived:false sort:updated-desc`. Requests to the user's teams need a search of their own with `review-requested:@me`.
  - Assigned Issues: `is:issue is:open assignee:@me archived:false sort:updated-desc`.
  - Search: the user's text in GitHub's search syntax, with ` sort:updated-desc` added when it has no `sort:`.
- `LiveFolderConfiguration` holds the source, the item limit, and the refresh interval. `TabFolder.live` keeps it.

### Feeds

- `FeedFetcher` loads the feed through a `URLSession` with an ephemeral configuration, no cookies, no cache, a 30-second limit, and an `Accept` header for RSS, Atom, and XML. Its requests carry the stored validators. A 304 keeps the items. 429 and 503 with `Retry-After`, in seconds or as a date, postpone the next attempt. Another status is an error that names it. The body stops at 5 MB.
- Feeds load outside every Persona's engine storage, so no site sees the user's sign-ins or cookies, and a feed that needs a signed-in session cannot load. A feed address containing a token works.
- `FeedParser` parses with `XMLParser`, namespaces on and external entities off, and recognizes the format by its root element (`rss`, `rdf:RDF`, or `feed`); anything else is not a feed. For each item:
  - ID: Atom `id`, RSS `guid`, RSS 1.0 `rdf:about`, else the link, else a digest of the title and date.
  - Address: Atom's alternate link, the RSS link, or a `guid` that is a permalink, resolved against `xml:base` and the feed's address. Items without an `http` or `https` address are skipped.
  - Title: plain text with markup removed and character references decoded (numeric ones and the common named ones), whitespace collapsed, and cut at 300 characters. Without one, the address without its scheme.
  - Date: Atom `updated`, else `published`; RSS `pubDate` in RFC 822 forms with or without the weekday and with numeric or named zones; `dc:date` in ISO 8601 with or without fractions.
- Items keep document order, or newest first when every item has a date. The first items up to the folder's limit are kept. The feed's title becomes the folder's default name.
- `FeedDiscovery` reads an HTML page's first 512 KB for `<link rel="alternate">` tags of the RSS and Atom types and returns up to ten addresses resolved against the page, with their titles.

### GitHub

- `GitHubCLI.locate()` finds `gh` with `LoginShell.locateExecutable(named: "gh")` once per launch and again on Check Again or when the file is gone.
- `GitHubCLI.status(host:)` runs `gh auth status --hostname <host>`: exit 0 is signed in, any other exit is signed out, and a missing executable is not installed.
- `GitHubCLI.search(_:limit:)` runs `gh api graphql --hostname <host> --input -` with the fixed query below on standard input and the search and limit as variables, through `CommandLineProcess` in a new empty folder under `TMPDIR`, with the minimal environment of `LoginShell.baseEnvironment` plus `GH_PROMPT_DISABLED=1`, `GH_NO_UPDATE_NOTIFIER=1`, and `NO_COLOR=1`. It ends the process after 30 seconds or 8 MB of output. Exit 4 means signed out. Exit 1 shows the first GraphQL error's message, or the last line of standard error, cut at 200 characters. A response whose errors have the type `RATE_LIMITED` waits until `rateLimit.resetAt`, or 15 minutes without it.

```graphql
query($q: String!, $n: Int!) {
  search(query: $q, type: ISSUE, first: $n) {
    nodes {
      __typename
      ... on PullRequest {
        number title url updatedAt state isDraft reviewDecision mergeable
        repository { nameWithOwner } author { login }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
      ... on Issue { number title url updatedAt state repository { nameWithOwner } author { login } }
    }
  }
  rateLimit { resetAt }
}
```

- Each node becomes a `LiveItem` whose ID is its `url`, with a `GitHubItem` that keeps its kind, state (open, draft, merged, or closed), repository, number, author, review decision, mergeable state, and check state. The item's detail line is "owner/repo #123 · author".

### Items as tabs

- `LiveFolderReconciler.plan(items:tabs:dismissed:)` compares the folder's items with its tabs, given as `LiveItemTab` values (tab ID, item ID, whether the tab has its page, whether a window shows it, and its title). The plan adds a tab for each listed item that has none and is not dismissed, retitles tabs whose items changed title, removes tabs for items the source no longer lists unless the tab has its page or a window shows it, and orders tabs by the source, with retained tabs for removed items last. A retained tab that later loses its page is removed at the next plan.
- The session applies the plan to the folder. A new tab is pinned, in the folder, with `liveItemID`, a saved page of the item's address and title, and a stand-in at that address in the default engine. It joins as a restored tab does, so hooks get no `tabOpened` for it; its first load counts as a visit, since the user chose to open it.
- Item tabs follow live folder rule 4. Their rows show the item's title while on the saved page unless the user renamed the tab, and Tab Names leaves them unnamed. A GitHub item's row shows, while its tab has no page, a symbol for its state in place of the site's icon: `arrow.triangle.pull` in green for an open pull request and gray for a draft, `arrow.triangle.merge` in purple for a merged one, `xmark.circle` in red for a closed one, `circle.circle` in green for an open issue, and `checkmark.circle` in purple for a closed one. The tooltip shows the detail line, the review decision, the check state, a conflict, and the address.
- `FolderTree` refuses every drop into a live folder and every reordering inside one. Moving an item's tab out by dragging, Move to Folder, Unpin Tab, or another space's symbol clears its `liveItemID` and keeps its saved page, and the session immediately plans the folder again with the stored items, adding a tab for the item marked read.

### Read and unread

- `live-folders.json` keeps, for each folder, when each listed item was last viewed (`viewedAt`). Items seen at the folder's first successful fetch count as viewed then. An item is unread if it has no `viewedAt` or, for GitHub, its `updatedAt` is later.
- A window showing an item tab sets its `viewedAt` to the current time, and again when a refresh arrives while it shows the tab, so changes the user makes while looking stay read. Mark as Read sets it, Mark as Unread clears it, and Mark All as Read sets it for every item of the folder.
- The tab's `isUnread` follows the item, so the row shows the existing dot. The folder's row shows the count of unread items after its name.
- After the next successful fetch, `viewedAt` and the dismissed set lose entries for items the source no longer lists.

### Refreshing

- `LiveFolderSchedule` is a pure function of a folder's state, its configuration, the trigger, the moment, and Low Power Mode. It answers whether to refresh now and when the next attempt is due, following live folder rule 6, so tests can drive every rule without timers.
- `LiveFolderService`, on the main actor, owns the store, one `NSBackgroundActivityScheduler` (interval 5 minutes, tolerance 1 minute, utility quality of service) that refreshes due folders, the queue that runs at most four fetches and one `gh` process, and the folders' current fetches. The session registers its live folders with it at launch and after each change, passes the triggers (Arch becoming active, a window showing a space, Refresh Now), and receives each result with the folder's items and read state to plan and apply.
- A refresh records its attempt and outcome: the items and validators on success; the error, the failure count, and the earliest next attempt on failure. `URLError.notConnectedToInternet` and `.networkConnectionLost` record the error without counting it. Quitting cancels running fetches and ends the `gh` process group.

### Interface

- New Live Folder…, after New Folder in the space menu, opens a sheet on the window titled "New Live Folder in <space>", or "New Live Folder in Work / Research" with two or more Personas (Persona rule 7).
  - Source: Feed or GitHub.
  - Feed: an address field prefilled with the selected tab's address when it is a web page. Add loads it: a feed is used directly; if an HTML page has only one feed, it is used immediately; several feeds appear in a list to choose from; with none, the sheet says "No feed found at this address."
  - GitHub: Host (`github.com` by default) and Show: My Pull Requests, Review Requests, Assigned Issues, or Search with its field. A status line comes from `GitHubCLI`: "Install the GitHub CLI in the built-in terminal, for example with `brew install gh`." when it is missing, "Sign in with `gh auth login` in the built-in terminal." when signed out, and the host when ready, with Open Terminal (`BrowserSession.openTerminal`, which the app shell sets as it does for Settings) and Check Again. Add is enabled only when ready.
  - Name (by default the feed's title, Pull Requests, Review Requests, Issues, or GitHub Search), Items (10, 25, or 50), and Refresh (15 minutes, 30 minutes, 1 hour, or 3 hours).
  - Add puts the folder after the space's pinned folders, expanded, and refreshes it. With 20 live folders, Add is disabled and the sheet says "Arch keeps up to 20 live folders."
- Edit Live Folder… opens the same sheet with the folder's values. Changing the source resets the folder: its items, read state, and dismissed items are removed, and it refreshes.
- The folder's row shows `dot.radiowaves.up.forward` for a feed or `arrow.triangle.pull` for GitHub in place of the folder symbol, the unread count after the name, a small progress indicator in the chevron's place while it refreshes, and, after a failed refresh, `exclamationmark.triangle` before the chevron with a tooltip showing the error and the next attempt.
- The folder's context menu: Refresh Now, Mark All as Read, Show Dismissed Items (with their number, while there are any), Edit Live Folder…, Rename Folder, Convert to Folder, and Delete Folder. Convert to Folder keeps the tabs as ordinary pinned tabs with their saved pages and forgets the source and the folder's entry in the store. Delete Folder closes the item tabs without adding them to the closed list once their pages agree; a tab whose page asks to stay leaves the folder as an ordinary pinned tab.
- An item tab's context menu: Mark as Read or Mark as Unread, Dismiss, Rename Tab, Copy Address, Go Back to Saved Page while off it, Open in Split View, Add to Favorites, and Move to Folder.

### Storage

- `LiveFolderStore` keeps `live-folders.json` in the app's Application Support folder: a version, and for each folder ID its last attempt and success, failure count, last error, earliest next attempt, feed validators, feed interval and title, items in source order, the time of the first successful fetch, `viewedAt`, and the dismissed item IDs. It writes on its own queue half a second after the last change, and again at quit.
- A file that does not decode moves to `live-folders.unreadable.json`, and the folders fetch again. After the session loads, entries for folders that are not live folders in `session.json` are removed, so a deleted folder, space, or Persona leaves nothing behind.

## session.json

- III.16 (the next free version): `TabRecord.savedPage`. `normalized()` gives a pinned open record without one its address and title, when it has an address, and drops it from an unpinned record. `TabRecord.closed` keeps it, so a reopened pinned tab returns with its saved page.
- III.18 (the next free version): `TabFolder.parentID`. `normalized()` clears a parent that is missing, in another space or list, part of a cycle, or deeper than the fourth level, or a live or agent folder.
- III.22 (the next free version): `TabFolder.live` and `TabRecord.liveItemID`. `normalized()` moves a live folder in the open list to the pinned list, clears its `parentID` when its parent is a live folder, drops `liveItemID` from records outside live folders, and takes records without an item ID out of live folders.
- Older builds ignore these fields. When they save, saved pages, parents, and live folders are dropped. The next load gives pinned tabs their current pages as saved pages again, the folders become one level deep, and live folders become ordinary folders that keep their tabs.

## Persona / Space labels

- `BrowserSession.label(ofSpace:)` gives a space's label under Persona rule 7: its name alone with one Persona, "Persona / Space" with two or more. `displayedName(ofPersona:)` gives a Persona-wide label, as today. III.15 adds `label(ofSpace:)` and moves the space header and the window title to it. Every label in this note uses them: the live folder sheet's title, the Bookmarks menu's submenus and their favorites heading.

## Interactions with other features

- Sync (V.9): a pinned tab syncs its saved page, the user's name, engine, order, space, and folder, not its current address, which settles open decision 2 of `docs/sync.md`. Folders sync their parent and their live configuration. Item tabs, `live-folders.json`, and every tab's current page stay on each Mac; each Mac fetches its own items.
- Browser import (V.12, built): each imported pinned tab's saved page is its imported address, and folders stay one level deep (bookmark rule 6).
- Agents (VII.12): agent folders stay at the top level of the open list and hold no folders; their tabs never unload automatically. A folder is ordinary, live, or an agent folder, never two kinds at once.
- Web extensions: a tab without its page is left out of the windows the host reports, as a restored tab is today, so unloading a tab removes it from the extensions' view until it loads again.
- AI hooks: unloading posts nothing; item tabs post no `tabOpened`; Tab Names does not name item tabs.
- The palette and the tab switcher list tabs without pages, as they list restored tabs, so the palette finds feed items and pull requests by title.
- History: refreshing records no visits. A pinned or item tab records a visit when the user opens its page.
- Split view: unloading or dismissing a pane's tab takes it out of the split view, as closing does.
- ⌘-numbers, Next and Previous Tab, and Close Other Tabs treat item tabs as pinned tabs. Archiving never closes pinned tabs, so it leaves item tabs alone.
- Small windows: a small window's tab is never pinned, so none of this applies there.

## Types and files

- `Packages/ARCH/Sources/Browsing`:
  - New `SavedPage.swift`: `SavedPage`, `URL.isSamePage(as:)`, `URL.isSameSite(as:)`, and the saved page commands' session methods.
  - New `TabUnloading.swift`: `TabCloseAction`, `UnloadCandidate`, `TabUnloading.tabsToUnload(_:now:after:pressure:)`, the memory pressure source, and `ARCHUnloadAfterHours`.
  - New `FolderTree.swift`: the tree, its rows with levels, its moves, `dropTarget(for:at:)`, and its repairs.
  - New `BookmarkMenu.swift`: `BookmarkMenu.entries(for:)`.
  - New `LiveFolderTabs.swift`: the session's side of live folders: registering folders, applying plans, read state, dismissal, conversion, deletion, and triggers.
  - New `LiveFolderSheet.swift`: the sheet and its model.
  - `Tab.swift`: `savedPage`, `liveItemID`, `isOffSavedPage`, `isOffSavedSite`, unloading into a stand-in, `answersBeforeUnloadWithStay`, and `displayTitle` for item tabs.
  - `UnloadedWebContents.swift`: an initializer that takes an icon.
  - `Space.swift`: `TabFolder.parentID` and `TabFolder.live`.
  - `SessionStore.swift`: the fields and migrations above.
  - `BrowserSession.swift`, `BrowserWindowModel.swift`, `TabRowView.swift`, `TabFolderRowView.swift`, `SpaceTabsView.swift`, `FavoritesGridView.swift`, `SidebarDragState.swift`, `SidebarDragAndDrop.swift`, `BrowserWindowController.swift`, `BrowserHooks.swift`, and `SidebarImport.swift` as described above.
- New `Packages/ARCH/Sources/LiveFolders` (depends on `AI`): `LiveFolderSource.swift` (`LiveFolderSource`, `GitHubSearch`, `LiveFolderConfiguration`), `LiveItem.swift` (`LiveItem`, `GitHubItem`, `LiveFolderError`), `FeedParser.swift`, `FeedDiscovery.swift`, `FeedFetcher.swift`, `GitHubCLI.swift`, `LiveFolderSchedule.swift`, `LiveFolderStore.swift`, `LiveFolderReconciler.swift`, and `LiveFolderService.swift`. `LiveFolderFetching` lets tests replace the fetchers.
- `Packages/ARCH/Sources/AI`: `LoginShell`, `CommandLineProcess`, and `CommandLineTermination` become public, so there is one copy of the process code.
- `Packages/ARCH/Sources/Preferences/PreferencesSections.swift`: the unload stepper.
- `Packages/ARCHApp/Sources/Arch/AppDelegate.swift`: the Tab menu's saved page items, the Bookmarks menu, and `BrowserSession.openTerminal`.
- `Package.swift`: the `LiveFolders` target and library, `Browsing` depending on it, and the `LiveFoldersTests` target.

## Tests

- `BrowsingTests`:
  - Saved pages: a version 12 file whose pinned records get their address and title as saved pages and whose open records get none; a round trip and the closed list keep them; pinning a `PageStub` tab saves its page, unpinning clears it, and a pinned tab without an address takes the first one reported; the comparisons (fragment, scheme, `www.`, host case, trailing slash, a different query or path, another host); Go Back on a tab without a page moves its stand-in without loading; Use Current Page; Edit Saved Address with accepted and rejected text; a favorite's Use Current Page disabled when another favorite of its Persona has the address.
  - Unloading: `TabCloseAction` for each kind of tab; Close on a pinned `PageStub` tab leaves a stand-in at its saved page without state, in the same place, folder, and ID, and no closed record; an automatic unload keeps the address, title, state, and icon; `tabsToUnload` with hours passed and not, 0 hours, a warning with 30 minutes, critical, and each exclusion; Delete Tab's closed record reopens pinned with its saved page.
  - Folders: repairs of `parentID`; rows with levels (folders before tabs at every level); a collapsed ancestor showing only the selected tab; allowed and refused moves; Delete Folder moving folders and tabs up; a file without `parentID` loads flat; `dropTarget` between rows at each level, on a folder row, inside the dragged folder's own tree, and on a live folder.
  - Bookmarks menu: one Persona (space names alone, spaces without pinned tabs left out, nested folders in order, live folders with their counts, No Bookmarks) and two (submenus titled "Work / Research", the favorites headed "Work", Personas in order).
  - Live folders in the session: the snapshot round trip and its repairs; a plan applied to `PageStub` and stand-in tabs; dismissing an item tab; moving one out, after which the next plan adds a tab for the item; a window showing an item tab marking it viewed; Convert to Folder; Delete Folder leaving no closed records.
  - The sheet's model: addresses accepted and refused (not HTTP or HTTPS, a user name or password), default names, the discovery outcomes (a feed, one link, several, none), the `gh` states from a stubbed `GitHubCLI`, Add disabled at 20 live folders, an edit of the source starting over, and the title with one and two Personas.
  - Labels: `label(ofSpace:)` with one Persona and with two, and a Persona-wide label.
- `LiveFoldersTests`:
  - Parsing: synthetic RSS 2.0, RSS 1.0, and Atom files with IDs, links, relative links with `xml:base`, titles with markup and character references, RFC 822 and ISO 8601 dates, items without links or with other schemes skipped, titles cut at 300 characters, `ttl` and the syndication interval, newest first when every item has a date, and a file that is not a feed.
  - Discovery: alternate links of both types, relative addresses, other link types ignored, and at most ten.
  - Fetching through a `URLProtocol` stub: validators sent and stored, 304 keeping the items, the 5 MB limit, `Retry-After` in both forms, other statuses, an offline error, and an `http` address tried as `https`.
  - `gh` through shell scripts that stand in for it, as `AITests` does for command-line tools: the arguments are fixed and the search arrives only on standard input; the environment holds only the listed keys; exit 0 with nodes of both kinds mapped to items with their state, review decision, mergeable state, and checks; exit 4 as signed out; exit 1 with an `errors` object and with only standard error; `RATE_LIMITED` with and without `resetAt`; a missing executable; the 30-second limit; and the 8 MB limit.
  - Schedule: each interval, the activation gap for GitHub and none for feeds, `ttl` up to 24 hours, the doubling up to 6 hours, offline failures not counted, `Retry-After`, the rate limit reset, and Low Power Mode.
  - Store: a round trip, an unreadable file moved, entries for removed folders dropped, and entries for removed items pruned after a success.
  - Reconciler: new items added in order, retitled tabs without pages, gone items' tabs removed unless they have pages or are shown, dismissed items left out, the first fetch read, later items unread, and GitHub items unread after a newer `updatedAt`.

## Implementation order

Each step builds, keeps the app working, passes `swift test`, and forms one commit with the subject `Task(<ID>): …`. Each finishes by removing its row, updating Current State and the rows in `docs/features.md`, and adding its checks below to the regression checklist as the next free numbers.

1. III.15: Persona / Space labels on the existing surfaces.
2. III.16: Saved pages.
3. III.17: Unloading.
4. III.18: Nested folders: model, rows, and menus.
5. III.19: Dragging folders.
6. III.20: The Bookmarks menu.
7. III.21: The `LiveFolders` module, which nothing in the app uses yet.
8. III.22: Live folders in the sidebar.
9. III.23: The New Live Folder sheet.
10. III.24: The checks below run from the bundle; rows 64 and 65 complete. III.25, which only the user can do, comes first: `gh` signed in for github.com in the built-in terminal, and a pull request that requests the user's review for the Review Requests part of check 7.

## Checks with the app

Run from the bundle launched through `open`, on both engines, with a fresh Application Support folder:

1. A pinned tab that follows a link to another site shows the back button under the pointer, and the button returns to the saved page. Following a link within the saved site shows none, while Tab ▸ Go Back to Saved Page is enabled. After Use Current Page as Saved Page, ⌘W, and a relaunch, the tab opens at the new saved page.
2. ⌘W on a selected pinned tab that left its saved page keeps its row in secondary text and selects another tab; clicking the row loads the saved page; ⌘Z does not bring the old page back. Delete Tab removes it, and ⌘Z reopens it pinned in its folder.
3. With `ARCHUnloadAfterHours` at 1, a pinned WebKit tab with three pages in its back list and a Chromium favorite's tab, left unshown past the next archive timer after an hour, unload; selecting each returns to the same page with its back list. A pinned tab that plays audio stays loaded. A simulated critical memory pressure (`memory_pressure -S -l critical`) unloads every tab that no window shows.
4. Folders nest four levels deep through New Folder Inside, and the fifth level is refused. A collapsed folder shows only the selected tab within it. Dragging a folder into another and onto another space's symbol moves it with its contents. The tree survives a relaunch.
5. With a second Persona named Work, the Bookmarks menu shows the favorites under the window's Persona's name, and submenus titled "Work / Personal" and "Default / <space>" with the spaces' pinned folders and tabs. Choosing a pinned tab of another space selects it there.
6. New Live Folder… from a blog's page finds its feed, adds up to 25 items without dots, and a later refresh that brings a new post shows a dot and the count. Selecting the item clears both. ⌘W dismisses an item; Show Dismissed Items brings it back. Read state and dismissed items survive a relaunch. Turning the network off shows the error symbol, and the folder recovers once the network is back.
7. A GitHub folder with My Pull Requests, using the Mac's signed-in `gh`, lists the open pull requests that `gh search prs --author=@me --state=open` lists, with state symbols and tooltips. With a pull request that requests the user's review, a Review Requests folder lists it. A folder for a host where `gh` is not signed in, such as `github.invalid`, shows the sign-in message in the sheet. Becoming active after 5 minutes refreshes it. Dragging an item out leaves a new tab for it in the folder.
8. With two Personas, a space's header shows "Work / Personal", the Window menu shows "<title> — Work / Personal", and the Clear Site Data sheet names Work alone.

## Not verified

- Whether App Transport Security makes the bundle's `URLSession` refuse an `http` feed (expected), and how often feeds offer HTTPS at the same address.
- How `NSBackgroundActivityScheduler` spaces its runs while Arch is in the background or the Mac is on battery.
- Whether `memory_pressure -S` reaches the app's memory pressure source.
- `gh`: results of `user-review-requested:@me` (the account had none), a GitHub Enterprise Server host, the shape of a rate-limited response, and running from the bundle, whose process tree differs from a shell's.

## Risks

1. Older builds drop the new fields (see session.json). Pinned tabs then get their current pages as saved pages, and live folders become ordinary folders.
2. GitHub's GraphQL schema can change. A query that fails shows its error on the folder row, and the folder keeps its last items.
3. Feeds vary. A malformed item is skipped, and a malformed file is an error that keeps the last items.
4. A feed that gives its items new IDs at every fetch marks them unread each time and replaces their tabs. The item limit bounds the churn.
5. Twenty folders of 50 items make 1,000 tabs without pages in `session.json`. They hold no engine pages, collapsed folders draw no rows, and the limits bound the file.

## Open decisions

Until the user decides otherwise, the implementation uses the option this note describes.

1. Other sources, such as calendars and documents: none yet (this note); a later plugin contribution in `docs/plugins.md` could add sources that a plugin fetches.
2. JSON Feed: not read (this note); it can join `FeedParser` later.
3. Notifications for new items: none (this note); the dots and counts are enough for now.
4. Requests to the user's teams in Review Requests: left out (this note); a search with `review-requested:@me` includes them.
