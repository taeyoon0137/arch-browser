# Hooks design

This note designs hooks for Arch, feature rows 64 to 68. A hook runs a script when a browser event matches it, and the script can run an agent. Each part has one job, one interface, and its own tests, so a later feature can use one part without the others: browser events, model tiers, the hook registry, the script runner, the agent run API, the agent hook editor with the Tidy Tab Names preset, and the same parts for outside programs. Nothing here is built; tasks VII.23 to VII.32 in `docs/plan.md` build it. The design builds on the AI interface (`docs/ai.md`), the plugin system (`docs/plugins.md`), and agents (`docs/agents.md`), whose rules apply unless this note says otherwise.

Terms: an "event" is a `BrowserEvent` delivered by the browser event bus. A "hook" is a trigger, a filter, and a script that Arch runs for each matching event. A "run" is one script handling one event. An "agent run" is one call of the agent run API: a prompt with a model choice, a record level, tools, and limits, run to completion without the user. An "agent hook" is a hook whose script the agent hook editor writes around one agent run.

## Purpose and principles

- One source of browser events serves every consumer: the AI hook center, hooks, plugins, and outside programs. Events carry identifiers, kinds, engines, reasons, and addresses, never page text, titles, or file paths (hook decision 2).
- A hook's action is always a script. A script that needs AI calls the agent run API. The agent hook editor writes an ordinary hook and its script, which the user can open and change, so agent hooks need no separate machinery (hook decision 3).
- One agent run API serves hook scripts, Arch's own interface, and `arch-cli`. Each run names its model or tier, what Arch keeps, the tools it may call, and its limits; for a hook the user sets these once in the editor.
- Automatic runs are unattended, so a run never asks: a step that needs the user's approval is refused (hook decision 5).
- Arch stays local. Hooks add no server, port, launchd job, or process that outlives Arch. Outside programs reach events and hooks through the agents' control channel under its grants (agent decision 1). AI goes only through the AI interface, subscriptions only through the CLIs that Arch runs (agent decision 3), keys stay in the Keychain, and run logs stay on the Mac without content. Arch collects no telemetry.
- Events, scripts, and agent runs work alike on WebKit and Chromium tabs: events come from `Tab` and the session, which both adapters feed; scripts run in Arch's own sandbox regardless of the tab's engine; and agent runs act through the tool host.
- Public APIs only: WebKit for the script sandbox, `posix_spawn` for shell scripts, Security and CryptoKit for the seal and digests, LocalAuthentication for trust and outside approvals. Nothing here needs a private API flag.
- Add kinds, permissions, tools, and methods only when a feature needs them, as with the engine protocols and the AI interface.

## Parts

| Part | Module | One job | Interface | Used by | Task |
|---|---|---|---|---|---|
| Browser events | `Events` (new) | Turns session changes into typed events and delivers them | `BrowserEventBus`, `BrowserEvent`, `BrowserEventFilter`, `BrowserEvent.view(_:)` | The AI hook center through `BrowserHooks`, the hook registry, plugins' events, outside subscribers | VII.23 |
| Model tiers | `AI` | Names models by tier (Fast, Standard, Deep) and lets a request carry its route | `AIModelTier`, `AIRouteChoice`, `AIFeatureRouting` | Agent runs, `arch-cli agent run`, the agent composer's model menu | VII.24 |
| Hook registry | `Hooks` (new) | Keeps hooks and matches events to them; runs their scripts in order with debounce, limits, loop protection, and pausing; logs runs | `HookRegistry`, `Hook`, `HookStore`, `HookRunLog` | Settings ▸ AI ▸ Agent Hooks, the editor, `arch-cli hooks` | VII.25 |
| Script runner | `Hooks`, on `Plugins`' script runtime | Runs one script for one event: JavaScript in the script plugin sandbox, or a shell script the user trusts | `HookScriptRunning`, the script API | The hook registry | VII.26, VII.31 |
| Agent run API | `Agent` | Runs one agent to completion for a caller, with a model choice, a record level, tools, and limits | `AgentRunner.run(_:)`, `arch.agent.run`, `agent/run`, `arch-cli agent run` | Hook scripts, the editor's Test, outside programs | VII.27 |
| Agent hook editor | `Preferences`, `Hooks` | Writes an agent hook: its situation, instructions, model, record, actions, limits, and script | Settings ▸ AI ▸ Agent Hooks, `AgentHookTemplate` | The user | VII.28 |
| Tidy Tab Names | `Hooks` | A preset agent hook | `HookPresets.tidyTabNames` | The editor | VII.29 |
| Outside programs | `AgentControl`, `ArchCLI`, `Agent`, `Hooks` | Events, hooks, agent runs, and renames for `arch-cli` and `arch-mcp` under grants | `events/*`, `hooks/*`, `agent/run`; the tools `watch_events` and `rename_tab`; `AgentHookRegistrar` | Scripts and agents outside Arch | VII.30 |

```
Browsing: BrowserEventSource ──post──▶ BrowserEventBus (Events)
   ├─▶ BrowserHooks ──AIHookEvent──▶ AIHookCenter (AI): Tab Names, Download Names
   ├─▶ PluginManager ──PluginEvent──▶ script plugins' arch.events.on
   ├─▶ HookRegistry (Hooks) ──▶ JavaScript in the plugin sandbox, or a trusted shell script
   │                               └─▶ arch.agent.run, or arch-cli agent run ──▶ AgentRunner (Agent)
   └─▶ AgentService (Agent) ──events/event──▶ arch-cli events; watch_events ──▶ arch-mcp
AgentRunner ──▶ AIService (AI: tiers, routes, budgets, usage)
   ├─▶ API-key tool loop (VII.19) ──▶ AgentToolHost
   └─▶ AIAgentSession on claude or codex (VII.16, VII.17) ──▶ arch-mcp --session ──▶ AgentToolHost
```

`Package.swift` additions, by hand:

```swift
.library(name: "Events", targets: ["Events"]),
.library(name: "Hooks", targets: ["Hooks"]),

.target(name: "Events", dependencies: ["ARCHEngine", "AI"], path: "Packages/ARCH/Sources/Events"),
.target(name: "Hooks", dependencies: ["Events", "AI", "Plugins", "Agent"], path: "Packages/ARCH/Sources/Hooks"),
.testTarget(name: "EventsTests", dependencies: ["Events"], path: "Packages/ARCH/Tests/EventsTests"),
// `Fixtures` holds the hook scripts and shell scripts the runner tests run.
.testTarget(name: "HooksTests", dependencies: ["Hooks"], path: "Packages/ARCH/Tests/HooksTests", resources: [.copy("Fixtures")]),
```

- `Plugins` and `Agent` add `Events`; `Browsing`, `Preferences`, and `Arch` add `Events` and `Hooks`. `AI` gains no dependency, and `ArchCLI` still depends on `AgentControl` alone: it prints events, hooks, and run results as JSON from Arch, as it does for tool results.
- The parts are separate modules because they serve different users: `Agent` and `Plugins` both need events and cannot depend on `Hooks`, which depends on both; the AI interface stays free of browser types.

## Decisions

Code comments and documents cite these as "hook decision 1" and so on.

1. One event bus. `BrowserEventBus` in the new `Events` module delivers every browser event, and `Browsing` posts them from one place, `BrowserEventSource`. The AI hook center keeps its `AIHookEvent`, which `BrowserHooks` makes from bus events, so `AI` keeps no dependencies and its hook tests stay unchanged. `Events` depends on `AI` only for `AISitePattern`, so site filters and site exclusions share one matcher, and on `ARCHEngine` for `EngineKind`.
2. Events carry no page content: identifiers, kinds, engines, reasons, and addresses only. A title or page text reaches a consumer only through a call its grant allows.
3. A hook's action is always a script. An agent hook is a hook whose script the editor writes; within a hook, only a script's call to the agent run API runs an agent.
4. Scripts are JavaScript in the script plugin sandbox by default. A shell script runs only after the user turns on Allow Shell Scripts and trusts the file with Touch ID or the login password. Arch then runs its own copy, checked by digest. Arch never writes, generates, or edits a shell script, and outside programs cannot add one.
5. Agent runs never ask the user. A call that would ask under agents' rules is refused with `wouldAsk`. A run works only on the tabs its caller gives it and calls only the tools its options name within its grant.
6. A run names a model or a tier (Fast, Standard, Deep) whose models the user assigns once in Settings ▸ AI ▸ Model Tiers. Tiers are routes in `ai.json`. An empty tier fails rather than falling back to another tier or the default route, since the user chose the tier for its cost.
7. Three record levels: Keep the Session, Keep Activity Only, and Keep Nothing (Record levels). No level writes a prompt, reply, title, page text, or address path to disk; Keep Nothing keeps only usage counters.
8. `hooks.json` is sealed like `agent.json`, with its own Keychain key, and holds each script's digest. A program that edits Arch's files therefore cannot add a hook or change one's script. A hook script can read signed-in pages through agent runs and write tab names, which `session.json` keeps. Allowing a program to add a hook by editing the file would let it read the user's signed-in pages through Arch.
9. Loop protection by causes: every event caused by code names the hooks whose runs led to it. A hook never runs for its own runs' effects, and no hook runs for an event three hooks deep. Rate limits pause a hook that still runs too often.
10. Outside programs may watch events under a grant scope and propose hooks. Each proposed hook takes effect only after the user allows it in Arch with Touch ID or the login password. This is the one exception to agents' rule that no command changes Arch's settings (`docs/agents.md`, What the agent can never change). The only other hook change a client can make is removing its own hooks.
11. `arch-mcp` offers events as a tool, `watch_events`, not as MCP notifications, because MCP clients do not pass a server's notifications to their model. It offers no hook tool or agent run tool, so a model steered by a page can neither add lasting automation nor start agents.
12. Tidy Tab Names runs on a new tab's first page load, not when the tab opens, since it has no title then and often no address.
13. Renames from code (AI hooks, plugins, hook scripts, and agents) set the tab's suggested name under the AI hooks' `renameTab` rules (`docs/ai.md`, Actions). The user's own name always wins, and a name the user rejects stays rejected for that address.
14. Site exclusions are an AI boundary. They keep events from hooks with the `agent` permission and from outside programs, and the agent run API refuses tabs on excluded sites (rule P16). A hook without `agent`, which cannot reach a model, runs on every site its filter covers, as plugins do.

## Browser events

### Kinds and payloads

```swift
// Events
public enum BrowserEventKind: String, Codable, Hashable, Sendable, CaseIterable {
    case tabOpened, tabClosed, pageLoaded, addressChanged, titleChanged, tabSelected, downloadFinished, spaceSwitched
}

public enum BrowserTabKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// A space's tab outside its pinned list.
    case open
    case pinned
    /// A favorite's tab, which belongs to no space.
    case favorite
    case smallWindow
    /// A tab in an agent folder (`docs/agents.md`, Agent folders). Hooks and the AI hook center never see these.
    case agent
}

public struct BrowserTabRef: Codable, Hashable, Sendable {
    public var id: UUID
    public var personaID: UUID
    /// nil for a favorite's tab.
    public var spaceID: UUID?
    public var kind: BrowserTabKind
    public var engine: EngineKind
    /// The committed address; nil until the engine reports one.
    public var url: URL?
}

public struct BrowserDownloadRef: Codable, Hashable, Sendable {
    public var id: UUID
    public var personaID: UUID
    /// The tab the download started from, while that tab is open.
    public var tabID: UUID?
    /// The file's name, which the server or the page chose; never its folder or contents.
    public var filename: String
    public var mediaType: String?
    public var byteCount: Int64?
    public var sourceURL: URL?
    public var pageURL: URL?
    /// The user chose the name in a save panel.
    public var isNamedByUser: Bool
}

public enum BrowserTabCloseReason: String, Codable, Hashable, Sendable {
    /// `TabCloseReason`'s cases, then closes by code and with a deleted space or Persona.
    case user, page, crash, archive, download, webExtension, plugin, hook, agent, spaceDeleted
}

public enum BrowserTitleSource: String, Codable, Hashable, Sendable {
    /// The page's own title.
    case page
    /// The user named the tab or cleared its name (`Tab.customTitle`).
    case user
    /// A hook, plugin, or agent named the tab (`Tab.suggestedTitle`).
    case suggested
}

public enum BrowserEventPayload: Codable, Sendable {
    case tabOpened(BrowserTabRef, openerTabID: UUID?)
    case tabClosed(BrowserTabRef, reason: BrowserTabCloseReason)
    /// `isFirstLoadAfterOpen`: the tab's first load with an `http` or `https` address since this launch's `tabOpened` for it.
    case pageLoaded(BrowserTabRef, isRestore: Bool, isFirstLoadAfterOpen: Bool)
    case addressChanged(BrowserTabRef, previousURL: URL?)
    case titleChanged(BrowserTabRef, source: BrowserTitleSource)
    case tabSelected(BrowserTabRef, windowID: UUID)
    case downloadFinished(BrowserDownloadRef)
    case spaceSwitched(windowID: UUID, spaceID: UUID, personaID: UUID, previousSpaceID: UUID?, previousPersonaID: UUID?)
}

public struct BrowserEvent: Identifiable, Codable, Sendable {
    public var id: UUID
    /// One more than the previous event's in this launch; outside programs resume after it.
    public var sequence: UInt64
    public var date: Date
    public var payload: BrowserEventPayload
    /// What made the change, when code made it (Causes).
    public var cause: BrowserEventCause?

    public var kind: BrowserEventKind { get }
    /// The tab, download, or window the event is about.
    public var subject: UUID { get }
    public var personaID: UUID { get }
    /// The addresses that site filters and exclusions apply to: the tab's, or the download's source and page.
    public var urls: [URL] { get }
}
```

| Kind | Posted when | Subject | Posts nothing for |
|---|---|---|---|
| `tabOpened` | A tab joins the session after launch, from any source: the palette, a link, a page, another app, a favorite's first opening, a plugin, an agent, or a hook | Tab | Tabs restored from the saved session, pinned tabs that a browser import opened, tabs that move between spaces or windows |
| `tabClosed` | A tab leaves the session | Tab | Tabs at quit |
| `pageLoaded` | The tab's main frame finishes loading a document while the tab has an address (`webContentsDidFinishLoadingDocument`) | Tab | Frames inside the page, navigations within the document |
| `addressChanged` | The tab's committed address changes, including within the document (`webContentsDidChangeURL`) | Tab | A report that repeats the tab's address |
| `titleChanged` | The tab row's name changes (`Tab.displayTitle`) | Tab | An input change that leaves the shown name unchanged |
| `tabSelected` | A window selects the tab | Tab | Selections that restore windows at launch |
| `downloadFinished` | A download entry's state becomes `completed` and its file exists | Download | Downloads that fail or are canceled |
| `spaceSwitched` | A window's current space changes; `previousPersonaID` differs when the Persona changes with it | Window | The first space of each window at launch |

### The bus

```swift
@MainActor
public final class BrowserEventBus {
    public init()
    /// Gives the event its identifier, sequence, date, and the cause of the enclosing `withCause` block when it has none, then delivers it to every subscriber whose filter matches, in subscription order, before returning.
    public func post(_ payload: BrowserEventPayload, cause: BrowserEventCause? = nil)
    @discardableResult
    public func subscribe(_ filter: BrowserEventFilter, _ handler: @escaping @MainActor (BrowserEvent) -> Void) -> BrowserEventSubscription
    /// Attaches `cause` to every event that `body`'s changes post before it returns.
    public func withCause<T>(_ cause: BrowserEventCause, _ body: () throws -> T) rethrows -> T
}

@MainActor
public final class BrowserEventSubscription {
    public func cancel()
}

public struct BrowserEventFilter: Codable, Hashable, Sendable {
    /// Empty matches every kind.
    public var kinds: Set<BrowserEventKind>
    public var scope: BrowserEventScope
    /// Empty matches every site. Otherwise an event matches only when one of its addresses matches a pattern, so an event without an address never matches a site list.
    public var sites: [AISitePattern]
    public var exceptSites: [AISitePattern]
    /// Empty matches both engines. Events without a tab ignore it.
    public var engines: Set<EngineKind>
    /// Empty matches every kind but `agent`, which only a filter that names it matches. Events without a tab ignore it.
    public var tabKinds: Set<BrowserTabKind>
    public func matches(_ event: BrowserEvent) -> Bool
}

public enum BrowserEventScope: Codable, Hashable, Sendable {
    case everywhere
    /// Whole Personas and single spaces, which the interface shows as "Persona" and "Persona / Space".
    case places([BrowserPlace])
}

public enum BrowserPlace: Codable, Hashable, Sendable {
    case persona(UUID)
    case space(UUID)
}
```

- Handlers run immediately on the main actor and must not wait: each consumer queues its own work. Every consumer sees events in sequence order.
- `BrowserSession` creates the bus (`BrowserSession.events`) and passes it to the consumers the app shell creates: `BrowserHooks`, each `PluginManager`, `AgentService`, and `HookRegistry`.

### Causes

```swift
public struct BrowserEventCause: Codable, Hashable, Sendable {
    public enum Origin: Codable, Hashable, Sendable {
        case hookRun(hook: UUID, run: UUID)
        case agentSession(UUID)
        case outsideClient(grant: UUID)
        case plugin(String)
    }
    public var origin: Origin
    /// The hooks whose runs led to this change, oldest first, at most three.
    public var hookChain: [UUID]
}
```

- An immediate change from code, such as a rename, runs inside `withCause`, so its events carry the cause.
- A navigation or new tab started by code finishes later. The source keeps the cause on the tab (`Tab.pendingCause`) and attaches it to that tab's next `addressChanged` and `pageLoaded`, and to the `tabOpened` of a tab opened by code. The user's own navigation in the tab clears it.
- A run's actions carry `hookRun` with the triggering event's `hookChain` followed by the run's hook, so successive effects keep their history (Loop protection). The agent tool host's actions carry `agentSession` or `outsideClient`, and tool calls from an agent run started by a hook carry the hook's run.

### Delivery views

Each consumer sees an event through the view its access allows. `BrowserEvent.view(_:)` in `Events` creates every view, giving the rules one implementation and one set of tests.

| Consumer | Tabs | Downloads | Cause | Events from excluded sites |
|---|---|---|---|---|
| Arch's own code (`BrowserHooks`, the registry, the agent service) | Everything | Everything | Everything | Each consumer applies its rule |
| A hook script or a script plugin | Identifiers, kind, engine, Persona, and space; the address with `tabs`, or when the grant's sites cover the page, as with plugin tabs | With `downloads` (plugins) or `tabs` (hooks): name, type, size, and both addresses; otherwise identifiers only | None | Hooks with `agent` get none (hook decision 14); the others get them as above |
| An outside program with the events scope (Outside programs) | Its own agent tabs and tabs shared with it: the tab handle and reduced address (`AgentAddress.reduced`); the user's other tabs in the grant's Persona: a watch ID and host only | Only downloads started by its own agent tabs: name as an untrusted block, type, size, and the source's host | `byThisClient` when its own action causes the event | No host or address, with `excluded: true` |

A hook script's event, with `tabs`:

```json
{ "id": "5E2C…", "kind": "pageLoaded", "date": "2026-11-14T09:30:12Z",
  "tab": { "id": "8A41…", "personaId": "D59D…", "spaceId": "1F07…", "kind": "open", "engine": "chromium", "url": "https://example.org/pricing" },
  "isRestore": false, "isFirstLoadAfterOpen": true,
  "hook": { "id": "3B0D…", "name": "Tidy Tab Names", "agent": { … } } }
```

An outside program's line for one of the user's tabs:

```json
{ "seq": 812, "kind": "pageLoaded", "date": "2026-11-14T09:30:12Z",
  "tab": { "watch": "w4", "space": "s1", "kind": "open", "engine": "chromium", "site": "example.org" },
  "isRestore": false, "isFirstLoadAfterOpen": true }
```

- Watch IDs (`w1`, `w2`, …) are per grant, last while Arch runs, and are never reused. No tool accepts one, so watching a tab never lets a program read or act on it; `request_tab` remains the only way to share one (`docs/agents.md`, Tools).
- The registry adds `hook` for hook scripts (Script API); a plugin's event has none.

### The source

`BrowserEventSource` in `Browsing` follows the session's tabs, favorites' tabs, small windows' tabs, windows, and downloads, as `BrowserHooks` now follows three kinds, and posts every kind.

- `tabClosed` comes from `BrowserSession.closeTab(_:remember:reason:)`, with `TabCloseReason` mapped case by case, and from deleting a space or a Persona as `spaceDeleted`.
- `titleChanged` follows the inputs of `Tab.displayTitle`: `title` (`page`), `customTitle` (`user`), and `suggestedTitle` (`suggested`).
- `tabSelected` and `spaceSwitched` follow each `BrowserWindowModel`'s selected tab and `currentSpaceID`, with the window model's identifier as `windowID`.
- `pageLoaded` keeps the current rules for `isRestore`: the first load of a restored tab and of a pinned tab opened by a browser import.
- Agent tabs post with kind `agent` once VII.12 marks agent folders; until then no tab has that kind.
- Once both exist, the agents' tool host (VII.12) gets navigations, opened tabs, and downloads for its tool results' events from the bus, filtered to the session's agent tabs.

### The AI hook center

The center keeps `AIHookEvent` and its tests. `BrowserHooks` subscribes to the bus for `pageLoaded`, `tabOpened`, `downloadFinished`, and `tabClosed` on every tab kind except `agent`, and maps:

| Bus event | The center |
|---|---|
| `pageLoaded(tab, isRestore, _)` | `post(.pageLoaded(AIPageLoad(tabID: tab.id, url: …, isRestore: isRestore)))` with the tab's address, which a `pageLoaded` always has |
| `tabOpened(tab, _)` | `post(.tabOpened(AITabOpen(tabID: tab.id, url: tab.url)))` |
| `downloadFinished(download)` | `post(.downloadFinished(AIDownloadFinish(…)))`, with the file's URL from the session's entry, omitted from the bus event, and `AIDownloadInfo` from the event's name, type, size, and addresses |
| `tabClosed(tab, _)` | `cancel(subject: tab.id)` |

Removing a download from the list still calls `cancel(subject:)` directly. The center's ordering, actions, checks, and built-in hooks stay as `docs/ai.md` describes them. Excluding agent tabs also keeps Tab Names off them, as VII.12 requires.

### Plugins

The plugin events planned in `docs/plugins.md` come from the bus. Each `PluginManager` subscribes for its Persona, and an enabled plugin receives the kinds listed in its manifest's `events`, through the script view above. The plugin kinds are the bus's kinds and the plugin's own `settingChanged`. VII.26 builds this with hook scripts, since both use `Plugin.handle(_:)` and `arch.events.on`.

## Hook registry

### A hook

```swift
// Hooks
public struct Hook: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var trigger: HookTrigger
    /// Its kinds come from the trigger.
    public var filter: BrowserEventFilter
    public var script: HookScript
    public var grant: HookGrant
    /// The agent run that an agent hook's script starts through `event.hook.agent`, which the editor edits; nil for other hooks.
    public var agent: AgentRunOptions?
    /// What the run log keeps of this hook's runs (Run log).
    public var record: AgentRunRecord
    public var timing: HookTiming
    public var state: HookState
    public var origin: HookOrigin
    public var created: Date
}

public enum HookTrigger: Codable, Hashable, Sendable {
    case tabOpened
    /// Empty matches every reason.
    case tabClosed(reasons: Set<BrowserTabCloseReason>)
    case pageLoaded(HookPageLoads, includesRestoredTabs: Bool)
    case addressChanged(HookAddressChanges)
    /// `[.page]` by default, so names that code gives start nothing.
    case titleChanged(sources: Set<BrowserTitleSource>)
    case tabSelected
    case downloadFinished
    case spaceSwitched(personaChangesOnly: Bool)

    public var kind: BrowserEventKind { get }
}

public enum HookPageLoads: String, Codable, Hashable, Sendable {
    /// The tab's first page after it opened in this launch (`isFirstLoadAfterOpen`).
    case firstAfterOpen
    /// A load whose address, without the fragment, differs from that of the tab's previous document. The default.
    case newAddress
    case every
}

public enum HookAddressChanges: String, Codable, Hashable, Sendable {
    /// The default, so that a single-page site's own address changes start nothing.
    case newHost
    case any
}

public enum HookScript: Codable, Hashable, Sendable {
    /// `Hooks/<hook id>/hook.js`. `generated`: the editor's template, which the editor writes again when `agent` changes.
    case javaScript(digest: String, generated: Bool)
    /// The file the user trusted, copied to `Hooks/<hook id>/hook.sh` (Shell scripts); `source` is where the user keeps it.
    case shell(source: String, digest: String)
}

public enum HookPermission: String, Codable, Hashable, Sendable, CaseIterable {
    /// Titles and addresses of the tabs of the event's Persona.
    case tabs
    /// Names tabs; the user's own name always wins (hook decision 13).
    case tabsRename = "tabs.rename"
    /// Agent runs within `HookGrant.agent`, whose tab access says whether they read page text.
    case agent
}

public struct HookGrant: Codable, Hashable, Sendable {
    public var permissions: Set<HookPermission>
    /// The ceiling of the script's agent runs; nil without `agent`.
    public var agent: AgentRunGrant?
}

public struct HookTiming: Codable, Hashable, Sendable {
    /// 0 to 60 seconds; 1.5 seconds by default for `pageLoaded` and 1 second for `addressChanged` and `titleChanged`. A newer matching event for the same subject during the wait replaces the waiting one.
    public var delay: Duration
    /// 1 second to 10 minutes, 30 seconds by default; for an agent hook, the agent run's time limit and 5 seconds.
    public var timeout: Duration
    /// 500 by default.
    public var runsPerDay: Int
}

public enum HookState: Codable, Hashable, Sendable {
    case active
    case paused(HookPauseReason)
}

public enum HookPauseReason: String, Codable, Hashable, Sendable {
    case user, failures, ranTooOften, stopAllAgents, placeDeleted, scriptChanged, shellScriptsOff, needsNewerArch
}

public enum HookOrigin: Codable, Hashable, Sendable {
    case user
    case preset(String)
    /// Added with `arch-cli hooks add` after the user allowed it.
    case outsideClient(AgentClientIdentity.Key, name: String)
}

@MainActor
public final class HookRegistry: ObservableObject, AgentHookRegistrar {
    @Published public private(set) var hooks: [Hook]
    /// Settings ▸ AI ▸ Agent Hooks ▸ Run Hooks. While it is off, no event reaches a hook.
    @Published public var runsHooks: Bool
    /// The last runs of each hook (Run log).
    @Published public private(set) var lastRuns: [UUID: [HookRunSummary]]
    /// A file set aside, a key the Keychain did not give, or a file from a newer Arch, for Settings.
    @Published public private(set) var notice: HookStoreNotice?

    public init(store: HookStore, bus: BrowserEventBus, host: any HookBrowserHost,
                javaScript: any HookScriptRunning, shell: any HookScriptRunning)
    public func add(_ hook: Hook, script: Data) throws
    public func update(_ hook: Hook, script: Data?) throws
    public func remove(_ id: UUID)
    public func move(_ id: UUID, to index: Int)
    public func pause(_ id: UUID)
    public func resume(_ id: UUID)
    /// Stop All Agents: cancels running runs and pauses every hook with `agent` until the user resumes it.
    public func stopAgentHooks()
    /// Runs the hook once for the tab as if its event had happened: the editor's Test and a row's Run on Current Tab. Without `applying`, actions are reported, not applied.
    public func test(_ id: UUID, onTab tab: UUID, applying: Bool) async -> HookRunResult
}

/// The browser side the registry needs, which `Browsing` provides.
@MainActor
public protocol HookBrowserHost: AnyObject {
    /// Every Persona with its spaces, in the session's order, for filters and their names.
    var places: [HookPersonaPlaces] { get }
    /// The tab as the bus would describe it now, or nil once it is gone.
    func tab(_ id: UUID) -> BrowserTabRef?
    /// Set by the registry; called after Personas or spaces change.
    var placesDidChange: (() -> Void)? { get set }
}

/// Runs one script for one event. The JavaScript and shell runners conform, and the tests use a fake.
@MainActor
public protocol HookScriptRunning: AnyObject {
    func run(_ invocation: HookInvocation) async -> HookRunOutcome
    func cancel(run: UUID)
}
```

`HookInvocation` carries the hook, the event in its script view, the run's identifier and cause, its deadline, and whether actions apply. `HookRunOutcome` is completed (with the actions applied or, in a test, proposed), failed (with a code and a sentence), timed out, or cancelled.

### Triggers and filters

- A hook has one trigger and one filter. The editor shows the scope as "Persona / Space" entries, with a whole Persona shown alone, such as "Personal / Work" or "Personal".
- Hooks never see agent tabs: the registry's filters never name `agent`.
- An event whose `hookChain` holds three hooks reaches no hook, and a hook skips an event whose chain holds it (Loop protection).
- A hook with `agent` gets no event from a site excluded from AI. Arch checks this when the event arrives and again after the delay (hook decision 14).
- Deleting a Persona or space removes it from every filter; a hook left with an empty scope pauses with `placeDeleted`.
- For each hook with `agent`, the registry registers the AI feature `agentHook.<hook id>`, named after the hook (Model choice and tiers), and unregisters it when the hook is removed.

### Storage

`~/Library/Application Support/Arch/hooks.json` is app-wide, since filters name Personas and spaces:

```json
{
  "seal": "…",
  "settings": {
    "version": 1,
    "generation": 7,
    "runsHooks": true,
    "allowsShellScripts": false,
    "hooks": [
      {
        "id": "3B0D…",
        "name": "Tidy Tab Names",
        "trigger": { "pageLoaded": { "loads": "firstAfterOpen", "includesRestoredTabs": false } },
        "filter": { "scope": "everywhere", "sites": [], "exceptSites": [], "engines": [], "tabKinds": ["open", "pinned"] },
        "script": { "javaScript": { "digest": "sha256:…", "generated": true } },
        "grant": { "permissions": ["agent"],
                   "agent": { "tools": ["rename_tab"], "tabAccess": "title", "maximumRecord": "none", "runsPerDay": 300,
                              "limits": { "timeout": 20, "rounds": 1, "toolCalls": 2 } } },
        "agent": { "prompt": "…", "tabAccess": "title", "model": { "tier": "fast" }, "record": "none", "tools": ["rename_tab"],
                   "limits": { "timeout": 20, "rounds": 1, "toolCalls": 2 } },
        "record": "none",
        "timing": { "delay": 1.5, "timeout": 25, "runsPerDay": 300 },
        "state": "active",
        "origin": { "preset": "tidyTabNames" },
        "created": 816000000.0
      }
    ]
  }
}
```

- Seal: `HookStore` seals the file like `agent.json` (`docs/agents.md`, Sealed settings): an HMAC-SHA256 over the settings' JSON with sorted keys, including members unknown to this build, with a 32-byte key and the last write's generation in its own Keychain item, service `xyz.taeyoon.arch.hooks`. VII.25 makes the seal reusable: `AgentSettingsFile`'s seal, generation record, and Keychain queue become `SealedSettingsFile` in `Agent`, which takes the file name and Keychain service. Both `agent.json` and `hooks.json` use it. Arch reads the key once per launch, only when the file exists or Arch first writes one, so a user without hooks sees no keychain prompt.
- A file is renamed `hooks.json.unreadable` if its seal does not match, it cannot be read, its key is missing from the Keychain, or its generation is below the item's. Arch starts with no hooks and says so in Settings ▸ AI ▸ Agent Hooks. If the Keychain does not give the key, Arch leaves the file unchanged and runs no hook for that launch, with Try Again.
- Scripts live in `~/Library/Application Support/Arch/Hooks/<hook id>/`, mode 0700, as `hook.js` or `hook.sh`, mode 0600. The sealed file holds each script's SHA-256 digest; a script whose bytes no longer match is not run, and its hook pauses with `scriptChanged` until the user reviews it in the editor.
- Versions: `version` starts at 1, and `HookStore.migrations` holds one step per later version. An earlier version is migrated in memory, step by step, and written at the next change after Arch copies it to `hooks-v<version>.json`. A later version is first copied to `hooks-v<version>.json`, replacing an older copy. Arch then reads what it knows and keeps unknown members and hooks unchanged in the sealed file. It lists a hook it cannot read as needing a newer Arch (`needsNewerArch`) and does not run it.
- Arch writes the file at each change, as it does for `agent.json`. Removing a hook deletes its folder and unregisters its feature; usage totals stay under the feature's identifier.

### Running

1. Match. For each bus event while Run Hooks is on, the registry selects active hooks whose trigger and filter match, in list order, skipping one whose identifier appears in the event's `hookChain`.
2. Wait. Each hook waits its delay per subject. A newer matching event for the same subject during the wait replaces the waiting run; one during a run cancels it and drops unapplied actions, then starts after the run stops, never later than the run's timeout.
3. Order. One event's hooks run one at a time per subject, in list order, so a later hook sees what an earlier one changed. Different subjects run independently.
4. Concurrency. At most 4 runs at once, at most 2 for one hook. Waiting runs start in arrival order; beyond 100 waiting runs, the oldest is dropped and logged as `dropped`.
5. Checks before a run starts: the hook is still active and within its daily count, the subject still exists, a `pageLoaded` hook's tab still shows the event's address, ignoring the fragment, and the site checks of Triggers and filters pass.
6. Timeout. At the hook's timeout, the runner cancels the run, which ends `timedOut`.

### Loop protection

- Own effects: a hook never runs for an event whose `hookChain` holds it, so a script that renames, opens, or navigates tabs never restarts itself through those changes.
- Depth: an event whose chain holds three hooks reaches no hook, so two hooks that react to each other stop after three steps.
- Rate: a hook that would start more than 10 runs for one subject in a minute, or more than 60 runs total in a minute, pauses with `ranTooOften` until the user resumes it. This covers effects that reach a hook without a cause, such as a page changing its own title after a hook renames its tab.
- `titleChanged` hooks react to page titles only unless the user picks other sources.
- The daily count skips runs past the hook's `runsPerDay` until the next day, and its row says so.

### Pausing

- A hook pauses when the user pauses it; after three consecutive failed or timed-out runs (`failures`), counting an agent run's `authentication` and `providerUnavailable` errors as the AI hook center does; with `ranTooOften`; at Stop All Agents for every hook with `agent`; or when its scope is deleted, its script changes outside Arch, shell scripts are switched off, or it needs a newer Arch.
- Resume clears the counts. A paused hook keeps its place and settings, and its row shows why with Resume or Review.
- Turning Run Hooks off stops every hook without changing their states.

### Run log

`~/Library/Application Support/Arch/hooks-activity.json` keeps runs for 30 days, with Clear Activity in Settings. A file that cannot be decoded is renamed `hooks-activity.json.unreadable`, as in other stores.

```json
{ "id": "…", "date": "2026-11-14T09:30:14Z", "hook": "3B0D…", "event": "pageLoaded", "subject": "open", "site": "example.org",
  "persona": "D59D…", "outcome": "completed", "duration": 1.8, "actions": { "renameTab": 1 },
  "agent": { "provider": "6F1C…", "model": "model-a", "inputTokens": 310, "outputTokens": 12 }, "test": false }
```

- Outcomes: `completed`, `failed` with a code, `timedOut`, `cancelled`, and `skipped` with `loop`, `rateLimit`, `dailyLimit`, `budget`, or `dropped`.
- Entries never hold page text, titles, assigned names, prompts, replies, script output, or an address's path or query. The site is the page's registrable domain, as in the agents' log (`AgentActivityEntry.site(of:)`).
- The hook's `record` decides: Keep the Session and Keep Activity Only log every run; Keep Nothing logs none. `lastRuns` keeps the last 20 runs in memory for Settings, from the log at the first two levels. For Keep Nothing it keeps only the day's run count, failure count, and last run's time and outcome.
- Events matching no hook's filter are not logged.

## Script runner

### JavaScript scripts

- A JavaScript hook script uses `Plugins`' unchanged script runtime: a `ScriptPlugin` instance with its hidden web view, `PluginSchemeHandler`, content security policy, rule list, Lockdown Mode, non-persistent data store, and bridge (`docs/plugins.md`, Sandboxing). The runner makes a package in memory: the manifest's identifier `xyz.taeyoon.arch.hook.<hook id>`, the hook's name, its grant's permissions (`tabs`, `tabs.rename`, `agent`), `events` with the trigger's kind, and `hook.js` as the background script, served from the hook's folder. `Plugins` makes `ScriptPlugin` and the package initializer public for this. The plugin manager takes no part. Hook scripts are not plugins in Settings ▸ Plugins and have no storage, secrets, settings, network, clipboard, or notifications.
- `HookScriptContext` in `Hooks` is the script's `PluginContext`, bound to the event's Persona with the hook's grant. Every action carries the run's cause and honors its test flag. Storage and secrets are empty and read-only.
- The script is a classic script of at most 256 KB and must parse. `JSCheckScriptSyntax` checks it without running it, as the composer checks plugins AI writes. It calls `arch.events.on(kind, listener)` when it loads; the run ends when the listener's promise settles. A rejected promise or thrown error fails the run with the error's message. Its first 200 characters stay in memory for the hook's last runs.
- Instances: at most 2 per hook and Persona, each handling one run at a time. Every call an instance makes belongs to its current run. An instance stops after 30 seconds without a run. The hook's timeout replaces the plugins' 10-second hang rule: a timeout ends the instance.

### The script API

| JavaScript | Needs | Does |
|---|---|---|
| `arch.events.on(kind, (event) => …)` | — | Receives the hook's events: the script view with `hook: {id, name, agent}` |
| `arch.tabs.get(id)` | — | `{id, spaceId, kind, engine, isPinned, isSelected}`, with `title` and `url` under `tabs`; tabs of the event's Persona only |
| `arch.tabs.list()` | — | The Persona's tabs in sidebar order, in the same form |
| `arch.tabs.rename(id, name)` | `tabs.rename` | Sets the tab's suggested name under hook decision 13, with the name's first line trimmed and cut to 60 characters; resolves `true` when the tab accepts it and `false` when the user's name or refusal prevents it; `null` clears the suggested name |
| `arch.agent.run(options)` | `agent` | An agent run (Agent run API); resolves with its result |

- These names match the plugin JavaScript API (`docs/plugins.md`, JavaScript API for script plugins). The same `PluginContext` members serve both: `tabs()`, `tab(_:)`, `renameTab(_:to:)`, and `runAgent(_:)`, which the context passes to the agent runner. `PluginBrowserHost` in `Plugins`, implemented by `Browsing`, reaches the tabs.
- In a test run, `rename` and the agent's `rename_tab` report what they would do and change nothing.

The editor's script for Tidy Tab Names:

```js
// Arch wrote this script for the agent hook "Tidy Tab Names".
// Its instructions, model, record, actions, and limits are in event.hook.agent, which Settings ▸ AI ▸ Agent Hooks edits.
arch.events.on("pageLoaded", async (event) => {
  await arch.agent.run({ ...event.hook.agent, tabs: [event.tab.id] });
});
```

### Shell scripts

- Settings ▸ AI ▸ Agent Hooks ▸ Allow Shell Scripts is off by default. Turning it off pauses every shell hook with `shellScriptsOff`.
- New Script Hook… ▸ Shell Script ▸ Choose File… opens `NSOpenPanel`. Arch shows the file's full text, its interpreter, and what the script receives. After Touch ID or the login password, Arch trusts the file, copies it into the hook's folder as `hook.sh`, and records its SHA-256 digest in `hooks.json`. Update from File… does the same for a changed file and marks the changed lines. Arch runs only its own copy.
- The file is a regular UTF-8 file of at most 1 MB. Its first line is `#!` with an absolute path to an executable, or `/usr/bin/env` and one program name.
- Running: Arch reads its copy, checks the digest, and starts the interpreter with `posix_spawn` in its own process group, as `CommandLineProcess` starts command-line tools. It pipes the checked bytes to the interpreter as descriptor 3 and passes `/dev/fd/3` as the script's path, so what runs is what Arch checked. Standard input carries the event as JSON in the script view with `tab.handle` (`t1`) for `arch-cli`, then closes.
- Environment, with nothing else from Arch's: `PATH` (the bundle's `Contents/Helpers`, then the login shell's PATH as `LoginShell` reads it), `HOME`, `LANG`, `TMPDIR` set to the run's working folder, `ARCH_HOOK_ID`, `ARCH_HOOK_EVENT` (the kind), and `ARCH_HOOK_TICKET`.
- The working folder is `Arch-Hook-<run id>/` in Arch's temporary folder, mode 0700, removed after the run.
- At the hook's timeout, Arch sends `SIGTERM` to the process group and `SIGKILL` 2 seconds later. Standard output is read and dropped. The last 4 KB of standard error stay in memory for the hook's last runs at Keep the Session or Keep Activity Only, never on disk. Exit status 0 completes the run; any other status fails it.
- Acting: `arch-cli` presents `ARCH_HOOK_TICKET` in `hello`. Arch binds the connection to the run when the ticket matches in a constant-time comparison and the script's process is an ancestor of the peer, following the rule for in-app sessions' tickets (`docs/agents.md`, In-app sessions: tickets). The bound connection has the hook's grant, the event's tab as `t1`, and the commands `rename`, `tabs`, and `agent run`. The socket listens while a shell hook runs, as for an in-app session on a CLI.
- A shell script runs with the user's rights. Arch vouches only for the text the user trusted, not for what it does (Risks). Outside programs cannot add shell hooks, AI never writes one, and Arch never edits one.

## Agent run API

### The call

```swift
// Agent
public enum AgentRunTabAccess: String, Codable, Comparable, Sendable {
    /// The tab's title and reduced address in the first message.
    case title
    /// Also the read tools on the tab's page.
    case page
}

public enum AgentRunRecord: String, Codable, Comparable, Sendable {
    case none, activity, session
}

public struct AgentRunLimits: Codable, Hashable, Sendable {
    /// 30 seconds by default; 5 seconds to 10 minutes.
    public var timeout: Duration
    /// Model requests, or a CLI's turns; 2 by default, 1 to 20.
    public var rounds: Int
    /// 5 by default, 1 to 50.
    public var toolCalls: Int
}

public struct AgentRunOptions: Codable, Hashable, Sendable {
    /// At most 4,000 characters.
    public var prompt: String
    public var tabAccess: AgentRunTabAccess
    public var model: AIRouteChoice
    public var record: AgentRunRecord
    /// Catalog names from the run tools (Tools).
    public var tools: [String]
    public var limits: AgentRunLimits
    /// Report the actions instead of applying them, for Test and `--dry-run`.
    public var dryRun: Bool
}

/// What a caller's runs may ask for: a hook's grant, or an outside client's.
public struct AgentRunGrant: Codable, Hashable, Sendable {
    public var tools: Set<String>
    public var tabAccess: AgentRunTabAccess
    public var maximumRecord: AgentRunRecord
    /// 200 by default, 1 to 2,000.
    public var runsPerDay: Int
    public var limits: AgentRunLimits
}

public enum AgentRunOrigin: Hashable, Sendable {
    case hook(UUID, run: UUID)
    case test(hook: UUID)
    case outsideClient(grant: UUID)
}

public struct AgentRunRequest: Sendable {
    public var options: AgentRunOptions
    /// The event's tab for a hook; the client's tabs for `arch-cli agent run`.
    public var tabs: [UUID]
    public var origin: AgentRunOrigin
    /// `agentHook.<hook id>` or `agentRun`.
    public var feature: AIFeatureID
    public var grant: AgentRunGrant
}

public struct AgentRunResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case completed, failed, timedOut, cancelled, refused }
    public var status: Status
    /// The AI error, or the refusal's rule, such as `wouldAsk` or `notGranted`.
    public var code: String?
    public var message: String?
    /// Applied, or proposed in a dry run.
    public var actions: [AgentRunAction]
    /// The agent's last text, for the caller only.
    public var reply: String?
    public var model: AIModelRef?
    public var usage: AIUsage
    /// Set with Keep the Session: the kept run in memory.
    public var keptRun: UUID?
}

public enum AgentRunAction: Codable, Hashable, Sendable {
    case renamedTab(UUID, name: String)
}

@MainActor
public final class AgentRunner {
    public func run(_ request: AgentRunRequest) async -> AgentRunResult
    /// Runs kept with Keep the Session, newest first, at most 20 per hook or grant, in memory until deleted or quit.
    @Published public private(set) var keptRuns: [AgentKeptRun]
    public func deleteKeptRun(_ id: UUID) async
    /// Stop All Agents.
    public func cancelAll()
}
```

- Callers: hook scripts through `arch.agent.run`; the editor's Test and a hook row's Run on Current Tab through `HookRegistry.test(_:onTab:applying:)`; outside programs through the control method `agent/run` and `arch-cli agent run`; and a shell hook's `arch-cli agent run` under the hook's grant. `AgentService` owns the runner.
- Before a run starts, the runner checks the options against the grant: tools within its tools, tab access and record at most its own, and limits at most its ceilings. A call that asks for more is `refused` with `notGranted` and a sentence naming the field. Each tab must exist in the caller's Persona and not be on a site excluded from AI (P16). The daily run count comes next, then the route.
- In JavaScript and on the wire, options are JSON: `{"prompt": …, "tabAccess": "title", "model": {"tier": "fast"} or {"models": [{"provider": …, "model": …}]}, "record": "none", "tools": ["rename_tab"], "limits": {"timeout": 20, "rounds": 1, "toolCalls": 2}, "tabs": [<tab id>], "dryRun": false}`, with durations in seconds. Omitted fields use the grant's values for tools and tab access and the defaults above for the rest; `prompt` and `model` are required.

### Model choice and tiers

```swift
// AI
public enum AIModelTier: String, Codable, Hashable, Sendable, CaseIterable {
    case fast, standard, deep
}

public enum AIRouteChoice: Codable, Hashable, Sendable {
    case tier(AIModelTier)
    /// A model and up to two fallbacks.
    case models([AIModelRef])
}

public enum AIFeatureRouting: String, Codable, Sendable {
    /// The feature's route in `ai.json`, which Settings ▸ AI ▸ Features edits. The default.
    case stored
    /// Each request names its route. Features does not list the feature; Usage lists it by name.
    case perRequest
}

// AIFeature
public var routing: AIFeatureRouting
// AIRequest and AIAgentSessionRequest
public var route: AIRouteChoice?
/// false leaves the request's Activity entry without content, so Show Content has nothing to show. true by default.
public var recordsContent: Bool
// AINotConfiguredReason
case emptyTier(AIModelTier)
```

- Tiers are routes in `ai.json` under `tier.fast`, `tier.standard`, and `tier.deep`, each with a model and up to two fallbacks. Their `isEnabled` is written true and not read. Settings ▸ AI ▸ Model Tiers edits them with the Features rows' model menus, explains each tier's purpose in a sentence, and starts empty. A tier lists any connected model; requirements drop unsuitable models when a request resolves it.
- Resolution: a `perRequest` feature takes the request's route and throws `notConfigured(.noModel)` without one. A `stored` feature with trigger `user` may use a request's route instead of its stored one, as the agent composer's model menu and `arch-cli agent run --tier` do. A `stored` automatic feature refuses one with `invalidRequest`, so Tab Names keeps its own route. A tier resolves to its route's models; an empty tier throws `notConfigured(.emptyTier(_:))`, whose action is "Assign a model to the Fast tier in Settings ▸ AI." with Open AI Settings. Step 3 of Routing (`docs/ai.md`) then drops models without a required capability, and fallbacks follow the tier's list as for any route.
- Budgets, rate limits, part checks, and usage apply as for every request. A `perRequest` automatic feature counts toward the daily limit for automatic requests and the monthly spending limit.
- Features: `agentHook.<hook id>` for each hook with `agent`, automatic and `perRequest`, named after the hook, requiring `agent`, with data `page` limited to 0 characters of text for tab access `title` and to the model's limit for `page`; and `agentRun`, "Agent Runs from Programs", automatic and `perRequest`, for runs started by outside programs.
- A run with tab access `title` sends the title and address as a page part without text, so the service's site exclusions and query removal apply on API-key models. CLI runs receive them in the first message after the runner's exclusion check and address reduction, as the tool host checks page data it passes to CLI sessions.

### Record levels

| Level | Transcript | Run log and agent activity | Codex thread | AI Activity in memory | Usage |
|---|---|---|---|---|---|
| Keep the Session (`session`) | The prompt, agent's replies, and tool steps kept in memory as a kept run until the user deletes it or Arch quits; at most 20 per hook or grant | An entry per run in `hooks-activity.json`, and one per tool call in `agent-activity.json`, as for any agent | Kept until the kept run is deleted, then deleted unless Keep Codex's Copy of Agent Conversations is on | With content | Counted |
| Keep Activity Only (`activity`) | None: dropped when the run ends | As above | None: the run uses `--ephemeral` | Without content | Counted |
| Keep Nothing (`none`) | None | None | None | Without content | Counted: the totals in `ai-usage.json` and the day's run count only |

- No level writes a prompt, reply, title, page text, or address path to disk; kept runs stay in memory, as agent sessions' transcripts do (`docs/agents.md`, Storage). Claude Code runs with `--no-session-persistence` at every level.
- Keep Nothing is allowed only when every tool the run may call reads or changes no more than a tab's name: the read tools and `rename_tab` today. A later tool that opens or closes tabs or acts in a page raises the lowest level to Keep Activity Only, so the agent activity log keeps each such step.
- The caller gets the result in memory at every level.

### Tools

| Tool | Tab access | What a run may do with it |
|---|---|---|
| `rename_tab` | `title` or `page` | Name one of the run's tabs |
| `read_text` | `page` | Read a run tab's text, paged, within agents' limits |
| `snapshot` | `page` | Read a run tab's outline; refs serve reading only, since a run has no interaction tool |

- Runs get no other tool: no navigation, interaction, approval, question, hand-over, history, or download tool, and no `guide`; the run's instructions are short and fixed.
- A run has none of the agents' modes. Its tools and tabs define its reach. An outside client's run also stays within its grant's level, and no step asks (hook decision 5).
- `rename_tab` joins the catalog in `AgentControl`: input `tab` and `name` (1 to 60 characters after taking and trimming the first line; an empty name clears a suggested name), output the name the row shows and whether it applied, class N, and `refused` with `userNamed` when the user's name or refusal keeps the tab's name. In-app sessions and outside clients may rename their own agent tabs freely, a tab the user shared after asking once per tab (rule P19), and no other tab.
- `AgentPolicy` gains the client kind `run`: rules that ask become `refused` with `wouldAsk`, P16 refuses as for every client, and P17 limits the run to its own tabs.
- Arch writes the first message: who the run works for, the prompt under "The user's instructions", each run tab with its handle (`t1`, …) and its title and reduced address as an untrusted block (`AgentUntrusted`), the tools, and "Finish without asking; nobody will answer." The instructions are `AgentHarness.runInstructions`, a short fixed text in `AgentHarness.swift`.

### Limits

- Rounds count model requests on API-key models and turns on CLIs. With one round, an API-key run performs the round's tool calls and ends without sending their results back, so a rename costs one request. Claude Code takes `--max-turns`. Codex has no turn limit flag, so the host ends its turn at the tool-call or time limit.
- At a limit, the run stops and applied actions stay; the result names the limit.
- The time limit covers the whole run, including the CLI's start.
- At most 2 automatic runs at once; their requests wait in the providers' rate limiters, where an automatic request gives up after 15 seconds.
- Runs per day count per feature in `ai-usage.json`, beside the day's automatic request counts.

### How a run runs

1. The runner resolves the route and takes its first usable model.
2. An API-key model with `tools` runs VII.19's loop (`AgentAPISession` on `AIClient.run`) with the run's tools as `AIToolHandler`s over the tool host as client `run`, `pinnedModel` for every round, and the rounds limit. It uses no socket.
3. A Claude Code or Codex preset runs one turn of an `AIAgentSession` (VII.16): `AIService.startAgentSession(_:)` with the route, `runInstructions`, a tool server listing only the run's tools under a ticket bound to the run (VII.17's binding), `maxTurns` set to the rounds, and `keepsThread` true only at Keep the Session. It sends the first message, waits for `turnFinished`, and calls `end(keepingThread:)`. A Claude Code turn that stops at `--max-turns` (`error_max_turns`) counts as completed. `AIAgentSessionRequest` gains `maxTurns` and `keepsThread`, which Codex turns into `--ephemeral` when false. Probes check both flags, as they check every flag Arch passes. Each run starts a process and takes a few seconds; the editor says so when the first model in a hook's choice is a CLI.
4. Fallbacks move to the next model only before the model's first output, as for sessions.
5. Stop All Agents, a canceled hook run, and the time limit stop the turn or loop and end the session; no process of the run remains.
6. The result lists the actions the tool host applied during the run, the last text, the model, and usage.

## Agent hook editor

### Settings ▸ AI ▸ Agent Hooks

- The page lists every agent and script hook in run order. The top has Run Hooks, Allow Shell Scripts, New Agent Hook…, New Script Hook…, and Presets with Tidy Tab Names. New Agent Hook… and the presets appear while a model with `agent` exists; script hooks need no AI.
- Each row shows the hook's switch, name, situation ("When a new tab loads its first page · Everywhere · All sites"), model ("Fast · model-a"), record ("Keeps nothing"), last run ("2 minutes ago · renamed a tab"), and, for a hook added by an outside program, origin ("Added by Codex · Terminal"). A paused row gives the reason, with Resume, or Review for a changed script. The row's menu has Edit…, Run on Current Tab, Duplicate, and Delete, which asks first; dragging reorders rows. A row opens to its last runs, with Show Session for a kept run.
- Notices: a file set aside, a key the Keychain did not provide (Try Again), and a file from a newer Arch.

### The editor

A sheet with these sections, in order:

1. Name.
2. When: the situation in plain words: "A new tab opens", "A tab loads a page" (with "Only a new tab's first page", "Each new address", or "Every load"), "A tab's address changes" (with "Only a new site" or "Any change"), "A tab's title changes" (with "The page's title", "Your names", and "Names from hooks and agents"), "You select a tab", "A tab closes" (with its reasons), "A download finishes", and "You switch spaces" (with "Only when the Persona changes").
3. Where: Everywhere, or "Persona / Space" entries; Sites: All Sites, Only These Sites, or All Sites Except These, as `AISitePattern` entries; Engines: Both, WebKit, or Chromium; Tabs: open tabs, pinned tabs, favorites' tabs, and small windows' tabs.
4. What the agent does: the instructions, with a placeholder example; Give the Agent: The Tab's Title and Address, or Also the Page's Text, which says page text goes to the model automatically and sites excluded from AI are skipped.
5. Model: Fast, Standard, or Deep, or A Specific Model… with connected models that have `agent`; below it, the resolved model, "Choose a model for the Fast tier" with the tier's menu inline when empty, and the note for a CLI model.
6. Record: Keep the Session, Keep Activity Only, or Keep Nothing, each with one sentence from Record levels.
7. Allowed Actions: Rename the Tab. The list grows with the run tools.
8. Limits: Time Limit, Rounds, Runs per Day, which sets both the hook's daily count and its agent runs', and Wait Before Running.
9. Test on Current Tab: runs the hook once on the front window's selected tab. It reports actions without applying them unless Apply Changes is checked. The sheet shows the result until it closes: what would change, the agent's reply, the model, tokens, and time. A test counts toward usage, not the hook's daily count, and is logged with `test` at the first two record levels.
10. Script: Show Script reveals the generated script, read-only; Edit Script makes it the user's (`generated` false). The editor then edits the situation and agent block but no longer writes the script. Restore Arch's Script writes the template again. The syntax check runs when the user saves an edited script.
11. Save: writes the hook with a grant derived exactly from its options, `agent` with the options' tools, tab access, record, limits, and runs per day, and registers its feature. An edited script calling `arch.tabs` needs `tabs` or `tabs.rename`, which the Script section then offers as checkboxes. The user's edits in Arch need no Touch ID, as switching on Tab Names needs none.

`AgentHookTemplate` in `Hooks` turns the editor's choices into the hook and its script, so Settings, the presets, and tests make hooks the same way.

## Tidy Tab Names

| Setting | Value | Why |
|---|---|---|
| Situation | A tab loads its first page after it opens (`pageLoaded`, `firstAfterOpen`), excluding restored tabs | A new tab has no title when it opens, and often no address; the first load has both (hook decision 12). Restored tabs keep their names |
| Wait | 1.5 seconds | Titles set by scripts settle, as Tab Names waits |
| Where | Everywhere; every site except those excluded from AI; both engines; open tabs and pinned tabs | Favorites' tabs go by their favorites' names, and small windows show no tab row |
| Gives the agent | The title and the address | Enough for a name without page text, so one request to a fast model works |
| Model | Fast | The user's choice for this task |
| Record | Keep Nothing | The user's choice for this task |
| Actions | `rename_tab` only | Nothing else to do |
| Limits | 20 seconds, 1 round, 2 tool calls, 300 runs per day | One request per tab |

Instructions: "Give this browser tab a short name that tells it apart from other tabs: at most four words, in the language of its title. Use the title and address in the tab block, and drop site names, slogans, counters, and separators unless the name needs them. Call rename_tab once with the name. If the title is already short and clear, do not call it."

- Choosing the preset opens the editor with each choice filled in for the user to see before saving. When the Fast tier is empty, the Model section asks for its model inline.
- Tab Names (`hook.tabName`, Settings ▸ AI ▸ Features) is an AI hook: a plain model request without tools on every new document of a tab, with up to 2,000 characters of page text, under its own stored route. It and Tidy Tab Names both set the suggested name, so both send a request on a new tab's first page and the later reply wins. Arch does not merge them. Whenever an active hook renames on `tabOpened` or `pageLoaded` while Tab Names is on, the editor and hook's row say "Tab Names also names tabs. Turn on one of them." with Turn Off Tab Names.
- Which to turn on: Tidy Tab Names for the user's case of new tabs only, a fast model, no page text, and no record. Tab Names remains for naming every page a tab loads from its text.
- The preset is data, `HookPresets.tidyTabNames`. Once saved it is an ordinary hook that the user can edit, duplicate, or delete.

## Outside programs

### Grants

- The new extra scope on the grant sheet, Watch Browser Events (off), allows `events/subscribe` and `watch_events` for the grant's Persona through the outside view. It asks for Touch ID or the login password, as Search History does, because it shows when and where the user browses. The sheet says: "See when tabs open, load, change, and close in <Persona>, with their sites. Never their titles or pages."
- `agent/run` needs the existing Start Agent Tasks scope. `hooks/add` needs a grant of any level, and the user allows each hook separately. `rename_tab` follows agents' rules with P19.
- Revoking a grant ends its subscriptions. Hooks it added stay, since the user allowed each, and Settings shows their origin.

### arch-cli events

```
arch-cli events [--kind <kind>]… [--space <name>]… [--site <pattern>]… [--except-site <pattern>]…
                [--engine webkit|chromium] [--tab-kind open|pinned|favorite|small-window|agent]… [--after <seq>] [--json]
```

- It streams until interrupted: with `--json`, one event per line in the outside view; otherwise one line per event such as `09:30:12 pageLoaded w4 example.org (chromium, open)`. It exits 6 without the scope.
- The Persona is always the grant's, and `--space` names its spaces. `--after` first replays events after that sequence from the grant's buffer of the last 500 in memory, then follows new events.
- Control methods: `events/subscribe` with `{"filter": {…}, "after": <seq>}` returns `{"subscription": …, "sequence": <last>}`; Arch then sends `events/event` with `{"subscription": …, "event": {…}}`, and `events/dropped` with a count when the connection's queue of 1,000 events overflows; `events/unsubscribe` ends one. A connection holds at most 4 subscriptions.

### arch-cli hooks

```
arch-cli hooks list [--json]
arch-cli hooks add --name <name> --event <kind> [--loads first|new|every] [--space <name>]… [--site <pattern>]…
                   [--except-site <pattern>]… [--engine webkit|chromium] [--tab-kind <kind>]… [--delay <ms>] [--timeout <s>]
                   --script <file.js> [--permission tabs|tabs.rename|agent]… [--agent <options.json>] [--record none|activity|session]
arch-cli hooks remove <id>
```

- `list` shows the hooks this client's identity added: identifier, name, trigger, state, and last run.
- `add` reads the script (a JavaScript file of at most 256 KB) and agent options, checks their form against the catalog, and sends `hooks/add`. Arch checks the script's syntax and shows the proposal sheet. The command waits with "Waiting for your approval in Arch…" and prints the new hook's identifier on Allow. Don't Allow exits 3. A refusal exits 4: a shell script, a script over the size limit or that does not parse, an unknown event, permission, or tool, a filter naming agent tabs, a scope outside the grant's Persona, or more than 20 hooks from one identity. With `agent`, the hook's grant matches the agent options, with 200 runs per day.
- The sheet appears like the grant sheet: in Arch's frontmost main window, with a notification without content while Arch is in the background. It names the client and its path, then the hook's name, its situation in words with "Persona / Space" entries, its permissions in sentences, its agent options (the model or tier with the resolved model, the record, the actions, and the limits), and the script's full source, read-only. It has no default button; Escape is Don't Allow; Allow needs a pointer click and Touch ID or the login password. An unanswered sheet closes as Don't Allow after the outside clients' approval window. After a decline, the identity's next proposal waits at least a minute.
- An allowed hook is an ordinary active hook with origin `outsideClient`, limited to the grant's Persona.
- `remove` removes a hook this identity added, without a sheet; any other identifier returns not found. No command edits, pauses, or resumes a hook; the user does that in Settings.

### arch-cli agent run and rename

```
arch-cli agent run (<prompt>|-) [--tab <t>]… [--tier fast|standard|deep | --model <provider>/<model>] [--page]
                   [--record none|activity|session] [--tools <tool>,…] [--timeout <s>] [--rounds <n>] [--dry-run] [--json]
arch-cli rename <tab> <name>
```

- From an outside client, `agent run` needs Start Agent Tasks, works on the client's agent tabs and the tabs shared with it, offers only the run tools that the grant's level allows, runs under `agentRun`, and counts toward the grant's runs per day. Without `--tier` or `--model` it uses the Standard tier; without `--record`, Keep Activity Only.
- Inside a shell hook's run it uses the hook's grant, feature, and tabs, with `t1` the event's tab.
- It prints the result's sentence and reply, or the result as JSON with `--json`, and exits 0 when completed, 1 when failed, 4 when refused, and 5 when timed out.
- `rename` calls `rename_tab`.

### arch-mcp

- `rename_tab` and `watch_events` join the tools `arch-mcp` lists when the connection's grant allows them.
- `watch_events` takes `kinds?`, `after?` (the `last` sequence of the previous result), and `timeout_ms?` (at most 30,000, the default). It returns up to 100 events after `after` from the grant's buffer, or waits up to the timeout for the first; its structured result is `{"events": […], "last": <seq>}`. It is class R and needs the events scope. Download names in it are untrusted blocks.
- No MCP notifications carry events, and `arch-mcp` offers no hook or agent run tool (hook decision 11).

### Control methods and the registrar

`AgentControlProtocol.swift` adds `events/subscribe`, `events/unsubscribe`, `hooks/list`, `hooks/add`, `hooks/remove`, and `agent/run`, and the notifications `events/event` and `events/dropped`; `hooks/add` and `agent/run` send `progress` while they wait. `AgentCommandLine.swift`'s table gains `events`, `hooks`, `agent run`, and `rename`, which the `cli` guide topic lists from the table. `Agent` reaches the registry through a protocol that `HookRegistry` implements, since `Agent` cannot depend on `Hooks`:

```swift
// Agent
@MainActor
public protocol AgentHookRegistrar: AnyObject {
    func hooks(addedBy client: AgentClientIdentity.Key) -> [AgentHookSummary]
    /// Shows the proposal sheet and returns once the user answers or the approval window closes.
    func propose(_ proposal: AgentHookProposal, from client: AgentClientIdentity, grant: AgentGrant) async -> AgentHookDecision
    func remove(_ id: UUID, addedBy client: AgentClientIdentity.Key) -> Bool
}
```

The app shell sets `AgentService.hookRegistrar` once both exist. The proposal sheet is `HookProposalSheet` in `Hooks`.

## Storage

| File | Contents | Protection |
|---|---|---|
| `~/Library/Application Support/Arch/hooks.json` | Run Hooks, Allow Shell Scripts, and the hooks with their triggers, filters, grants, agent options, record levels, timing, states, origins, and script digests | Sealed; no secrets |
| `~/Library/Application Support/Arch/Hooks/<hook id>/hook.js` or `hook.sh` | The hook's script, or Arch's copy of a trusted shell script | 0700 folder, 0600 file, digest in the sealed file |
| `~/Library/Application Support/Arch/hooks-activity.json` | Run log, 30 days | No content |
| `ai.json` | The tier routes `tier.fast`, `tier.standard`, and `tier.deep` | As `ai.json` |
| `ai-usage.json` | Totals of the hooks' features and `agentRun`, and the day's run counts | No content |
| `$TMPDIR/Arch-Hook-<run id>/` | A shell run's working folder | 0700, removed after the run |

- Keychain: `xyz.taeyoon.arch.hooks` holds the seal key and the last write's generation. Run tickets live only in memory and in the run's process tree.
- Kept runs, last runs, event buffers, and test results stay in memory until deleted or Arch quits.

## Errors

| Situation | What the user, the script, or the program sees |
|---|---|
| An empty tier | `notConfigured(.emptyTier)`: "Assign a model to the Fast tier in Settings ▸ AI." with Open AI Settings; the hook's row shows it |
| Options beyond the grant | `refused`, `notGranted`, with the field: "This hook may not keep sessions." |
| A step that would ask | The tool result is `refused`, `wouldAsk`: "This run cannot ask the user, so Arch refused the step." |
| A tab on an excluded site | `refused` (P16) before the run starts |
| A script that throws or exits nonzero | The run fails with its message; three in a row pause the hook |
| A script changed outside Arch | The hook pauses: "Its script changed outside Arch." with Review |
| `hooks.json` set aside or unreadable | The notice in Settings; no hooks run |
| Shell scripts switched off | Shell hooks pause: "Shell scripts are off." |
| A hook that ran too often | It pauses: "This hook ran too often, so Arch paused it." with Resume |
| `arch-cli` without the events scope, or a declined hook | Exit 6, or 3 |

## Tests

- `EventsTests` (VII.23): each payload's JSON against fixed text; `kind`, `subject`, `personaID`, and `urls` for every case; filters by kind, scope (whole Personas and single spaces), sites and exceptions through `AISitePattern`, engines, and tab kinds, with `agent` matched only when named and events without an address never matching a site list; every delivery view, with no titles, addresses only under `tabs` or a covering grant, hosts and watch IDs for outside programs, downloads only from the client's agent tabs, `excluded: true`, and `byThisClient`; `withCause` and sequence order.
- `BrowsingTests` (VII.23): the source posts each kind for session changes on fake web contents: a new tab but no restored tabs, closes with each reason, `isRestore` and `isFirstLoadAfterOpen`, address changes with the previous address, title changes from each source but none when the shown name stays, selection and space switches with a Persona change, a finished download, and `Tab.pendingCause` on the next load; `BrowserHooks` maps bus events to the AI hook center as before, and existing hook action tests pass unchanged.
- `AITests` (VII.24): tier resolution with fallbacks, an empty tier's error, request routes accepted for `perRequest` and user features and refused for stored automatic ones, capability drops after a tier, budgets for `perRequest` automatic features, `recordsContent` false leaving Activity without content, and the tier routes read and written in `ai.json`.
- `HooksTests` (VII.25): `hooks.json` read and written sealed; an edited file, a restored earlier copy, and a missing key handled as for `agent.json`; a test migration from version 0, and a file from a later version copied and kept, with its unknown hook listed but not run; triggers and filters; list order; delay and replacement; a newer event canceling a run; concurrency caps and the dropped oldest run; loop protection (own effects, depth, the rate pause); pausing after three failures and Resume; Stop All Agents; a deleted place; a changed digest; the daily count; and run log entries with no title, name given, prompt, reply, output, or address path, with none at Keep Nothing.
- `HooksTests` and `PluginsTests` (VII.26): a fixture hook script in the sandbox receiving its event; `arch.tabs.get` without `tabs` lacking title and address; `rename` through a fake `PluginBrowserHost` under the suggested name rules, carrying the run's cause and reporting in a test; a timed-out run ending its instance; the syntax check; and plugin events through the script view for a manifest's `events`.
- `AgentTests` (VII.27): options checked against the grant; the `run` client kind refusing every asking rule with `wouldAsk` and other tabs with P17; `rename_tab` and P19 for sessions and outside clients; each record level's files and memory; one round ending after its tool calls without sending results back, through the scripted provider; a CLI run's arguments with `--max-turns`, `--ephemeral`, and only the run's tools, through the fake CLIs of `AITests`; the daily run count; and Stop All Agents.
- `PreferencesTests` and `HooksTests` (VII.28, VII.29): the editor's choices turned into a hook, a grant, and the template script; an edited script kept and the template restored; Test reporting a rename without applying it; row summaries with "Persona / Space" entries; the Tidy Tab Names preset's values; `firstAfterOpen` matching a new tab's first page but neither its second nor a restored tab's; and the Tab Names warning.
- `AgentControlTests` and `AgentTests` (VII.30): parsing of `events`, `hooks`, `agent run`, and `rename`; JSON lines; the events scope's views and buffer with `--after`; `watch_events` with its cursor and timeout; `hooks/add` through a fake registrar with Touch ID through the fake authenticator, a decline's minute, the 20-hook cap, and `remove` of the client's own hooks only; `agent run` under Start Agent Tasks and `agentRun`.
- `HooksTests` (VII.31): fixture shell scripts receiving the event on standard input, exactly the listed environment, the checked bytes through `/dev/fd/3`, a changed copy refused, the time limit ending the process group, standard error kept only in memory, and the ticket bound only within the run's process tree.

## Checks from the bundle

Each task that needs the app adds its check to the regression checklist in `docs/plan.md` with these numbers. Run them on both engines with a fresh Application Support folder.

69. Script hooks: with Run Hooks on, New Script Hook… with a JavaScript script that renames a new tab's first page to its host through `arch.tabs.rename` renames tabs on both engines and leaves tabs the user named alone. A second hook that renames on `titleChanged` with the source "Names from hooks and agents" runs once for each of the first hook's renames and never for its own; Pause and Resume work. Editing `hook.js` in another editor pauses the hook with Review. Editing `hooks.json` by hand sets it aside, shows the notice, and no hook runs.
70. Agent runs: with an API-key model with tools as the Fast tier, a script hook calling `arch.agent.run` with the Fast tier and `rename_tab` renames a new tab in one request (Settings ▸ AI ▸ Activity). At Keep Nothing, `hooks-activity.json` gains no entry and the Activity entry has no Show Content; at Keep Activity Only, an entry has no title or address path; at Keep the Session, the row's last runs offer Show Session. An empty Fast tier fails with its sentence.
71. The editor: New Agent Hook… makes the hook described in Tidy Tab Names by hand. Test on Current Tab shows the proposed name without renaming; Apply Changes renames. Show Script shows the template, Edit Script keeps the user's change, and Restore Arch's Script restores the template.
72. Tidy Tab Names: the preset with the Fast tier on an API-key model renames each new tab once on both engines, leaves restored tabs alone after a relaunch, and keeps nothing. With Claude Code, then Codex, as the Fast tier, each new tab's run ends with no `claude`, `codex`, or `arch-mcp` process left, and Codex keeps no thread. With Tab Names also on, the warning appears, and Turn Off Tab Names switches it off.
73. Outside programs: with Allow Outside Clients on and a grant in the default Persona with Watch Browser Events, `arch-cli events --json` prints a line for opening a tab, its first load, an address change, a title change, a selection, a close, a finished download, and a space switch, with hosts and no titles; excluded sites have no host. `arch-cli hooks add` shows the sheet with the script, Don't Allow exits 3, Allow with Touch ID adds the hook, `hooks list` shows it, and `hooks remove` removes it. `arch-cli agent run --tab t1 --tier fast --tools rename_tab "…"` renames the client's agent tab. A `claude` with `arch-mcp` reads events with `watch_events`.
74. Shell scripts: with Allow Shell Scripts on, trusting a script with Touch ID copies it; the script receives the event on standard input and only the listed environment, and `arch-cli rename t1 …` inside it renames the event's tab. Changing the source file has no effect until Update from File…, the time limit ends a sleeping script, and `lsof -nP -p <Arch pid> -i` lists no listening port.

## Risks

1. A hook with page access sends signed-in pages' text to the model automatically. The editor says so, site exclusions apply, and agent hooks default to the title and address only.
2. A JavaScript hook script can copy an agent run's result into tab names, which `session.json` keeps in plain text and the user's other programs can read. Arch runs only scripts the user wrote, reviewed, or allowed. The seal keeps programs from adding one, and names are cut to 60 characters.
3. Effects without a cause can still chain, as when a page changes its title because a hook renamed its tab. Rate limits bound them.
4. A shell script runs with the user's rights and can do anything the user can. Arch ensures only that the text the user trusted is the text that runs.
5. A run on Claude Code or Codex starts a process for each event and uses the user's plan; many new tabs can use much of it. The editor's note, daily count, and concurrency cap limit this.
6. Hooks added by outside programs stay after their grants end, until the user removes them.
7. Watch IDs let a program with the events scope follow one tab's sites over time, so the scope asks for Touch ID.

## Open decisions

None needs the user's decision. The following remain for later features: storage for hook scripts, which none needs yet; run tools beyond the three, each with its own rule and record floor; Tab Names as an agent hook preset, which a plain request serves well today; and the `agent` permission for installed script plugins, whose install sheet would then state the grant.
