# Live sources design

Status: a design note awaiting the user's approval (queue row III.37 in `docs/plan.md`). Nothing here is built. Once the user approves it, rows that build it replace III.37.

A live source is a sidebar folder that a hook keeps filled with links from a feed, a GitHub search, or any address the user grants. It replaces the live folders removed on November 23 (`docs/bookmarks.md`, Live sources) without restoring their code: the removed `LiveFolders` module, `live-folders.json`, `TabFolder.live`, `TabRecord.liveItemID`, and the sync record's `live` field stay gone or unused. The design follows `docs/hooks.md`, whose rules apply unless this note says otherwise: a hook's action is a script, a script that needs AI runs an agent, and each new part has one job and serves later features too.

Terms: a "source folder" is the sidebar folder; a "source hook" is the hook that fills it; an "item" is one link the hook writes into the folder.

## Principles

1. A live source is an ordinary hook plus a folder. The hook registry runs it on the shared scheduler with its pausing, loop protection, daily counts, and run log. Live sources add no runner, scheduler, or store of their own for scripts.
2. A script writes items only through one narrow call bound to one folder, which the hook's grant names. It cannot open, read, or rename tabs through it.
3. Network goes only to the hosts the user granted, through the plugins' checked fetch (`docs/plugins.md`, Permissions: `network`), without cookies. GitHub goes only through the user's own signed-in `gh`, in a fixed read-only command. Arch runs no server and adds no telemetry.
4. Items are rows, not tabs. Opening an item opens an ordinary tab, so the session, sync, and tab lists hold no generated tabs.
5. Nothing of a live source syncs. Hooks stay on each Mac (hook decision 8), so a folder that only a hook fills stays on its Mac too.

## Reusable parts

| Part | Module | One job | Interface | Also serves |
|---|---|---|---|---|
| Scheduled trigger | `Hooks` | Runs a hook every interval while Arch runs | `HookTrigger.schedule(every:)`, `HookClock` | Any hook on a timer, such as a daily digest |
| Hook network | `Hooks`, on `Plugins` | Gives a hook script `arch.net.fetch` to granted hosts | `HookPermission.network`, `HookGrant.network`, `PluginNetworkFetch` made public | Any hook that reads a public service |
| GitHub search | `Hooks`, on `AI`'s `CommandLineProcess` and `LoginShell` | Runs `gh search` read-only and returns JSON | `HookPermission.githubSearch`, `arch.github.search(kind, query, options)` | Any hook that needs the user's GitHub view |
| Folder items | `Hooks` (call), `Browsing` (store, rows) | Replaces one source folder's items | `HookPermission.folderItems`, `HookGrant.folder`, `arch.folder.items()`, `arch.folder.setItems(…)`, `arch.folder.unchanged()`, `arch-cli items set`, `SourceFolderWriting` | Any hook that keeps a list, such as one an agent picks |
| Source templates | `Hooks` | Turns the New Source sheet's choices into a hook and its script | `SourceHookTemplate`, `HookPresets.feed`, `HookPresets.githubSearch` | Settings ▸ AI ▸ Hooks presets |
| Agent pick (later) | `Agent` | Lets an agent run keep, order, or drop items | Run input `items`, run tool `choose_items` | Any list a hook wants filtered |

### Scheduled trigger

- `HookTrigger.schedule(every:)` takes 15 minutes to 1 day; the sheet offers 15 minutes, 30 minutes, 1 hour (default), 3 hours, 12 hours, and 1 day. It is not a browser event: `HookClock` in the registry posts the step on the shared scheduler with the hook's identifier as the subject, so a hook never overlaps itself and a late tick replaces a waiting one.
- Runs happen only while Arch runs; no launchd job or helper wakes it. At launch, overdue hooks run 30 seconds after the session restores, 5 seconds apart in list order. Ticks missed during sleep become one run after wake. While macOS reports no network path (`NWPathMonitor`), ticks wait and count toward no failure.
- The last run's time is kept in `hooks.json` with the hook, so a relaunch does not refresh every source at once.
- A scheduled run has no event tab and no run tabs; its script view is `{"kind": "schedule", "date": …, "hook": {…}}`.

### Hook network

- A hook the user makes in Arch may hold `network` with hosts, under the plugins' host rules: names or `*.` names, no IP literals, `localhost`, ports, or paths. The checked fetch applies unchanged: HTTPS on 443, public addresses only, one resolution, no proxy, no cookies, no cache, checked redirects, 5 MB UTF-8 responses, 30 seconds, 60 requests a minute per hook.
- Hooks from outside programs never get `network` (Hooks from outside programs in `docs/hooks.md` gains the row), and neither does a shell hook, whose script can reach the network by itself.
- The editor and the New Source sheet state the grant as "Connect to \<hosts>, without your cookies."

### GitHub search

- `arch.github.search(kind, query, {limit})` runs `gh search issues|prs|repos <query> --json <fixed fields> --limit <n>` at the `gh` that the login shell's PATH resolves, as the built-in terminal finds it, with `posix_spawn` and no shell. `kind` is one of the three, `query` is one argument of at most 256 characters that may not start with `-`, and `limit` is 1 to 100. No other subcommand, flag, or `gh api` call is reachable, so the script cannot write to GitHub.
- It returns `[{title, url, updatedAt, state, repository}]`; `url` must be an `https://github.com` address, or the item is dropped.
- Failures: `gh` not found, not signed in (`gh auth status` fails), or a nonzero exit, each with Arch's sentence and the last line of standard error in memory only.
- The grant reads "Search GitHub as you, through gh." `gh` sends the request to GitHub under the user's sign-in; Arch adds no host of its own.

### Folder items

```js
await arch.folder.setItems({
  items: [{ key: "tag:example.org,2026:post-12", title: "Release notes", url: "https://example.org/notes", date: "2026-11-23T08:00:00Z" }],
  validator: "W/\"5e2c\""
});
```

- `items()` returns the folder's current items and the last `validator`, a source's ETag or Last-Modified of at most 256 characters, so a script can send a conditional request. `unchanged()` records a successful refresh without changes, as after a 304.
- `setItems` replaces the list in the given order and resolves `{added, kept, removed}`. Each item has a `key` (1 to 256 characters, the source's identifier, or the address when the source has none), a `title` (first line, trimmed, cut to 200 characters, the address's host when empty), an `http` or `https` `url` without user information of at most 2,048 characters, and an optional ISO 8601 `date`. Items past the folder's limit, duplicate keys, and duplicate addresses after the first are dropped; an invalid item rejects the call with `invalidItem` and its index, and nothing changes.
- A shell hook with `folderItems` writes the same JSON with `arch-cli items set -` on its run's ticket connection (`docs/hooks.md`, Shell scripts), and `arch-cli items` prints the current items.
- `SourceFolderWriting`, which `Browsing` implements, applies the list and keeps read state by key. The call reaches only the folder in `HookGrant.folder`; a folder that is gone rejects with `placeDeleted` and pauses the hook.

### Source templates

- Feed: fetches the address; when it is a page, finds the first RSS, Atom, or JSON Feed `<link rel="alternate">`, parses with `DOMParser` in the script sandbox, and writes items. The sheet runs it once at Create to find the feed's host and asks to add it when it differs from the page's.
- GitHub search: calls `arch.github.search` and writes the results.
- Each template is an ordinary JavaScript hook whose script Arch writes (`generated: true`), which the user can open, edit, or restore, as with agent hooks. Arch writes no shell script (hook decision 4); a user who wants another command, such as a private `gh api` query, writes a shell hook with `folderItems`.

### Agent pick (later)

- A source hook's script may pass its items to `arch.agent.run` as the run input `items`, an untrusted block of titles and addresses without page text, with the run tool `choose_items(keys)`, which keeps the listed keys in the listed order. The New Source sheet offers it as "Choose items with an agent" with the agent hook editor's Instructions, Model (a tier or a model), and Record sections, so the user picks the model and what Arch keeps as for any agent hook.
- It reads no page and acts on no tab, so Keep Nothing is allowed under the record rule (`docs/hooks.md`, Record levels).

## The folder

- A source folder sits at the top level of a space's pinned list, after the space's pinned folders, and holds only items. It takes no dropped tabs and no nested folders.
- `session.json` version 17 lists source folders in a new top-level `sourceFolders` array (`id`, `spaceID`, `index`, `name`, `hookID`, `isCollapsed`), not among `TabFolder`s, so an older build drops them rather than turning them into ordinary pinned folders that would sync. Items and read state live in `~/Library/Application Support/Arch/source-items.json`, mode 0600, keyed by folder.
- An item row shows the site's icon, the title, and the date in secondary text. An unread item shows its title in the label color with a 6-point accent dot; a read item shows it in the secondary label color. Each row is plain text, never markup. A collapsed folder shows its unread count in secondary text at the row's trailing edge.
- Clicking an item selects an open tab of the space already on its address (bookmark rule 3) or opens a new open tab with the default engine and selects it; Command-click opens it behind. Opening marks it read.
- Item menu: Open, Open in New Window, Copy Address, Pin to Space (an ordinary pinned tab with the item's saved page, which syncs as any pinned tab), and Mark as Read. Dragging an item into the pinned list or a pinned folder pins it the same way.
- Folder menu: Refresh Now (runs the hook at once; at most once a minute), Mark All as Read, Edit Source… (the hook's editor), Pause Updates or Resume, Rename, and Delete Folder…, which says that it also deletes the hook.
- The folder and its hook are one unit: deleting either deletes both and the folder's items.
- Read state: an item is unread when it first appears, read once opened or marked. Keys that leave the list drop their state.

## Refresh limits

| Limit | Value |
|---|---|
| Interval | 15 minutes to 1 day; 1 hour by default |
| Refresh Now | Once a minute per folder |
| Runs per day | 100 by default, the hook's `runsPerDay` |
| Timeout | 30 seconds by default, at most 2 minutes |
| Requests | 60 a minute per hook (checked fetch); the templates make at most 3 a run |
| Items | 25 by default; 10, 25, 50, or 100 |
| Back-off | After a failed run, the next tick waits twice the interval, up to 1 day; three failures in a row pause the hook (`failures`) |
| Server limits | The templates honor `Retry-After` and 429 or 503 by skipping ticks until then |

## Failure states

The folder keeps its last items through every failure. Its row shows a warning symbol and the hover text names the state; the folder menu offers the action.

| State | Folder row says | Action |
|---|---|---|
| Not run yet | "Waiting for the first refresh" | Refresh Now |
| Source unreachable or timed out | "Couldn't refresh · 2 hours ago" | Refresh Now |
| Host refused or redirect to another host | "The source moved to \<host>" | Edit Source… to allow the host |
| Unreadable response | "The source sent something Arch couldn't read" | Edit Source… |
| `gh` missing or signed out | "gh isn't signed in" | Open Terminal, a built-in terminal tab in the folder's space with `gh auth login` typed but not run |
| Hook paused | The pause reason's sentence (`docs/hooks.md`, Errors) | Resume or Review |
| Run Hooks off | "Hooks are off" | Open Hook Settings |
| Offline | "Offline · updated 2 hours ago" | None; refreshes when back online |
| Empty source | "No items" | None |

## Privacy

- Requests go only to the granted hosts, or through `gh` to GitHub, never to an Arch server. Fetches carry no cookies, so a source sees an anonymous client with `User-Agent: Arch`.
- The run log keeps no titles or addresses, as for other hooks; a run's actions record only the count, `{"folderItems": 3}`. Titles and addresses of items live only in `source-items.json`, which deleting the folder removes.
- No item reaches a model unless the user turns on the agent pick, and then only titles and addresses as untrusted data, under the hook's site exclusions (hook decision 14).
- Phase 1 takes public sources only: the sheet refuses an address with user information and warns that an address with a query is stored in the hook's script. Private feed addresses wait for hook secrets in the Keychain (open decision 5).

## Personas

- A source folder belongs to one space; its hook's scope is that space, shown as "Persona / Space" in Settings ▸ AI ▸ Hooks and on the sheet, such as "Personal / Work", or the space's name alone with one Persona.
- Items open in that space, so the page loads with that Persona's cookies; the hook's own fetches carry none.
- Deleting the space or Persona deletes its source folders and their hooks. Moving a space to another Persona moves its folders with it.

## Sync

- Source folders, their items, and read state do not sync. Hooks do not sync, so another Mac would show the folder empty and unable to refresh; each Mac that wants a source makes its own. Syncing items would also put source titles and addresses in iCloud for no gain, since each Mac fetches them anyway.
- Source folders are never `Folder` records. `SidebarSyncState` leaves them out as it leaves agent folders out, so no schema change is needed and `schemaVersion` stays 2.
- The `live` field stays unused: this build keeps neither reading nor writing it, as `docs/sync.md` (Schema versions) describes.
- A pinned tab made from an item is an ordinary pinned tab and syncs.

## UI

- The sidebar's New menu gains New Source Folder…, which opens a sheet built from the site settings parts: Name; Source (Feed or Website, GitHub Search with kind and query, or Script, which opens New Script Hook… with `folderItems` checked); Where, the current "Persona / Space", changeable; Refresh Every; Show at Most; the grant sentences ("Connect to example.org, without your cookies." or "Search GitHub as you, through gh."); and, later, Choose Items with an Agent with Instructions, Model, and Record. Create makes the folder and its hook and runs the first refresh.
- Settings ▸ AI ▸ Hooks lists each source hook as a row with its situation ("Every hour · Personal / Work · fills Release Notes"), last run ("5 minutes ago · 3 new items"), and Edit…, which opens the same sheet. Script options stay in the hook editor.
- Placeholders: the source folder's symbol and the warning symbol are left for the user to choose; code uses SF Symbols until then and adds no graphic asset.

## Build order after approval

1. Scheduled trigger, with `HooksTests` for intervals, launch catch-up, sleep, and offline.
2. Hook network: `PluginNetworkFetch` made public, the permission, and its refusal for outside programs and shell hooks.
3. Folder items and the source folder: `session.json` version 17, `source-items.json`, the rows, menus, and read state, with `BrowsingTests` and `HooksTests`.
4. The New Source sheet and the Feed template.
5. GitHub search.
6. Agent pick, after the user confirms open decision 6.

Each step adds its bundle check to the regression checklist in `docs/plan.md`.

## Open decisions

1. Items as rows or as tabs. Recommendation: rows. The removed item tabs filled `session.json` and the tab lists with generated tabs and needed special cases in drops, closes, and sync.
2. Sync. Recommendation: sync nothing of a live source, as above; a user can pin an item to sync it.
3. Network for hook scripts. `docs/plugins.md` says hook scripts cannot request `network`. Recommendation: allow it for hooks the user makes in Arch, never for outside programs' hooks or shell hooks, and update that sentence when step 2 is built.
4. GitHub through a fixed read-only `gh search` or through shell hooks only. Recommendation: the fixed command for the preset, since it cannot write to GitHub; shell hooks remain for anything else.
5. Private feed addresses that carry a token. Recommendation: public sources only in phase 1; add hook secrets in the Keychain (`arch.secrets.get`, service `xyz.taeyoon.arch.hooks.secrets`) as a later reusable part.
6. The agent pick's record floor. Recommendation: allow Keep Nothing and make it the default, since the run reads no page and changes only which items show.
7. The shortest interval. Recommendation: 15 minutes, which keeps a source well under common rate limits.
8. Placement. Recommendation: top level of the pinned list only in phase 1; inside pinned folders later if the user asks.
9. Deleting the folder or the hook. Recommendation: one unit, so neither is left behind without the other.
