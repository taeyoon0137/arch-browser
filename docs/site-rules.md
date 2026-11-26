# Site rules design

Status: the user accepted all decisions below on November 24, including the routing toast and Undo. Phase 1 is implemented for feature row 74 in `docs/features.md`. Production sync schema deployment and checks in the running app are pending.

A site rule opens a site's pages in a chosen "Persona / Space". A link to `mail.example.com` from another app then opens in "Work / Mail" with the Work Persona's cookies, regardless of where the user was when they clicked it. The rules in `docs/windows-personas.md` apply unless stated otherwise here: a tab's Persona is fixed when the tab is created (Persona rule 3), and the interface names a Persona as "Persona / Space" (Persona rule 7).

Terms: a "rule" is one row of the table; its "site" is a host with an optional path prefix; its "destination" is a space, which names its Persona. An "opening" is any action that creates a tab for an address.

## Principles

1. A rule decides where a new tab is created, before its first request. Loading a page before moving it sends the wrong Persona's cookies to the site, which rules must prevent.
2. Rules apply only to openings, never to navigation inside a tab. A tab keeps its Persona for life, and redirects, form posts, and sign-in flows stay in the tab that started them.
3. One small built-in table, matched synchronously on the main actor. No script, model, or network request runs to decide where a link opens.
4. Rules hold only hosts and path prefixes. They never name page titles, touch page content, or reach a provider.
5. The feature works the same on WebKit and Chromium: covered openings are decided by the session before an engine creates web contents, or by `EngineNavigationPolicy.openLinkInNewTab`, which both adapters already report.

## Which openings rules apply to

| Opening | Today | With a matching rule | Recommendation |
|---|---|---|---|
| A link from another app, an `open location` script, or a link that waited for launch (`AppDelegate.application(_:open:)`) | A small window in the last main window's space while Arch is in the background, otherwise a new tab in the sidebar target's current space | The tab is created in the destination: a small window whose tab belongs to the destination space, or a new tab there | Apply. This is the main case |
| A link the user opens in a new tab from a page: Command-click, middle-click, Command-Shift-click, and Open Link in New Tab in the page's context menu (`Tab.webContents(_:decidePolicyFor:)` returning `.openLinkInNewTab`, then `openNewTab`) | A new tab in the page's space and Persona, with the page as opener and referrer | Same Persona, other space: the engine's new web contents joins the destination space, keeping opener and referrer. The page context menu retains its existing fresh request without an engine referrer; its tab keeps the app-level opener. Other Persona: the policy returns `.cancel`, and the session opens the address in new web contents in the destination Persona, with no opener and no referrer | Apply |
| An address typed in the palette for a new tab (⌘T) or with no tab selected | A new tab in the window's current space | A new tab in the destination | Apply |
| An address typed over the current tab (⌘L, `CommandPaletteMode.editCurrent`) | The current tab navigates | The current tab stays unchanged, and a new tab opens in the destination. The palette's address row says "Opens in Work / Mail" in secondary text, and Option-Return opens it in the current tab instead | Apply, with the hint and the override |
| A link clicked without a modifier that opens a new tab (`target="_blank"`), and `window.open` | The engine creates the new web contents in the page's Persona, with an opener, so sign-in popups can report back (row 48) | Unchanged in phase 1 | Do not apply in phase 1. User clicks on `target="_blank"` links can follow in phase 2, when the engines report whether the new page would get an opener; that needs a new member on `EngineNavigationAction`, added only then |
| Same-tab navigation: link clicks, redirects, form posts, Back and Forward, and scripts' navigation | The tab navigates | Unchanged | Never apply (principle 2). Moving a tab to another Persona reloads it signed out, loses the form post's body, and would break sign-in flows that pass through another site |
| Favorites, pinned tabs, the Bookmarks menu, source folder items, restored tabs, synced pins, imports, and links dropped on the sidebar | Their own place | Unchanged | Never apply: each belongs to a place the user already chose |
| Previews (Shift-click), agent tabs, hook run tabs, plugins' and extensions' `tabs.create`, and `arch-cli` | Their own rules | Unchanged | Never apply. Agent tabs stay in their Persona and folder (`docs/agents.md`), and code never routes a tab across Personas |

A rule changes nothing if the opening is already in the destination space. When it changes the user’s context, the source window shows "Opened in Persona / Space" with Undo. When no main window is open, a routed small window shows the toast itself. The toast fades after a few seconds. Undo moves the tab to the original space and selects it, recreating it in the original Persona’s profile when necessary, without applying the rule again. Background openings show the same toast without switching windows or spaces.

## Matching

A rule's site is a host and an optional path prefix.

- Host: what the user types or the current tab's host, parsed using the rules of `AISitePattern(parsing:)` (lowercase, without brackets and trailing dots, a leading `*.` dropped). A host always covers its subdomains, so `example.com` matches `example.com`, `www.example.com`, and `mail.example.com`. IP addresses and `localhost` match only themselves. Ports are ignored.
- Path prefix: optional, such as `/work`. It matches that path and paths below it at segment boundaries, so `/work` matches `/work` and `/work/inbox` but not `/workshop`. Comparison is case-sensitive and excludes the query and fragment; storage omits the trailing slash. `/` and an empty prefix mean no prefix.
- Only `http` and `https` addresses match. Internal pages, `file` addresses, and other schemes never do.
- No wildcards inside a host and no regular expressions. Host plus subdomains plus one prefix covers the cases asked for: a whole site, one subdomain, and one area of a shared host. Patterns would complicate precedence and require a tester in the editor.

## Destination

- A destination is one space and its Persona. The editor offers every space except those in the Agents Persona, named "Persona / Space", or by the space's name alone with one Persona.
- Where it opens: "In Its Space" (default) or "In a New Window".
  - In Its Space: a main window on the destination space takes the tab and comes forward. Otherwise the sidebar target switches to the destination space, as a click on its symbol does, and takes it. A link the user opens in the background (Command-click without Shift) joins the destination space unselected and marked unread, and no window switches.
  - In a New Window: a new main window opens on the destination space with the tab selected. A background opening joins the space unselected as above.
- A link from another app while small windows are on (Settings ▸ General) opens in a small window whose tab belongs to the destination space, so Move to Main Window and Switch Persona start from there. The rule decides the place; the small window setting still decides the window.
- The new tab uses the default engine, as an opening from another app does today. A link opened from a page into the same Persona keeps the page's engine (row 48); one opened in another Persona uses the default engine.
- Across Personas the new tab has no opener and no referrer: the source page learns nothing about the tab it opened in another Persona.

## Precedence and conflicts

1. The most specific rule wins: the host with more labels first (`mail.example.com` over `example.com`), then the longer path prefix.
2. Two rules cannot share a host and prefix. The editor refuses the second and offers to change the first rule's destination instead, so no ordering is needed and the table has no drag handles.
3. There is no "open anywhere" rule. To exempt `docs.example.com` from an `example.com` rule, the user adds a rule for `docs.example.com` with its own destination.
4. Rules route an opening once and never route the tab's later navigation (principle 2), so they cannot chain or loop.

## When the destination is missing

| Case | Behavior |
|---|---|
| The destination space was deleted | The rule stays and opens in its Persona's preferred space (`preferredSpace(in:)`), so its sites keep that Persona's cookies. Settings marks the rule "Space deleted" with Choose Space… |
| The destination Persona was deleted | Its rules are deleted with it. The Delete Persona sheet says how many: "Its 3 site rules are deleted too." |
| The Persona has no profile this launch, as when an engine did not start | The tab opens in the destination with its address held in the stand-in already used by `makeWebContents`, and loads once a profile can. It never falls back to another Persona |
| A synced rule names a space or Persona this Mac does not have yet | The rule waits like records held out of sync (`docs/sync.md`, Schema versions), and applies when the space arrives |
| Every space is gone | Cannot happen: a Persona always keeps a space (sync decision 11) |

## Where rules are edited

- Settings ▸ Websites gains a group above the remembered permissions, Where Sites Open, with a table: Site (host and prefix, such as "example.com/work"), Opens In ("Work / Mail"), and Window (In Its Space or In a New Window). Add…, Edit…, and Remove act on the selection. The group is app-wide, so the Persona picker below it, which selects whose permissions appear, does not filter it. A footnote says "Links from other apps, links you open in new tabs, and addresses you type open here. Pages already open stay where they are."
- The address pill's site settings popover gains a group, Open This Site In, with a picker: Anywhere (no rule) and the destinations. Choosing one adds or changes the rule for the tab's host, without a prefix. When the tab is in another Persona / Space, the group's footnote offers Move This Tab, which uses Move to Space, and says the page loads signed out in another Persona. The rule never moves the tab by itself.
- The tab row's context menu and the Tab menu gain Always Open This Site In ▸, with the destinations listed as in Move to Space (`MoveToSpaceMenu`) and Anywhere, checked according to the matching rule. The palette gains "Always Open This Site In…" rows, one per destination.
- Placeholder: the user chooses the symbol for Where Sites Open; code uses an SF Symbol until then and adds no graphic asset.

## Storage

- `~/Library/Application Support/Arch/site-rules.json`, mode 0600: `{"version": 1, "rules": [{"id", "host", "pathPrefix", "spaceID", "personaID", "window": "space" | "newWindow", "modifiedAt"}]}`. The Persona is stored beside the space so a rule survives the space's deletion. A file from a later version is kept and not written.
- The file is not sealed. A program that can edit it can also edit `session.json`, and a rule only chooses which of the user's own Personas opens a site; it cannot read a page or send anything.

## Sync

- Accepted: rules sync with the sidebar while sync is on, as a new record type, and stay local while it is off.
  - `SiteRule`, named by the rule's UUID, with `host`, `pathPrefix`, and `window` in `encryptedValues`, so CloudKit encrypts them end to end as it does pinned tabs' addresses. `persona` and `space` are references, which CloudKit cannot encrypt and which contain no names.
  - Merge units: the site (`host` with `pathPrefix`) and the destination (`persona` with `space` and `window`), each by its edit time (sync decision 3). The first sync on a Mac joins rules with the same site within the same Persona (sync decision 4).
  - `SiteRule` is an additive record type in `schemaVersion` 4 (shared with other Macs' open tabs). Deploy it to the Production schema before a build writes it (`docs/sync.md`, Schema versions).
- Alternative: rules stay on each Mac, like remembered permissions. Rules resemble pinned tabs more than permissions: they name sites the user chose and spaces that already sync.

## Hooks or a built-in table

| | Built-in rules table | A hook (`docs/hooks.md`) |
|---|---|---|
| When it decides | Before the tab exists, synchronously | After `tabOpened` or `pageLoaded`, through the shared scheduler, on a later turn |
| Cookies | The first request goes from the right Persona | The page loads first in the wrong Persona, then moves and loads again signed out |
| Cost per opening | A lookup in a short list | A script run in the plugin sandbox, with its limits, run log, and daily count |
| Failure | None beyond a missing destination | Paused hooks, Run Hooks off, timeouts, and loop protection all leave links unrouted |
| Editing | A Settings table and Always Open This Site In ▸ | The hook editor, a filter, and a script |
| Sync | Can sync, end to end encrypted | Hooks never sync (hook decision 8) |
| Flexibility | Host, subdomains, and one path prefix | Any logic, including an agent |

Accepted: the built-in table. Hooks cannot meet principle 1 because they see a tab only after it exists. A synchronous decision hook would put a script runtime and a timeout in front of every link.

Hooks may still extend it:

- A routed tab posts `tabOpened` in its destination space as any new tab does, so hooks scoped to that "Persona / Space" see it without a new kind or cause.
- Later, when a feature needs it: a hook permission `siteRules` with `arch.siteRules.list()` and `arch.siteRules.propose(rule)`. A proposal shows a sheet in Arch, and only the user choosing Add makes it a rule. For example, an agent hook could notice that the user keeps moving one site's tabs to Work and suggest a rule. Hooks from outside programs never get this permission.

## Privacy

- Rules hold hosts, optional path prefixes, and space identifiers: no titles, queries, fragments, or page content. The editor refuses an address with user information and keeps only the host and prefix of a pasted address.
- They stay on the Mac in `site-rules.json`, and reach iCloud only with sync on, encrypted end to end (Sync).
- No rule, match, or routing decision goes to a provider, a hook without that future permission, `arch-cli`, `arch-mcp`, or a log. The tab close log and the run log record nothing about rules.
- Across Personas a routed tab has no opener and no referrer (Destination), so the opening page cannot follow the user into the other Persona.

## Module layout

- `Browsing`: `SiteRule` and `SiteRuleSet` (matching and precedence, pure and synchronous), `SiteRuleStore` (`site-rules.json`), and `BrowserSession.destination(forOpening:url:)`, which the four covered openings call: `AppDelegate.application(_:open:)` through `openTab` and `openSmallWindow`, `Tab.openNewTab` with `.openLinkInNewTab`, and `BrowserWindowModel.submitCommandPalette`.
- `Preferences`: the Where Sites Open group in Settings ▸ Websites.
- `Sync`: the `SiteRule` record mapping, in the sync step.
- No engine protocol member, bridge change, or private API in phase 1.

## Tests

- `BrowsingTests` (`SiteRuleSetTests`): host and subdomain matching, IP addresses and `localhost` matching only themselves, ports ignored, prefixes at segment boundaries (`/work` against `/work`, `/work/`, `/work/inbox`, and `/workshop`), case-sensitive paths, query and fragment ignored, non-web schemes refused, specificity by labels then prefix length, and duplicate sites refused.
- `BrowsingTests` (`SiteRuleRoutingTests`, on fake web contents): a link from another app opening in the destination space as a tab and, in the background, as a small window of that space; a Command-click into the same Persona keeping opener and referrer; one into another Persona cancelling the engine's policy and opening new web contents in that Persona without an opener; a background opening leaving every window's space unchanged; In a New Window; typed addresses in both palette modes, with Option-Return navigating the current tab; `target="_blank"`, `window.open`, same-tab navigation, redirects, favorites, pinned tabs, previews, agent tabs, and plugins' tabs never routed; an opening already in the destination unchanged.
- `BrowsingTests` (`SiteRuleRoutingTests`): routing toast only for a different context, background toast without switching, Undo returning and selecting the tab in its original space, cross-Persona Undo recreating its original profile, and expired or closed-tab Undo doing nothing.
- `BrowsingTests` (`SiteRuleStoreTests`): reading and writing the file with mode 0600, preserving a later version without writing to it, a deleted space falling back to the Persona's preferred space and marked, a deleted Persona deleting its rules, a Persona without a profile getting the stand-in.
- `PreferencesTests`: the table's rows named "Persona / Space", or by space alone with one Persona, the duplicate refusal offering to edit the first rule, and the popover's picker adding, changing, and removing the tab host's rule.
- `SyncTests`: the `SiteRule` record with its encrypted fields and plain references, the two merge units, the first-sync join, and a rule held until its space arrives.
- Bundle checks, added to the regression checklist in `docs/plan.md` as each step is built: a link from Terminal (`open https://…`) and from Mail with Arch in front and in the background on both engines; a Command-click into another Persona that loads signed out there while the source tab keeps its sign-in; Always Open This Site In ▸ and Move This Tab.

## Build order

1. `SiteRule`, `SiteRuleSet`, and `SiteRuleStore`, with `SiteRuleSetTests` and `SiteRuleStoreTests`.
2. Routing of links from other apps and typed addresses, with the palette's hint and Option-Return.
3. Routing of links opened in new tabs from a page, across spaces and Personas.
4. Settings ▸ Websites ▸ Where Sites Open, the popover group, and Always Open This Site In ▸ in the menus and the palette.
5. Sync of `SiteRule` records is built. Deploy the Production schema before a build writes these records (a user step).
6. Later, on request: `target="_blank"` clicks with the engine member, and the `siteRules` hook permission.

## Accepted decisions

1. Which openings rules apply to. Links from other apps, links opened in new tabs from a page, and typed addresses, never same-tab navigation, favorites, pinned tabs, agents, or code.
2. A typed address over the current tab. Open it in a new tab in the destination, with the palette's hint and Option-Return to stay in the current tab.
3. `target="_blank"` links and `window.open`. Unchanged in phase 1; user clicks on `target="_blank"` links later, once the engines report the opener, and `window.open` never, since sign-in popups need their opener.
4. Matching. Host with its subdomains plus one optional path prefix; no wildcards or regular expressions.
5. Precedence. Most specific wins (host labels, then prefix length), with duplicate sites refused, so the table needs no order.
6. Destination. One "Persona / Space", with In Its Space (default) or In a New Window; no "any space of a Persona" in phase 1.
7. Background openings. A Command-click joins the destination space unselected and unread, and no window switches.
8. A deleted destination space. Keep the rule, open in its Persona's preferred space, and mark it in Settings; delete rules with their Persona.
9. Where rules are edited. A Where Sites Open group in Settings ▸ Websites, Open This Site In in the site settings popover, and Always Open This Site In ▸ in the tab menus and the palette; choosing a rule never moves an open tab automatically.
10. Sync. Sync rules with the sidebar as end-to-end encrypted `SiteRule` records while sync is on; local otherwise.
11. Hooks or a built-in table. The built-in table, since only it decides before the first request; hooks see routed tabs through `tabOpened` now and may propose rules through a `siteRules` permission later.

12. Routing feedback and Undo. When a rule opens a tab outside the user’s current space or Persona, show a toast in the source window, such as "Opened in Work / Mail", with Undo. A background Command-click shows the toast without switching windows or spaces. Openings that stay in the current space show no toast. When no main window is open, a routed small window shows the toast itself. The toast fades after a few seconds. Undo returns the tab to the space the user was browsing and selects it; across Personas it recreates the tab in the original Persona’s profile through the existing tab-move behavior. Undo does not run the rule again.
