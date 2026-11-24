# Site rules design

Status: design awaiting the user's approval (queue row IV.28 in `docs/plan.md`, feature row 74 in `docs/features.md`). Nothing here is built. After approval, implementation rows replace IV.28.

A site rule says that pages of a site open in a chosen "Persona / Space". A link to `mail.example.com` from another app then opens in "Work / Mail" with the Work Persona's cookies, wherever the user was when they clicked it. The rules in `docs/windows-personas.md` apply unless this note says otherwise: a tab's Persona is fixed when the tab is created (Persona rule 3), and the interface names a Persona as "Persona / Space" (Persona rule 7).

Terms: a "rule" is one row of the table; its "site" is a host with an optional path prefix; its "destination" is a space, which names its Persona. An "opening" is any action that creates a tab for an address.

## Principles

1. A rule decides where a new tab is created, before its first request. A page that loads first and moves afterwards has already sent the wrong Persona's cookies to the site. That is what a rule exists to prevent.
2. Rules apply only to openings, never to navigation inside a tab. A tab keeps its Persona for life, and redirects, form posts, and sign-in flows stay in the tab that started them.
3. One small built-in table, matched synchronously on the main actor. No script, model, or network request runs to decide where a link opens.
4. Rules never name a page title, never touch page content, and never reach a provider. They hold hosts and path prefixes only.
5. The feature works the same on WebKit and Chromium: every opening it covers is decided by the session before an engine creates web contents, or by `EngineNavigationPolicy.openLinkInNewTab`, which both adapters already report.

## Which openings rules apply to

| Opening | Today | With a matching rule | Recommendation |
|---|---|---|---|
| A link from another app, an `open location` script, or a link that waited for launch (`AppDelegate.application(_:open:)`) | A small window in the last main window's space while Arch is in the background, otherwise a new tab in the sidebar target's current space | The tab is created in the destination: a small window whose tab belongs to the destination space, or a new tab there | Apply. This is the main case |
| A link the user opens in a new tab from a page: Command-click, middle-click, Command-Shift-click, and Open Link in New Tab in the page's context menu (`Tab.webContents(_:decidePolicyFor:)` returning `.openLinkInNewTab`, then `openNewTab`) | A new tab in the page's space and Persona, with the page as opener and referrer | Same Persona, other space: the engine's new web contents joins the destination space, keeping opener and referrer. Other Persona: the policy returns `.cancel`, and the session opens the address in a new web contents of the destination Persona, with no opener and no referrer | Apply |
| An address typed in the palette for a new tab (⌘T) or with no tab selected | A new tab in the window's current space | A new tab in the destination | Apply |
| An address typed over the current tab (⌘L, `CommandPaletteMode.editCurrent`) | The current tab navigates | The current tab stays as it is, and a new tab opens in the destination. The palette's address row says "Opens in Work / Mail" in secondary text, and Option-Return opens it in the current tab instead | Apply, with the hint and the override |
| A link clicked without a modifier that opens a new tab (`target="_blank"`), and `window.open` | The engine creates the new web contents in the page's Persona, with an opener, so sign-in popups can report back (row 48) | Unchanged in phase 1 | Do not apply in phase 1. A user click on a `target="_blank"` link can follow in phase 2, when the engines report whether the new page would get an opener; that needs a new member on `EngineNavigationAction`, added only then |
| Same-tab navigation: link clicks, redirects, form posts, Back and Forward, and scripts' navigation | The tab navigates | Unchanged | Never apply (principle 2). Moving a tab to another Persona reloads it signed out, loses the form post's body, and would break sign-in flows that pass through another site |
| Favorites, pinned tabs, the Bookmarks menu, source folder items, restored tabs, synced pins, imports, and links dropped on the sidebar | Their own place | Unchanged | Never apply: each belongs to a place the user already chose |
| Previews (Shift-click), agent tabs, hook run tabs, plugins' and extensions' `tabs.create`, and `arch-cli` | Their own rules | Unchanged | Never apply. Agent tabs stay in their Persona and folder (`docs/agents.md`), and code never routes a tab across Personas |

When the opening is already in the destination space, a rule changes nothing.

## Matching

A rule's site is a host and an optional path prefix.

- Host: what the user types or the current tab's host, read as `AISitePattern(parsing:)` reads it (lowercase, without brackets and trailing dots, a leading `*.` dropped). A host always covers its subdomains, so `example.com` matches `example.com`, `www.example.com`, and `mail.example.com`. IP addresses and `localhost` match only themselves. Ports are ignored.
- Path prefix: optional, such as `/work`. It matches the path itself and every path below it at a segment boundary, so `/work` matches `/work` and `/work/inbox` but not `/workshop`. It is compared case-sensitively, without the query and fragment, and stored without a trailing slash. `/` and an empty prefix mean no prefix.
- Only `http` and `https` addresses match. Internal pages, `file` addresses, and other schemes never do.
- No wildcards inside a host and no regular expressions. Host plus subdomains plus one prefix covers the cases asked for: a whole site, one subdomain, and one area of a shared host. Patterns would make precedence hard to explain, and the editor would need a tester.

## Destination

- A destination is one space, and so one Persona. The editor offers every space of every Persona but the Agents Persona, named "Persona / Space", or by the space's name alone with one Persona.
- Where it opens: "In Its Space" (default) or "In a New Window".
  - In Its Space: a main window whose current space is the destination takes the tab and comes forward. Otherwise the sidebar target switches to the destination space, as a click on its symbol does, and takes it. A link the user opens in the background (Command-click without Shift) joins the destination space unselected and marked unread, and no window switches.
  - In a New Window: a new main window opens on the destination space with the tab selected. A background opening joins the space unselected as above.
- A link from another app while small windows are on (Settings ▸ General) opens in a small window whose tab belongs to the destination space, so Move to Main Window and Switch Persona start from there. The rule decides the place; the small window setting still decides the window.
- The new tab uses the default engine, as an opening from another app does today. A link opened from a page into the same Persona keeps the page's engine (row 48); one opened into another Persona uses the default engine.
- Across Personas the new tab has no opener and no referrer: the page of one Persona learns nothing about the tab it caused in another.

## Precedence and conflicts

1. The most specific rule wins: the host with more labels first (`mail.example.com` over `example.com`), then the longer path prefix.
2. Two rules with the same host and the same prefix cannot exist. The editor refuses the second and offers to change the first rule's destination instead, so no ordering is needed and the table has no drag handles.
3. There is no "open anywhere" rule. To exempt `docs.example.com` from an `example.com` rule, the user adds a rule for `docs.example.com` with its own destination.
4. Rules do not chain. An opening is routed once, and the routed tab's later navigation is not routed (principle 2), so no rule can loop.

## When the destination is missing

| Case | Behavior |
|---|---|
| The destination space was deleted | The rule stays and opens in its Persona's preferred space (`preferredSpace(in:)`), so its sites keep that Persona's cookies. Settings marks the rule "Space deleted" with Choose Space… |
| The destination Persona was deleted | Its rules are deleted with it. The Delete Persona sheet says how many: "Its 3 site rules are deleted too." |
| The Persona has no profile this launch, as when an engine did not start | The tab opens in the destination with its address held in the stand-in `makeWebContents` already uses, and loads once a profile can. It never falls back to another Persona |
| A synced rule names a space or Persona this Mac does not have yet | The rule waits, as records held out of sync do (`docs/sync.md`, Schema versions), and applies when the space arrives |
| Every space is gone | Cannot happen: a Persona always keeps a space (sync decision 11) |

## Where rules are edited

- Settings ▸ Websites gains a group above the remembered permissions, Where Sites Open, with a table: Site (host and prefix, such as "example.com/work"), Opens In ("Work / Mail"), and Window (In Its Space or In a New Window). Add…, Edit…, and Remove act on the selection. The group is app-wide, so the Persona picker below it, which picks whose permissions show, does not filter it. A footnote says "Links from other apps, links you open in new tabs, and addresses you type open here. Pages already open stay where they are."
- The site settings popover of the address pill gains a group, Open This Site In, with a picker: Anywhere (no rule) and the destinations. Choosing one adds or changes the rule for the tab's host, without a prefix. When the tab is in another Persona / Space, the group's footnote then offers Move This Tab, which uses Move to Space, and says that in another Persona the page loads signed out. The rule never moves the tab by itself.
- The tab row's context menu and the Tab menu gain Always Open This Site In ▸, with the destinations as Move to Space lists them (`MoveToSpaceMenu`) and Anywhere, checked by the rule that matches. The palette gains "Always Open This Site In…" rows, one per destination.
- Placeholder: the user chooses the symbol of Where Sites Open; code uses an SF Symbol until then and adds no graphic asset.

## Storage

- `~/Library/Application Support/Arch/site-rules.json`, mode 0600: `{"version": 1, "rules": [{"id", "host", "pathPrefix", "spaceID", "personaID", "window": "space" | "newWindow", "modifiedAt"}]}`. The Persona is stored beside the space so a rule survives the space's deletion. A file from a later version is kept and not written.
- The file is not sealed. A program that can edit it can also edit `session.json`, and a rule only chooses which of the user's own Personas opens a site; it cannot read a page or send anything.

## Sync

- Recommendation: rules sync with the sidebar while sync is on, as a new record type, and stay local while it is off.
  - `SiteRule`, record name the rule's UUID, with `host`, `pathPrefix`, and `window` in `encryptedValues`, so CloudKit encrypts them end to end as it does pinned tabs' addresses. `persona` and `space` are references, which CloudKit cannot encrypt and which name nothing.
  - Merge units: the site (`host` with `pathPrefix`) and the destination (`persona` with `space` and `window`), each by its edit time (sync decision 3). The first sync on a Mac joins rules with the same site within the same Persona (sync decision 4).
  - A new record type is additive: `schemaVersion` 3, deployed to the Production schema before a build writes it (`docs/sync.md`, Schema versions).
- Alternative: rules stay on each Mac, like remembered permissions. Rules are closer to pinned tabs than to permissions: they name sites the user chose and spaces that already sync.

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

Recommendation: the built-in table. The hook path cannot meet principle 1, because hooks see a tab only after it exists. A synchronous decision hook would put a script runtime and a timeout in front of every link.

Hooks may still extend it:

- A routed tab posts `tabOpened` in its destination space as any new tab does, so hooks scoped to that "Persona / Space" see it with no new kind or cause.
- Later, when a feature needs it: a hook permission `siteRules` with `arch.siteRules.list()` and `arch.siteRules.propose(rule)`. A proposal shows a sheet in Arch, and only the user's Add makes it a rule. For example, an agent hook could notice that the user keeps moving one site's tabs to Work and suggest a rule. Hooks from outside programs never get it.

## Privacy

- Rules hold hosts, optional path prefixes, and space identifiers: no titles, queries, fragments, or page content. The editor refuses an address with user information and keeps only the host and prefix of a pasted address.
- They stay on the Mac in `site-rules.json`, and reach iCloud only with sync on, encrypted end to end (Sync).
- No rule, match, or routing decision goes to a provider, a hook without the future permission, `arch-cli`, `arch-mcp`, or a log. The tab close log and the run log record nothing about rules.
- Across Personas a routed tab has no opener and no referrer (Destination), so the opening page cannot follow the user into the other Persona.

## Module layout

- `Browsing`: `SiteRule` and `SiteRuleSet` (matching and precedence, pure and synchronous), `SiteRuleStore` (`site-rules.json`), and `BrowserSession.destination(forOpening:url:)`, which the four covered openings call: `AppDelegate.application(_:open:)` through `openTab` and `openSmallWindow`, `Tab.openNewTab` with `.openLinkInNewTab`, and `BrowserWindowModel.submitCommandPalette`.
- `Preferences`: the Where Sites Open group in Settings ▸ Websites.
- `Sync`: the `SiteRule` record mapping, in the sync step.
- No engine protocol member, bridge change, or private API in phase 1.

## Tests

- `BrowsingTests` (`SiteRuleSetTests`): host and subdomain matching, IP addresses and `localhost` matching only themselves, ports ignored, prefixes at segment boundaries (`/work` against `/work`, `/work/`, `/work/inbox`, and `/workshop`), case-sensitive paths, query and fragment ignored, non-web schemes refused, specificity by labels then prefix length, and duplicate sites refused.
- `BrowsingTests` (`SiteRuleRoutingTests`, on fake web contents): a link from another app opening in the destination space as a tab and, in the background, as a small window of that space; a Command-click into the same Persona keeping opener and referrer; one into another Persona cancelling the engine's policy and opening a new web contents of that Persona without opener; a background opening leaving every window's space unchanged; In a New Window; typed addresses in both palette modes, with Option-Return navigating the current tab; `target="_blank"`, `window.open`, same-tab navigation, redirects, favorites, pinned tabs, previews, agent tabs, and plugins' tabs never routed; an opening already in the destination unchanged.
- `BrowsingTests` (`SiteRuleStoreTests`): the file read and written with mode 0600, a later version kept unwritten, a deleted space falling back to the Persona's preferred space and marked, a deleted Persona deleting its rules, a Persona without a profile getting the stand-in.
- `PreferencesTests`: the table's rows named "Persona / Space", or by space alone with one Persona, the duplicate refusal offering to edit the first rule, and the popover's picker adding, changing, and removing the tab host's rule.
- `SyncTests`: the `SiteRule` record with its encrypted fields and plain references, the two merge units, the first-sync join, and a rule held until its space arrives.
- Checks from the bundle, added to the regression checklist in `docs/plan.md` as each step is built: a link from Terminal (`open https://…`) and from Mail with Arch in front and in the background on both engines; a Command-click into another Persona that loads signed out there while the source tab keeps its sign-in; Always Open This Site In ▸ and Move This Tab.

## Build order after approval

1. `SiteRule`, `SiteRuleSet`, and `SiteRuleStore`, with `SiteRuleSetTests` and `SiteRuleStoreTests`.
2. Routing of links from other apps and typed addresses, with the palette's hint and Option-Return.
3. Routing of links opened in new tabs from a page, across spaces and Personas.
4. Settings ▸ Websites ▸ Where Sites Open, the popover group, and Always Open This Site In ▸ in the menus and the palette.
5. Sync of `SiteRule` records, after the Production schema is deployed (a user step).
6. Later, each when asked: `target="_blank"` clicks with the engine member, and the `siteRules` hook permission.

## Open decisions

1. Which openings rules apply to. Recommendation: links from other apps, links opened in new tabs from a page, and typed addresses, never same-tab navigation, favorites, pinned tabs, agents, or code.
2. A typed address over the current tab. Recommendation: open it in a new tab in the destination, with the palette's hint and Option-Return to stay in the current tab.
3. `target="_blank"` links and `window.open`. Recommendation: unchanged in phase 1; user clicks on `target="_blank"` links later, once the engines report the opener, and `window.open` never, since sign-in popups need their opener.
4. Matching. Recommendation: host with its subdomains plus one optional path prefix; no wildcards or regular expressions.
5. Precedence. Recommendation: most specific wins (host labels, then prefix length), with duplicate sites refused, so the table needs no order.
6. Destination. Recommendation: one "Persona / Space", with In Its Space (default) or In a New Window; no "any space of a Persona" in phase 1.
7. Background openings. Recommendation: a Command-click joins the destination space unselected and unread, and no window switches.
8. A deleted destination space. Recommendation: keep the rule, open in its Persona's preferred space, and mark it in Settings; delete rules with their Persona.
9. Where rules are edited. Recommendation: a Where Sites Open group in Settings ▸ Websites, Open This Site In in the site settings popover, and Always Open This Site In ▸ in the tab menus and the palette; choosing a rule never moves an open tab by itself.
10. Sync. Recommendation: sync rules with the sidebar as end-to-end encrypted `SiteRule` records while sync is on; local otherwise.
11. Hooks or a built-in table. Recommendation: the built-in table, since only it decides before the first request; hooks see routed tabs through `tabOpened` now and may propose rules through a `siteRules` permission later.
