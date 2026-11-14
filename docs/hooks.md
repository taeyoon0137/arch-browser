# Hooks design

This note designs hooks for Arch, feature rows 66 to 68, 71, and 72. A hook runs a script when a browser event matches it, and the script can run an agent. Each part has one job, one interface, and its own tests, so a later feature can use one part without the others: browser events, the shared hook scheduler, model tiers, the hook registry, the script runner, the agent run API, the agent hook editor with the Tidy Tab Names preset, and the same parts for outside programs. Browser events, the shared hook scheduler, model tiers, the hook registry, and the JavaScript script runner with Settings ▸ AI ▸ Agent Hooks are built; tasks VII.27 to VII.32 in `docs/plan.md` build the rest, and VII.23.1, VII.24.1, VII.25.1, and VII.26.1 check the built parts from the bundle. The design builds on the AI interface (`docs/ai.md`), the plugin system (`docs/plugins.md`), and agents (`docs/agents.md`), whose rules apply unless this note says otherwise.

Terms: an "event" is a `BrowserEvent` delivered by the browser event bus. A "hook" is a trigger, a filter, and a script that Arch runs for each matching event. A "run" is one script handling one event. An "agent run" is one call of the agent run API: a prompt with a model choice, a record level, tools, and limits, run to completion without the user. An "agent hook" is a hook whose script the agent hook editor writes around one agent run.

## Purpose and principles

- One source of browser events serves every consumer: the AI hook center, hooks, plugins, and outside programs. Events carry identifiers, kinds, engines, reasons, and addresses, never page text, titles, or file paths (hook decision 2).
- One scheduler runs every hook: the AI hook center's hooks, plugin hooks, and the registry's hooks for one event run in one ordered chain per subject, under one set of rules for waiting, replacement, timeouts, cancellation, failure pauses, and budgets (hook decision 15).
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
| Browser events | `Events` (new) | Turns session changes into typed events and delivers them | `BrowserEventBus`, `BrowserEvent`, `BrowserEventFilter`, `BrowserEvent.view(_:)` | The AI hook center through `BrowserHooks`, the hook registry, plugins' events, outside subscribers | VII.23 (built) |
| Hook scheduler | `AI` | Runs each event's hooks one at a time per subject in one order, with waits, replacement, timeouts, cancellation, failure pauses, and budget checks | `AIHookScheduler`, `AIHookStep`, `AIHookStepOutcome` | The AI hook center, plugin hooks, the hook registry | VII.23 (built) |
| Model tiers | `AI` | Names models by tier (Fast, Standard, Deep) and lets a request carry its route | `AIModelTier`, `AIRouteChoice`, `AIFeatureRouting`, `AIService.resolvedModels(for:route:)` | Agent runs, `arch-cli agent run`, the agent composer's model menu | VII.24 (built) |
| Hook registry | `Hooks` (new) | Keeps hooks and matches events to them; runs their scripts as steps of the shared scheduler with limits, loop protection, and pausing; logs runs | `HookRegistry`, `Hook`, `HookStore`, `HookRunLog` | Settings ▸ AI ▸ Agent Hooks, the editor, `arch-cli hooks` | VII.25 (built) |
| Script runner | `Hooks`, on `Plugins`' script runtime | Runs one script for one event: JavaScript in the script plugin sandbox, or a shell script the user trusts | `HookScriptRunning`, `HookScriptRunner`, the script API | The hook registry | VII.26 (JavaScript, built), VII.31 |
| Agent run API | `Agent` | Runs one agent to completion for a caller, with a model choice, a record level, tools, and limits | `AgentRunner.run(_:)`, `arch.agent.run`, `agent/run`, `arch-cli agent run` | Hook scripts, the editor's Test, outside programs | VII.25 (its value types, built), VII.27 |
| Agent hook editor | `Preferences`, `Hooks` | Writes an agent hook: its situation, instructions, model, record, actions, limits, and script | Settings ▸ AI ▸ Agent Hooks, `AgentHookTemplate` | The user | VII.28 |
| Tidy Tab Names | `Hooks` | A preset agent hook | `HookPresets.tidyTabNames` | The editor | VII.29 |
| Outside programs | `AgentControl`, `ArchCLI`, `Agent`, `Hooks` | Events, hooks, agent runs, and renames for `arch-cli` and `arch-mcp` under grants | `events/*`, `hooks/*`, `agent/run`; the tools `watch_events` and `rename_tab`; `AgentHookRegistrar` | Scripts and agents outside Arch | VII.30 |

```
Browsing: BrowserEventSource ──post──▶ BrowserEventBus (Events)
   ├─▶ BrowserHooks ──AIHookEvent──▶ AIHookCenter (AI): Tab Names, Download Names ──steps──┐
   ├─▶ HookRegistry (Hooks) ──steps──────────────────────────────────────────────────────▶ AIHookScheduler (AI): one ordered chain per event
   │      └─ a step runs JavaScript in the plugin sandbox, or a trusted shell script
   │            └─▶ arch.agent.run, or arch-cli agent run ──▶ AgentRunner (Agent)
   ├─▶ PluginManager ──PluginEvent──▶ script plugins' arch.events.on
   └─▶ AgentService (Agent) ──events/event──▶ arch-cli events; watch_events ──▶ arch-mcp
AgentRunner ──▶ AIService (AI: tiers, routes, budgets, usage)
   ├─▶ API-key tool loop (VII.19) ──▶ AgentToolHost
   └─▶ AIAgentSession on claude or codex (VII.16, VII.17) ──▶ arch-mcp --session ──▶ AgentToolHost
```

`Package.swift` additions, by hand:

```swift
.library(name: "Events", targets: ["Events"]),
.library(name: "Hooks", targets: ["Hooks"]),

.target(name: "Events", dependencies: ["ARCHEngine", "AI", "AgentControl"], path: "Packages/ARCH/Sources/Events"),
// `Agent` and `AgentControl` give the agent run's values and the JSON values that keep a later build's members of `hooks.json`, and `Plugins` the script runtime.
.target(name: "Hooks", dependencies: ["Events", "AI", "Plugins", "Agent", "AgentControl"], path: "Packages/ARCH/Sources/Hooks"),
.testTarget(name: "EventsTests", dependencies: ["Events"], path: "Packages/ARCH/Tests/EventsTests"),
// `Fixtures` holds the hook scripts the runner tests run, and from VII.31 the shell scripts.
.testTarget(name: "HooksTests", dependencies: ["Hooks"], path: "Packages/ARCH/Tests/HooksTests", resources: [.copy("Fixtures")]),
```

- `Browsing` depends on `Events`. `Plugins` and `Agent` add `Events`, and `Browsing`, `Preferences`, and `Arch` add `Hooks`, with the tasks that use them. `AI` gains no dependency, and `ArchCLI` still depends on `AgentControl` alone: it prints events, hooks, and run results as JSON from Arch, as it does for tool results.
- The parts are separate modules because they serve different users: `Agent` and `Plugins` both need events and cannot depend on `Hooks`, which depends on both; the AI interface stays free of browser types.

## Decisions

Code comments and documents cite these as "hook decision 1" and so on.

1. One event bus. `BrowserEventBus` in the new `Events` module delivers every browser event, and `Browsing` posts them from one place, `BrowserEventSource`. The AI hook center keeps its `AIHookEvent`, which `BrowserHooks` makes from bus events, so `AI` keeps no dependencies and its hook tests stay unchanged. `Events` depends on `AI` only for `AISitePattern`, so site filters and site exclusions share one matcher, on `ARCHEngine` for `EngineKind`, and on `AgentControl` for `AgentAddress.reduced` and `AgentUntrusted`, so the outside view reduces addresses and marks names as agents' tools do.
2. Events carry no page content: identifiers, kinds, engines, reasons, and addresses only. A title or page text reaches a consumer only through a call its grant allows.
3. A hook's action is always a script. An agent hook is a hook whose script the editor writes; within a hook, only a script's call to the agent run API runs an agent.
4. Scripts are JavaScript in the script plugin sandbox by default. A shell script runs only after the user turns on Allow Shell Scripts and trusts the file with Touch ID or the login password. Arch then runs its own copy, checked by digest. Arch never writes, generates, or edits a shell script, and outside programs cannot add one.
5. Agent runs never ask the user. A call that would ask under agents' rules is refused with `wouldAsk`. A run works only on the tabs its caller may give it (hook decision 16) and calls only the tools its options name within its grant.
6. A run names a model or a tier (Fast, Standard, Deep) whose models the user assigns once in Settings ▸ AI ▸ Model Tiers. Tiers are routes in `ai.json`. An empty tier fails rather than falling back to another tier or the default route, since the user chose the tier for its cost.
7. Three record levels: Keep the Session, Keep Activity Only, and Keep Nothing (Record levels). No level writes a prompt, reply, title, page text, or address path to disk: Claude Code runs without session persistence and Codex with `--ephemeral` at every level, and Keep Nothing keeps only usage counters. Runs for outside programs keep at least the activity.
8. `hooks.json` is sealed like `agent.json`, with its own Keychain key, and holds each script's digest and the providers the user set up (Known providers). A program that edits Arch's files therefore cannot add a hook, change one's script, or send a hook's data to a provider it wrote into `ai.json`. A hook script can read signed-in pages through agent runs and write tab names, which `session.json` keeps. Allowing a program to add a hook by editing the file would let it read the user's signed-in pages through Arch; for the same reason, hooks that outside programs propose stay within what the proposing grant can read (Hooks from outside programs).
9. Loop protection by causes: every event caused by code names the hooks whose runs led to it. A hook never runs for its own runs' effects, and no hook runs for an event three hooks deep. Rate limits skip runs past their caps, and a `titleChanged` hook that keeps running for one tab pauses.
10. Outside programs may watch events under a grant scope and propose hooks. Each proposed hook takes effect only after the user allows it in Arch with Touch ID or the login password, reaches no more than the proposing grant can read, and pauses when that grant ends. This is the one exception to agents' rule that no command changes Arch's settings (`docs/agents.md`, What the agent can never change). The only other hook change a client can make is removing its own hooks.
11. `arch-mcp` offers events as a tool, `watch_events`, not as MCP notifications, because MCP clients do not pass a server's notifications to their model. It offers no hook tool or agent run tool, so a client that has only MCP can neither propose hooks nor start agent runs. A client with a shell can run `arch-cli hooks add` and `arch-cli agent run`, and a page can steer it to. The proposal sheet with Touch ID, the caps on outside programs' hooks, the record floor, and the grant's runs per day bound what that gains (Hooks from outside programs).
12. Tidy Tab Names runs on a new tab's first page load, not when the tab opens, since it has no title then and often no address.
13. Renames from code (AI hooks, plugins, hook scripts, and agents) set the tab's suggested name under the AI hooks' `renameTab` rules (`docs/ai.md`, Actions). Each rename names the document it belongs to: an AI hook's event address, a hook run's document for the tab (Run tabs), or, for plugins, sessions, and outside clients, the tab's address when the call arrives. It applies only while the tab still shows that document, ignoring the fragment, and is `stale` otherwise. The user's own name always wins, and a name the user rejects stays rejected for that address.
14. Site exclusions are an AI boundary. They keep events from hooks with the `agent` permission and from outside programs, keep the titles and addresses of tabs on excluded sites out of such hooks' tab lists, and the agent run API keeps tabs on excluded sites out of every run (rule P16). A hook without `agent`, which cannot reach a model, runs on every site its filter covers, as plugins do.
15. One scheduler. The AI hook center's scheduling becomes `AIHookScheduler`, which the center, plugin hooks, and the hook registry share: one event's hooks run in one ordered chain per kind and subject, under one set of rules for waits, replacement, timeouts, cancellation at a close or a new document, failure pauses, and budgets (The shared scheduler). It lives in `AI` because `AI` depends on nothing, so both the center and `Hooks` can use it. Plugins never register with the center.
16. A hook reaches only the tabs its filter covers in the event's Persona, never agent tabs: its script's tab calls and its agent runs accept no other tab (Run tabs). A hook from an outside program reaches only the event's own tab.

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
    /// The source tab's kind when the download started. It survives takeover and close.
    public var tabKind: BrowserTabKind?
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

/// The labels name each value, so the synthesized JSON reads `{"pageLoaded":{"tab":{…},"isRestore":false,"isFirstLoadAfterOpen":true}}`.
public enum BrowserEventPayload: Codable, Hashable, Sendable {
    case tabOpened(tab: BrowserTabRef, openerTabID: UUID?)
    case tabClosed(tab: BrowserTabRef, reason: BrowserTabCloseReason)
    /// `isFirstLoadAfterOpen`: the tab's first load with an `http` or `https` address since this launch's `tabOpened` for it.
    case pageLoaded(tab: BrowserTabRef, isRestore: Bool, isFirstLoadAfterOpen: Bool)
    case addressChanged(tab: BrowserTabRef, previousURL: URL?)
    case titleChanged(tab: BrowserTabRef, source: BrowserTitleSource)
    case tabSelected(tab: BrowserTabRef, windowID: UUID)
    case downloadFinished(download: BrowserDownloadRef)
    case spaceSwitched(windowID: UUID, spaceID: UUID, personaID: UUID, previousSpaceID: UUID?, previousPersonaID: UUID?)
}

public struct BrowserEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// One more than the previous event's in this launch; outside programs resume after it.
    public var sequence: UInt64
    public var date: Date
    public var payload: BrowserEventPayload
    /// What made the change, when code made it (Causes).
    public var cause: BrowserEventCause?

    public var kind: BrowserEventKind { get }
    /// The tab of a tab event; nil for downloads and space switches.
    public var tab: BrowserTabRef? { get }
    /// The tab, download, or window the event is about.
    public var subject: UUID { get }
    /// For `spaceSwitched`, the Persona of the space the window switched to.
    public var personaID: UUID { get }
    /// The tab's space, or for `spaceSwitched` the space the window switched to; nil for a favorite's tab and for downloads, which belong to their Persona only.
    public var spaceID: UUID? { get }
    /// The addresses that site filters and exclusions apply to: the tab's, or the download's source and page.
    public var urls: [URL] { get }
}
```

| Kind | Posted when | Subject | Posts nothing for |
|---|---|---|---|
| `tabOpened` | A tab joins the session after launch, from any source: the palette, a link, a page, another app, a favorite's first opening, a plugin, an agent, or a hook | Tab | Tabs restored from the saved session, pinned tabs that a browser import opened, tabs that move between spaces or windows |
| `tabClosed` | A tab leaves the session; posted while the session still lists it, so a consumer can read its last name and address during delivery (Closed tabs) | Tab | Tabs at quit |
| `pageLoaded` | The tab's main frame finishes loading a document while the tab has an address (`webContentsDidFinishLoadingDocument`) | Tab | Frames inside the page, navigations within the document |
| `addressChanged` | The tab's committed address changes, including within the document (`webContentsDidChangeURL`); an address reported while the page loads posts once the load or its document's load ends, with the address the tab then shows | Tab | A report that repeats the tab's address, an address the tab leaves before it commits, as WebKit reports for a navigation that fails or becomes a download |
| `titleChanged` | The tab row's name changes (`Tab.displayTitle`) while the tab shows its committed address; a change while its address waits to settle posts once it settles, if the name then differs, with the committed address | Tab | An input change that leaves the shown name unchanged, a name shown only while the tab is at an address it leaves before it commits |
| `tabSelected` | A window selects the tab | Tab | Selections that restore windows at launch |
| `downloadFinished` | A download entry's state becomes `completed` and its file exists | Download | Downloads that fail or are canceled |
| `spaceSwitched` | A window's current space changes; `previousPersonaID` differs when the Persona changes with it | Window | The first space of each window at launch |

Scope filters, Persona checks, and a hook script's Persona treat `spaceSwitched` as an event of the space the window switched to. A favorite's tab and a download belong to their Persona only, so only a whole Persona in a scope takes their events.

### The bus

```swift
@MainActor
public final class BrowserEventBus {
    /// Nonisolated, so that the session, which is not isolated yet, can make it with itself.
    public nonisolated init()
    /// The cause of the innermost enclosing `withCause` block, which code that starts a change finishing later keeps for its events.
    public var currentCause: BrowserEventCause? { get }
    /// Gives the event its identifier, sequence, date, and the cause of the enclosing `withCause` block when it has none, then delivers it to every subscriber whose filter matches, in subscription order, before returning. A post from a handler is delivered once the current event has reached every subscriber.
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

/// In JSON, `"everywhere"` or the list of places, each `{"persona": "<id>"}` or `{"space": "<id>"}`.
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
    /// Labeled, so the JSON reads `{"agentSession":{"id":"…"}}`.
    public enum Origin: Codable, Hashable, Sendable {
        case hookRun(hook: UUID, run: UUID)
        case agentSession(id: UUID)
        case outsideClient(grant: UUID)
        case plugin(id: String)
    }
    public var origin: Origin
    /// The hooks whose runs led to this change, oldest first, at most three.
    public var hookChain: [UUID]
}
```

- An immediate change from code, such as a rename, runs inside `withCause`, so its events carry the cause.
- A navigation or new tab started by code finishes later. The source keeps the cause on the tab (`Tab.pendingCause`) and attaches it to that tab's next `addressChanged` events and `pageLoaded`, which uses it up, and to the `tabOpened` of a tab opened by code inside `withCause`, which keeps it for its first load. Code that starts a navigation sets `pendingCause` to the bus's `currentCause`. The cause belongs to that one navigation: a load that ends without a `pageLoaded`, as one that fails or becomes a download, drops it once the rest of that update has run, since WebKit reports the end of a load just before its document's load. The user's own navigation in the tab from the app, from the address field, Home, Back, Forward, the History menu, Reload, the page's context menu, or the crash notice's Reload, clears it. A link the user follows in the page while code's navigation still loads keeps the cause, since Chromium does not report such a click.
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
- Window events for an outside program: `tabSelected` reaches a grant only for a tab of its Persona, and `spaceSwitched` only when the grant's Persona is on one side of the switch. Windows get handles per grant (`win1`, `win2`, …), as tabs and spaces do, and never their identifiers. A space of the grant's Persona appears as its space handle (`s1`); the other side of a switch between Personas appears as `"otherPersona": true` with no identifier, so the line says only that the window entered or left the grant's Persona.
- The registry adds `hook` for hook scripts (Script API); a plugin's event has none.

```swift
// Events
public struct BrowserEventScriptAccess {
    public var showsAddress: (URL) -> Bool
    public var showsDownloadDetails: Bool
    /// For a hook with `agent`, the AI interface's site check: an event with an address it refuses never reaches the hook, and a refused previous address stays out. nil for every other consumer.
    public var allowsAI: ((URL) -> Bool)?
    /// Addresses and download details with `tabs`.
    public static func hook(tabs: Bool, allowsAI: ((URL) -> Bool)?) -> Self
    /// Addresses with `tabs` or on the pages the granted sites cover, download details with `downloads`.
    public static func plugin(tabs: Bool, downloads: Bool, covers: @escaping (URL) -> Bool) -> Self
}

/// What an outside program's view needs from its grant. `Agent` implements it over the grant's handle tables (VII.30).
@MainActor
public protocol BrowserEventOutsideReader: AnyObject {
    var grantID: UUID { get }
    var personaID: UUID { get }
    /// `.own("t1")` or `.shared("t2")` by handle, or `.watched("w4")`, given on first use and never reused.
    func name(ofTab id: UUID) -> BrowserEventOutsideTab
    func handle(ofSpace id: UUID) -> String
    func handle(ofWindow id: UUID) -> String
    func allowsAI(on url: URL) -> Bool
}

extension BrowserEvent {
    /// `BrowserEventScriptView`, with camel-case keys such as `personaId`, or nil when the event does not reach the consumer.
    public func view(_ access: BrowserEventScriptAccess) -> BrowserEventScriptView?
    /// `BrowserEventOutsideView`, one line of the outside view, or nil when the event does not reach the grant.
    @MainActor public func view(_ reader: some BrowserEventOutsideReader) -> BrowserEventOutsideView?
}
```

- A tab's engine shows as `webkit` or `chromium` in both views, as `arch-cli` and the agent tools name it.
- An outside program's tab carries `handle` and the reduced `url`, or `watch` and the host as `site`, or `excluded: true` without either; an address change adds `previousUrl` or `previousSite` unless the previous address is excluded. A download carries the name as `<untrusted source="page">…</untrusted>`, the type, the size, the source's host, and the agent tab's handle, or `excluded: true` without the name and host. A space switch carries `window`, `to`, and `from`, each `{"space": "s1"}` or `{"otherPersona": true}`:

```json
{ "seq": 813, "kind": "spaceSwitched", "date": "2026-11-14T09:31:02Z", "window": "win1", "to": { "otherPersona": true }, "from": { "space": "s1" } }
```

### The source

`BrowserEventSource` in `Browsing` follows the session's tabs, favorites' tabs, small windows' tabs, windows, and downloads, as `BrowserHooks` now follows three kinds, and posts every kind.

- `tabClosed` comes from `BrowserSession.closeTab(_:remember:reason:)`, with `TabCloseReason` mapped case by case, and from deleting a Persona, whose tabs close as `spaceDeleted`; deleting a space moves its tabs instead. Closes by code pass their reason (`plugin`, `hook`, or `agent`) through `closeTab(_:remember:reason:eventReason:)`. The source posts it before the session removes the tab from its lists, so the tab's last name and address are still there while subscribers handle the event.
- `tabOpened` follows the session's tab lists and names the opening tab, which the session sets before a popup's tab joins its list. The tabs listed when the session attaches the source are the restored ones.
- `titleChanged` follows the inputs of `Tab.displayTitle` with the tab's committed address, and waits while the tab's address waits to settle, so a navigation the tab leaves before it commits posts no name for that address, and the page's title of a document that commits posts after its `addressChanged`. A suggested name that code gives while the address waits, which the tab takes for the document it still shows, keeps its cause, and the title change that names it posts with that cause once the address settles, so the hook or plugin that gave it still sees its own effect. Its source is the input that supplies the new name: `customTitle` set or cleared, or a hook's name that the user turns down (`user`); a hook's name in `suggestedTitle` (`suggested`); and otherwise the page's title or host (`page`), also when another address drops a hook's name.
- `addressChanged` follows `Tab.committedURL`, which takes the tab's address at once when it changes while the page is not loading. WebKit reports a navigation's address before it commits and goes back to the earlier one when the navigation fails, is stopped, or becomes a download, while Chromium reports an address only once it commits, so an address that changes while the page loads waits until the load ends or its document loads, and posts only when the tab then shows an address it has not posted. The tab drops a hook's name at the same point, so the name stays through such a navigation, and every event's `BrowserTabRef.url` is the committed address.
- `tabSelected` and `spaceSwitched` follow each `BrowserWindowModel`'s selected tab and `currentSpaceID`, with the window model's identifier as `windowID`. Reopening main windows from the saved session, or the last main window once none is open, runs inside `BrowserEventSource.restoringWindows(_:)`, so their selections and spaces, and what other windows give up for them, post nothing. A window's space when the source first sees it is no switch.
- `pageLoaded` keeps the current rules for `isRestore`: the first load of a restored tab and of a pinned tab opened by a browser import.
- A tab in an agent folder (`Tab.agentOwnerID`) posts with kind `agent`, also its `tabOpened`, since the session puts an agent's new tab and the popups its page opens in the folder before they join its list. A tab the user takes over, by dragging it out or with Keep Tabs, posts with its own kind from then on. Closes by the agents' code (`close_tab`, a popup past the agent tab limit, and a popup whose first address rule P16 refuses) give `agent`.
- Once both exist, the agents' tool host (VII.12) gets navigations, opened tabs, and downloads for its tool results' events from the bus, filtered to the session's agent tabs.

### The AI hook center

The center keeps `AIHookEvent`, its registrations, actions, and tests, and runs its hooks on the shared scheduler. `BrowserHooks` subscribes to the bus for `pageLoaded`, `tabOpened`, `downloadFinished`, `addressChanged`, and `tabClosed` on every tab kind except `agent`, and maps:

| Bus event | The center or its scheduler |
|---|---|
| `pageLoaded(tab, isRestore, _)` | `post(.pageLoaded(AIPageLoad(tabID: tab.id, url: …, isRestore: isRestore)), event: event.id)` with the tab's address, which a `pageLoaded` always has |
| `tabOpened(tab, _)` | `post(.tabOpened(AITabOpen(tabID: tab.id, url: tab.url)), event: event.id)` |
| `downloadFinished(download)` | `post(.downloadFinished(AIDownloadFinish(…)), event: event.id)`, with the file's URL from the session's entry, omitted from the bus event, and `AIDownloadInfo` from the event's name, type, size, and addresses |
| `addressChanged(tab, previousURL)` to another document, ignoring the fragment | `scheduler.cancel(subject: tab.id, otherThan: tab.url)` |
| `tabClosed(tab, _)` | `scheduler.cancel(subject: tab.id, except: event.id)` |

Removing a download from the list still calls `cancel(subject:)` directly. The center's ordering, actions, checks, and built-in hooks stay as `docs/ai.md` describes them. `BrowserHooks.events`, the filter it subscribes with, names no tab kinds, so agent tabs stay out, which also keeps Tab Names off them, as VII.12 requires. `attach(events:service:)` hosts the center of any `AIService`, which the tests use.

### The shared scheduler

The center's scheduling moves out of `AIHookCenter` into `AIHookScheduler`, in `AI` beside it (hook decision 15). The center owns it (`AIHookCenter.scheduler`), and the hook registry and the plugin managers post their steps to the same instance, so one event's hooks from every owner run in one chain.

```swift
// AI
@MainActor
public final class AIHookScheduler {
    /// Adds steps to the chain of `kind` and `subject`. Steps posted with the same `event` join one chain in ascending order, ties in posting order, whoever posts them; a post with another event replaces the chain, which starts after the old one stops. `document` is the event's address for page events, and `urls` are the addresses site exclusions apply to: a step with a feature whose event has an excluded address skips at once, and a post left without steps changes no chain. `causes` are the owners whose runs led to the event: an event that the running step's owner caused joins that chain after its waiting steps instead of replacing it (Loop protection).
    public func post(_ steps: [AIHookStep], kind: String, subject: UUID, event: UUID, document: URL?, urls: [URL] = [], causes: Set<String> = [])
    /// The subject went away: cancels its chains, except the chain of `event`, the close's own.
    public func cancel(subject: UUID, except event: UUID? = nil)
    /// The tab committed another document: cancels its chains that have a document other than this one, ignoring the fragment. Chains without a document stay.
    public func cancel(subject: UUID, otherThan document: URL?)
    /// The owner's hooks went away: its waiting steps skip, and its running steps stop.
    public func cancel(owner: String)
    /// Owners paused after consecutive authentication or provider errors, until resumed or a route of their steps changes.
    @Published public private(set) var pausedOwners: Set<String>
    public func resume(owner: String)
}

public struct AIHookStep: Sendable {
    /// What failure counts and pauses apply to: the feature ID for the center's hooks, `plugin.<id>` for plugin hooks, `hook.<hook id>` for the registry's.
    public var owner: String
    /// Built-in hooks 100, plugin hooks 200, the registry's hooks 1,000 plus their place in its list.
    public var order: Int
    /// The AI feature the step's requests use, whose checks the scheduler applies; nil for a script hook without `agent`.
    public var feature: AIFeatureID?
    /// The routes in `ai.json` that the step's requests resolve through, such as `hook.tabName` or `tier.fast`; a change to one resumes the owner.
    public var routes: Set<String>
    public var delay: Duration
    public var timeout: Duration
    /// The owner's own checks, run after the delay and before the step starts.
    public var mayRun: @MainActor @Sendable () -> Bool
    /// The step's work. It reports each AI request's end, nil for a reply, for the failure count.
    public var run: @Sendable (_ requestDidEnd: @escaping @MainActor @Sendable ((any Error)?) -> Void) async throws -> Void
    /// Gets the step's one end, before the chain's next step starts.
    public var didEnd: @MainActor @Sendable (AIHookStepOutcome) -> Void
}

/// Every posted step ends exactly once.
public enum AIHookStepOutcome: Sendable {
    case finished, failed(any Error), timedOut
    /// Canceled while it ran: its chain was replaced or canceled, its owner was canceled, or one of its routes changed, also after its work returned but before the scheduler took its end.
    case stopped
    /// It never started: `canceled`, `declinedByOwner`, `paused`, `excludedSite`, `unavailable`, or `budgetReached(AIBudget)`.
    case skipped(AIHookSkipReason)
}
```

- What moves from the center unchanged: chains per kind and subject; each step's delay measured from the event, with a newer event of the same kind and subject replacing the chain, waiting steps included; one step at a time in order; a canceled step's chain waiting for it to stop, never past its timeout, before the next chain starts; timeouts; cancellation at quit; and, for steps with an AI feature, the checks before the step starts and again after its delay: the owner is not paused, the feature is automatic, switched on, and has a usable model, it is within the daily limit for automatic requests and the monthly spending limit, and the event's addresses are not excluded from AI.
- Failure pause: three consecutive `authentication` or `providerUnavailable` request errors pause the owner, and any other end of a request resets its count. A change to one of the step's routes resumes it, as a changed route resumes the center's hooks now; for an agent hook this is the tier route its agent options name. Each owner keeps its other rules: the center its last errors, actions, and `appliedActions`; the registry its matching, loop protection, concurrency caps, daily counts, script failure pause, and run log.
- Order: one event's steps from every owner join one chain, so Tab Names runs before Tidy Tab Names on the same page load, and the name Tidy Tab Names gives wins.
- Documents: steps of `pageLoaded`, `addressChanged`, and `titleChanged` events carry the event's address. When a tab commits another document, `BrowserHooks` cancels the tab's chains for other documents, whose renames would no longer fit and whose page reads would read the wrong page.
- Closes: at `tabClosed`, the tab's other chains end, registry runs included, and the close's own chain runs.
- `AIHookCenter.post(_:)` keeps its signature and posts under a new event identifier, so the center's tests pass unchanged; `post(_:event:)` takes the bus event's identifier. `pausedFeatures` and `resume(_:)` read and resume the scheduler's owners. The center's kinds use the bus's kind names, so its steps join the chain of the bus event they come from. A center hook's `stop` skips the center's later hooks only; the center applies a hook's actions when its step ends finished and records a failure, a timeout, or a reached budget as the feature's last error. Ending a subscription cancels its feature's steps (`cancel(owner:)`).
- A route change cancels the running steps whose `routes` name it and resumes the owners whose latest steps with a feature name it.
- A `perRequest` feature (Model choice and tiers) has a usable model only with a route, and a step names its routes in `ai.json` but not its route choice, so the built check finds a `perRequest` feature unavailable. VII.25, whose `agentHook.<id>` features are the first `perRequest` steps, added `AIHookStep.route: AIRouteChoice?`, which the check passes to `AIService.isAvailable(_:route:)`; the center's features keep their stored routes and pass none.

### Plugins

Plugin events come from the bus (built with hook scripts, since both use `Plugin.handle(_:)` and `arch.events.on`). Each `PluginManager` subscribes for its Persona, without agent tabs, and an enabled plugin receives the kinds listed in its manifest's `events`, through the script view above with its grant's access, as the events arrive; what its listener throws goes nowhere. Plugin listeners run outside hook chains, so their calls carry no hook chain, and loop protection for them works by owner instead: a plugin never receives an event whose cause is its own (`plugin(id:)`), such as its rename's title change, and receives at most 10 events for one subject and 60 in all within a minute, the hooks' rate (`BrowserEventRateLimiter` in `Events`, which both use). Two plugins that rename a tab in answer to each other, or a plugin and a hook, therefore stop within the minute's cap, and the hook also pauses with `ranTooOften`. The plugin kinds are the bus's kinds, and later the plugin's own `settingChanged`, which is not built yet.

Plugin hooks take the same path. Once plugins have `ai`, a plugin with `ai` that declares hooks has its listeners for those kinds run as steps of the event's chain at order 200 under its feature `plugin.<id>`, so the scheduler applies that feature's checks and pause; it does not register with the center (hook decision 15). Other plugins' listeners get events as they arrive, outside any chain.

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
    case pageLoaded(loads: HookPageLoads, includesRestoredTabs: Bool)
    case addressChanged(changes: HookAddressChanges)
    /// `[.page]` by default, so names that code gives start nothing.
    case titleChanged(sources: Set<BrowserTitleSource>)
    case tabSelected
    case downloadFinished
    case spaceSwitched(personaChangesOnly: Bool)

    public var kind: BrowserEventKind { get }
    /// The trigger's options; the filter is checked apart. `previousDocument` is the tab's last loaded address, which `newAddress` compares, and `carriesFirstLoad` is the `firstAfterOpen` carry-over (Running, step 4).
    public func matches(_ event: BrowserEvent, previousDocument: URL? = nil, carriesFirstLoad: Bool = false) -> Bool
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
    /// The file the user trusted, copied to `Hooks/<hook id>/hook.sh` (Shell scripts); `source` is where the user keeps it, and `interpreter` the program its first line resolved to when the user trusted it.
    case shell(source: String, digest: String, interpreter: HookInterpreter)
}

public struct HookInterpreter: Codable, Hashable, Sendable {
    /// Absolute, with links resolved.
    public var path: String
    /// SHA-256 of the executable file.
    public var digest: String
}

public enum HookPermission: String, Codable, Hashable, Sendable, CaseIterable {
    /// Titles and addresses of the tabs the hook's filter covers in the event's Persona (Run tabs).
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
    /// 0 to 60 seconds; 1.5 seconds by default for `pageLoaded` and 1 second for `addressChanged` and `titleChanged`. A newer event of the same kind for the same subject during the wait replaces the waiting run (Running).
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
    /// `failures` covers three failed or timed-out runs in a row; `providerErrors` the scheduler's pause after three authentication or provider errors, which a change to the hook's tier route lifts; `scriptChanged` a shell hook's interpreter too; `grantEnded` an outside program's hook whose grant ended; `unknownProvider` a run that would reach a provider Arch did not see the user set up (Known providers).
    case user, failures, providerErrors, ranTooOften, stopAllAgents, placeDeleted, scriptChanged, shellScriptsOff, needsNewerArch, grantEnded, unknownProvider
}

public enum HookOrigin: Codable, Hashable, Sendable {
    case user
    case preset(String)
    /// Added with `arch-cli hooks add` after the user allowed it.
    case outsideClient(AgentClientIdentity.Key, name: String)
}

/// VII.30 adds the conformance to `AgentHookRegistrar`.
@MainActor
public final class HookRegistry: ObservableObject {
    @Published public private(set) var hooks: [Hook]
    /// Settings ▸ AI ▸ Agent Hooks ▸ Run Hooks. While it is off, no event reaches a hook.
    @Published public var runsHooks: Bool
    /// The last runs of each hook (Run log).
    @Published public private(set) var lastRuns: [UUID: [HookRunSummary]]
    /// Each hook's runs and failures today, in memory.
    @Published public private(set) var dayCounts: [UUID: HookDayCount]
    /// A file set aside, a key the Keychain did not give, a file from a newer Arch, or a change not written, for Settings.
    @Published public private(set) var notice: HookStoreNotice?
    /// Whether `hooks.json` has been read; until then no event reaches a hook and no change is accepted.
    @Published public private(set) var isReady: Bool
    public let log: HookRunLog

    /// The app's registry: `hooks.json` in `directory` and `AIService.shared`, whose hook scheduler the center's hooks run on too.
    public convenience init(directory: URL, bus: BrowserEventBus, host: any HookBrowserHost, javaScript: any HookScriptRunning, shell: any HookScriptRunning)
    /// The scheduler is `ai.hooks.scheduler`; the registry also registers its features with `ai` and reads its providers and site exclusions.
    public init(store: HookStore, bus: BrowserEventBus, ai: AIService, host: any HookBrowserHost,
                javaScript: any HookScriptRunning, shell: any HookScriptRunning, now: @escaping () -> Date = Date.init)
    /// Settings' Try Again after the Keychain did not give the key.
    public func retryLoading()
    public func add(_ hook: Hook, script: Data) throws
    /// Keeps the hook's origin, creation date, and state, which only `pause(_:)`, `resume(_:)`, and the registry's own pauses change.
    public func update(_ hook: Hook, script: Data?) throws
    public func remove(_ id: UUID)
    public func move(_ id: UUID, to index: Int)
    public func pause(_ id: UUID)
    public func resume(_ id: UUID)
    /// Stop All Agents: cancels running runs and pauses every hook with `agent` until the user resumes it.
    public func stopAgentHooks()
    /// Runs the hook once for the tab as if its event had happened: the editor's Test and a row's Run on Current Tab. Without `applying`, actions are reported, not applied. A close hook treats the tab as closed without closing it (Closed tabs). A tab the hook's filter does not cover, such as an agent tab, is not run.
    public func test(_ id: UUID, onTab tab: UUID, applying: Bool) async -> HookRunResult
}

/// The browser side the registry needs, which `Browsing` provides.
@MainActor
public protocol HookBrowserHost: AnyObject {
    /// Every Persona with its spaces, in the session's order, for filters and their names.
    var places: [HookPersonaPlaces] { get }
    /// The tab as the bus would describe it now, or nil once it is gone.
    func tab(_ id: UUID) -> BrowserTabRef?
    /// The Persona's open tabs in sidebar order, never agent tabs; a run's tabs are those its filter covers (Run tabs).
    func tabs(inPersona id: UUID) -> [BrowserTabRef]
    /// A listed tab's shown name and committed address, which while its `tabClosed` is delivered are the closing tab's last ones; nil once the tab is gone. The registry asks only at a close and for a test of a close hook.
    func closingTab(_ id: UUID) -> AgentRunClosedTab?
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

`HookInvocation` carries the hook, the event in its script view, the run's identifier and cause (the run, with the event's hook chain and the hook), its deadline, whether actions apply, the script's checked bytes, the run's tabs, the event's tab and its document, a close's closed tab, the known providers, and a callback for each AI request's end, which the scheduler's failure pause counts. `HookRunOutcome` is completed (with the actions applied or, in a test, proposed, and the run's agent use), failed (with a code and a sentence), timed out, or cancelled. `HookRunResult`, which `test(_:onTab:applying:)` returns, is the outcome or the sentence of a test that could not start. It also carries the event's Persona, and each run tab's document (Run tabs), which the registry sets as the run starts. The app gives the registry `HookScriptRunner` for JavaScript and, until VII.31, `UnavailableHookScriptRunner` for shell scripts, whose runs fail with `runnerMissing`.

What VII.25 decided while building the registry:

- The registry takes the AI service rather than the scheduler alone, since it also registers the hooks' features, reads site exclusions, and follows `AISettingsStore.providers`; the scheduler is the service's `hooks.scheduler`.
- `HookBrowserHost` gives each Persona's open tabs (`tabs(inPersona:)`), from which the registry takes the run's tabs with the filter applied to each tab as to an event about it.
- A hook with `agent` but without agent options, a script that names its own model in each call, posts its step without a feature, since the scheduler cannot check a `perRequest` feature without a route; its agent runs meet the AI interface's checks per request (VII.27).
- An empty tier, or another missing model, fails the run with the AI interface's sentence, which the row shows, and counts toward no failure pause, since no setting of the hook changes it.
- The daily counts, failure counts, and rate windows live in memory and start again at each launch, as Keep Nothing keeps them; agent runs' daily counts, which cost the user's plan, are kept in `ai-usage.json` by VII.27.
- A test runs at once, outside the scheduler and the counts, within the hook's timeout, and is logged with `test` at the first two record levels. It runs only on a tab the hook's filter covers, so it never passes an agent tab or a tab outside the hook's reach to the script (hook decision 16).
- `update(_:script:)` keeps the hook's state, as it keeps its origin and creation date, so an edit cannot lift a pause that Resume would refuse or that the scheduler holds.
- The scheduler's pause is the hook's `providerErrors`, kept in `hooks.json`, rather than `failures`: the scheduler holds its pauses in memory, so after a relaunch the registry itself resumes a hook paused so when the tier route its options name changes.
- A run that never got a slot before its timeout is logged as `dropped`, not as timed out, since its script never started.

### Triggers and filters

- A hook has one trigger and one filter. The editor shows the scope as "Persona / Space" entries, with a whole Persona shown alone, such as "Personal / Work" or "Personal".
- Hooks skip agent tabs and downloads that started in them, including downloads that finish after the user takes over or closes the tab.
- The filter is also the hook's reach: its script's tab calls and its agent runs accept only the tabs the filter covers in the event's Persona (hook decision 16, Run tabs).
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
    "knownProviders": [ { "id": "6F1C…", "destination": "https://api.example.com/v1" } ],
    "hooks": [
      {
        "id": "3B0D…",
        "name": "Tidy Tab Names",
        "trigger": { "pageLoaded": { "loads": "firstAfterOpen", "includesRestoredTabs": false } },
        "filter": { "scope": "everywhere", "sites": [], "exceptSites": [], "engines": [], "tabKinds": ["open", "pinned"] },
        "script": { "javaScript": { "digest": "sha256:…", "generated": true } },
        "grant": { "permissions": ["agent"],
                   "agent": { "tools": ["rename_tab"], "tabAccess": "title", "minimumRecord": "none", "maximumRecord": "none", "runsPerDay": 300,
                              "limits": { "timeout": 20, "rounds": 1, "toolCalls": 2 }, "returnsReply": true } },
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

- Seal: `HookStore` seals the file like `agent.json` (`docs/agents.md`, Sealed settings): an HMAC-SHA256 over the settings' JSON with sorted keys, including members unknown to this build, with a 32-byte key and the last write's generation in its own Keychain item, service `xyz.taeyoon.arch.hooks`. VII.25 made the seal reusable: `AgentSettingsFile`'s seal, generation record, and Keychain queue became `SealedSettingsFile` in `Agent`, which takes the file's address and a key store: `AgentKeychainSealKey` with the file's own Keychain service and account (account `hooks.json seal`). A sealed file's generation member stays out of the settings it reads, so `HookStore` keeps the other members as read. Both `agent.json` and `hooks.json` use it. Arch reads the key once per launch, only when the file exists or Arch first writes one, so a user without hooks sees no keychain prompt.
- A file is renamed `hooks.json.unreadable` if its seal does not match, it cannot be read, its key is missing from the Keychain, or its generation is below the item's. Arch starts with no hooks and says so in Settings ▸ AI ▸ Agent Hooks. If the Keychain does not give the key, Arch leaves the file unchanged and runs no hook for that launch, with Try Again.
- Scripts live in `~/Library/Application Support/Arch/Hooks/<hook id>/`, mode 0700, as `hook.js` or `hook.sh`, mode 0600. The sealed file holds each script's SHA-256 digest; a script whose bytes no longer match is not run, and its hook pauses with `scriptChanged` until the user reviews it in the editor.
- Versions: `version` starts at 1, and `HookStore.migrations` holds one step per later version. An earlier version is migrated in memory, step by step, and written at the next change after Arch copies it to `hooks-v<version>.json`. A later version is first copied to `hooks-v<version>.json` unless a copy is there already: once this build writes the file, it still says the later version, so a copy made at a later launch would hold this build's write instead of the newer Arch's file. Arch then reads what it knows and keeps unknown members and hooks unchanged in the sealed file. It lists a hook it cannot read as needing a newer Arch (`needsNewerArch`) and does not run it. In a later version's file, that includes a hook with a member this build does not know inside one of its values, such as one that narrows its filter or grant, since this build keeps only a hook's own unknown members and would drop the other at its next write.
- Arch writes the file at each change, as it does for `agent.json`. Removing a hook deletes its folder and unregisters its feature; usage totals stay under the feature's identifier.
- `knownProviders` lists the providers the user set up while Arch ran (Known providers).

### Running

1. Match. For each bus event while Run Hooks is on, the registry selects active hooks whose trigger and filter match, in list order, skipping one whose identifier appears in the event's `hookChain`.
2. Schedule. Each matching hook becomes a step of the event's chain in the shared scheduler, at order 1,000 plus its place in the list, with its delay and timeout; a hook with `agent` names its feature and the tier route its options use. A newer event of the same kind and subject replaces the chain, waiting runs included; one that arrives during a run cancels it and drops unapplied actions, and the new chain starts after the run stops, never later than the run's timeout. An event whose hook chain holds the running run's hook, its own effect, joins the chain after its waiting steps instead (Loop protection).
3. Order. One event's steps, the center's hooks and the registry's alike, run one at a time in order, so a later hook sees what an earlier one changed. Different subjects and kinds run independently.
4. Documents and closes. When a tab commits another document, its chains for earlier documents end, registry runs included; when that ends a `firstAfterOpen` run, the hook also matches the tab's next page load once, which `firstAfterOpen` alone would not, so a page that moves on during the run still gets its name. A tab's close ends its other chains, and the close's own chain runs (The shared scheduler).
5. Concurrency. At most 4 registry runs at once, at most 2 for one hook. A step waiting for a slot holds its chain, and waiting steps start in arrival order; beyond 100 waiting steps, the oldest is dropped and logged as `dropped`.
6. Checks before a run starts, after the delay: the hook is still active and within its daily count, which is checked again when the run gets its slot, since runs that waited for slots together all passed it before any of them ran; the subject still exists, except for `tabClosed`, whose subject is gone by design (Closed tabs); a `pageLoaded`, `addressChanged`, or `titleChanged` hook's tab still shows the event's address, ignoring the fragment; the site checks of Triggers and filters pass; and, for a hook with `agent`, the scheduler's checks for its feature pass.
7. Timeout. At the hook's timeout, the runner cancels the run, which ends `timedOut`.

### Closed tabs

- While a `tabClosed` event is delivered, `HookBrowserHost.closingTab(_:)` gives the tab's last shown name and committed address. The registry keeps them in memory with each queued close run, never on disk, and drops them when the run ends.
- A close run's script gets the event with the tab as it was in the script view; `arch.tabs.get` returns `null` for it, since it is gone.
- An agent run for a close gets the closed tab as data: the option `closedTab` with the event's tab identifier puts its last name and reduced address in the first message as an untrusted block without a handle, and no tool acts on it. The runner accepts `closedTab` only from a run of that close. The run's tabs, which it may read and rename, are open tabs its filter covers (Run tabs), such as the tabs left in the closed tab's space, which the editor's script passes.
- Test on Current Tab and Run on Current Tab run a close hook with the front window's selected tab as the closed tab, without closing it, and the rest of its space as the tabs left.

### Loop protection

- Own effects: a hook never runs for an event whose `hookChain` holds it, so a script that renames, opens, or navigates tabs never restarts itself through those changes. Such an event never stops the run either: when it has the kind and subject of the chain the run runs in, as a `titleChanged` hook's rename does, the other hooks' steps for it join that chain after its waiting steps, and the registry passes the event's hook chain as the scheduler's `causes` for this.
- Depth: an event whose chain holds three hooks reaches no hook, so two hooks that react to each other stop after three steps.
- Rate: a hook skips runs beyond 10 for one subject or 60 in all within a minute (`BrowserEventRateLimiter`, which plugin events use too) and logs them as `skipped` with `rateLimit`, one entry a minute, so a burst of selections or new tabs only thins its runs and a page that reloads itself does not fill the log. A `titleChanged` hook that would start more than 10 runs for one tab in a minute pauses with `ranTooOften` until the user resumes it, since a page that changes its own title after each rename keeps it running without a cause. Hook scripts and agent runs cannot load or navigate pages, so the other kinds have no such loop.
- `titleChanged` hooks react to page titles only unless the user picks other sources.
- The daily count skips runs past the hook's `runsPerDay` until the next day, logs one `dailyLimit` entry that day, and its row says so.

### Pausing

- A hook pauses when the user pauses it; after three consecutive failed or timed-out runs (`failures`); when the scheduler pauses its owner after three consecutive `authentication` or `providerUnavailable` errors (`providerErrors`), which a change to the tier route its options name resumes, also after a relaunch; with `ranTooOften`; at Stop All Agents for every hook with `agent`; when its scope is deleted, its script or a shell hook's interpreter changes outside Arch, shell scripts are switched off, or it needs a newer Arch; when the grant of the outside program that added it ends (`grantEnded`); and when a run would reach a provider Arch did not see the user set up (`unknownProvider`).
- Resume clears the counts. A paused hook keeps its place and settings, and its row shows why with Resume or Review.
- Turning Run Hooks off stops every hook without changing their states.

### Run log

`~/Library/Application Support/Arch/hooks-activity.json` keeps runs for 30 days, at most the latest 10,000 entries, with Clear Activity in Settings. Arch writes it only after an entry or Clear Activity changes it, so a launch without runs leaves no file. A file that cannot be decoded is renamed `hooks-activity.json.unreadable`, as in other stores.

```json
{ "id": "…", "date": "2026-11-14T09:30:14Z", "hook": "3B0D…", "event": "pageLoaded", "subject": "open", "site": "example.org",
  "persona": "D59D…", "outcome": "completed", "duration": 1.8, "actions": { "renameTab": 1 },
  "agent": { "provider": "6F1C…", "model": "model-a", "inputTokens": 310, "outputTokens": 12 }, "test": false }
```

- Outcomes: `completed`, `failed` with a code, `timedOut`, `cancelled`, and `skipped` with `loop`, `rateLimit`, `dailyLimit`, `budget`, or `dropped`. A hook past a limit logs one skip for it a minute, `rateLimit` and `budget`, or a day, `dailyLimit`.
- Entries never hold page text, titles, assigned names, prompts, replies, script output, or an address's path or query. The site is the page's registrable domain, as in the agents' log (`AgentActivityEntry.site(of:)`).
- The hook's `record` decides: Keep the Session and Keep Activity Only log every run; Keep Nothing logs none. `lastRuns` keeps the last 20 runs in memory for Settings, from the log at the first two levels. For Keep Nothing it keeps only the day's run count, failure count, and last run's time and outcome.
- Events matching no hook's filter are not logged.

## Script runner

### JavaScript scripts

- A JavaScript hook script uses `Plugins`' unchanged script runtime: a `ScriptPlugin` instance with its hidden web view, `PluginSchemeHandler`, content security policy, rule list, Lockdown Mode, non-persistent data store, and bridge (`docs/plugins.md`, Sandboxing). The runner makes a package in memory: the manifest's identifier `xyz.taeyoon.arch.hook.<hook id>`, the hook's name, the plugin permissions of its grant's (`tabs` and `tabs.rename`; `agent` maps to one once VII.27 adds it), `events` with the trigger's kind, and `hook.js` as the background script, which the scheme handler serves from the checked bytes the package holds. `Plugins` makes `ScriptPlugin` and the package initializer public for this. The plugin manager takes no part. Hook scripts are not plugins in Settings ▸ Plugins and have no storage, secrets, settings, network, clipboard, or notifications.
- `HookScriptContext` in `Hooks` is the script's `PluginContext`, bound to the event's Persona with the hook's grant and the run's tabs (Run tabs). Every action carries the run's cause and honors its test flag. Storage and secrets are empty and read-only.
- The script is a classic script of at most 256 KB and must parse. `JSCheckScriptSyntax` checks it without running it, as the composer checks plugins AI writes. It calls `arch.events.on(kind, listener)` when it loads; the run ends when the listener's promise settles. A rejected promise or thrown error fails the run with the error's message. Its first 200 characters stay in memory for the hook's last runs.
- Instances: at most 2 per hook and Persona, each handling one run at a time. Every call an instance makes belongs to its current run. An instance stops after 30 seconds without a run. The hook's timeout replaces the plugins' 10-second hang rule: a timeout ends the instance.

What VII.26 decided while building the runner:

- The package holds the checked bytes in memory, and the scheme handler serves `hook.js` from there rather than from the hook's folder (`PluginPackage.init(manifest:background:source:rootURL:)`), so a change to the file between the registry's digest check and the load cannot run.
- A test that comes while both of a hook's instances run, which the registry's caps never allow for scheduled runs, gets an instance that ends with its run instead of waiting.
- An instance belongs to its hook's script, name, trigger kind, permissions, and timeout; a change to any of them ends the old instances once their runs end.
- The runner's own watchdog ends a run at its deadline as `timedOut`, beside the scheduler's cancel, and the script plugin's hang limit, the hook's timeout and a second, only backs it up; a cancel ends the instance too.
- `Plugin.handle(_:)` throws, so a hook run fails with a listener's error, and the plugin manager ignores what a plugin's throws. The bridge's delivery function catches what a listener throws and returns it as JSON, `{"error": text}`, or `{"noListener": true}` for a script that set no listener for the kind, and `ScriptPlugin.handle(_:)` throws them as `PluginError.listenerFailed(text)` and `PluginError.noListener`, so the runner reads only these public errors and no WebKit exception details. The text is an error's message, after its name unless it is a plain `Error` (`TypeError: …`), or the thrown value as text. The codes: a listener's error fails the run with `scriptError` and that text; a script without a listener for the run's kind with `noListener`; a load that fails with `loadFailed`; an instance whose web content process ends, or whose document does not finish loading within the hang limit, with `stopped`; and a script that is too large, not UTF-8, or does not parse with `invalidScript`.
- The runner holds the instance it picks for a run (`ScriptPlugin.isHeld`) until the run ends, so the instance's idle stop, which may come due as the runner picks it, cannot end it before the event reaches it.
- `arch.events.on` may set several listeners for a kind, which run one after another; one for a kind the manifest does not list never runs. The event's dates are ISO 8601.
- The registry gives every run tab its document as the run starts, so the script context, and later the agent runner, bind renames alike. `BrowserHookHost` describes tabs as events do, by their committed addresses, so a WebKit tab whose navigation has not committed keeps the document it shows, for renames and for site exclusions alike. `rename(id)` without a name, or with `null`, removes a suggested name for that document, keeps a name the user turned down, and is not listed among the run's actions.
- For a hook with `agent`, a tab's title and address stay out when its shown address or its committed document is on a site excluded from AI, since a tab that leaves such a page shows that page's title until the next one commits.
- Storage and secrets refuse writes with `quotaExceeded`, `ui.copy` throws `permissionDenied`, and badges do nothing. `agent` maps to no plugin permission until VII.27 adds `PluginPermission.agent` with `runAgent(_:)`.
- A tab the script does not reach is refused with `PluginError.notGranted`, whose bridge name is `notGranted`. Tab objects name the engine as plugin tabs do (`webKit` or `chromium`), and events as their views do (`webkit` or `chromium`).

### The script API

| JavaScript | Needs | Does |
|---|---|---|
| `arch.events.on(kind, (event) => …)` | — | Receives the hook's events: the script view with `hook: {id, name, agent}` |
| `arch.tabs.get(id)` | — | `{id, spaceId, kind, engine, isPinned, isSelected}`, with `title` and `url` under `tabs`, for a tab the hook reaches (Run tabs), otherwise `null`; for a hook with `agent`, a tab on a site excluded from AI has no `title` or `url` (hook decision 14) |
| `arch.tabs.list()` | — | The tabs the hook reaches, in sidebar order, in the same form |
| `arch.tabs.rename(id, name)` | `tabs.rename` | Sets the suggested name of a tab the hook reaches under hook decision 13, with the name's first line trimmed and cut to 60 characters. The name belongs to the run's document for the tab; it resolves `true` when the tab takes it and `false` when the user's name or refusal prevents it or the tab no longer shows that document. `null` clears the suggested name |
| `arch.agent.run(options)` | `agent` | An agent run (Agent run API); resolves with its result, without `reply` for an outside program's hook |

- These names match the plugin JavaScript API (`docs/plugins.md`, JavaScript API for script plugins). The same `PluginContext` members serve both: `tabs()`, `tab(_:)`, `renameTab(_:to:)`, and `runAgent(_:)`, which the context passes to the agent runner. `PluginBrowserHost` in `Plugins`, implemented by `Browsing`, reaches the tabs: its tab list never includes agent tabs, and its `renameTab(_:to:showing:)` takes the address the name belongs to, which the hook context sets to the run's document and plugins to the tab's address when the call arrives.
- In a test run, `rename` and the agent's `rename_tab` report what they would do and change nothing.

The editor's script for Tidy Tab Names:

```js
// Arch wrote this script for the agent hook "Tidy Tab Names".
// Its instructions, model, record, actions, and limits are in event.hook.agent, which Settings ▸ AI ▸ Agent Hooks edits.
arch.events.on("pageLoaded", async (event) => {
  await arch.agent.run({ ...event.hook.agent, tabs: [event.tab.id] });
});
```

The template for "A tab closes" passes the closed tab as data and the tabs left in its space as the run's tabs:

```js
arch.events.on("tabClosed", async (event) => {
  const left = (await arch.tabs.list()).filter((tab) => tab.spaceId === event.tab.spaceId);
  await arch.agent.run({ ...event.hook.agent, closedTab: event.tab.id, tabs: left.map((tab) => tab.id) });
});
```

### Shell scripts

- Settings ▸ AI ▸ Agent Hooks ▸ Allow Shell Scripts is off by default. Turning it off pauses every shell hook with `shellScriptsOff`.
- New Script Hook… ▸ Shell Script ▸ Choose File… opens `NSOpenPanel`. Arch shows the file's full text, its interpreter's resolved path, and what the script receives, and says: "Commands this script runs by name come from your PATH, and each of them gets this hook's access to Arch." After Touch ID or the login password, Arch trusts the file, copies it into the hook's folder as `hook.sh`, and records its SHA-256 digest and its interpreter in `hooks.json`. Update from File… does the same for a changed file and marks the changed lines. Arch runs only its own copy.
- The file is a regular UTF-8 file of at most 1 MB. Its first line is `#!` with an absolute path to an executable, or `/usr/bin/env` and one program name.
- Interpreter: at trust time Arch resolves the first line to an absolute path, looking a `/usr/bin/env` program up in the PATH the script will get and following links, and records the path and the SHA-256 of the executable (`HookInterpreter`). Before each run it checks both and starts that path itself, never through `env`. A changed interpreter, as after an update or a replaced file, pauses the hook with `scriptChanged`, whose Review shows the interpreter's path and asks for Touch ID again. Arch does not refuse interpreters in folders the user can write to, since package managers install there; the sheet names such a folder.
- With `agent`, a shell hook's runs get tab access `title` unless the user also checks Let Agent Runs Read Pages on the trust sheet, which is off by default and states that the script and every command it runs can then read the event's page through agent runs.
- Running: Arch reads its copy, checks the digest and the interpreter, and starts the interpreter with `posix_spawn` in its own process group, as `CommandLineProcess` starts command-line tools. It pipes the checked bytes to the interpreter as descriptor 3 and passes `/dev/fd/3` as the script's path, so what runs is what Arch checked. Standard input carries the event as JSON in the script view with `tab.handle` (`t1`) for `arch-cli`, then closes.
- Environment, with nothing else from Arch's: `PATH` (the bundle's `Contents/Helpers`, then the login shell's PATH as `LoginShell` reads it), `HOME`, `LANG`, `TMPDIR` set to the run's working folder, `ARCH_HOOK_ID`, `ARCH_HOOK_EVENT` (the kind), and `ARCH_HOOK_TICKET`.
- The working folder is `Arch-Hook-<run id>/` in Arch's temporary folder, mode 0700, removed after the run.
- At the hook's timeout, Arch sends `SIGTERM` to the process group and `SIGKILL` 2 seconds later. Standard output is read and dropped. The last 4 KB of standard error stay in memory for the hook's last runs at Keep the Session or Keep Activity Only, never on disk. Exit status 0 completes the run; any other status fails it.
- Acting: `arch-cli` presents `ARCH_HOOK_TICKET` in `hello`. Arch binds the connection to the run when the ticket matches in a constant-time comparison and the script's process is an ancestor of the peer, following the rule for in-app sessions' tickets (`docs/agents.md`, In-app sessions: tickets). The bound connection has the hook's grant, the event's tab as `t1` and the run's other tabs as further handles (Run tabs), and the commands `rename`, `tabs`, and `agent run`. The socket listens while a shell hook runs, as for an in-app session on a CLI.
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
    /// A close hook's closed tab, given to the agent as data (Closed tabs).
    public var closedTab: UUID?
    /// Report the actions instead of applying them, for Test and `--dry-run`.
    public var dryRun: Bool
}

/// What a caller's runs may ask for: a hook's grant, or an outside client's (arch-cli agent run and rename).
public struct AgentRunGrant: Codable, Hashable, Sendable {
    public var tools: Set<String>
    public var tabAccess: AgentRunTabAccess
    /// `activity` for outside programs, so every run and tool call is logged; `none` otherwise.
    public var minimumRecord: AgentRunRecord
    public var maximumRecord: AgentRunRecord
    /// 200 by default, 1 to 2,000.
    public var runsPerDay: Int
    public var limits: AgentRunLimits
    /// false for an outside program's hook, whose script then gets no `reply` (Hooks from outside programs).
    public var returnsReply: Bool
}

public enum AgentRunOrigin: Hashable, Sendable {
    case hook(UUID, run: UUID)
    case test(hook: UUID)
    case outsideClient(grant: UUID)
}

/// Who wrote the prompt, which the first message names.
public enum AgentRunPromptSource: Hashable, Sendable {
    /// A hook the user made or a preset: "The user's instructions".
    case user
    /// An outside program's hook or `arch-cli agent run`: "Instructions from <name>, a program the user allowed".
    case program(name: String)
}

public struct AgentRunRequest: Sendable {
    public var options: AgentRunOptions
    /// The tabs the run reads and renames (Run tabs).
    public var tabs: [UUID]
    /// For a hook, the tabs it reaches, which `tabs` must stay within; nil for an outside client.
    public var allowedTabs: Set<UUID>?
    /// The document each run tab's renames belong to; the event's address for the event's tab, and the runner adds the others' addresses as it writes the first message.
    public var documents: [UUID: URL]
    /// A close run's closed tab, from the registry.
    public var closedTab: AgentRunClosedTab?
    /// For a hook, the providers in `knownProviders`; a route that resolves to another provider is refused (Known providers).
    public var knownProviders: [AIProviderID: String]?
    public var origin: AgentRunOrigin
    public var promptSource: AgentRunPromptSource
    /// `agentHook.<hook id>` or `agentRun`.
    public var feature: AIFeatureID
    public var grant: AgentRunGrant
}

/// A closed tab's last shown name and committed address, kept in memory for its close runs.
public struct AgentRunClosedTab: Sendable {
    public var name: String
    public var url: URL?
}

public struct AgentRunResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case completed, failed, timedOut, cancelled, refused }
    public var status: Status
    /// The AI error, or the refusal's rule, such as `wouldAsk`, `notGranted`, or `unknownProvider`.
    public var code: String?
    public var message: String?
    /// Applied, or proposed in a dry run.
    public var actions: [AgentRunAction]
    /// The agent's last text, for the caller only; nil when the grant returns no reply.
    public var reply: String?
    public var model: AIModelRef?
    public var usage: AIUsage
    /// Set with Keep the Session: the kept run in memory.
    public var keptRun: UUID?
}

/// In JSON, `{"renamedTab": {"tab": …, "name": …}}`.
public enum AgentRunAction: Codable, Hashable, Sendable {
    case renamedTab(tab: UUID, name: String)
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
- Before a run starts, the runner checks the options against the grant: tools within its tools, tab access at most its own, the record between its minimum and maximum, and limits at most its ceilings. A call that asks for more is `refused` with `notGranted` and a sentence naming the field. Each tab must be in `allowedTabs` when the request sets it and exist in the caller's Persona. A tab on a site excluded from AI is left out of the run, and the run is refused (P16) when that leaves it no tab and no closed tab, so a close run over a space's tabs skips an excluded one. `closedTab` must be the close of the run's own event. The daily run count comes next, then the route, which for a hook must resolve to a known provider.
- In JavaScript and on the wire, options are JSON: `{"prompt": …, "tabAccess": "title", "model": {"tier": "fast"} or {"models": [{"provider": …, "model": …}]}, "record": "none", "tools": ["rename_tab"], "limits": {"timeout": 20, "rounds": 1, "toolCalls": 2}, "tabs": [<tab id>], "closedTab": <tab id>, "dryRun": false}`, with durations in seconds. Omitted fields use the grant's values for tools and tab access and the defaults above for the rest; `prompt` and `model` are required. `AgentRunOptions`' own decoding, which `hooks.json` uses, requires `tabAccess` and `tools` too, so the script API and `agent/run` fill them from the grant before decoding (VII.27).

Saving agent options already checks the grant, prompt, tool access, record level, and run limits. The API-key runner checks those limits, its caller and tabs, and the provider destinations before reserving one daily run in the usage store. It supports title data, document-bound `rename_tab`, and `read_text` with page access. The CLI hook runner uses the same checks and tools on one ephemeral turn. It requires its own process-bound ticket for tool calls and closes the connection after the turn. A route may contain HTTP models or CLI presets, with fallback within that transport. The script binding, page outlines, and activity entries for individual tool calls are pending.

### Run tabs

- A hook's run tabs are the open tabs its filter covers in the event's Persona, never agent tabs and never another Persona's (hook decision 16). The registry gives each run the set as `allowedTabs`; `HookScriptContext` limits `arch.tabs` and `rename` to it, the shell hook's connection lists only it, and the runner refuses any other tab with `notGranted`. A hook from an outside program reaches only the event's tab.
- The event's tab is the tab of a tab event, the download's tab for `downloadFinished` while it is open, and none for `spaceSwitched` and for `tabClosed`, whose tab is gone (Closed tabs).
- Each run tab's renames belong to one document: for the event's tab of a `pageLoaded`, `addressChanged`, or `titleChanged` event, the event's address; for any other run tab, the tab's committed address when the run starts, which the first message shows. `rename_tab` and `arch.tabs.rename` apply only while the tab still shows that document, ignoring the fragment; otherwise `rename_tab` returns `stale` and `arch.tabs.rename` resolves `false`. A tab without a committed address takes no name from a run.
- An outside client's runs use its own agent tabs and the tabs shared with it (arch-cli agent run and rename).

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
// AIRequest
/// false leaves the request's Activity entry without content, so Show Content has nothing to show. true by default.
public var recordsContent: Bool
// AINotConfiguredReason
case emptyTier(AIModelTier)
// AIFeatureID: a tier's route in `ai.json`, which is not a feature
public static func tier(_ tier: AIModelTier) -> AIFeatureID
// AIService
/// The models a request with `route` would try, in order, after Routing's step 3 without its page data rule.
public func resolvedModels(for id: AIFeatureID, route: AIRouteChoice? = nil) throws -> [AIModelRef]
public func isAvailable(_ id: AIFeatureID, route: AIRouteChoice? = nil) -> Bool
```

- Tiers are routes in `ai.json` under `tier.fast`, `tier.standard`, and `tier.deep`, each with a model and up to two fallbacks. Their `isEnabled` is written true and not read, so a hand-written tier may leave it out. Settings ▸ AI ▸ Model Tiers edits them with the Features rows' model menus, explains each tier's purpose in a sentence that names no feature, says that the features under Features use the models chosen there, and starts empty. A tier lists any connected model; requirements drop unsuitable models when a request resolves it.
- Resolution: a `perRequest` feature takes the request's route and throws `notConfigured(.noModel)` without one. A `stored` feature with trigger `user` may use a request's route instead of its stored one, as the agent composer's model menu and `arch-cli agent run --tier` do. A `stored` automatic feature refuses one with `blockedByPolicy(.routeNotAllowed)`, so Tab Names keeps its own route; its sentence, "This feature uses the models chosen for it in Settings ▸ AI, so a request cannot name its own.", blames no provider, and it offers no action, since neither a retry nor a setting changes it. A tier resolves to its route's models; an empty tier throws `notConfigured(.emptyTier(_:))`, whose action is "Assign a model to the Fast tier in Settings ▸ AI." with Open AI Settings. Step 3 of Routing (`docs/ai.md`) then drops models without a required capability, and fallbacks follow the tier's list as for any route.
- A stored automatic feature refuses a request's route before its switch is read, so the refusal does not depend on the switch. A route that lists no model throws `notConfigured(.noModel)`; one that lists more than three keeps the first three.
- `AIAgentSessionRequest.route` applies when the request names no `model`, which stays the way to pin one model. A pinned model resolves as a route of that one model, so a stored automatic feature refuses it with `routeNotAllowed` and a stored feature's switch applies to it. A CLI session makes no Activity entry, so `recordsContent` is on `AIRequest` alone, which an API-key session's rounds use; a CLI session's transcript stays with its owner in memory.
- `resolvedModels(for:route:)` tells a caller which models a choice reaches before any request, as the runner needs to pick the API-key loop or a CLI session and to check known providers; `isAvailable(_:route:)` answers the same question as a Boolean, and a `perRequest` feature is available only with a route.
- Budgets, rate limits, part checks, and usage apply as for every request. A `perRequest` automatic feature counts toward the daily limit for automatic requests and the monthly spending limit, on a CLI session too: each turn of an automatic feature's session is checked against both limits, counts as one automatic request, and waits behind the user's requests for a provider slot.
- Features: `agentHook.<hook id>` for each hook with `agent`, automatic and `perRequest`, named after the hook, requiring `agent`, with data `page` limited to 0 characters of text for tab access `title` and to the model's limit for `page`; and `agentRun`, "Agent Runs from Programs", automatic and `perRequest`, for runs started by outside programs.
- A run with tab access `title` sends the title and address as a page part without text, so the service's site exclusions and query removal apply on API-key models. CLI runs receive them in the first message after the runner's exclusion check and address reduction, as the tool host checks page data it passes to CLI sessions.

### Known providers

The API interface checks each hook's approved provider destination again after waiting for a slot. For HTTP it checks after the Keychain read and before dispatch. For a CLI it checks before sign-in checks and again before handing the tool a message. A changed destination refuses the run before sending page data.

`ai.json` is not sealed, so a program could add a provider with its own address, or change an existing provider's address, and point a tier at it; every hook on that tier would then send its titles and page text there. Hooks therefore use only providers Arch saw the user set up.

- `hooks.json` keeps `knownProviders`: each provider's identifier and destination (`AgentRunRequest.destination(of:)`): an HTTP provider's base address, since its headers and format cannot send requests to another host, or a command-line tool's executable path followed by the SHA-256 of its preset, arguments, and environment, since a variable such as one that names another server or a proxy, or another argument, can send the tool's requests elsewhere. The registry follows `AISettingsStore.providers` while Arch runs and records each provider the user adds or changes in Settings ▸ AI ▸ Providers. When Arch first writes `hooks.json`, it records the providers `ai.json` holds then.
- `AISettingsStore` reads `ai.json` only at launch, so a provider or destination that first appears at a later launch came from an edit outside Arch. A hook's run that resolves to it is refused with `unknownProvider` before any request, and the hook pauses with `unknownProvider`. Its row says "Its model is now \<provider> at \<destination>, which was not set up in Arch." with Review; Allow records the provider and resumes the hook.
- Outside clients' runs (`agentRun`) skip the check, since their results go to the client that asked anyway.

### Record levels

| Level | Transcript | Run log and agent activity | AI Activity in memory | Usage |
|---|---|---|---|---|
| Keep the Session (`session`) | The prompt, agent's replies, and tool steps kept in memory as a kept run until the user deletes it or Arch quits; at most 20 per hook or grant | An entry per run in `hooks-activity.json`, or in `agent-activity.json` for an outside client's run, and one per tool call in `agent-activity.json`, as for any agent | With content | Counted |
| Keep Activity Only (`activity`) | None: dropped when the run ends | As above | Without content | Counted |
| Keep Nothing (`none`) | None | None | Without content | Counted: the totals in `ai-usage.json` and the day's run count only |

- AI Activity applies to API-key runs, whose rounds are requests of the AI interface with `recordsContent` true only at Keep the Session. A CLI run makes no Activity entry at any level, as no CLI session does (Model choice and tiers); its usage counts all the same.
- No level writes a prompt, reply, title, page text, or address path to disk; kept runs stay in memory, as agent sessions' transcripts do (`docs/agents.md`, Storage). Claude Code runs with `--no-session-persistence` and Codex with `--ephemeral` at every level, so neither tool keeps the run, and a kept run's transcript is Arch's copy in memory. Runs never resume, so no level needs the tool's own thread.
- Keep Nothing is allowed only for hooks the user made in Arch, and only when every tool the run may call reads or changes no more than a tab's name: the read tools and `rename_tab` today. A later tool that opens or closes tabs or acts in a page raises the lowest level to Keep Activity Only, so the agent activity log keeps each such step.
- Runs for outside programs, their hooks and outside clients' `agent run`, keep at least Keep Activity Only (`AgentRunGrant.minimumRecord`), so each such run and each of its tool calls is logged as the client's own calls are.
- The caller gets the result in memory at every level.

### Tools

| Tool | Tab access | What a run may do with it |
|---|---|---|
| `rename_tab` | `title` or `page` | Name one of the run's tabs |
| `read_text` | `page` | Read a run tab's text, paged, within agents' limits |
| `snapshot` | `page` | Read a run tab's outline; refs serve reading only, since a run has no interaction tool |

- Runs get no other tool: no navigation, interaction, approval, question, hand-over, history, or download tool, and no `guide`; the run's instructions are short and fixed.
- A run has none of the agents' modes. Its tools and tabs define its reach. An outside client's run also stays within its grant's level, and no step asks (hook decision 5).
- `rename_tab` joins the catalog in `AgentControl`: input `tab` and `name` (1 to 60 characters after taking and trimming the first line; an empty name clears a suggested name), output the name the row shows and whether it applied, class N, `refused` with `userNamed` when the user's name or refusal keeps the tab's name, and `stale` when the tab no longer shows the document the name belongs to (hook decision 13). The model never gives the address; the host binds it.
- Rule P19, renaming a tab: in-app sessions and outside clients may rename their own agent tabs freely, a tab the user shared after asking once per tab, and no other tab. A run (client kind `run`) reads and renames its run tabs without asking, within its grant: for a hook, the tabs its filter covers (Run tabs); for an outside client's run, its own agent tabs and the tabs shared with it, so renaming a shared tab that the user has not allowed once would ask and is refused with `wouldAsk`.
- `AgentPolicy` gains the client kind `run`: rules that ask become `refused` with `wouldAsk`, P16 refuses as for every client, P17 limits the run to its run tabs, and P19 applies as above.
- Arch writes the first message: who the run works for; the prompt under "The user's instructions" for a hook the user made, or under "Instructions from \<name>, a program the user allowed" for an outside program's hook or run (`promptSource`), so the model does not take a program's words for the user's; each run tab with its handle (`t1`, …) and its title and reduced address as an untrusted block (`AgentUntrusted`); a close run's closed tab as an untrusted block without a handle; the tools; and "Finish without asking; nobody will answer." The instructions are `AgentHarness.runInstructions`, a short fixed text in `AgentHarness.swift`.

### Limits

- Rounds count model requests on API-key models and turns on CLIs. With one round, an API-key run performs the round's tool calls and ends without sending their results back, so a rename costs one request. Claude Code takes `--max-turns`. Codex has no turn limit flag, so the host ends its turn at the tool-call or time limit.
- At a limit, the run stops and applied actions stay; the result names the limit.
- The time limit covers the whole run, including the CLI's start.
- At most 2 automatic runs at once; their requests wait in the providers' rate limiters, where an automatic request gives up after 15 seconds.
- Runs per day count per feature in `ai-usage.json`, beside the day's automatic request counts, and for outside clients per grant there too.

### How a run runs

1. The runner resolves the route and takes its first usable model.
2. An API-key model with `tools` runs VII.19's loop (`AgentAPISession` on `AIClient.run`) with the run's tools as `AIToolHandler`s over the tool host as client `run`, the first round's model as the route of every later round (`route: .models([model])`; `docs/agents.md`, API-key sessions), and the rounds limit. It uses no socket.
3. A Claude Code or Codex preset runs one turn of an `AIAgentSession` (VII.16): `AIService.startAgentSession(_:)` with the route, `runInstructions`, a tool server listing only the run's tools under a ticket bound to the run (VII.17's binding), `maxTurns` set to the rounds, and `ephemeral` true at every record level. It sends the first message, waits for `turnFinished`, and calls `end(keepingThread: false)`. A Claude Code turn that stops at `--max-turns` (`error_max_turns`) counts as completed. `AIAgentSessionRequest.maxTurns` sets Claude Code's bound. With `ephemeral` set, Codex includes `--ephemeral` on its first turn. The session refuses a second message and removes its folder after the first turn finishes. The runner never sets a thread to keep, so Keep Codex's Copy of Agent Conversations does not apply to runs. Before a bounded run reaches the tool, a cached probe checks Claude Code's missing-value diagnostic for `--max-turns` or Codex's `exec --ephemeral --help`. Both checks run without a model. Each run starts a process and takes a few seconds; the editor says so when the first model in a hook's choice is a CLI.
4. Fallbacks move to the next model only before the model's first output, as for sessions.
5. Stop All Agents, a canceled hook run, and the time limit stop the turn or loop and end the session; no process of the run remains.
6. The result lists the actions the tool host applied during the run, the last text, the model, and usage.

## Agent hook editor

### Settings ▸ AI ▸ Agent Hooks

- The page lists every agent and script hook in run order. The top has Run Hooks, Allow Shell Scripts, New Agent Hook…, New Script Hook…, and Presets with Tidy Tab Names. New Agent Hook… and the presets appear while a model with `agent` exists; script hooks need no AI.
- Each row shows the hook's switch, name, situation ("When a new tab loads its first page · Everywhere · All sites"), model ("Fast · model-a"), record ("Keeps nothing"), last run ("2 minutes ago · renamed a tab"), and, for a hook added by an outside program, origin ("Added by Codex · Terminal"). A paused row gives the reason, with Resume, or Review for a changed script or interpreter and for an unknown provider. Edit… of a script changed outside Arch opens Review too, and Duplicate takes no changed script, so another program's bytes run only once the user has read and saved them (hook decision 8). The row's menu has Edit…, Run on Current Tab, Duplicate, and Delete, which asks first; dragging reorders rows. A row opens to its last runs, with Show Session for a kept run.
- Notices: a file set aside, a key the Keychain did not provide (Try Again), and a file from a newer Arch.
- Built with VII.26: Run Hooks, the notices and a change not saved, New Script Hook… (`ScriptHookSheet`) with the situation and its options, Everywhere or places named as Persona rule 7 names them (`BrowserSession.displayedPlace(ofPersona:space:among:)`: each Persona by its name and each space as "Persona / Space", or, with one Persona, its spaces by their names alone), sites, engines, tab kinds, Read Tab Titles and Addresses and Rename Tabs, and the script from a template for the situation, which Add, or Save for a hook that exists, checks with `HookScriptRunner.problem(in:)`; and the rows with the switch, name, situation, an agent hook's model and record, last run, origin, the pause with Resume or Review, the menu with Edit…, Run on Current Tab, Duplicate, and Delete…, dragging, and the last runs. Review opens the sheet on the script as the file holds it, and its Save records the digest and resumes a hook that the change paused. `HookRegistry.scriptFile(of:)` reads the file and says whether it still matches its digest, and pauses an active hook whose file does not with `scriptChanged`, so Edit… of such a file opens Review, and Duplicate is off for a hook paused with `scriptChanged` and refuses a changed file. The Tabs toggles keep the last kind left on, since an empty set means every kind. An unknown provider's Review, which names the provider and records it with Allow, comes with VII.27, which pauses hooks for one; until then its row has no button. Allow Shell Scripts, New Agent Hook…, and the presets come with VII.31, VII.28, and VII.29.

### The editor

A sheet with these sections, in order:

1. Name.
2. When: the situation in plain words: "A new tab opens", "A tab loads a page" (with "Only a new tab's first page", "Each new address", or "Every load"), "A tab's address changes" (with "Only a new site" or "Any change"), "A tab's title changes" (with "The page's title", "Your names", and "Names from hooks and agents"), "You select a tab", "A tab closes" (with its reasons), "A download finishes", and "You switch spaces" (with "Only when the Persona changes").
3. Where: Everywhere, or "Persona / Space" entries; Sites: All Sites, Only These Sites, or All Sites Except These, as `AISitePattern` entries; Engines: Both, WebKit, or Chromium; Tabs: open tabs, pinned tabs, favorites' tabs, and small windows' tabs.
4. What the agent does: the instructions, with a placeholder example; Give the Agent: The Tab's Title and Address, or Also the Page's Text, which says page text goes to the model automatically and sites excluded from AI are skipped. For "A tab closes", the agent gets the closed tab's last title and address as data and the tabs left in its space as the tabs it may act on, and the choice reads The Titles and Addresses, or Also the Pages' Text of the tabs left (Closed tabs).
5. Model: Fast, Standard, or Deep, or A Specific Model… with connected models that have `agent`; below it, the resolved model, "Choose a model for the Fast tier" with the tier's menu inline when empty, and the note for a CLI model.
6. Record: Keep the Session, Keep Activity Only, or Keep Nothing, each with one sentence from Record levels.
7. Allowed Actions: Rename the Tab, or Rename the Tabs Left for "A tab closes". The list grows with the run tools.
8. Limits: Time Limit, Rounds, Runs per Day, which sets both the hook's daily count and its agent runs', and Wait Before Running.
9. Test on Current Tab: runs the hook once on the front window's selected tab; a close hook treats that tab as closed without closing it (Closed tabs). It reports actions without applying them unless Apply Changes is checked. The sheet shows the result until it closes: what would change, the agent's reply, the model, tokens, and time. A test counts toward usage, not the hook's daily count, and is logged with `test` at the first two record levels.
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
- Tab Names (`hook.tabName`, Settings ▸ AI ▸ Features) is an AI hook: a plain model request without tools on every new document of a tab, with up to 2,000 characters of page text, under its own stored route. It and Tidy Tab Names both set the suggested name, so both send a request on a new tab's first page. Both run in that load's chain, Tab Names first (The shared scheduler), so the name Tidy Tab Names gives wins. Arch does not merge them. Whenever an active hook renames on `tabOpened` or `pageLoaded` while Tab Names is on, the editor and hook's row say "Tab Names also names tabs. Turn on one of them." with Turn Off Tab Names.
- Which to turn on: Tidy Tab Names for the user's case of new tabs only, a fast model, no page text, and no record. Tab Names remains for naming every page a tab loads from its text.
- The preset is data, `HookPresets.tidyTabNames`. Once saved it is an ordinary hook that the user can edit, duplicate, or delete.

## Outside programs

### Grants

- The new extra scope on the grant sheet, Watch Browser Events (off), allows `events/subscribe` and `watch_events` for the grant's Persona through the outside view. It asks for Touch ID or the login password, as Search History does, because it shows when and where the user browses. The sheet says: "See when tabs open, load, change, and close in \<Persona>, with their sites. Never their titles or pages."
- The scope is `AgentGrantScopes.watchEvents`. `AgentGrantScopes` and `AgentGrant` get hand-written decoders that read the new members with `decodeIfPresent`, `watchEvents` false and `runsPerDay` 200 when absent, as `AgentSettings` and `AgentClientIdentity` read their later members, so an `agent.json` written before VII.30 still opens with its grants and Allow Outside Clients instead of being set aside.
- `agent/run` needs the existing Start Agent Tasks scope and runs under the client's run grant (arch-cli agent run and rename). `hooks/add` needs a grant of any level, and the user allows each hook separately. `rename_tab` follows agents' rules with P19.
- Revoking a grant ends its subscriptions and pauses the hooks it added (Hooks from outside programs).

### Hooks from outside programs

A hook that an outside program proposes reaches no more than the proposing grant can: the grant sees the user's own tabs only as watch IDs and hosts, and reads only its agent tabs and the tabs shared with it. Such a hook therefore never reads page text, and nothing the model writes reaches its script.

| Part | Cap |
|---|---|
| Permissions | `tabs.rename` and `agent` only; `tabs` is refused, so the script's events and tab calls carry no titles or addresses |
| Tabs | The event's tab only (Run tabs), for `arch.tabs.rename` and agent runs |
| Agent tab access | `title` only |
| Record | Keep Activity Only at least, so every run and tool call is logged |
| Result | Without `reply`, so the script cannot write the model's words into tab names |
| Instructions | Labeled in the first message as the program's, not the user's |
| Shell scripts | Refused |

- When the grant that proposed a hook ends, by Revoke, expiry, `arch-cli release`, the end of the process it was bound to, or quit for a grant until Arch quits, the hook pauses with `grantEnded` until the user resumes it in Settings ▸ AI ▸ Agent Hooks. Resume needs no Touch ID, and the hook keeps its caps.
- The proposal sheet says: "Names this hook gives your tabs are saved in Arch's session file, which other programs on this Mac can read."
- The `cli` guide topic lists `hooks add` and `agent run` from the command table with the sentence that each proposal waits for the user's approval in Arch, and the entry skill tells agents to propose a hook only when the user's own message asks for one.

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
                   --script <file.js> [--permission tabs.rename|agent]… [--agent <options.json>] [--record activity|session]
arch-cli hooks remove <id>
```

- `list` shows the hooks this client's identity added: identifier, name, trigger, state, and last run.
- `add` reads the script (a JavaScript file of at most 256 KB) and agent options, checks their form against the catalog, and sends `hooks/add`. Arch checks the script's syntax and shows the proposal sheet. The command waits with "Waiting for your approval in Arch…" and prints the new hook's identifier on Allow. Don't Allow exits 3. A refusal exits 4: a shell script, a script over the size limit or that does not parse, an unknown event, permission, or tool, the permission `tabs`, tab access `page` or record `none` in the agent options or the request, a filter naming agent tabs, a scope outside the grant's Persona, or more than 20 hooks from one identity. With `agent`, the hook's grant matches the agent options within the caps of Hooks from outside programs, with 200 runs per day.
- The sheet appears like the grant sheet: in Arch's frontmost main window, with a notification without content while Arch is in the background. It names the client and its path, then the hook's name, its situation in words with "Persona / Space" entries, its permissions in sentences, its agent options (the model or tier with the resolved model, the record, the actions, and the limits), the sentence about tab names above, and the script's full source, read-only. It has no default button; Escape is Don't Allow; Allow needs a pointer click and Touch ID or the login password. An unanswered sheet closes as Don't Allow after the outside clients' approval window. After a decline, the identity's next proposal waits at least a minute.
- An allowed hook is an ordinary active hook with origin `outsideClient`, limited to the grant's Persona and to the caps above, which the user's later edits in Arch cannot lift; a hook without them is one the user makes in Arch.
- `remove` removes a hook this identity added, without a sheet; any other identifier returns not found. No command edits, pauses, or resumes a hook; the user does that in Settings.

### arch-cli agent run and rename

```
arch-cli agent run (<prompt>|-) [--tab <t>]… [--tier fast|standard|deep | --model <provider>/<model>] [--page]
                   [--record none|activity|session] [--tools <tool>,…] [--timeout <s>] [--rounds <n>] [--dry-run] [--json]
arch-cli rename <tab> <name>
```

- From an outside client, `agent run` needs Start Agent Tasks, works on the client's agent tabs and the tabs shared with it, runs under `agentRun`, and counts toward the grant's runs per day. Without `--tier` or `--model` it uses the Standard tier; without `--record`, Keep Activity Only. Its run grant, `AgentRunGrant.forClient(_:)` in `Agent`, comes from the client's `AgentGrant`:

| Field | Value |
|---|---|
| `tools` | `read_text` and `snapshot`, which the client could call itself at every level, and `rename_tab` for its own agent tabs (P19) |
| `tabAccess` | `page` |
| `minimumRecord`, `maximumRecord` | Keep Activity Only, Keep the Session; `--record none` is refused with `notGranted` |
| `limits` | The ceilings: 10 minutes, 20 rounds, 50 tool calls |
| `runsPerDay` | `AgentGrant.runsPerDay`, 200 by default, which the grant sheet shows under Start Agent Tasks and the grant's row in Settings ▸ AI ▸ Agents changes; the day's count is kept per grant in `ai-usage.json` |
| `returnsReply` | true, since the client asked |

- Each outside run logs an entry with its grant, client, model, and outcome in `agent-activity.json`, and one per tool call, as the client's own calls are, so a run reads nothing that `arch-cli text` would not have logged. Its prompt is labeled as the program's in the first message.
- Inside a shell hook's run it uses the hook's grant, feature, and run tabs, with `t1` the event's tab.
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
| `~/Library/Application Support/Arch/hooks.json` | Run Hooks, Allow Shell Scripts, the known providers, and the hooks with their triggers, filters, grants, agent options, record levels, timing, states, origins, script digests, and shell interpreters | Sealed; no secrets |
| `~/Library/Application Support/Arch/agent.json` | Grants gain the Watch Browser Events scope and `runsPerDay`, both read with `decodeIfPresent` | Sealed, as `docs/agents.md` describes |
| `~/Library/Application Support/Arch/Hooks/<hook id>/hook.js` or `hook.sh` | The hook's script, or Arch's copy of a trusted shell script | 0700 folder, 0600 file, digest in the sealed file |
| `~/Library/Application Support/Arch/hooks-activity.json` | Run log, 30 days | No content |
| `ai.json` | The tier routes `tier.fast`, `tier.standard`, and `tier.deep` | As `ai.json` |
| `ai-usage.json` | Totals of the hooks' features and `agentRun`, and the day's run counts per feature and per outside grant | No content |
| `$TMPDIR/Arch-Hook-<run id>/` | A shell run's working folder | 0700, removed after the run |

- Keychain: `xyz.taeyoon.arch.hooks` holds the seal key and the last write's generation. Run tickets live only in memory and in the run's process tree.
- Kept runs, last runs, event buffers, closed tabs' last names and addresses, and test results stay in memory until deleted, used, or Arch quits.

## Errors

| Situation | What the user, the script, or the program sees |
|---|---|
| An empty tier | `notConfigured(.emptyTier)`: "Assign a model to the Fast tier in Settings ▸ AI." with Open AI Settings; the hook's row shows it |
| Options beyond the grant | `refused`, `notGranted`, with the field: "This hook may not keep sessions." |
| A step that would ask | The tool result is `refused`, `wouldAsk`: "This run cannot ask the user, so Arch refused the step." |
| A tab on an excluded site | Left out of the run; `refused` (P16) before the run starts when no tab remains |
| A tab outside the hook's reach | `refused`, `notGranted`, naming the tab |
| A script that throws or exits nonzero | The run fails with its message; three in a row pause the hook |
| A script changed outside Arch | The hook pauses: "Its script changed outside Arch." with Review |
| `hooks.json` set aside or unreadable | The notice in Settings; no hooks run |
| Shell scripts switched off | Shell hooks pause: "Shell scripts are off." |
| A hook that ran too often | Runs past the caps are skipped and logged; a `titleChanged` hook that keeps running for one tab pauses: "This hook ran too often, so Arch paused it." with Resume |
| A rename after the tab moved to another document | `rename_tab` returns `stale`; `arch.tabs.rename` resolves `false` |
| A run that would reach a provider not set up in Arch | `refused`, `unknownProvider`; the hook pauses with Review |
| A shell hook's interpreter changed | The hook pauses: "Its interpreter changed." with Review |
| The grant that added a hook ended | The hook pauses: "The program's access ended." with Resume |
| `arch-cli` without the events scope, or a declined hook | Exit 6, or 3 |

## Tests

- `EventsTests` (VII.23): each payload's JSON against fixed text; `kind`, `subject`, `personaID` (the new side for `spaceSwitched`), and `urls` for every case; filters by kind, scope (whole Personas and single spaces, with `spaceSwitched` matched by its new space), sites and exceptions through `AISitePattern`, engines, and tab kinds, with `agent` matched only when named and events without an address never matching a site list; every delivery view, with no titles, addresses only under `tabs` or a covering grant, hosts and watch IDs for outside programs, downloads only from the client's agent tabs, `excluded: true`, and `byThisClient`; the outside view of `tabSelected` and `spaceSwitched`, delivered only with the grant's Persona on one side, with window handles, space handles for the grant's spaces, and `otherPersona: true` without identifiers for the other side; `withCause` and sequence order.
- `BrowsingTests` (VII.23): the source posts each kind for session changes on fake web contents: a new tab but no restored tabs, closes with each reason and the tab's last address, `isRestore` and `isFirstLoadAfterOpen`, address changes with the previous address, only for addresses the tab commits, title changes from the input that supplies the shown name but none when it stays, a hook's name kept and no title change through a WebKit navigation that becomes a download or is stopped before it commits, selection and space switches with a Persona change, a finished download, and `Tab.pendingCause` on the next load, dropped by a load that ends without one; `BrowserHooks` maps bus events to the AI hook center as before, cancels a tab's chains for an earlier document, not for an address the tab leaves before it commits, and at its close, and existing hook action tests pass unchanged. The tests build no session, so VII.23.1 confirms the session's code: `closeTab` posts `tabClosed` while the session still lists the tab, `adopt` and `openSmallWindow` set a popup's opener before its tab joins the list, every selection of `reopenWindows`, from `restoreWindows()` and `sidebarTarget()` alike, runs inside `restoringWindows(_:)`, and `deletePersona` closes its tabs with `eventReason: .spaceDeleted`. Nothing in the bundle subscribes to `tabSelected`, `spaceSwitched`, or a popup's opener before VII.26, so checks 87 and 91 observe them.
- `AITests` (VII.23): `AIHookScheduler` with steps of one event from two owners in order, steps of another event replacing the chain, `cancel(subject:except:)` keeping the close's own chain, `cancel(subject:otherThan:)` ending only other documents' chains, the per-owner pause after three authentication or provider errors and its resume when one of the step's routes changes, the feature checks for steps with a feature and none without, and a step stopped after its work returned but before its chain took the end ending as stopped; the center's existing hook tests pass unchanged.
- `AITests` (VII.24, built in `ModelTierTests.swift`): tier resolution with fallbacks, an empty tier's error, request routes accepted for `perRequest` and user features and refused for stored automatic ones, capability drops after a tier, budgets for `perRequest` automatic features, `recordsContent` false leaving Activity without content, a session started on a tier, `AIRouteChoice`'s JSON, and the tier routes read and written in `ai.json`.
- `HooksTests` (VII.25, built in `HookStoreTests.swift` and `HookRegistryTests.swift`): `hooks.json` read and written sealed; an edited file, a restored earlier copy, and a missing key handled as for `agent.json`; a test migration from version 0, and a file from a later version copied and kept, with its unknown hook listed but not run; triggers and filters; list order after the center's hooks in one chain through the scheduler; delay and replacement; a newer event canceling a run; a new document ending a run for the earlier one, and a `firstAfterOpen` hook so ended running once for the next load; a `tabClosed` hook running after the tab is gone, with the closed tab's last name and address kept in memory only; a close ending the tab's other runs; concurrency caps and the dropped oldest run; loop protection (own effects, depth, runs past the caps skipped as `rateLimit` without a pause and logged once a minute, and the `titleChanged` pause); pausing after three failures, after the scheduler's pause, also across a relaunch, and Resume; an update that keeps the state; Stop All Agents; a deleted place; a changed digest; the daily count, also for runs that waited for slots together; a later version's hook with an unknown member inside a value listed but not run, and its copy kept across launches; a command-line provider's destination; a test only on a tab the filter covers; run log entries with no title, name given, prompt, reply, output, or address path, with none at Keep Nothing; no file without hooks; and the log's latest entries. `AgentTests` (VII.25, built in `AgentRunTests.swift`): the JSON of `AgentRunOptions`, `AgentRunLimits`, `AgentRunGrant`, `AgentRunRecord`, `AgentRunTabAccess`, and `AgentRunResult` against fixed text, with `closedTab` and the grant's `minimumRecord` and `returnsReply`. `AITests` (VII.25, built in `AIHookSchedulerTests.swift`): a `perRequest` step skipped as `unavailable` without its route and run with a tier that has a model.
- `HooksTests` and `PluginsTests` (VII.26, built in `HookScriptRunnerTests.swift` with `Fixtures`, `PluginEventsTests.swift`, and, for the rename rule, `BrowserEventSourceTests.swift`, with the row texts in `AgentHooksSummaryTests.swift`): a fixture hook script in the sandbox receiving its event; `arch.tabs.get` without `tabs` lacking title and address; `arch.tabs.list` and `get` limited to the tabs the hook's filter covers in the event's Persona, without agent tabs, and, for a hook with `agent`, without the title and address of a tab on an excluded site; `rename` of a tab outside the filter refused; `rename` through a fake `PluginBrowserHost` under the suggested name rules, carrying the run's cause and reporting in a test, bound to the run's document and resolving `false` after the tab moves to another document; a timed-out run ending its instance; a held instance kept past its idle limit; a listener's thrown values as the run's message; a run tab's committed document from the registry keeping an excluded page's title out while the tab shows another address; the syntax check; plugin events through the script view for a manifest's `events`, never for the plugin's own renames and at most 10 for one tab a minute (`PluginEventsTests.swift`, with `BrowserEventRateLimiterTests.swift` in `EventsTests`); a run's own effect joining its chain without stopping it (`AIHookSchedulerTests.swift`, `HookRegistryTests.swift`); a deferred name's cause and the hook host's committed addresses (`BrowserEventSourceTests.swift`); and `scriptFile(of:)`, Edit… and Duplicate on a changed file, and the last tab kind kept on (`HookRegistryTests.swift`, `AgentHooksSummaryTests.swift`).
- `AgentTests` (VII.27): options checked against the grant, with the record between its minimum and maximum; tabs outside `allowedTabs` refused with `notGranted`, so a script that passes every tab of the Persona reaches none outside its filter; `closedTab` accepted only from its own close and given as an untrusted block without a handle; the `run` client kind refusing every asking rule with `wouldAsk` and other tabs with P17; P19 as a policy table for sessions, outside clients, and runs, with a run renaming and reading its run tabs without asking and an outside client's run refused with `wouldAsk` on a shared tab not yet allowed; `rename_tab` bound to the run's document, `stale` after a navigation during the run; each record level's files and memory, and no reply for a grant that returns none; the first message's label for the user's and a program's instructions; a hook's run refused with `unknownProvider` for a provider outside `knownProviders`; one round ending after its tool calls without sending results back, through the scripted provider; a CLI run's arguments with `--max-turns`, `--ephemeral` at every record level, and only the run's tools, through the fake CLIs of `AITests`; the daily run count; and Stop All Agents.
- `PreferencesTests` and `HooksTests` (VII.28, VII.29): the editor's choices turned into a hook, a grant, and the template script, the close template among them; an edited script kept and the template restored; Test reporting a rename without applying it, and Test of a close hook treating the selected tab as closed; row summaries with "Persona / Space" entries; the Tidy Tab Names preset's values; `firstAfterOpen` matching a new tab's first page but neither its second nor a restored tab's; and the Tab Names warning.
- `AgentControlTests` and `AgentTests` (VII.30): parsing of `events`, `hooks`, `agent run`, and `rename`; JSON lines; the events scope's views and buffer with `--after`; `watch_events` with its cursor and timeout; `hooks/add` through a fake registrar with Touch ID through the fake authenticator, a decline's minute, the 20-hook cap, refusals of `tabs`, page access, and Keep Nothing, and `remove` of the client's own hooks only; an outside program's hook limited to the event's tab, without `reply`, and paused with `grantEnded` when its grant is revoked, expires, or is released; `agent run` under Start Agent Tasks and `agentRun` with `AgentRunGrant.forClient(_:)`, `--record none` refused, an activity entry for each run and tool call, and the grant's runs per day; an `agent.json` sealed before VII.30, without `watchEvents` and `runsPerDay`, opening with its grants and Allow Outside Clients.
- `HooksTests` (VII.31): fixture shell scripts receiving the event on standard input, exactly the listed environment, the checked bytes through `/dev/fd/3`, a changed copy refused, the interpreter recorded by path and digest, a replaced interpreter pausing the hook with `scriptChanged`, the hook's agent grant at tab access `title` until the user allows pages, the time limit ending the process group, standard error kept only in memory, and the ticket bound only within the run's process tree.

## Checks from the bundle

Each task that needs the app adds its check to the regression checklist in `docs/plan.md` with these numbers. Run them on both engines with a fresh Application Support folder.

87. Script hooks: with Run Hooks on, New Script Hook… with a JavaScript script that renames a new tab's first page to its host through `arch.tabs.rename` renames tabs on both engines and leaves tabs the user named alone, and Save refuses a script that does not parse. A second hook that renames on `titleChanged` with the source "Names from hooks and agents" runs once for each of the first hook's renames and never for its own; Pause and Resume work. A hook on "A tab closes" runs once for each tab the user closes. Right after a relaunch, hooks on "You select a tab" and "You switch spaces" have not run; each then runs once for each selection and switch the user makes. A hook on "A new tab opens" gets a sign-in popup's opener as `openerTabId`. Dragging a row reorders the hooks, Duplicate and Delete… work, and Run on Current Tab reports what the hook did. Editing `hook.js` in another editor pauses the hook with Review, whose Save lets it run again. Editing `hooks.json` by hand sets it aside, shows the notice, and no hook runs.
88. Agent runs: with an API-key model with tools as the Fast tier, a script hook calling `arch.agent.run` with the Fast tier and `rename_tab` renames a new tab in one request (Settings ▸ AI ▸ Activity). At Keep Nothing, `hooks-activity.json` gains no entry and the Activity entry has no Show Content; at Keep Activity Only, an entry has no title or address path; at Keep the Session, the row's last runs offer Show Session. An empty Fast tier fails with its sentence.
89. The editor: New Agent Hook… makes the hook described in Tidy Tab Names by hand. Test on Current Tab shows the proposed name without renaming; Apply Changes renames. Show Script shows the template, Edit Script keeps the user's change, and Restore Arch's Script restores the template.
90. Tidy Tab Names: the preset with the Fast tier on an API-key model renames each new tab once on both engines, leaves restored tabs alone after a relaunch, and keeps nothing. With Claude Code, then Codex, as the Fast tier, each new tab's run ends with no `claude`, `codex`, or `arch-mcp` process left, and Codex keeps no thread. With Tab Names also on, the warning appears, and Turn Off Tab Names switches it off.
91. Outside programs: with Allow Outside Clients on and a grant in the default Persona with Watch Browser Events, `arch-cli events --json` prints a line for opening a tab, its first load, an address change, a title change, a selection, a close, a finished download, and a space switch, with hosts and no titles; excluded sites have no host. A popup that a page opens prints its opener, and right after a relaunch `--after 0` replays no selection or space switch. `arch-cli hooks add` shows the sheet with the script and the sentence about tab names, Don't Allow exits 3, Allow with Touch ID adds the hook, `hooks list` shows it, and `hooks remove` removes it; a proposal with `--permission tabs` or page access exits 4, and Revoke pauses the client's hooks. `arch-cli agent run --tab t1 --tier fast --tools rename_tab "…"` renames the client's agent tab. A `claude` with `arch-mcp` reads events with `watch_events`.
92. Shell scripts: with Allow Shell Scripts on, trusting a script with Touch ID copies it; the script receives the event on standard input and only the listed environment, and `arch-cli rename t1 …` inside it renames the event's tab. Changing the source file has no effect until Update from File…, a script whose `#!/usr/bin/env` names an interpreter in a folder of the user's on PATH pauses with Review after that file is replaced, the time limit ends a sleeping script, and `lsof -nP -p <Arch pid> -i` lists no listening port.
93. The registry at launch (VII.25.1): with a fresh Application Support folder and no hooks, a launch, a new tab on each engine, and a quit leave no `hooks.json`, `hooks-activity.json`, or `Hooks` folder, no keychain prompt appears, and `security find-generic-password -s xyz.taeyoon.arch.hooks` finds no item; a `hooks.json` with any text written before a launch is renamed `hooks.json.unreadable` at launch without a prompt; and Tab Names still names a new tab once on both engines.

## Risks

1. A hook with page access sends signed-in pages' text to the model automatically. The editor says so, site exclusions apply, and agent hooks default to the title and address only.
2. A JavaScript hook script the user made can copy an agent run's result into tab names, which `session.json` keeps in plain text and the user's other programs can read. Arch runs only scripts the user wrote, reviewed, or allowed. The seal keeps programs from adding one, names are cut to 60 characters, and an outside program's hook gets neither page text nor the reply (Hooks from outside programs).
3. Effects without a cause can still chain, as when a page changes its title because a hook renamed its tab. Rate limits bound them.
4. A shell script runs with the user's rights and can do anything the user can. Arch ensures only that the text the user trusted is the text that runs, and that its interpreter is the one recorded. Commands the script runs by name come from the PATH and get the hook's ticket; the trust sheet says so. A program that replaces the interpreter's file between Arch's check and the start can still run in its place.
5. A run on Claude Code or Codex starts a process for each event and uses the user's plan; many new tabs can use much of it. The editor's note, daily count, and concurrency cap limit this.
6. Hooks added by outside programs pause when their grants end and stay until the user resumes or removes them.
7. Watch IDs let a program with the events scope follow one tab's sites over time, so the scope asks for Touch ID.
8. `ai.json` stays unsealed. Known providers keep hooks' data from a provider that only an edit outside Arch added or changed, but other AI features, such as Tab Names, still follow whatever providers and routes `ai.json` names, as agents' site exclusions do (`docs/agents.md`, Risk 9).
9. A client with a shell that a page steers can propose a hook or start agent runs. The proposal sheet, Touch ID, the caps on outside programs' hooks, the activity record of every outside run, and the grant's runs per day bound this; a steered client can still spend the grant's runs on the pages it was shared.

## Open decisions

None needs the user's decision. The following remain for later features: storage for hook scripts, which none needs yet; run tools beyond the three, each with its own rule and record floor; Tab Names as an agent hook preset, which a plain request serves well today; and the `agent` permission for installed script plugins, whose install sheet would then state the grant.
