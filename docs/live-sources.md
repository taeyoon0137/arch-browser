# Live sources design

Status: design awaiting the user's approval (queue row III.37 in `docs/plan.md`). Nothing here is built. After approval, implementation rows replace III.37.

A live source is a sidebar folder that a hook fills with links from a feed, a GitHub search, or any address the user grants. It replaces the live folders removed on November 23 (`docs/bookmarks.md`, Live sources) without restoring their code: the `LiveFolders` module, `live-folders.json`, `TabFolder.live`, `TabRecord.liveItemID`, and the sync record's `live` field remain removed or unused. The rules in `docs/hooks.md` apply unless this note says otherwise: a hook runs a script, a script that needs AI runs an agent, and each new part has one job and supports later features too.

Terms: a "source folder" is the sidebar folder; a "source hook" fills it; an "item" is one link the hook writes into it.

## Principles

1. A live source is an ordinary hook plus a folder. The hook registry uses the shared scheduler's pausing, loop protection, daily counts, and run log. Live sources add no runner, scheduler, or store for scripts.
2. A script writes items only through one limited call bound to the folder named in the hook's grant. It cannot open, read, or rename tabs through that call.
3. Network requests go only to granted hosts through the plugins' checked fetch (`docs/plugins.md`, Permissions: `network`), without cookies. GitHub requests use only the user's signed-in `gh` with a fixed read-only command. Arch runs no server and adds no telemetry.
4. Items are rows, not tabs. Opening an item opens an ordinary tab, so the session, sync, and tab lists hold no generated tabs.
5. No part of a live source syncs. Hooks stay on each Mac (hook decision 8), so folders filled only by hooks stay there too.

## Reusable parts

| Part | Module | One job | Interface | Also serves |
|---|---|---|---|---|
| Scheduled trigger | `Hooks` | Runs a hook at intervals while Arch runs | `HookTrigger.schedule(every:)`, `HookClock` | Any hook on a timer, such as a daily digest |
| Hook network | `Hooks`, on `Plugins` | Lets a hook script use `arch.net.fetch` for granted hosts | `HookPermission.network`, `HookGrant.network`, `PluginNetworkFetch` made public | Any hook that reads a public service |
| GitHub search | `Hooks`, on `AI`'s `CommandLineProcess` and `LoginShell` | Runs `gh search` read-only and returns JSON | `HookPermission.githubSearch`, `arch.github.search(kind, query, options)` | Any hook that needs the user's GitHub view |
| Folder items | `Hooks` (call), `Browsing` (store, rows) | Replaces one source folder's items | `HookPermission.folderItems`, `HookGrant.folder`, `arch.folder.items()`, `arch.folder.setItems(…)`, `arch.folder.unchanged()`, `arch-cli items set`, `SourceFolderWriting` | Any hook that keeps a list, such as one an agent picks |
| Source templates | `Hooks` | Creates a hook and script from the New Source sheet's choices | `SourceHookTemplate`, `HookPresets.feed`, `HookPresets.githubSearch` | Settings ▸ AI ▸ Hooks presets |
| Agent pick (later) | `Agent` | Lets an agent run keep, order, or drop items | Run input `items`, run tool `choose_items` | Any list a hook wants filtered |

### Scheduled trigger

- `HookTrigger.schedule(every:)` accepts 15 minutes to 1 day; the sheet offers 15 minutes, 30 minutes, 1 hour (default), 3 hours, 12 hours, and 1 day. It is not a browser event: the registry's `HookClock` posts the step to the shared scheduler with the hook's identifier as the subject. A hook never overlaps itself, and a late tick replaces a waiting one.
- Hooks run only while Arch runs; no launchd job or helper wakes it. At launch, overdue hooks run 30 seconds after the session restores, 5 seconds apart in list order. Ticks missed during sleep become one run after wake. While macOS reports no network path (`NWPathMonitor`), ticks wait without counting as failures.
- Each hook's last run time is stored in `hooks.json`, so relaunching does not refresh every source at once.
- A scheduled run has no event tab and no run tabs; its script view is `{"kind": "schedule", "date": …, "hook": {…}}`.

### Hook network

- A hook the user creates in Arch may have `network` access to hosts under the plugins' host rules: names or `*.` names, no IP literals, `localhost`, ports, or paths. The checked fetch rules apply unchanged: HTTPS on 443, public addresses only, one resolution, no proxy, no cookies, no cache, checked redirects, 5 MB UTF-8 responses, 30 seconds, 60 requests a minute per hook.
- Hooks from outside programs never get `network` (Hooks from outside programs in `docs/hooks.md` gains the row). Neither do shell hooks, whose scripts can reach the network themselves.
- The editor and the New Source sheet state the grant as "Connect to \<hosts>, without your cookies."

### GitHub search

- `arch.github.search(kind, query, {limit})` runs `gh search issues|prs|repos <query> --json <fixed fields> --limit <n>` using the `gh` found on the login shell's PATH, as in the built-in terminal, with `posix_spawn` and no shell. `kind` is one of the three, `query` is one argument of at most 256 characters that may not start with `-`, and `limit` is 1 to 100. No other subcommand, flag, or `gh api` call is available, so the script cannot write to GitHub.
- It returns `[{title, url, updatedAt, state, repository}]`; `url` must be an `https://github.com` address, or the item is dropped.
- Failures are a missing `gh`, no sign-in (`gh auth status` fails), or a nonzero exit. Each gets an Arch message and the last line of standard error, kept only in memory.
- The grant reads "Search GitHub as you, through gh." `gh` sends the request to GitHub under the user's sign-in; Arch adds no host of its own.

### Folder items

```js
await arch.folder.setItems({
  items: [{ key: "tag:example.org,2026:post-12", title: "Release notes", url: "https://example.org/notes", date: "2026-11-23T08:00:00Z" }],
  validator: "W/\"5e2c\""
});
```

- `items()` returns the folder's current items and last `validator`: the source's ETag or Last-Modified, at most 256 characters, for conditional requests. `unchanged()` records a successful refresh without changes, as after a 304.
- `setItems` replaces the list in the given order and resolves `{added, kept, removed}`. Each item has a `key` (1 to 256 characters, the source's identifier, or the item's address if the source has none), a `title` (first line, trimmed, cut to 200 characters, defaulting to the address's host when empty), an `http` or `https` `url` of at most 2,048 characters without user information, and an optional ISO 8601 `date`. Items past the folder's limit and duplicate keys or addresses after the first are dropped. An invalid item rejects the call with `invalidItem` and its index; nothing changes.
- A shell hook with `folderItems` writes the same JSON with `arch-cli items set -` on its run's ticket connection (`docs/hooks.md`, Shell scripts), and `arch-cli items` prints the current items.
- `SourceFolderWriting`, implemented by `Browsing`, applies the list and keeps read state by key. The call reaches only the folder in `HookGrant.folder`; a missing folder rejects it with `placeDeleted` and pauses the hook.

### Source templates

- Feed: fetches the address; for a page, finds the first RSS, Atom, or JSON Feed `<link rel="alternate">`, parses with `DOMParser` in the script sandbox, and writes items. The sheet runs it once at Create to find the feed's host and asks to add it if it differs from the page's host.
- GitHub search: calls `arch.github.search` and writes the results.
- Each template is an ordinary JavaScript hook with a script written by Arch (`generated: true`). The user can open, edit, or restore it, as with agent hooks. Arch writes no shell scripts (hook decision 4); a user who wants another command, such as a private `gh api` query, writes a shell hook with `folderItems`.

### Agent pick (later)

- A source hook's script may pass items to `arch.agent.run` as the run input `items`: an untrusted block of titles and addresses without page text. The run tool `choose_items(keys)` keeps the listed keys in the listed order. The New Source sheet offers "Choose items with an agent" with the agent hook editor's Instructions, Model (a tier or a model), and Record sections. As with any agent hook, the user picks the model and what Arch keeps.
- It reads no page and acts on no tab, so Keep Nothing is allowed under the record rule (`docs/hooks.md`, Record levels).

## The folder

- A source folder sits at the top level of a space's pinned list, after its pinned folders, and holds only items. It accepts no dropped tabs or nested folders.
- `session.json` version 17 lists source folders in a new top-level `sourceFolders` array (`id`, `spaceID`, `index`, `name`, `hookID`, `isCollapsed`), outside `TabFolder`s. Older builds therefore drop them rather than turn them into ordinary pinned folders that sync. Items and read state live in `~/Library/Application Support/Arch/source-items.json`, mode 0600, keyed by folder.
- An item row shows the site's icon, the title, and the date in secondary text. An unread item's title uses the label color with a 6-point accent dot; a read item's title uses the secondary label color. Each row is plain text, never markup. A collapsed folder shows its unread count in secondary text at the row's trailing edge.
- Clicking an item selects an open tab in the space already at its address (bookmark rule 3), or opens and selects a new open tab with the default engine; Command-click opens it in the background. Opening marks it read.
- Item menu: Open, Open in New Window, Copy Address, Pin to Space (an ordinary pinned tab with the item's saved page, which syncs as any pinned tab), and Mark as Read. Dragging an item into the pinned list or a pinned folder pins it the same way.
- Folder menu: Refresh Now (runs the hook at once; at most once a minute), Mark All as Read, Edit Source… (the hook's editor), Pause Updates or Resume, Rename, and Delete Folder…, which says that it also deletes the hook.
- The folder and its hook are one unit: deleting either deletes both and the folder's items.
- Read state: an item is unread when it first appears and read once opened or marked. Keys removed from the list lose their state.

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

The folder keeps its last items through every failure. Its row shows a warning symbol, hover text names the state, and the folder menu offers the action.

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
- As with other hooks, the run log keeps no titles or addresses; a run's actions record only the count, `{"folderItems": 3}`. Item titles and addresses live only in `source-items.json`, which deleting the folder removes.
- Items reach a model only if the user turns on the agent pick. It receives only titles and addresses as untrusted data, subject to the hook's site exclusions (hook decision 14).
- Phase 1 accepts only public sources: the sheet refuses addresses with user information and warns that addresses with queries are stored in the hook's script. Private feed addresses wait for hook secrets in the Keychain (open decision 5).

## Personas

- A source folder belongs to one space, and its hook is scoped to that space. Settings ▸ AI ▸ Hooks and the sheet show it as "Persona / Space", such as "Personal / Work", or just the space's name with one Persona.
- Items open in that space, so the page loads with that Persona's cookies; the hook's own fetches carry none.
- Deleting the space or Persona deletes its source folders and their hooks. Moving a space to another Persona moves its folders with it.

## Sync

- Source folders, their items, and read state do not sync. Hooks do not sync, so another Mac would show an empty folder that cannot refresh. Each Mac needs its own source. Syncing items would also put source titles and addresses in iCloud even though each Mac fetches them.
- Source folders are never `Folder` records. `SidebarSyncState` leaves them out as it leaves agent folders out, so no schema change is needed and `schemaVersion` stays 2.
- The `live` field stays unused: this build neither reads nor writes it, as `docs/sync.md` (Schema versions) describes.
- A pinned tab made from an item is an ordinary pinned tab and syncs.

## UI

- The sidebar's New menu gains New Source Folder…, opening a sheet built from the site settings parts: Name; Source (Feed or Website, GitHub Search with kind and query, or Script, which opens New Script Hook… with `folderItems` checked); Where, the changeable current "Persona / Space"; Refresh Every; Show at Most; the grant sentences ("Connect to example.org, without your cookies." or "Search GitHub as you, through gh."); and, later, Choose Items with an Agent with Instructions, Model, and Record. Create makes the folder and hook and runs the first refresh.
- Settings ▸ AI ▸ Hooks lists each source hook with its status ("Every hour · Personal / Work · fills Release Notes"), last run ("5 minutes ago · 3 new items"), and Edit…, which opens the same sheet. Script options stay in the hook editor.
- Placeholders: the user chooses the source folder and warning symbols; code uses SF Symbols until then and adds no graphic asset.

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
2. Sync. Recommendation: sync no part of a live source; users can pin items to sync them.
3. Network for hook scripts. `docs/plugins.md` says hook scripts cannot request `network`. Recommendation: allow it for hooks the user creates in Arch, never for outside programs' hooks or shell hooks, and update that sentence when step 2 is built.
4. GitHub through a fixed read-only `gh search` or through shell hooks only. Recommendation: the fixed command for the preset, since it cannot write to GitHub; shell hooks remain for anything else.
5. Private feed addresses that carry a token. Recommendation: public sources only in phase 1; add hook secrets in the Keychain (`arch.secrets.get`, service `xyz.taeyoon.arch.hooks.secrets`) as a later reusable part.
6. The agent pick's record floor. Recommendation: allow Keep Nothing and make it the default, since the run reads no page and changes only which items show.
7. The shortest interval. Recommendation: 15 minutes, which keeps a source well under common rate limits.
8. Placement. Recommendation: top level of the pinned list only in phase 1; inside pinned folders later if the user asks.
9. Deleting the folder or the hook. Recommendation: treat them as one unit, so neither remains without the other.
