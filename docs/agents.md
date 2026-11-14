# Agents design

This note describes the design for agents in Arch, feature rows 58 to 63. The user instructs an AI agent inside the browser through their existing ChatGPT or Claude subscription, with a harness and skills built on `arch-cli`. Outside agents and scripts use the browser through `arch-cli` and `arch-mcp`. Nothing here is built; Phase VII tasks VII.9 to VII.22 and Phase VI task VI.6 in `docs/plan.md` build it. Facts lists what was checked; Not verified lists what the tasks check first.

Terms: "the user's CLI" is Claude Code's `claude` or OpenAI's Codex CLI `codex`, which the user installs and signs in to in the built-in terminal (row 56). An "in-app session" is an agent session that Arch starts. An "outside client" is a program that reaches Arch through `arch-cli` or `arch-mcp` without Arch having started it.

## Purpose and principles

- Browser state, tools, and every check of what an agent may do live in the Arch app. `arch-cli` and `arch-mcp` are thin clients with no policy. No entry point, client kind, or debugging route skips the checks.
- A subscription connects only through the vendor's own CLI, run headless as a subprocess with its own sign-in. Arch builds every argument to disable the CLI's own tools, settings, hooks, plugins, and other MCP servers, leaving only Arch's tools. It checks the CLI's start event or stream for anything else.
- All AI work goes through the AI interface (`docs/ai.md`): an in-app session resolves the `agent` feature's route, records usage, and passes page data only as tool results. API-key sessions send them through the interface's part checks. CLI sessions and outside clients receive them from the tool host through `arch-mcp`, never through `AIService`, so the tool host applies the same site exclusions and address reduction itself (Site exclusions). Arch calls no vendor service itself.
- Arch runs no servers. `arch-cli` and `arch-mcp` reach the app through one local Unix domain socket that has no network port and exists only while Arch runs and an agent feature uses it (decision 1).
- Reading is free; the host, not the prompt, gates acting, typing, and going to sites the user did not name. A page cannot approve anything. Approvals happen only in Arch's own interface outside the page area, and an unanswered approval is a denial. No tool, command, or MCP call changes a setting, grant, exclusion, permission, plugin, or Persona.
- Fail closed: a quit, a crash of the client, Stop All Agents, an expired grant, an unknown tool, a failed check, or an unknown stream event ends the call or the session.
- Every tool runs on WebKit and Chromium tabs through the engine protocols. Engines below lists what still differs and why.
- Public APIs only: Unix domain sockets, audit tokens, Security's code signing functions, the process table through `sysctl` (`KERN_PROC_PID`), `posix_spawn`, LocalAuthentication, CryptoKit, and the engine protocols. Arch does not use `libproc`, whose header calls its interfaces private. Nothing here needs a private API flag.
- Add types, tools, and engine members only when a feature needs them, as with the AI interface and the engine protocols.

## Using agents

- In the browser: the user adds Claude Code or Codex in Settings ▸ AI ▸ Providers, signs in to it in the built-in terminal, and starts a session with File ▸ New Agent Task, the palette's Ask Agent row, or Continue as Agent Task in the page reader. The session opens its tabs in the background in an agent folder of the space. The agent panel beside the page shows the conversation, each step Arch performed, and the approvals Arch requests. An API-key model with tools serves the same sessions.
- From Claude Code or Codex outside Arch: the user turns on Settings ▸ AI ▸ Agents ▸ Allow Outside Clients, runs `arch-cli setup claude` or `arch-cli setup codex`, and optionally `arch-cli skills install`. The tool then starts `arch-mcp`, and its first call shows a grant sheet in Arch.
- From a script: `arch-cli tabs`, `arch-cli open https://example.org`, `arch-cli snapshot t1`, `arch-cli click t1 e5`, with `--json` for machine-readable output, under the same grant.

## Decisions

Code comments and documents cite these as "agent decision 1" and so on.

1. The control channel is a Unix domain socket served by the app process. Under the plan's Goals, it counts as local inter-process communication, not a server: it has no TCP or UDP port, so no web page, DNS rebinding, or other machine can reach it; it exists only while Arch runs and an agent feature uses it; it accepts only Arch's own bundled tool running as the same user. A loopback port would be reachable from pages and is a server; an XPC Mach service needs a launchd job that can outlive the app. The user may overturn this reading. The fallback is Apple Events (Fallback transport), which keeps `arch-cli`, `arch-mcp`, and subscription sessions working.
2. The executables are `arch-cli` and `arch-mcp`, never `arch`, because macOS ships `/usr/bin/arch`. They share one Mach-O, target `ArchCLI` with product `arch-cli`, in `Arch.app/Contents/Helpers`; `arch-mcp` is a relative symbolic link that the binary distinguishes by `argv[0]`. One binary means one code directory hash for the peer check and one target in `Package.swift`.
3. Subscriptions connect only through the official CLIs (`claude`, `codex`), signed in by the user in the built-in terminal and run by Arch as subprocesses with their own sign-in. Arch never reads a CLI's credential files or Keychain items, never uses a vendor's OAuth client, callback, or endpoint, never imitates a CLI, and reads no usage endpoint. The status Arch shows comes from the CLIs' own status commands.
4. Agent sessions are the only place a command-line tool gets tools from Arch, and only Arch's MCP tools (`docs/ai.md`, Command-line tools). The Claude Code and Codex presets build their own arguments for every request. Their ordinary requests (page reader, questions, hooks, Plugin Writer) run with no tools and therefore accept page data.
5. Every check runs in the app's tool host, the same code for the in-app CLI, the in-app API-key loop, `arch-cli`, and `arch-mcp`. The CLIs' own approval features, MCP elicitation, AppleScript, and the agent itself never approve anything.
6. Tools are atomic browser actions. No tool runs code in a page, fetches outside a tab, reads files, cookies, passwords, or the clipboard, or changes any setting.
7. Page actions use DOM events in the `arch.agent` script world in the first build, and results say so (`inputKind: dom`). Trusted input through a new engine member comes later as its own task (VII.21), because neither engine's route is verified and DOM events serve most sites.
8. In-app sessions gate the addresses an agent writes by the data they carry, in every mode, including Read Only: an address the session has not seen asks, whatever its site, and so does any address to a site outside the site scope (Site scope and navigation). The page that injects instructions is often in scope itself, since it is the attached tab, so the site alone guards nothing. Typing is the other route off the Mac, and the mode gates it. Outside clients navigate freely in their own agent tabs because they can already send data anywhere themselves. Their grant and Persona limit what they read.
9. Outside clients are offered a separate Persona named Agents, with no sign-ins, and Read Only by default. The Agents Persona is agent-only, an exception to Persona rule 6: remembered permission answers from `permissions.json` are not copied into its profiles, and its permission requests are denied without a sheet and not remembered.
10. Agent tabs record no history visits, are not saved in `session.json` until the user keeps them, and never join the closed tab list, so `session.json` keeps its schema (version 13). Agent folders exist in memory only.
11. Claude Code sessions run as one long-lived process with `--no-session-persistence`, so the conversation lives only in the process and in Arch's memory; `CommandLineProcess` gains an open standard input mode for it. Codex sessions run one process per turn and resume the thread, which Codex keeps under its own folder; Arch deletes the thread with the session unless the user keeps Codex's copy.
12. Session facts (attached tabs, Persona, mode, scope) never go into a CLI's arguments. Arguments carry only Arch's static harness and configuration. The first message on standard input carries the user's words and a short preamble with tab handles. Details come from the `session_info` tool, whose calls wait for the start check.
13. Refs are stateless: the snapshot script keeps nothing in the page, and the host keeps a fingerprint per ref with the document's address. This behaves the same on Chromium, where every script world shares the page's main world, as on WebKit.
14. `AIModelCapability.agent` is derived from the provider kind and cannot be added or removed in `ai.json`, so the `agent` route holds only models that can run a session.
15. The approval card never edits site exclusions. Navigation to a site excluded from AI is refused, and so is every read of a page on one. The user changes exclusions only in Settings, so a page cannot steer the user into removing one.
16. In-app sessions get Arch's skills as `guide` topics, not as the CLIs' native skills. This is a substitution for the request's "skills on top of `arch-cli`": the topics and the entry skill come from the same text in `AgentHarness.swift`, so an in-app agent and an outside agent with the entry skill installed follow the same guidance. Native skills stay off in in-app sessions because turning them on would also load the user's own skills and need the CLIs' skill tools, which the start check refuses. The user may overturn this (open decision 3).

## Parts and modules

```
Arch.app (one process)
 ├─ Agent: AgentService (sessions, grants, endpoint, Stop All), AgentEndpoint (socket, peer checks),
 │         AgentToolHost (every tool), AgentPolicy, AgentApprovals, AgentPageScripts, activity log, views
 ├─ AI: the agent feature, Claude Code and Codex presets, AIAgentSession (CLI runner), API-key tool loop
 ├─ Browsing: BrowserAgentHost (agent tabs and folders, dialogs, downloads, permissions), panel placement
 ├─ Preferences: Settings ▸ AI ▸ Agents, the presets in Settings ▸ AI ▸ Providers
 ├─ Contents/Helpers/arch-cli ─────────── control protocol ──┐
 └─ Contents/Helpers/arch-mcp → arch-cli ─ control protocol ──┤ Unix domain socket
          ▲ stdio MCP                                         │
          ├─ the user's claude or codex, started by Arch for an in-app session (with a ticket)
          └─ outside MCP clients the user runs (with a grant)
```

| Target | Location | Kind | Role | Depends on |
|---|---|---|---|---|
| `AgentControl` | `Packages/ARCH/Sources/AgentControl` | library | Wire messages and framing, JSON-RPC, the socket location rule, code identity checks for both ends, the tool catalog (names, schemas, MCP annotations, access classes, limits), the untrusted wrapper, exit codes, the harness text (`AgentHarness.swift`), the I/O-free MCP server core, the CLI command table, the skill and PATH link installers, the client | Foundation, Security |
| `Agent` | `Packages/ARCH/Sources/Agent` | library | `AgentService`, `AgentEndpoint`, grants (`agent.json`), sessions, `AgentPolicy`, `AgentApprovals`, `AgentToolHost` over `AgentBrowserHost`, `AgentPageScripts`, the activity log, the API-key session, and the panel, card, composer, and grant sheet views | `ARCHEngine`, `AI`, `AgentControl` |
| `ArchCLI` | `Packages/ARCHApp/Sources/ArchCLI` | executable, product `arch-cli` | `arch-cli`, and `arch-mcp` when started under that name or as `arch-cli mcp` | `AgentControl` |
| `AgentControlTests` | `Packages/ARCH/Tests/AgentControlTests` | tests | Framing, catalog, MCP transcripts, CLI parsing, installers, escaping | `AgentControl` |
| `AgentTests` | `Packages/ARCH/Tests/AgentTests` | tests, with `Fixtures` | Endpoint, grants, policy table, approvals, tool host over a fake host, page scripts in WebKit | `Agent`, `ARCHEngineWebKit` |

- `Browsing`, `Preferences`, and `Arch` add `Agent`. `AI` gains no dependency: `Agent` gives it a description of the MCP server to start (`AIAgentToolServer`). `Agent` depends on neither `Browsing` nor `Plugins`; `Browsing` implements `AgentBrowserHost` and places the views.
- The names follow Arch's conventions: feature modules in `Packages/ARCH/Sources` without a prefix, app-side executables as `Arch*`. The products carry the user's names (decision 2).
- The harness lives in `AgentControl/AgentHarness.swift` as string literals, like the plugin composer's reference in `PluginComposerInstructions.swift`. The app and executable carry the same text without a resource bundle.

`Package.swift` additions, by hand:

```swift
.library(name: "AgentControl", targets: ["AgentControl"]),
.library(name: "Agent", targets: ["Agent"]),
.executable(name: "arch-cli", targets: ["ArchCLI"]),

.target(name: "AgentControl", path: "Packages/ARCH/Sources/AgentControl", linkerSettings: [.linkedFramework("Security")]),
.target(name: "Agent", dependencies: ["ARCHEngine", "AI", "AgentControl"], path: "Packages/ARCH/Sources/Agent"),
// `scripts/bundle_app.sh` copies it into Contents/Helpers as arch-cli, with arch-mcp as a link to it.
.executableTarget(name: "ArchCLI", dependencies: ["AgentControl"], path: "Packages/ARCHApp/Sources/ArchCLI"),
.testTarget(name: "AgentControlTests", dependencies: ["AgentControl"], path: "Packages/ARCH/Tests/AgentControlTests"),
// `Fixtures` holds the pages the snapshot and action scripts run on in WebKit.
.testTarget(name: "AgentTests", dependencies: ["Agent", "ARCHEngineWebKit"], path: "Packages/ARCH/Tests/AgentTests", resources: [.copy("Fixtures")]),
```

Bundle: `scripts/bundle_app.sh` copies the built `arch-cli` to `Arch.app/Contents/Helpers/arch-cli`, makes `Contents/Helpers/arch-mcp` a relative symbolic link to it, and signs as it does now (`codesign --force --deep`). VII.10 checks whether SwiftPM names the binary after the product; the script copies the name SwiftPM writes.

## Local control channel

### Transport

- One `SOCK_STREAM` Unix domain socket. Arch adds no TCP, UDP, HTTP, WebSocket, Bonjour, launchd agent, login item, or XPC service. `arch-mcp` is a standard-input process started by its client; it listens on nothing.
- Path: `~/Library/Application Support/Arch/Agent/control.sock`, with both sides taking the home folder from `getpwuid(getuid())`, never `$HOME`. When the path exceeds `sun_path`'s 104 bytes, both sides use `<per-user temporary folder>/xyz.taeyoon.arch/control.sock`, with the folder from `confstr(_CS_DARWIN_USER_TEMP_DIR)`.
- The `Agent` folder has mode 0700 and the socket 0600 (umask set around `bind`). Before binding, Arch `lstat`s the folder: it must be a folder, not a symbolic link, owned by the user, with mode 0700. A socket file is removed only after a `connect` to it fails, so a second Arch leaves a live one alone and reports the channel as unavailable.
- Arch listens only while an in-app session on a CLI runs or Allow Outside Clients is on. Otherwise the socket file does not exist and clients report that agent access is off. API-key sessions need no socket.
- While Allow Outside Clients is off, the socket serves only in-app sessions: Arch answers a `hello` without a valid ticket with `refused` ("outside access is off") and shows no grant sheet, and the client exits with code 69.

### What "runs no servers" allows

Allowed: this socket, while the app runs; child processes that Arch starts with pipes and ends at quit, as command-line providers already do; `arch-mcp` as a standard-input child of whichever client starts it; Apple Events through `Arch.sdef` as today. Not allowed: any listening TCP or UDP socket, loopback included; an HTTP, WebSocket, or MCP streamable HTTP endpoint; an OAuth callback listener; a debugging port (the bridge sets no remote debugging port for Chromium, and check 59's `lsof` would list one); a launchd job or login item; a relay; a process that outlives Arch; any request from Arch to a vendor's service. The CLIs reach their vendors as they do in a terminal, under the user's sign-in.

### Framing and methods

- Frames: a 4-byte big-endian length, then a UTF-8 JSON-RPC 2.0 message, at most 16 MiB (a full-page screenshot fits); a larger frame closes the connection. Length framing keeps page text from splitting messages.
- The client's first message is `hello` with `protocol` (1), `client` (`arch-cli` or `arch-mcp`), the client's version, and an in-app session ticket if it has one. Arch answers with its version and the connection's status: `bound` (an in-app session), `granted` (level, Persona, expiry), `none` (no grant yet), or `refused` with a reason. Another protocol version is refused with both versions named, and the client exits with code 75.
- Methods: `tools/list`, `tools/call`, `tools/cancel`, `task/start`, `task/send`, `task/events` (a stream of notifications), `task/stop`, `sessions/list`, `grant/show`, `grant/release` (a client may give up its own grant and can never widen one), and `guide/get`. Notifications from Arch: `progress` (a call ID and a sentence such as "Waiting for your approval in Arch"), `tools/changed` (the client's tool list changed, as after a grant), `revoked` (then Arch closes the connection), and `task/event`.
- Every `tools/call` carries a client-chosen call ID; Arch answers each once. A connection runs at most four calls at a time; more are refused with `busy`.

### Peer checks

Arch accepts a connection only when all of these hold, checked on accept before it reads a byte:

1. Same user: `getsockopt(SOL_LOCAL, LOCAL_PEERCRED)` gives the peer's effective user ID, which must equal Arch's.
2. Audit token: `LOCAL_PEERTOKEN` gives the peer's audit token, from which Arch takes the process ID and its version (`audit_token_to_pid`, `audit_token_to_pidversion`), so a reused process ID cannot pass.
3. Code identity: `SecCodeCopyGuestWithAttributes` with `kSecGuestAttributeAudit`, then `SecCodeCheckValidity`, and the code directory hash (`kSecCodeInfoUnique`) must equal the one Arch reads at launch from its own bundle's `Contents/Helpers/arch-cli` through `SecStaticCodeCreateWithPath`. The same rule applies to Apple Development and ad hoc signatures. Each rebuild changes the hash on both sides together, and no signing identity or team is written anywhere (plan Working Rule 8). A copy of the binary elsewhere has the same hash and behavior, so the check does not require the bundle's path.

A connection that fails a check is closed at once and logged as refused with the reason and executable's name. This keeps other programs from speaking the protocol. It cannot keep the user's own processes from running `arch-cli`, so grants control their access.

### Client checks of Arch

`arch-cli` and `arch-mcp` apply the same checks to the listening process before sending `hello`: same user, valid code, and the code directory hash of `Contents/MacOS/Arch` in the app bundle containing the client. They find the bundle from the client's own path (`_NSGetExecutablePath`, then `realpath`, which follows a PATH link). A client that finds anything else, or runs outside an app bundle, exits with code 77 ("the socket is not Arch's") and sends nothing. A program that binds the path first therefore collects no ticket or call.

### In-app sessions: tickets

- When Arch starts a CLI for a session, it makes a base64url-encoded ticket of 32 random bytes (`SecRandomCopyBytes`). The ticket reaches `arch-mcp` as `ARCH_AGENT_TICKET` through the CLI's MCP configuration (Claude Code, Codex below). `arch-mcp --session` refuses to run without it.
- Arch binds a connection to the session only when the ticket matches in a constant-time comparison and the session's CLI process is an ancestor of the peer. Arch walks the parent chain with `sysctl` (`CTL_KERN`, `KERN_PROC`, `KERN_PROC_PID`), reading each process's parent ID (`kp_eproc.e_ppid`) and start time (`kp_proc.p_starttime`) from its `kinfo_proc`, and compares process IDs and start times with the process it spawned, whose start time it reads the same way right after `posix_spawn`. A CLI may start its MCP server more than once; each connection binds while the CLI process lives.
- The ticket dies with the session. A ticket from a process outside that tree is refused and logged, and the session shows "Another program tried to use this session's access."
- The ticket is not a secret from the user's own processes, which can read the user's files and environments; the ancestry check binds it. Risks says so.

### Outside clients: identity, grants, revocation

Identity: Arch identifies the client by the peer's nearest ancestor that is not a shell, `env`, `login`, `sudo`, or one of Arch's tools, walking the chain through `sysctl` as for tickets. Security's `SecCodeCopyGuestWithAttributes` with `kSecGuestAttributePid`, `SecCodeCopyPath`, and `SecCodeCopySigningInformation` give the ancestor's path and signature, and Arch reads its start time again afterward, so a process that ended in between is not taken for another.

- A signature with a team identifier identifies the client by signing identifier and team. Any other signature, ad hoc ones included, whose identifier the signer chooses (`codesign -s - -i <any>`), counts as unsigned: the client is its executable path and code directory hash. The enclosing `.app` bundle's name is for display ("claude in Terminal"). An unsigned client's identity changes with each update, so it asks again.
- The walk never stops at launchd (process 1) or at Arch itself, as for a job the system adopted or `arch-cli` in the built-in terminal, since every such process would share the grant. The client is then the process just below them on the chain, by path and code directory hash, bound to that process's ID and start time so that its grant ends with it, and the sheet names its executable ("zsh in Arch's terminal").
- An interpreter such as `node` or `python3` is one identity for every script it runs, and the sheet says so.

The first `tools/call` asks for a grant; `hello` and `tools/list` do not, so a client can start and list tools at once. The grant sheet appears in Arch's frontmost main window, a notification without page content posts while Arch is in the background, and the call waits. While Allow Outside Clients is off, no grant sheet appears (Transport).

| Field | Choices | Default |
|---|---|---|
| Client | The identity above, with its executable path | — |
| Persona | Agents (created on demand, empty, no sign-ins), or an existing Persona | Agents |
| Space | A space of that Persona, where the client's agent folder goes | Its first space |
| Access | Read Only; Ask Before Acting; Act in Agent Tabs | Read Only |
| Extra scopes | Search history (history is shared by every Persona, Persona rule 6); Start agent tasks on your AI subscription (`task/start`) | Both off |
| Duration | Until Arch quits; 24 hours; Until I revoke it | Until Arch quits |

- Every grant asks for Touch ID or the login password through LocalAuthentication (`deviceOwnerAuthentication`), as Arch does for other sensitive settings, except a Read Only grant in the Agents Persona with no extra scope until Arch quits. A grant in one of the user's own Personas reads with their sign-ins, so it always asks.
- The sheet has no default button, so Return and Space do nothing; Allow requires a pointer click, and the posted-event check of sensitive cards (Approval interface) applies to it.
- The sheet explains in plain sentences which Persona's sign-ins the client can use and that pages it reads may contain text aimed at it. It also explains that if the client can run commands on the Mac, a page could try to make it do so, and Arch cannot prevent that. The sheet says that sensitive steps still ask in Arch.
- Don't Allow remembers nothing; the next call asks again, at most once a minute per identity, so a looping client cannot flood the user.
- A grant is a ceiling: no call exceeds its level, sensitive steps still ask, and a grant never carries approvals.
- Revocation: Settings ▸ AI ▸ Agents lists grants (client, Persona, space, access, scopes, expiry, last use) with Revoke and Revoke All. A connected client's sidebar row has Disconnect. Revocation or expiry sends `revoked`, fails the client's running calls with `revoked`, denies its pending approvals, and closes its connections at once.

### Sealed settings

`agent.json` carries an HMAC-SHA256 (CryptoKit) over its contents, encoded with sorted keys. The 32-byte key is in a generic password item (service `xyz.taeyoon.arch.agent`, accessible when unlocked, not synchronizable). It is read once per launch on a separate Keychain queue off the main thread, as `AIKeychain` does. A file whose seal does not match, as after another program edited it, is renamed to `agent.json.unreadable`. Arch starts with the defaults (outside access off, no grants, the Agents Persona an ordinary Persona) and says so in Settings ▸ AI ▸ Agents. This keeps an outside agent with a shell from granting itself access by editing a file. `ai.json` stays unsealed (Risks).

A key the Keychain does not give is not a mismatch: the user may have cancelled the login keychain prompt that follows each ad hoc rebuild (`docs/ai.md`, Keychain), or the keychain may be locked. Arch then leaves `agent.json` untouched and, for that launch, keeps outside access off and uses no grant. It keeps the recorded Agents Persona agent-only, trusting the unverified ID only to restrict a Persona, never to widen one. Settings ▸ AI ▸ Agents says why, with Try Again. Only a verified mismatch renames the file.

### Fallback transport

If the user overturns decision 1, the channel moves to Apple Events with the same messages: one custom event, class `'ArAg'` and ID `'call'`, outside `Arch.sdef` so AppleScript users see only today's terms. It is handled through `NSAppleEventManager` with `suspendCurrentAppleEvent()` so a long call never blocks the main thread. The handler reads the sender's audit token (`keySenderAuditTokenAttr`) and applies the code identity check above. macOS asks the user once per sending app for Automation consent. A GUI MCP client app whose own Info.plist lacks `NSAppleEventsUsageDescription` may be denied without a prompt, since that description belongs in the sender's Info.plist, not Arch's. Every call answers within 45 seconds, returning `approvalPending` if still waiting, because a sent event waits with a timeout. Tickets, grants, and the tool host stay as designed. None of this is built unless the user overturns decision 1.

## Sessions on the user's CLI

### Connecting a subscription

- Settings ▸ AI ▸ Providers ▸ Add Provider gains two presets beside HTTP API and Command-Line Tool: Claude Code (Claude subscription) and Codex (ChatGPT subscription). Each is a command-line provider whose `AICommandLineConfiguration` has `agent` set to `.claudeCode` or `.codex`. A preset finds the executable through the login shell's PATH (`AICommandLineConfiguration.locateExecutable(named:)`) or lets the user choose it; Arch downloads nothing.
- Arch builds these providers' arguments for every request, so the editor hides Arguments, Output, and Runs Without Its Own Tools. It keeps Environment for non-secret variables such as `CLAUDE_CONFIG_DIR` or `CODEX_HOME` when the user has moved the tool's folder. It also keeps Models and Limits. Limits default to two concurrent requests so a running turn does not block the page reader. The minimal environment never carries `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, so each tool uses its own sign-in.
- Models: the user names them as for any command-line provider, or leaves the name empty for the tool's default; Claude Code accepts aliases such as `sonnet` and `opus`. Neither tool has a command that lists models.
- The editor shows the version (`--version`) and sign-in state from the tool's own status command: `claude auth status --json`, from which Arch reads only `loggedIn`, and `codex login status`, from which it reads only the exit status. When signed out, it offers Sign In. This opens the built-in terminal with `claude auth login` or `codex login` typed at the prompt but not run (`TerminalWindowController.show(typing:)`, a new member). The user presses Return, and the tool runs its own sign-in.
- Check runs only status and capability probes, never a model, so it uses no subscription allowance: the status command; for Claude Code, whether `claude --help` lists every listed flag Arch passes; for Codex, `codex --no-daemon features list` and the configuration probe below. If a flag or feature is missing, Check names it and suggests updating the tool in the terminal.
- Sessions run the same probes before their first turn, and Arch keeps the results (the `--help` check, Codex's derived disables and probe) under a key of the executable's resolved path (`realpath`), size, and modification time. Before each process start, a `stat` of the path checks the key. When it changed, as after a tool updated itself by switching a link (`~/.local/bin/codex` to `…/standalone/current/bin/codex` to `releases/<version>`, `~/.local/bin/claude` to `~/.local/share/claude/versions/<version>`), Arch reads `--version` and runs the probes again before the turn, so a feature a new version adds is off from its first turn.
- Ordinary requests through these presets (page reader, questions, hooks, Plugin Writer) use the arguments in Ordinary requests, with no tools, and therefore accept page data (decision 4).

### Claude Code

One long-lived process per session (decision 11):

```
claude -p --verbose
  --input-format stream-json --output-format stream-json --include-partial-messages
  --no-session-persistence --session-id <session UUID>
  --restricted --tools ""
  --strict-mcp-config --mcp-config <session folder>/mcp.json
  --allowedTools "mcp__arch__*"
  --permission-mode dontAsk --permission-prompts none
  --disable-slash-commands
  --append-system-prompt <static harness>
  --max-turns 150
  [--model <name>] [--effort <level>]
```

| Argument | Why |
|---|---|
| `-p`, stream-json in and out, `--include-partial-messages` | Non-interactive, with machine-readable events and text deltas; each user message goes to standard input |
| `--verbose` | Earlier versions required it with stream-json output; whether 2.1.323 does is checked in VII.9 |
| `--no-session-persistence`, `--session-id` | No transcript on disk; Arch names the conversation |
| `--restricted` | Removes the command-running tools and web fetch, and ignores the user, project, and local settings files, hooks among them. A probe showed that plain `-p` runs the user's own `SessionStart` hook and that `--restricted` suppresses it, so the argument tests pin it |
| `--tools ""` | No built-in tools |
| `--strict-mcp-config --mcp-config` | Only Arch's server, none from the user's configuration |
| `--allowedTools "mcp__arch__*"`, `--permission-mode dontAsk`, `--permission-prompts none` | Arch's tools run without the CLI asking, since Arch asks; anything else is denied and nothing waits for a prompt |
| `--disable-slash-commands` | The user's own skills and commands stay out of Arch's sessions |
| `--append-system-prompt` | The static harness, which holds no session facts (decision 12) |
| `--max-turns 150` | A limit in the tool alongside the host's per-turn limit (Limits). It is not in `--help`, so a version that drops it fails to start before reading a message |

- Not passed: `--bare`, which never reads the subscription sign-in; `--safe-mode`, which also turns MCP servers off; `--fallback-model`, which moves any turn to another model while the first is overloaded and retries the first at the next turn, so the model could change mid-conversation (Model choice and fallbacks); the tool's switch for its integration with another browser, whose name would name another browser product (`AGENTS.md`), since `--restricted`, `--tools ""`, `--strict-mcp-config`, and the start check keep it out; `--dangerously-skip-permissions` and `bypassPermissions`.
- `mcp.json` (mode 0600 in the session folder, so the ticket stays out of the argument list):

```json
{ "mcpServers": { "arch": { "type": "stdio", "command": "<bundle>/Contents/Helpers/arch-mcp", "args": ["--session"], "env": { "ARCH_AGENT_TICKET": "<ticket>" } } } }
```

- Environment: the command-line providers' minimal environment (`HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`, `LANG`, `TMPDIR`, `TERM=dumb`), the provider's configured variables, and `DISABLE_TELEMETRY=1`, `DISABLE_ERROR_REPORTING=1`, `DISABLE_AUTOUPDATER=1`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `ENABLE_TOOL_SEARCH=false` (so Arch's tools are not deferred behind a search tool), `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` and `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` (so the user's own instruction files and memory, such as a global "decide without asking", do not join a browser session and work against `ask_user` and `request_approval`), `MCP_TIMEOUT=20000`, and `MCP_TOOL_TIMEOUT=900000` (above the approval wait). The variable names are in the binary; their effects are checked in VII.9.
- Start check: Claude Code writes no `system` `init` event before the first message reaches standard input (a probe with open, idle input for 6 seconds produced none), so the check gates the tools rather than the first message. Arch writes the first message, which holds only the user's words and the preamble of decision 12. Until the `init` event passes the check, the tool host holds the session's tool calls for at most 10 seconds, then refuses them, so no page data flows. The check requires every tool in `tools` to start with `mcp__arch__` and the list to include every tool the session's `tools/list` offered. It also requires `mcp_servers` to be exactly `arch` with status connected, `permissionMode` to be `dontAsk`, `plugins` and `skills` empty, `agents` empty or holding only the built-in agent types VII.9 records for the version (no tool in `tools` can start one), no `memory_paths`, and `analytics_disabled` true. Otherwise Arch ends the process group and shows "Claude Code started with tools Arch did not ask for: …" or "Arch's tools did not connect." The user's first words may already have reached the vendor then; nothing from the browser has.
- Follow-up: one `user` message per line on standard input, through the open input mode that `CommandLineProcess` gains (today it writes its input once and closes standard input).
- Stop: the stream-json interrupt request, whose shape VII.9 records; if the turn has not ended within 3 seconds, SIGTERM to the process group and SIGKILL 2 seconds later. Stopping the process ends the tool's conversation. The next message starts a new process whose first message carries the earlier conversation as text from Arch's transcript (the user's messages and the agent's replies, not tool results), marked as earlier conversation.

### Codex

One process per turn; follow-ups resume the thread:

```
codex --no-daemon exec --json --skip-git-repo-check --ignore-user-config --ignore-rules
  -c sandbox_mode="read-only" -c approval_policy="never" -c web_search="disabled"
  -c history.persistence="none" -c project_doc_max_bytes=0
  -c analytics.enabled=false -c otel.exporter="none" -c check_for_update_on_startup=false
  --disable <each feature the derivation below names>
  -c mcp_servers.arch.command="<bundle>/Contents/Helpers/arch-mcp"
  -c mcp_servers.arch.args=["--session"]
  -c mcp_servers.arch.env_vars=["ARCH_AGENT_TICKET"]
  -c mcp_servers.arch.required=true
  -c mcp_servers.arch.startup_timeout_sec=20
  -c mcp_servers.arch.tool_timeout_sec=900
  -c mcp_servers.arch.default_tools_approval_mode="approve"
  -c developer_instructions="<static harness as a TOML basic string>"
  [-m <model>] [-c model_reasoning_effort="<level>"]
  -C <session folder> -
```

Follow-up turns: `codex --no-daemon exec resume <thread id> --json` with the same `--skip-git-repo-check --ignore-user-config --ignore-rules`, `-c`, and `--disable` arguments, the session's `-m`, and `-`, run with the session folder as the working directory, since `exec resume` takes neither `-C` nor `-s`. Without `-m`, a resumed turn could run on Codex's default model rather than the session's.

| Argument | Why |
|---|---|
| `--no-daemon` | A top-level flag, so it comes before `exec` (`codex exec --no-daemon` is rejected): the turn runs in the spawned process even while a shared app-server that the user's own Codex started is running. `--disable daemon_auto_start` only keeps Codex from starting one |
| `--json`, `-` | JSON lines on standard output; the prompt from standard input, never in the arguments |
| `--ignore-user-config`, `--ignore-rules` | The user's `config.toml` (its MCP servers, profiles, hooks) and command rules do not load; sign-in still comes from `CODEX_HOME` |
| `sandbox_mode="read-only"`, `approval_policy="never"` | Anything that would still run is read-only and never waits for a person |
| `web_search="disabled"` | No web search outside a tab |
| `history.persistence="none"`, `project_doc_max_bytes=0` | The user's words do not join Codex's prompt history, and no project document loads |
| `analytics.enabled=false`, `otel.exporter="none"`, `check_for_update_on_startup=false` | The tool's own telemetry and update check stay off in Arch's runs |
| `mcp_servers.arch.*` | Arch's server only; the ticket passes by name from the environment Arch gives `codex`; `required` fails the turn when the server cannot start; a tool timeout above the approval wait; the CLI approves Arch's calls because Arch asks the user |
| `developer_instructions` | The static harness through a key Codex validates, rather than project-document discovery in a folder outside a Git repository, encoded as a TOML basic string so that text cannot be read as TOML |

- Feature derivation: before the first turn, and again whenever the executable changed (Connecting a subscription), Arch runs `codex --no-daemon features list` with `CODEX_HOME` set to an empty temporary folder (`$TMPDIR/Arch-Codex-Probe-<UUID>/`, mode 0700, removed afterward). The user's own `config.toml` would otherwise change the reported states, which `--ignore-user-config` then ignores in the session: a feature the user turned off there is listed as off, gets no `--disable`, and is back at its default in Arch's run. The command works signed out. Arch passes `--disable` for every listed feature, whatever its reported state, except those at stage `removed`, which the tool no longer switches, and those on Arch's keep list. The keep list starts empty, and a feature joins it only with a reason recorded beside it, when VII.9 shows that a turn needs it and that it adds no tool. With Codex 0.164.0 the derivation disables all 136 features not at stage `removed`, among them `shell_tool`, `unified_exec`, `shell_snapshot`, `browser_use`, `browser_use_external`, `in_app_browser`, `computer_use`, `code_mode_host`, `apps`, `plugins`, `remote_plugin`, `hooks`, `multi_agent`, `image_generation`, `view_image`, `skill_mcp_dependency_install`, `skill_search`, `tool_suggest`, `tool_call_mcp_elicitation`, `goals`, `sleep_tool`, and `daemon_auto_start`, so a later version's new feature is off until reviewed. A list without `shell_tool` or `unified_exec` causes the session to be refused, since Arch could not confirm that the shell is off.
- Configuration probe: when the derivation runs, and at Check, Arch runs `codex --no-daemon --strict-config <every -c and --disable of the session> app-server --print-startup-config` with `CODEX_HOME` set to the same empty temporary folder. This validates every key, value, and feature name and starts nothing. With the user's `CODEX_HOME`, one stale key in the user's `config.toml` would fail it with the same message as a bad argument from Arch. The tool names an unknown feature but reports an unknown key or value only as "startup configuration unavailable". On failure, Arch probes the arguments in groups and refuses the session, naming the group the tool refuses: each `-c` alone, except the `mcp_servers.arch.*` arguments, which go together because the server is invalid without its `command`.
- `--no-daemon` and the disabled `daemon_auto_start` keep the turn in the spawned process, so no shared app-server outlives Arch or serves a socket, the turn never runs in a server that loaded the user's `config.toml`, MCP servers, and features, and `arch-mcp` is a descendant of the `codex` process Arch spawned, which the ticket check and the process-group stop assume. VII.9 checks this with a shared daemon already running.
- Stream watcher: Codex has no start event that lists tools, so Arch accepts only the item types `agent_message`, `reasoning`, `mcp_tool_call` to the server `arch`, `todo_list`, and `error`. Any other item, including `command_execution`, `file_change`, and `web_search`, or an MCP call to another server ends the process group at once and shows what happened. The read-only sandbox is the second layer.
- Thread: Codex keeps the thread, with the page text the agent read, in its own folder under `CODEX_HOME`, which `resume` needs. The panel says so. When the user deletes the session, Arch runs `codex delete <thread id>` unless Settings ▸ AI ▸ Agents ▸ Keep Codex's Copy of Agent Conversations is on. `--ephemeral` cannot be resumed, so sessions do not use it.
- Environment: the minimal environment, the provider's variables, and `ARCH_AGENT_TICKET`.
- The user's own instructions: `--ignore-user-config` skips only `config.toml`, and `project_doc_max_bytes=0` covers project documents. VII.9 records whether a non-empty `$CODEX_HOME/AGENTS.md` or `AGENTS.override.md` joins a turn under these arguments and looks for an argument that keeps it out. If one joins and no argument keeps it out, the composer warns, while the file is not empty, that Codex adds the user's own instructions from that path to Arch's sessions; the host's rules apply whatever the model was told.

### Ordinary requests

The presets' requests for other features carry page data with no tools and no MCP server:

- Claude Code: `-p --output-format stream-json --verbose --include-partial-messages --no-session-persistence --restricted --tools "" --strict-mcp-config --permission-mode dontAsk --permission-prompts none --disable-slash-commands [--model <name>]`, with the environment above less the MCP variables, the prompt on standard input, and the text from the text deltas. An `init` that lists any tool or server, or fails the start check's other conditions, ends the request with `blockedByPolicy(.agentUsedOwnTools)` before the model's reply could call one.
- Codex: `--no-daemon exec --json --ephemeral --skip-git-repo-check --ignore-user-config --ignore-rules` with the session's `-c` arguments other than `mcp_servers` and `developer_instructions`, the derived `--disable` arguments, `[-m <model>]`, and `-`, with the text of the completed `agent_message` item. The stream watcher applies.

### The session folder

`$TMPDIR/Arch-Agent-<session UUID>/`, mode 0700, is the CLI's working directory. It holds only `mcp.json` (Claude Code), so the tool finds nothing else on disk there. Arch removes it when the session ends and, at launch, removes folders left by an earlier run.

### The runner

`AIAgentSession` in `AI` builds the arguments, starts the tool through `CommandLineProcess` in a process group of its own with pipes, and decodes its events:

| Arch event | Claude Code line | Codex line |
|---|---|---|
| `ready` | `system` `init` that passed the start check | `thread.started` (its thread ID) |
| `text` | `stream_event` with a text delta | `item.completed` of type `agent_message` |
| `thinking` | `stream_event` with a thinking delta | item of type `reasoning` |
| `usage` | `result.usage` (`input_tokens`, `output_tokens`, `cache_read_input_tokens` as cached input) | `turn.completed.usage` (`input_tokens`, `cached_input_tokens`, `output_tokens`) |
| `notice` | `rate_limit_event` | — |
| `turnFinished` | `result` (`subtype`, `is_error`) | `turn.completed`, `turn.failed`, `error` |

- The field names come from strings in the binaries; VII.9 records real transcripts as test fixtures and matches the decoders to them. Unknown Claude Code line types are skipped; unknown Codex items end the session, as the watcher requires.
- Timeouts: 120 seconds to the first output, as for command-line tools, and 180 seconds between outputs. The latter timer pauses while one of the session's tool calls runs in Arch's host, since the tool prints nothing while Arch waits for the user.
- The panel's tool steps come from Arch's tool host, not from the stream, so what the user sees is what Arch did.
- Errors map to `AIError`: a signed-out tool to `authentication` with Open Terminal, a nonzero exit to `providerUnavailable` with the last line of standard error, and the start check and the watcher to `blockedByPolicy(.agentUsedOwnTools)`, a new reason.

```swift
public enum AIAgentKind: String, Codable, Sendable, CaseIterable { case claudeCode, codex }

// AICommandLineConfiguration
/// Set by the Claude Code and Codex presets. Arch then builds every argument and reads the output in the kind's format; `arguments`, `output`, and `runsWithoutTools` do not apply.
public var agent: AIAgentKind?

// AIModelCapability
/// Derived: models of a provider with an agent kind, and HTTP models with `tools`. `ai.json` overrides cannot add or remove it.
case agent

public struct AIAgentToolServer: Sendable {
    public var executable: URL              // Contents/Helpers/arch-mcp
    public var arguments: [String]          // ["--session"]
    public var environment: [String: String] // ARCH_AGENT_TICKET
    /// The `mcp__arch__` tools the session offers, which Claude Code's start event must list.
    public var tools: [String]
}

public struct AIAgentSessionRequest: Sendable {
    public var feature: AIFeatureID         // .agent
    /// The session's model; nil uses the route.
    public var model: AIModelRef?
    public var instructions: String         // the static harness
    public var toolServer: AIAgentToolServer
    public var folder: URL
    public var effort: String?
}

public enum AIAgentEvent: Sendable {
    case ready(AIModelRef), text(String), thinking(String), usage(AIUsage), notice(String), turnFinished(AIFinishReason)
}

@MainActor
public final class AIAgentSession {
    public let events: AsyncThrowingStream<AIAgentEvent, any Error>
    public func send(_ message: String)
    public func stop()
    /// Pauses the idle timer while the host runs one of the session's calls.
    public func toolCallDidStart(), toolCallDidEnd()
}

extension AIService {
    public func startAgentSession(_ request: AIAgentSessionRequest) throws -> AIAgentSession
}

extension AIFeatureID { public static let agent = AIFeatureID(rawValue: "agent") }
```

### Model choice and fallbacks

- `AgentService` registers the `agent` feature (trigger `user`; data `page`, `selection`, and `file` for screenshots; requirement `agent`). Its route lists models with the `agent` capability (decision 14) and is on by default, like other features the user starts. Without such a model, Arch shows no agent command.
- The composer shows the route's first model, a menu of the other agent models for the session, and an effort menu where the tool takes one (Claude Code's `--effort`; Codex's `model_reasoning_effort`, whose values VII.9 records).
- Fallbacks apply only when a session starts: Arch moves to the route's next model when the first fails before `ready` (tool missing, signed out, a failed probe or start check, `providerUnavailable`, `authentication`, `rateLimited`). Once a tool holds the conversation, a failure ends the turn with the error and offers Retry and Start Over With \<model>. A conversation never moves to another model: Claude Code runs without `--fallback-model`, and every Codex turn, resumed ones included, passes the session's `-m`. The panel and usage still take each turn's model from the stream (Claude Code's `result` `modelUsage`, which VII.9 confirms), so a model the tool chose by itself shows as it is.

### API-key sessions

- With an HTTP model that has `tools`, the same session runs on `AIClient.run(_:tools:maxRounds:)` with `AIToolHandler`s that call the same tool host and policy, at most 50 rounds per user message. No socket is involved.
- `AIRequest` gains `pinnedModel: AIModelRef?`, so every round of a session uses the model of its first round.
- Tool results return as `.text` parts for text the host wrote and `.page` parts for page text, so the interface's part checks (site exclusions, query and fragment removal) apply. Screenshots return as `.file` parts with an image type when the model has `images`.
- The conversation is the session's `[AIMessage]` in memory. Tool results older than the last eight rounds become one-line notes ("Read 12,000 characters of t2"). A screenshot is sent only in the round that took it, so long sessions stay within the model's input limit.

## Tools

### Catalog

One catalog in `AgentControl` serves `tools/list`, the MCP server, the CLI's commands, and the API-key loop. Names are 1 to 64 characters from `a-z`, `0-9`, and `_`, valid for MCP, `AITool`, and both CLIs. Tab handles are `t1`, `t2`, and so on per session, or per grant for an outside client. They last while Arch runs and are never reused; a handle from elsewhere reads as not found. Classes: R reads, N navigates in agent tabs, I interacts, S is sensitive (Permissions and approvals).

| Tool | Input | Output | Class |
|---|---|---|---|
| `session_info` | — | Mode, Persona, space, site scope, agent tabs, limits left, what asks | R |
| `list_spaces` | — | Spaces of the session's Persona: handle, name, agent tab count | R |
| `list_tabs` | `scope` (`agent` default, `shared`) | Agent tabs (handle, title, address, loading, engine) and tabs the user shared (handle, title, host) | R |
| `request_tab` | `reason`, `access` (`read` or `act`) | The tab the user picks in Arch, shared with the session, or `denied` | R, asks |
| `open_tab` | `url` or `ref` (a link in a snapshot), `tab?` (the ref's tab), `engine?` | The new agent tab, opened in the background | N |
| `navigate` | `tab`, and `url`, `ref` (follow that link), or `action` (`back`, `forward`, `reload`) | Address and title once the document loads, or after 30 seconds | N |
| `close_tab` | `tab` | — (agent tabs of this session or client only) | N |
| `snapshot` | `tab`, `mode` (`interactive` default, `full`), `ref?` (a subtree), `max_chars?`, `diff?` | The page as an outline with refs (Page snapshots) | R |
| `read_text` | `tab`, `offset?`, `max_chars?` | Readable text from `readableContent`, paged | R |
| `screenshot` | `tab`, `area` (`viewport`, `full`, or a ref) | One image | R |
| `click` | `tab`, `ref`, `count?` (1 or 2), `modifiers?` | What it hit, and the events that followed | I |
| `type` | `tab`, `ref`, `text`, `replace?`, `submit?` | The field it typed into, and the events | I |
| `press` | `tab`, `keys` (such as `Enter`, `Escape`, `Meta+A`), `ref?` | The events | I |
| `select_option` | `tab`, `ref`, `values` | The selected values | I |
| `scroll` | `tab`, `ref?` or `direction` with `amount?` | The new position | I, allowed in Read Only because it changes no data |
| `hover` | `tab`, `ref` | The events | I, allowed in Read Only likewise |
| `wait_for` | `tab`, one of `load`, `text`, `url`, `ref`; `timeout_ms` (at most 30,000) | Met or timed out | R |
| `list_downloads` | — | Downloads the session's tabs started: name, size, state, no path | R |
| `search_history` | `query`, `limit` (at most 20) | Titles and addresses without query or fragment; excluded sites left out | R, needs the scope or setting |
| `ask_user` | `question`, `choices?` | The user's answer | R, waits for the user |
| `request_approval` | `summary`, `kind` (`submit`, `purchase`, `send`, `delete`, `download`, `other`), `tab?` | `approved`, `denied`, or the user's instruction | S |
| `hand_to_user` | `tab`, `reason` (`sign_in`, `verification`, `payment`, `other`), `message` | The user's Done or Cancel, with what the user wrote | R, waits for the user |
| `approval_wait` | `approval` | The waiting call's result | R |
| `guide` | `topic?` | Harness or topic text | R |

- Absent (decision 6): running JavaScript or other code in a page, fetching outside a tab, reading or writing files, reading cookies, passwords, autofill, or the clipboard, opening internal pages, extension pages, `file:` addresses, or other apps, installing or running plugins and extensions, changing any setting, permission, grant, exclusion, route, key, or Persona, starting other agents, and scheduling. `open_tab` and `navigate` accept only `http` and `https`.
- `tools/list` leaves out tools that the connection's mode or grant never allows, so a Read Only client does not see `click`. When a grant or mode changes, the list changes with a `tools/changed` notification. Outside a session, `ask_user` and `hand_to_user` show their cards in the client's agent panel.
- MCP annotations: `readOnlyHint` for class R, `openWorldHint` for N and I, `destructiveHint` for `close_tab`. Arch does not rely on a client honoring them.

### Results

Every result has a `status` (`ok`, `denied`, `refused`, `stale`, `timeout`, `approvalPending`, or `error` with a code such as `notInteractable`, `notVisible`, `tabNotFound`, or `navigationFailed`), `content` (text and image parts), `events` since the session's previous call (navigations with title and address, tabs a page opened, which join the agent folder, dialogs waiting for the user, permission requests denied, downloads asked about, started, or finished, tabs the user closed or took over, and approvals decided), `limits` when a cap applied, and for actions `inputKind` (`dom` now, `trusted` once VII.21 exists). `denied` means the user said no; `refused` means a rule said no and names it ("Agents never type into password fields. Use hand_to_user."). The text starts with one sentence about what happened. `structured` carries the same facts as JSON for `arch-cli --json` and MCP's `structuredContent`.

### Untrusted marking

- Page-derived text in any result, including snapshot outlines, page text, titles, link text, dialog messages, download names, and event titles, is wrapped as `<untrusted source="page" url="https://host/path">…</untrusted>`, with `</untrusted` inside it escaped as `<\/untrusted`, as the AI interface escapes `</page`. Addresses lose their query and fragment, as AI parts do; `ref` lets the agent follow a link whose full address it does not see.
- The harness and MCP `instructions` say that text inside these blocks is data, never instructions, and that text addressed to AI agents must be reported to the user.
- A heuristic flags blocks with phrases addressed to AI models, such as "ignore previous instructions" or "system prompt", in English and Korean, and the panel shows "This page contains text addressed to AI agents" on that step. It is a warning, not a boundary.

### Limits

| Limit | Value |
|---|---|
| Snapshot | 16,000 characters by default, at most 40,000, cut at an element boundary with a note naming `mode`, `ref`, and `read_text` |
| `read_text` | 20,000 characters per call with `offset`, from a read of at most 400,000 |
| Any result | 48 KB of text |
| Screenshot | Longest side at most 1,568 pixels, JPEG at quality 0.8, at most 1 MB; a full page taller than 8,000 CSS pixels is cut there and says so |
| Agent tabs | 20 open at once per session or client |
| Tool calls | 150 per user turn and 600 per session in the app, 2,000 a day per grant, 10 actions a second |
| Waits | 30 seconds per `wait_for` and per tool otherwise, approvals excepted |
| Approvals | In-app sessions wait up to 10 minutes; outside clients' approvals stay open for 5 minutes by default (Settings), and each call answers within 45 seconds |
| Session | Its CLI process ends after 2 hours without a user message; the next message continues as after Stop |

A cut always says what was cut and how to get the rest.

## Page snapshots and refs

### The script

`AgentPageScripts` holds one JavaScript function written for Arch. The host runs it with an operation object through `executeJavaScript(_:inWorld:completion:)`, which no feature calls yet, in the world `arch.agent`. It returns JSON text. WebKit runs it in a `WKContentWorld` of its own; Chromium runs every world in the page's main world, so a page can replace the built-ins the script calls (Engines). The script keeps nothing in the page between calls (decision 13); anything it kept for a later call on Chromium would be reachable by the page.

### Format

```
page "Checkout – Example" example.org/checkout   t3 · chromium · snapshot 4
- banner
  - link "Home" [e1] → example.org/
  - searchbox "Search" [e2] value=""
- main
  - heading "Your order" level=1
  - textbox "Email" [e5] value=<personal> (asks the user)
  - textbox "Card number" [e6] value hidden (agents do not type here)
  - button "Place order" [e7] submits form (asks the user)
- frame "Payments" (another site; not read)
```

- Roles follow HTML's implicit roles and explicit `role`; names follow reduced accessible name rules (`aria-labelledby`, `aria-label`, `<label>`, `alt`, `title`, `placeholder`, then the text for roles named by content), at most 80 characters. The outline is computed from the DOM on both engines, so it does not depend on an engine's accessibility tree, which Chromium builds only while an assistive app asks.
- Interactive mode keeps elements with refs and the landmarks and headings around them; full mode adds visible text in paragraphs of at most 200 characters each. Hidden elements, `aria-hidden` subtrees, `script`, `style`, and `template` are left out; open shadow roots are followed; same-origin frames are walked with refs like `f1e3`; frames of other sites are listed, not read.
- `diff: true` returns the lines added, removed, or changed since the session's last snapshot of the tab, which the host keeps.
- Annotations come from the policy, so the model knows before it tries: "(asks the user)" on elements a rule asks about, "(agents do not type here)" on fields rule P1 covers, and "(CAPTCHA: hand to the user)" on frames of known challenge services and elements named as one.

### Refs

Refs are indexes in the script's walk. The snapshot returns a fingerprint per ref (tag, role, input type, and the first 40 characters of the name), which the host keeps with the document's address. An action passes the index and fingerprint. The script walks again; if the element at that index differs or the address changed, the action fails with `stale`: "The page changed since your last snapshot. Take a new snapshot." For links, the host also keeps the full address, which `open_tab` and `navigate` with `ref` use.

### Fields the script never reveals

- No value for: password inputs; fields whose `autocomplete` names a credential, one-time code, or payment token (`current-password`, `new-password`, `one-time-code`, `cc-*`); fields whose label, name, or ID names a secret (password, PIN, passcode, CVV, CVC, security code, verification code, OTP, token, API key, social security number, and Korean equivalents such as 비밀번호, 인증번호, 주민등록번호); hidden inputs. They show `value hidden`.
- Personal data (`autocomplete` tokens for email, telephone, street address and postal code, and birthday; `type=email` and `type=tel`) shows as `value=<personal>`.
- In a tab the user shared, no field values, as `readableContent` already leaves them out.
- Elements inside frames from extension origins, including password managers' inline menus, are left out and cannot be targets, so an agent cannot pick a stored credential from such a menu.
- Screenshots reveal no more: a capture shows the rendered values, as after the user typed a card number during `hand_to_user` or a password manager filled a field. Before every capture that goes to an agent, the host runs the script's `boxes` operation, which returns the boxes of fields in the hidden and personal classes, of frames from other sites (which a snapshot lists but does not read, and where payment fields often live), and of extension frames. On both engines the host paints them over in the captured image before scaling and encoding. It reads the boxes again after the capture; if they moved, it captures once more and then refuses. A tab whose script does not answer gets no screenshot. The capture on an approval card, which only the user sees, is not painted over.

### Actions

Each action resolves the ref, checks that the element is connected, visible, enabled, and the topmost element at its center (`elementFromPoint`; a cover is named in the error), scrolls it into view, and then acts through DOM events: a pointer and mouse event sequence and `click()`; focus, then the native value setter from the element's prototype with `input` and `change` events, or `insertText` for editable areas; `KeyboardEvent`s, with Enter in a form field calling `requestSubmit()`; `selected` with `change`. These events are not trusted (`isTrusted` is false), and the result says `inputKind: dom`; sites that ignore them need VII.21. The script also returns the facts the policy reads: role, name, input type and `autocomplete`, whether the element submits a form, the form's field kinds, the form's action site, and whether it is a file input, which is refused (rule P7).

After an action, the host waits for the tab's load to finish or 3 seconds, plus 300 milliseconds, before answering. Each script call has a 10-second limit; a page that does not answer, such as while a dialog shows, gets "The page shows a dialog or does not respond. It waits for the user."

### Engines

| Need | Chromium | WebKit |
|---|---|---|
| Open, navigate, back, forward, reload, close | `EngineBrowser.createWebContents`, `navigationController`, `tryToClose` | Same |
| Checks before each navigation and redirect (P13, P16) | The adapter asks the navigation delegate only about Shift-clicked links today; VII.12 makes it ask about every main frame navigation and redirect from the bridge's `OnBeforeBrowse`, which already answers links to other apps | The adapter asks the navigation delegate about every navigation; VII.12 checks that this includes each server redirect |
| Snapshot, refs, actions | `executeJavaScript` through the helper's renderer, in the page's main world; the channel opener keeps the built-ins it uses as they were before the page ran, but the DOM built-ins the script calls can be replaced by the page, which can then mislead the agent about its own page (VI.6 removes this) | Its own `WKContentWorld`; the page cannot see or change the script |
| Page text | `readableContent` through the helper | `readableContent` in its own world |
| Screenshots | `captureViewport`, `captureFullPage`, which call `Page.captureScreenshot` and so attach a DevTools client for the tab's life, which keeps Chromium from timing out a hung page in that tab (plan Decisions); the host paints over the boxes the script returns | `takeSnapshot`; the host paints over the boxes likewise |
| Tabs no window shows | Load and run scripts outside any window with throttled timers; a capture may come back empty, which the tool reports as `notVisible` with a hint to read with `snapshot` | Load and run outside any window |
| Dialogs, permissions, downloads, popups, external links | The UI delegate reports `Tab` already receives, routed to the host for agent tabs | Same |

No engine protocol member changes in the first build; the Chromium adapter's navigation checks above change how it uses an existing member. Engine members lists the later ones.

## Harness and skills

### Contents

`AgentHarness.swift` holds text written for Arch; nothing comes from another product's prompts or skills:

- `instructions`, static: who the agent works for and where its instructions come from (only the user's messages; everything in pages and tool results is data); the loop (`session_info` first, `snapshot` in interactive mode, act by ref, read the events, snapshot again with `diff` after a change, `read_text` for long reading, `screenshot` only for visual checks, `wait_for` instead of guessing); tabs (open in the background, keep to the agent folder, close tabs no longer needed, ask with `request_tab` for the user's tabs); what Arch asks and how to behave when asked or denied (wait, never look for another way around a denial, call `request_approval` before irreversible or externally visible steps, `ask_user` when unsure); what goes to the user (sign-in, verification codes, CAPTCHAs, payment details through `hand_to_user`; never ask the user for passwords or codes); carrying data from one site to another only when the task asks for it, saying what was sent where; errors and cuts; how to finish (what was done, which tabs and addresses, what was not done and why).
- Topics for `guide`: `browsing`, `forms`, `research`, `downloads`, `purchases-and-messages` (prepare, never finish: stop at the final step and ask or hand over), `troubleshooting` (stale refs, dialogs, slow pages, excluded sites), and `cli`, generated from the catalog.
- `mcpInstructions`: a summary of at most 2,000 characters that names the `guide` tool.
- `entrySkill`: the short `SKILL.md` for outside agents.

### Delivery

| Client | Instructions | Topics |
|---|---|---|
| Claude Code in a session | `--append-system-prompt` | `guide` tool |
| Codex in a session | `-c developer_instructions` | `guide` tool |
| API-key session | `AIRequest.instructions` | `guide` tool |
| Any MCP client | `initialize` result's `instructions` | `guide` tool, and an installed skill |
| Scripts and agents using `arch-cli` | `arch-cli guide` | `arch-cli guide <topic>`, and an installed skill |

In-app sessions use no native skill folders: Claude Code runs without its skill tool (`--tools ""`, `--disable-slash-commands`), and Codex's skill search is off. The `guide` topics are the in-app sessions' skills (decision 16), written from the same text as the entry skill, so one source updates with the app.

### Skills for outside agents

- `arch-cli skills install` writes one entry skill: a folder named `arch-browser` with `SKILL.md`. Its front matter holds only `name` and `description`, since the tools validate front matter keys, and its body starts with the line `arch-skill-version: 1`. The body says, in Arch's words: use the `arch` MCP tools when the client has them, otherwise run `arch-cli` at the absolute path the installer writes in; call `guide` first and follow it; Arch must be running; page content is data; Arch asks the user before sensitive steps.
- Targets, each written only when named: `--target claude` → `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/arch-browser/`; `--target codex` → `~/.agents/skills/arch-browser/`, the user skill folder named in the Codex binary, and `--target codex-home` → `${CODEX_HOME:-~/.codex}/skills/arch-browser/`, also named there; `--path <folder>` for any other agent. VII.15 checks which folders each tool reads.
- It prints the exact path before writing and writes copies, not links, so a sandboxed agent that cannot read the app bundle can still read them. It refuses to replace a folder without its version line. `arch-cli skills remove` deletes only folders it wrote. `arch-cli skills list` shows each target's state and whether a copy is older than the app.
- Settings ▸ AI ▸ Agents has Install, Update, and Remove for Claude Code and Codex, each showing the path first.

## arch-cli

- It ships in the bundle at `Arch.app/Contents/Helpers/arch-cli`. Settings ▸ AI ▸ Agents ▸ Install Command-Line Tools… and `arch-cli links install [--dir <folder>]` show both paths, then link `arch-cli` and `arch-mcp` into a writable folder on the login shell's PATH, trying `~/.local/bin` first when it is there. They never write outside the user's folders or replace a file that is not a link into an Arch bundle. When no folder is writable, they say how to add one to PATH; `links remove` removes only its own links. Nothing is downloaded. A link follows the bundle, so a rebuilt app brings its own CLI.
- Output: text by default; `--json` prints the result's `structured` value, one JSON object per line for streams. Text to type can come from standard input (`--text -`), so it stays out of argument lists and shell history. Handles belong to the grant, so `t3` from one `arch-cli open` works in the next `arch-cli click`.
- Exit codes: 0 done, 1 tool error (such as a stale ref), 2 usage error, 3 denied by the user, 4 refused by a rule, 5 timed out, 6 no grant or the grant was refused, 69 Arch is not running or agent access is off, 70 internal error, 75 protocol mismatch, 77 the socket is not Arch's.

| Command | Does |
|---|---|
| `arch-cli status` | Whether Arch runs, agent access, this client's grant, versions |
| `arch-cli guide [topic]` | The harness or a topic; works without Arch running |
| `arch-cli tools` | The catalog with parameters |
| `arch-cli spaces`, `arch-cli tabs [--shared]` | Lists |
| `arch-cli open <url>`, `navigate <tab> <url>`, `back`, `forward`, `reload`, `close <tab>` | Agent tabs |
| `arch-cli snapshot <tab> [--full] [--ref r] [--diff]`, `text <tab> [--offset n]`, `screenshot <tab> [--full\|--ref r] -o <file>` | Reading; a screenshot is written only to the file named, or to `arch-screenshot-<time>.png` in the current folder |
| `arch-cli click <tab> <ref>`, `type <tab> <ref> (<text>\|--text -) [--submit]`, `press <tab> <keys>`, `select <tab> <ref> <value>…`, `scroll <tab> …`, `hover <tab> <ref>` | Acting; a step that waits for approval prints "Waiting for your approval in Arch…" and keeps calling `approval_wait` |
| `arch-cli wait <tab> --load\|--text t\|--url u [--timeout ms]` | Waiting |
| `arch-cli downloads`, `arch-cli history <query>` | Lists |
| `arch-cli call <tool> '<json>'` | Any tool with raw JSON arguments |
| `arch-cli task "<task>" [--space name] [--mode read\|ask\|act] [--model name] [--deny-approvals]` | Starts an in-app session on the user's `agent` route and streams its progress; requires the grant's Start Agent Tasks scope. The session runs in the grant's Persona, in the space `--space` names among that Persona's spaces (the grant's space by default), at most at the lower of the grant's level and the Settings default, so `--mode` can only lower it. Addresses in the client's task text do not join the site scope. Approvals happen in Arch and count as an outside client's, so sensitive ones ask for Touch ID; `--deny-approvals` denies each at once |
| `arch-cli sessions [list\|show <id>\|stop <id>]` | Sessions this client started |
| `arch-cli skills list\|install\|remove [--target claude\|codex\|codex-home] [--path <folder>]` | Skills |
| `arch-cli links install [--dir <folder>]`, `links remove` | PATH links |
| `arch-cli mcp-config [claude\|codex\|json]` | Prints the configuration with the absolute path of `arch-mcp`: `claude mcp add --scope user arch -- <path>`, or Codex's `[mcp_servers.arch]` table with `tool_timeout_sec = 120` |
| `arch-cli setup claude\|codex` | Shows `claude mcp add --scope user arch -- <path>/arch-mcp` or `codex mcp add arch -- <path>/arch-mcp`, asks y/N, and runs it; Arch never edits another tool's configuration files itself |
| `arch-cli release` | Gives up this client's grant |
| `arch-cli mcp` | Runs as `arch-mcp` |

There is no command for signing in, settings, grants other than releasing one's own, remote hosts, or starting Arch; `arch-cli status` says to open Arch when it is not running.

## arch-mcp

- A stdio MCP server: JSON-RPC 2.0, one message per line, logs on standard error. `initialize` answers with the client's protocol version when it is 2024-11-05, 2025-03-26, 2025-06-18, or 2025-11-25, otherwise with the newest; `serverInfo` `{ "name": "arch", "version": <app version> }`; capabilities `{ "tools": { "listChanged": true } }`; and `instructions`. No resources, prompts, sampling, logging, or elicitation.
- `tools/list` comes from Arch for the connection's grant or session. While Arch is not running or no grant exists yet, it comes from the compiled-in catalog. After a grant or mode change it sends `notifications/tools/list_changed`.
- `tools/call` becomes one control `tools/call`. Text results become `text` content with `structuredContent`; screenshots become `image` content with `mimeType`. A call that waits for the user answers after at most 45 seconds with `approvalPending`, an approval ID, and "Waiting for the user in Arch; call approval_wait with this ID.", which works under any client's tool timeout; in-app sessions raise their tools' timeouts (Claude Code, Codex) so a call simply waits. While a call waits, it sends `notifications/progress` when the client gave a progress token. `notifications/cancelled` cancels the call in Arch and withdraws its approval. A call while Arch is not running returns an error result: "Open Arch and turn on Allow Outside Clients in Settings ▸ AI ▸ Agents."
- With `--session`, it presents `ARCH_AGENT_TICKET` and refuses to run without it; without `--session`, it is an outside client and the grant applies.
- MCP elicitation is never used for approvals: a client can answer it by itself, and some clients have automatic reviewers. Approvals are Arch's (decision 5).

## In the browser

### Agent folders

- A session belongs to one space and its Persona. Its tabs sit in an agent folder among the space's open tabs. The folder takes its name from the task's first words, and the user can rename it. It is a `TabFolder` with an `agentSessionID` that is not encoded, and `SessionStore` leaves agent folders and their tabs out of `session.json` (decision 10).
- Agent tabs are ordinary tabs otherwise: they use the Persona's profiles on either engine, so the agent works with the user's signed-in sites, and the Persona's plugins' page scripts and web extensions run in them. They open in the background with the default engine, never take focus, and never switch the window's space. A page that an agent tab opens joins the folder with its opener's engine.
- The user can select any agent tab to watch it or drag it out of the folder to take it over. Taking over a tab removes it from the agent's reach and makes it an ordinary tab that is saved and records visits. Keep Tabs turns the folder into an ordinary folder. Close Other Tabs and the archive timer skip agent folders of running sessions. Unkept agent tabs close at quit.
- Closing an unkept agent tab, by `close_tab`, by the user, at the session's end, or at quit, passes `remember: false` to `BrowserSession.closeTab`, so it never joins the closed list that `session.json` saves and ⇧⌘T reopens, and the tab close log leaves it out.
- An outside client's tabs go to an agent folder named after the client ("Claude Code · Terminal") in its grant's space.
- Deleting the space stops its sessions; deleting a Persona stops and removes its sessions and grants.

### Sidebar and attention

- The agent folder's row shows the session's state before its name: running, waiting for the user, done, failed, or stopped. Its context menu has Show Session, Stop, Keep Tabs, and Delete Session.
- When a session in another space waits for the user, that space's symbol in the bottom bar shows a dot. While Arch is in the background, a waiting session posts a notification through UserNotifications that says only "An agent is waiting for you in Arch", with no page or task text, since notifications show on the lock screen. Clicking it opens the panel at the waiting card.
- While an outside client is connected, a row below the plugin sidebar items names it ("Codex · Terminal — Read Only — Agents") with Disconnect.
- While any agent acts, the bottom bar shows an agents indicator. Its menu lists the acting sessions and clients and Stop All Agents, also available as File ▸ Stop All Agents. Stop All Agents cancels every running call, denies every pending approval, stops every session's CLI process group, disconnects every outside client, and keeps the grants.
- While its session acts, an agent tab shown in a window gets a thin colored frame in the app interface around the page area, not over it.

### The agent panel

- It replaces the page reader in the trailing column (`PageReaderColumn`) at the same width; only one shows, in main and small windows alike. It shows the selected agent tab's session, or the one chosen from a row, a notification, or View ▸ Show Agent Panel.
- Header: the session's title, tool and model, mode (a menu that lowers the mode at once and raises it only after a confirmation), the site scope, and Stop. Transcript: the user's messages; the agent's replies, rendered as the page reader renders them (inline Markdown, no images, links showing their full address and opening only when clicked); thinking, collapsed; one row per tool step from the host ("Clicked “Next” on example.org", "Read t2 — 12,000 characters"), each naming its tab with a button that shows it; approval and question cards inline; errors as one sentence with one action, as `docs/ai.md` Errors defines; and the model and tokens under each turn.
- Composer: a field with Send, which becomes Stop while a turn runs, and the selected tab attached as a removable chip unless its site is excluded. Messages typed during a turn are shown as queued with Remove and sent when the turn ends.
- Take Over pauses the session and selects the tab; Hand Back resumes it. Keep Tabs keeps the folder.
- Empty states: without an agent model, "Add Claude Code or Codex in Settings ▸ AI" with Open AI Settings; with the tool signed out, the status with Sign In.

### Starting a session

- File ▸ New Agent Task opens the composer in the panel for the window's current space and its Persona, with the selected tab attached. The composer offers Use the Agents Persona, which starts the session in the Agents Persona's space instead.
- The command palette: once the text has two or more words, an Ask Agent row ("Ask Agent: “compare these two plans”") follows the primary row while the `agent` feature has a usable model. Return on it starts a session; rows for running sessions whose titles match the text switch to them.
- The page reader and the question popover gain Continue as Agent Task, which opens the composer with the question and the tab attached.
- In a small window, the panel shows in the small window's trailing column. The session belongs to the small window's destination space (the space Move to Main Window would use), its agent tabs open in that space's folder, and the small window's tab is attached as a shared tab.
- New Agent Task, Show Agent Panel, and Stop All Agents have no default shortcut, as Show Page Reader has none; Settings ▸ Shortcuts lists them.
- A session ends when the user deletes it or Arch quits. Its transcript stays in memory until then.

### Settings ▸ AI ▸ Agents

- New sessions start in: Read Only, Ask Before Acting (default), or Act in Agent Tabs.
- Let In-App Agents Search History (off).
- Allow Outside Clients (`arch-cli` and `arch-mcp`) (off), with the sentences of the grant sheet and of Risks about outside clients.
- Outside clients' approval window: 2, 5 (default), or 10 minutes.
- Keep Codex's Copy of Agent Conversations (off).
- Command-line tools: where `arch-cli` and `arch-mcp` live, Install Command-Line Tools… and Remove; the MCP configuration for Claude Code and Codex with Copy; skills for Claude Code and Codex with their paths, Install, Update, and Remove.
- Grants with Revoke and Revoke All; Activity.
- A note that Codex keeps its own copy of agent conversations unless removed, and that Claude Code keeps none of Arch's sessions.

Settings ▸ AI ▸ Providers gains the presets, and Settings ▸ AI ▸ Features the Agent Tasks row (`agent`).

## Permissions, approvals, and injection defenses

### Modes

| Mode | R | N in agent tabs | I | S |
|---|---|---|---|---|
| Read Only | yes | yes, by the site scope rule for in-app sessions | refused, except `scroll` and `hover` | refused |
| Ask Before Acting (default) | yes | yes, by the site scope rule | asks, with Allow on This Page and Allow on \<site> for This Session | always asks |
| Act in Agent Tabs | yes | yes, by the site scope rule | free in agent tabs on sites in scope (in-app) or in the client's own agent tabs (outside); asks once per site elsewhere | always asks |

- An in-app session starts in the mode set in Settings. The user can lower it at any time and raise it only from the panel's mode menu with confirmation. An outside client's mode is its grant's level, which the client cannot raise. A session an outside client starts with `arch-cli task` starts at the lower of the grant's level and the Settings default, and the client's `--mode` can only lower it.
- `session_info` and the panel's header show the mode and scope, so the agent knows what requires approval.

### Site scope and navigation

An in-app session's scope contains registrable domains: the sites of tabs attached at the start or shared later; the sites of addresses the user wrote in the task or a later message; and sites the user allows during the session. The search engine set in Settings ▸ General is in it only through its results address (`SearchEngine.resultsURL` with nothing but the search terms set), not as a domain, so its redirect endpoints are not. In a session an outside client started, the client's task text adds nothing, since the user did not write it. Rule P13 below applies the scope in every mode, and P16 refuses excluded sites in every session.

- Seen addresses: the host keeps each address the session has seen verbatim, compared after normalizing scheme, host case, default port, and an empty path: the committed address of each of its tabs, the full address behind each link ref in its snapshots, the addresses in the user's own messages, and each address the user approved.
- A link the agent follows, by `ref` or a click, opens without asking because the page wrote its address, which can carry only what the page already has.
- An address the agent writes (`open_tab` or `navigate` with `url`) opens without asking only when it is a seen address, the search engine's results address, or the bare origin (`https://host/`, no path, query, or fragment) of a site in scope. Any other written address asks in every mode, also on a site in scope, because its path, query, or fragment can carry what the agent read elsewhere: the card shows the full address with the parts the session has not seen highlighted ("The agent wants to open shop.example/t?d=… — an address no page showed"), and a site outside the scope adds "a site you did not name".
- Redirects: the host applies P13 and P16 again at each redirect hop of a navigation the agent started, before the hop's request (Engines). A hop to an excluded site is refused; a hop of a navigation by a written address that leads to a site outside the scope stops the navigation and asks with the hop's full address.

### Site exclusions

- Every reading tool (`snapshot`, `read_text`, `screenshot`, `wait_for` with `text`) and every event and tab title checks, at call time, the tab's committed address and the address of each same-origin frame it reads against the current exclusions in `ai.json`, with the AI module's `AISitePattern` matcher. A page on an excluded site returns `refused` (P16), and events and lists name it with no title. A site the user excludes during a session is therefore refused at the next call.
- P16 applies to every navigation in an agent tab, not only the agent's: each redirect hop, each navigation a page starts by itself, and each popup that joins the agent folder. A hop's request leaves before its page commits, so the host refuses it before the request where the engine asks (Engines), and the read checks keep any page that still commits on an excluded site from the agent.
- CLI sessions and outside clients get these checks, with the same matcher and the same query and fragment removal, in place of the AI interface's part checks; API-key sessions get both.

### Rules

`AgentPolicy.swift` holds these rules in a table tested for every mode and both client kinds. The host classifies each call by the tool, the page script's element facts, the page's address, and the session's state.

| Rule | Trigger | Result |
|---|---|---|
| P1 | Typing or pressing keys into a password, credential, one-time-code, or payment field, or a field whose label names a secret | Refused: "Agents never type credentials, codes, or card details. Use hand_to_user." |
| P2 | Typing into a personal-data field | Asks, showing the exact text |
| P3 | Submitting a form (a submit control, or Enter in a field) that contains password, one-time-code, payment, or personal fields | Asks |
| P4 | Clicking a control whose name or value reads as an irreversible step: buy, purchase, order, checkout, pay, subscribe, donate, transfer, send, post, publish, share, reply, comment, submit, delete, remove, cancel subscription, unsubscribe, confirm, agree, accept, sign, and Korean equivalents such as 구매, 결제, 주문, 구독, 송금, 보내기, 전송, 게시, 공유, 댓글, 제출, 삭제, 탈퇴, 확인, 동의, 수락, 서명 | Asks |
| P5 | Submitting a form whose action is on a different site from the page, after the session typed into it | Asks |
| P6 | A download from an agent tab (`shouldDownload`) | Asks, with Allow Downloads from This Site for This Session |
| P7 | A file input or a file chooser in an agent tab | Refused until VII.22; then asks, and the user picks the file in `NSOpenPanel`; the agent never names a local path |
| P8 | A permission request (camera, microphone, location, screen, notifications, and others) from an agent tab | Denied without asking; the result tells the agent to hand the tab to the user |
| P9 | A `confirm`, `prompt`, or leave-page dialog, or HTTP authentication, in an agent tab | The user answers in Arch's own card over the agent tab's pane; the agent waits, and `Browsing`'s `AgentBrowserHost` reads the tab's `TabPromptQueue` to tell the agent that a prompt waits; the agent sees the dialog's text as untrusted |
| P10 | An `alert` in an agent tab | Dismissed and reported as an event |
| P11 | A link to another app (`openExternally`) from an agent tab | Asks, naming the app |
| P12 | Any interaction in a tab the user shared | Asks every time, whatever the mode |
| P13 | In-app navigation by an address the agent wrote that is not a seen address, the search engine's results address, or the bare origin of a site in scope; a redirect hop of a written address's navigation to a site outside the scope | Asks, in every mode (Site scope and navigation) |
| P14 | In-app typing on a site outside the scope in Act in Agent Tabs | Asks, showing the exact text |
| P15 | `request_approval` | Asks |
| P16 | Navigation, a redirect hop, a page's own navigation, or a popup to a site excluded from AI, an internal page, a `file:` address, or another scheme; any read of a page on an excluded site | Refused; events from an excluded page carry no title; the card offers no change to the exclusions (decision 15) |
| P17 | Closing a tab the session did not open; acting on a tab of another session or Persona | Refused; an unknown handle returns not found |
| P18 | A CAPTCHA or bot check | Refused: "Hand the tab to the user." |

- P4's word list reads page-controlled text, so a page can label a button to avoid a match. The words can only add approval requests, never remove one. The harness tells the model to call `request_approval` before any irreversible step, and the default mode asks before every action. This remains under Risks.
- A JavaScript dialog never gets an automatic OK, and no CAPTCHA is solved.
- No mode, grant, or setting turns P1 to P18 into automatic approvals, whatever the amount, site, or client. Arch has no "pay under an amount" or "send without asking" setting, and approvals never outlive their session.

### Approval interface

- Cards appear in the agent panel beside the page and in the sidebar's folder row, never over the page, so a page cannot draw or cover one.
- A card leads with facts the host computed: the action in a sentence ("Click “Place order” on shop.example"), the tab and site, the element's box marked on a fresh viewport capture when the tab can be captured, and the exact text or address that would be sent. The model's explanation follows under "The agent says:", marked as the agent's.
- Buttons: Allow Once, Allow on This Page (I class in Ask Before Acting, until the document changes), Allow on \<site> for This Session (I class, P14), Deny, Deny and Stop, and Reply…, which sends an instruction instead of yes or no. These allowances cover typing too, so the card for a `type` call says that the site then receives whatever the agent types there (Risks). Cards for P2 to P5, P11 to P13, and P15 are sensitive: they offer only Allow Once, Deny, Deny and Stop, Reply…, and Take Over (the user does it). A P13 card allows only its one address, whose site then joins the scope.
- The host applies P1's secret words to the text of `ask_user`, `hand_to_user`, and `request_approval` cards. On a match, an Arch-written line leads the card: "Agents never need your passwords or codes. Type them only into the page after Take Over." An answer goes to the agent, and an address that would carry it on to a site asks under P13.
- Sensitive cards have no default button, so Return and Space do nothing, and Allow requires a pointer click. VII.13 checks whether a click's event source process (`CGEventField.eventSourceUnixProcessID`) distinguishes hardware clicks from posted events; if it does, Allow also refuses posted events. For outside clients, and in sessions an outside client started with `arch-cli task`, Allow on a sensitive card also asks for Touch ID or the login password, so a program that drives the interface through accessibility cannot approve.
- Several approvals can queue per session. An approval for a page that has moved on is withdrawn and its call fails with `stale`. Unanswered approvals are denied (`timeout`), as are pending approvals at Stop, Stop All Agents, revocation, and quit.

### Injection defenses

| Threat | Example | Defense |
|---|---|---|
| Text in a page | A page tells the agent to send the inbox it read to another site, or to its own site, which is in scope | Untrusted marking; written addresses that no page showed ask in every mode; the site scope and the rules in the host; no fetch or code tool; the CLI's own tools off and checked |
| Text in tool output and events | A tab title or dialog text addressed to the model | The same marking; events carry page text only in untrusted blocks |
| A steered model that approves itself | `request_approval` with a misleading summary | Cards lead with facts the host computed; the model's words are labeled as the agent's |
| A page that drives the user | A page asks the user to remove a site exclusion | Cards never edit exclusions (decision 15) |
| Quiet use of the user's sign-ins | A script runs `arch-cli` to read the user's mail tab | Grants approved in Arch, with Touch ID for any Persona but Agents, the Agents Persona by default, user tabs only through `request_tab`, the connected client's row, revocation |
| Web pages reaching the channel | Requests to a local port, DNS rebinding | No port |
| Other accounts on the Mac | Another account connects | Folder and socket modes, the peer user check |
| A squatter on the socket | A program binds the path before Arch | Clients check Arch's code and exit 77 |
| Editing Arch's files | An outside agent with a shell edits the grants | `agent.json` sealed with a Keychain key |
| Accidental approval | Return approves a purchase | No default button; Touch ID for outside clients |
| A runaway agent | A loop opens hundreds of tabs | Limits; Stop All Agents |

## What the agent can never change

No tool, command, control method, or MCP call exists for: Settings and `ai.json` (providers, keys, routes, exclusions, limits); `agent.json` (modes, grants, outside access); site permissions; plugins and web extensions and their grants; Personas and spaces of other Personas; cookies and site data; passwords and passkeys; the clipboard; local files; internal pages; AppleScript; and other apps. `Arch.sdef` gains no agent or approval term. Only the user can change modes, grants, scopes, and approvals, through Arch's interface.

## Personas, history, and permissions

- A session belongs to one Persona from its creation: the Persona of the space where the user started it, or the grant's Persona for an outside client. Its tools see only that Persona's spaces and tabs.
- The Agents Persona is an ordinary Persona with storage of its own on both engines (Persona rule 2), so it holds no sign-ins until the user signs in there. `agent.json` records its ID, and the session leaves it out of `SitePermissionAnswers.follow(_:)` and denies its permission requests without a sheet or a record (decision 9). If `agent.json` loses its seal, the Persona becomes ordinary again.
- In the user's own Personas, `BrowserSession` copies the remembered answers from `permissions.json` into every profile. On Chromium, `CEFBridgeRequestContext` sets them as content settings, so Chromium answers a remembered request without asking the delegate. A site the user allowed the camera, microphone, or location keeps that access in Chromium agent tabs of that Persona. P8 applies on WebKit, which asks the delegate each time, and to every request that is not remembered. The composer says so when the session's Persona has such answers.
- Agent tabs record no history visits, so pages an agent visits enter neither suggestions nor the app-wide history (Persona rule 6). `search_history` reads that app-wide history, which spans every Persona. It is off unless the user turns it on for in-app sessions or grants it to an outside client with Touch ID. Its results omit excluded sites, queries, and fragments.
- Downloads: an agent sees only those its own tabs started, by name and state.
- Arch has no private window. If one is added, agents never see its tabs, cannot open one, and a request to read one is refused.

## Usage and cost

- Each turn's tokens come from the tool's stream, or the provider's reply for an API-key model, and go to `AIUsageStore` under the `agent` feature, provider, and model. An Activity entry stays in memory (feature, model, tool step count, tokens, result; Show Content shows the turn's text and tool names, not tool results).
- The panel shows the model and tokens under each turn. A subscription shows "Included in your subscription" and no cost; Claude Code's `total_cost_usd` is ignored, since Arch shows cost only from prices the user entered. An HTTP model shows the estimated cost.
- A rate-limit or quota notice shows only when the tool's stream reports one. Arch reads no usage endpoint and shows no quota meter.
- The monthly spending limit applies to API-key sessions; the daily limit for automatic requests does not apply, since every turn is the user's. The session limits apply to every model.

## Storage

| File | Contents | Protection |
|---|---|---|
| `~/Library/Application Support/Arch/agent.json` | Settings ▸ AI ▸ Agents, grants (identity, Persona, space, level, scopes, expiry, last use), and the Agents Persona's ID | Sealed; no secrets |
| `~/Library/Application Support/Arch/agent-activity.json` | Activity log, 90 days | No content |
| `~/Library/Application Support/Arch/Agent/control.sock` | The socket, while it listens | 0700 folder, 0600 socket |
| `$TMPDIR/Arch-Agent-<session UUID>/mcp.json` | Claude Code's MCP configuration with the ticket | 0700 folder, 0600 file, removed with the session |

- Keychain: `xyz.taeyoon.arch.agent` holds the seal key. Tickets live only in memory and in the session's process tree.
- Activity log entries: time, session or grant, client name, Persona ID, tool, class, the page's registrable domain, decision (`auto`, `approved`, `approvedWithTouchID`, `denied`, `refused` with the rule, `timedOut`), and outcome. Grant events (granted, first use in a launch, revoked, expired, refused peer) use the same format. No page text, typed text, address path or query, or screenshot. Settings ▸ AI ▸ Agents ▸ Activity lists entries by day with filters by client and site, and Clear Activity. A file that does not decode is renamed to `agent-activity.json.unreadable`, as in other stores.
- Transcripts, tool steps, and approvals stay in memory until the session is deleted or Arch quits, as the page reader's conversations do. Claude Code keeps none (`--no-session-persistence`); Codex keeps its thread until Arch deletes it.
- `ai-usage.json` gains the `agent` feature's totals, with no content.

## Errors

| Situation | What the user and the agent see |
|---|---|
| No agent model | No agent command; Settings ▸ AI says how to add Claude Code or Codex |
| The tool is missing or signed out | "Claude Code is not signed in." with Sign In, which opens the terminal with the command typed |
| A flag, feature, or configuration key is missing | "Codex \<version> does not accept `tool_timeout_sec`. Update Codex in the terminal." with Open Terminal; the session does not start |
| The start check or the watcher fails | "Claude Code started with tools Arch did not ask for: …" or "Codex ran a command." with Retry; the process group has ended |
| The tool's rate limit | The tool's sentence, with its reset time when provided |
| An unanswered approval | The call returns `timeout`; the card shows "Not answered" |
| A rule refuses the call | The result names the rule in a sentence for the model; the panel shows the step as refused |
| The page changed | `stale`: "Take a new snapshot." |
| A hidden, disabled, or covered element | `error` (`notInteractable`) naming the cover |
| A tab that no window shows cannot be captured | `error` (`notVisible`): "Read it with snapshot." |
| `arch-cli` without Arch, without agent access, with the wrong peer, or another protocol | Exit 69, 69, 77, or 75 with one sentence |

`AIPolicyReason` gains `agentUsedOwnTools`. The panel shows AI errors with the actions in `docs/ai.md` Errors.

## Engine members

The first build adds no engine protocol member; `executeJavaScript(_:inWorld:completion:)`, captures, `readableContent`, navigation, and the UI delegate reports cover it. VII.12 changes one adapter rule: the Chromium adapter asks the navigation delegate about every main frame navigation and redirect from `OnBeforeBrowse`, as the WebKit adapter asks about every navigation, so the host can refuse a hop before its request (Site scope and navigation; Site exclusions). Later tasks add these with their features:

- VII.21, trusted input: an optional `EngineWebContents.input` (`EngineInput`) with pointer moves, clicks, wheel, keys, and text at a point in view coordinates. Chromium: bridge methods over `CefBrowserHost::SendMouseMoveEvent`, `SendMouseClickEvent`, `SendMouseWheelEvent`, `SendKeyEvent`, and `ImeCommitText`. WebKit: `NSEvent`s made with public constructors and sent to the web view's responder methods while the view is in a window. The task first checks whether either reaches the page as trusted input. If neither does, actions keep using DOM events rather than a private API.
- VII.22, file choosers: a UI delegate report of a page's file chooser with its accepted types and multiple selection, from `CefDialogHandler::OnFileDialog` and `WKUIDelegate`'s `runOpenPanelWith`.
- VI.6, optional: isolated script worlds on Chromium in Arch's engine, listed in the plan's engine changes table, so pages cannot see or change the agent's script.
- Arch never enables Chromium's remote debugging port: the bridge sets none, and check 59 lists no listening port.

## Tests

- `AgentControlTests`: framing and the 16 MiB limit; JSON-RPC errors; the catalog (names valid for MCP and `AITool`, schemas that parse, annotations that match classes); escaping of `</untrusted`; query and fragment removal; the socket location rule with the long-home fallback; the MCP core against hand-written transcripts (`initialize` with each version, `tools/list` per grant and `list_changed`, `tools/call` with text and image results, `approvalPending` at the cap and `approval_wait`, progress, cancellation, an unknown tool, `ping`, Arch not running), also through pipes against the built executable; the command table and exit codes; `argv[0]` dispatch; the harness (every topic exists, front matter with only `name` and `description`, the version line, MCP instructions within 2,000 characters); the skill and link installers in temporary folders (named targets only, refusal of foreign folders and files, removal of their own only, stale copies reported).
- `AgentTests`:
  - Endpoint: a connection from the test process is refused because it is not Arch's tool; an injected verifier accepts; another user ID is refused; a folder with the wrong mode or a symbolic link is refused; a stale socket is replaced only when nothing answers; the listener exists only while needed; a client refuses a listener whose code does not match; with Allow Outside Clients off, a `hello` without a ticket gets `refused` and no grant sheet.
  - Tickets: refused from a process outside the session's tree (a fake ancestry provider) and after the session ended; constant-time comparison.
  - Identity: a team-signed client by identifier and team; an ad hoc signed one by path and code directory hash; a chain that reaches launchd or Arch bound to the process below it.
  - Grants: levels and scopes; Touch ID asked through a fake authenticator for every grant except Read Only in the Agents Persona with no scope until quit; revocation and expiry close connections, fail running calls, and deny pending approvals; the deny rate limit; a tampered `agent.json` renamed and ignored, with outside access off; a Keychain that does not give the key leaves the file untouched, outside access off, and the Agents Persona agent-only.
  - Policy: P1 to P18 in every mode for in-app and outside clients, as a table; scope additions; followed links against written addresses; written addresses on a site in scope with unseen paths, queries, or fragments asking in Read Only too, seen addresses, the search engine's results address and its other addresses, and bare origins; redirect hops off the scope and to excluded sites; reads refused after a redirect, a page's own navigation, or a popup to an excluded site, and after the user excludes the site mid-session; excluded sites with no card that edits exclusions; shared tabs always asking; tabs of other sessions and Personas not found; a session from `arch-cli task` capped at the grant's level and the Settings default, limited to the grant's Persona's spaces, with no scope from the client's text and Touch ID on sensitive cards.
  - Approvals: grouping per page, withdrawal when the page moves on, denial on timeout, Stop All Agents, revocation, and quit; the warning line on cards whose text names a secret.
  - Tool host over a fake `AgentBrowserHost`: events since the last call, limits and their messages, statuses, the per-turn limit, calls held until `ready` and refused after 10 seconds.
  - Page scripts in WebKit web views over a non-persistent store on fixture pages: roles, names, refs and fingerprints, a stale ref after a DOM change, hidden elements, open shadow roots, same-origin frames, other sites' frames listed, each redaction rule and the personal class, no values in shared tabs, extension frames omitted, the `boxes` operation returning hidden and personal fields, other sites' frames, and extension frames, a screenshot of a filled password field painted over, annotations, a page that replaced built-ins (which cannot reach WebKit's own world), actionability and covers, typing into a framework-style controlled input, selects, Enter submission, element facts, and cuts.
  - Activity log: no entry carries an address path, query, typed text, or page text.
- `AITests`: fake CLIs as shell scripts that record their arguments, environment, and standard input and print the transcripts VII.9 recorded; the exact argument arrays for Claude Code and Codex first turns, follow-ups (with `-m` on `exec resume`), ordinary requests, efforts, and start-only fallbacks with no `--fallback-model`; `--no-daemon` before `exec`; the environment; the start check refusing each failing `init`, a non-empty `plugins` or `skills` and `memory_paths` among them, and passing a good one; the watcher ending on each forbidden and unknown item; the feature derivation from recorded `features list` output with an empty `CODEX_HOME`, disabling features listed as off too, with a refusal when `shell_tool` is missing; a failed configuration probe naming its group, with the `mcp_servers.arch.*` arguments as one; the probes running again when the executable's resolved path, size, or modification time changes; the open input mode writing several messages; Stop sending the interrupt and then ending the process group; the idle timer pausing during host calls; `codex delete` at deletion; usage under `agent`; an `ai.json` override that cannot add `agent`; `pinnedModel`, compaction, and screenshots dropped after their round in the API-key loop through the scripted provider.
- `BrowsingTests`: agent folders and tabs omitted from `session.json`, no visits, Keep Tabs saving them, unkept tabs closed at quit; closed agent tabs kept out of the closed list and the tab close log; P8 denying permission requests in agent tabs; the Agents Persona getting no remembered answers; AppleScript and `list_tabs` reading one sidebar order (`BrowserSession.tabsInSidebarOrder`).
- `PreferencesTests`: the presets' fields from a fake login shell PATH, and status parsing from fake status commands.
- From the bundle: the checks below, and `lsof -nP -p <Arch pid> -i`, which must list no listening port.

## Checks from the bundle

Each task that needs the app adds its check to the regression checklist in `docs/plan.md` with these numbers. Run them on both engines with a fresh Application Support folder.

Fixture pages: a fresh `ai.json` excludes `file:` and `local-network` (`AISitePattern.defaultExclusions`), so P16 refuses fixtures served from `file:` or the Mac itself. Checks 61 and 66 serve `Packages/ARCH/Tests/AgentTests/Fixtures` with a small HTTP server written for the check and kept out of the commit, on `127.0.0.1`, with one path that answers 302 to the same server under `localhost`, a different site. Each check first removes `local-network` in Settings ▸ AI's excluded sites and puts it back afterward.

59. With Allow Outside Clients on, `arch-cli status` from Terminal reports Arch; `arch-cli tabs` shows the grant sheet naming the client, Don't Allow exits 6, and Allow with Read Only and the Agents Persona lists that Persona's tabs; a grant in another Persona asks for Touch ID. `lsof -nP -p <Arch pid> -i` lists no listening port. With outside access off and no session, the socket file does not exist; with outside access off during an in-app session, `arch-cli tabs` exits 69 without a sheet. A script that binds the socket's path before Arch starts makes `arch-cli status` exit 77. A hand-edited `agent.json` is renamed at the next launch and outside access is off.
60. `arch-cli open https://example.org` opens a background tab in the client's agent folder without selecting it; `text` and `close` work. An excluded site is refused, as is `arch-cli open http://127.0.0.1:<port>/` while `local-network` is excluded; a tab the user did not share returns not found. The agent tab records no visit, does not join ⇧⌘T's list when closed, and is gone after a relaunch unless kept.
61. On the fixture form in Ask Before Acting: `snapshot` lists its fields with refs and hides the password field's value; after the user fills the password field by hand, `screenshot -o` writes an image with that field and the personal fields painted over; `arch-cli type` and `click` on its submit button ask in the panel, Deny exits 3, and Allow types and submits; typing into the password field is refused; Return on a sensitive card does nothing; a download asks; a camera request is denied without a sheet; a `confirm` dialog waits for the user.
62. `arch-cli setup claude` in the built-in terminal adds the server; `claude` there lists tabs and reads one after the grant. An approval left for a minute returns `approvalPending`, and `approval_wait` returns its result after Allow. The same holds with `arch-cli setup codex` and `codex`.
63. `arch-cli skills install --target claude` and `--target codex` write the entry skill; a `claude` and a `codex` session in the terminal use it for a web task and read `arch-cli guide`; `skills remove` leaves a foreign `arch-browser` folder alone.
64. Settings ▸ AI ▸ Add Provider ▸ Claude Code shows the version and Signed In without a model request. New Agent Task with the selected tab attached and "summarize this tab and open its first link" reads the tab, opens the link in the agent folder, and asks before a submission. Stop ends the turn within 3 seconds; a follow-up continues. After the session is deleted, no `claude` or `arch-mcp` process remains and the tool's projects folder has nothing for the session folder.
65. The same session on Codex, also while a shared Codex app-server that the user's own `codex` started is running: `lsof` on the session's process group shows no connection to that server's socket, and `arch-mcp` binds its ticket. Deleting the session runs `codex delete`, and no `codex` process remains.
66. In an in-app session with the fixture page attached, in Read Only and in Act in Agent Tabs: the page's text asking the agent to open an outside address with the page's data makes `navigate` ask with the full address; its text asking for its own site's address with that data in the query, a site in scope, asks the same way; the 302 path, written by the user in the task, opens without asking and stops at the hop to `localhost` to ask; with `localhost` excluded, the hop is refused and no read of it succeeds. Stop All Agents ends every session's processes, disconnects outside clients, and denies pending approvals; the grants remain.
67. Typing `compare these two plans` in the palette shows Ask Agent after the primary row, and Return starts a session in the window's space. Continue as Agent Task in the page reader starts one with the question and the tab attached. In a small window, New Agent Task shows the panel in its trailing column, the session's tabs open in the destination space's agent folder, and the small window's tab is attached as a shared tab. A session waiting in another space puts a dot on that space's symbol.

## Facts

Checked on this Mac with Claude Code 2.1.323 and Codex 0.164.0, with no model run and nothing signed in or out:

- `claude --help`: `-p`, `--input-format stream-json` (print mode only), `--output-format stream-json`, `--include-partial-messages`, `--verbose`, `--no-session-persistence`, `--session-id`, `--restricted` (its text as quoted under Claude Code), `--tools`, `--strict-mcp-config`, `--mcp-config`, `--allowedTools`, `--permission-mode` (`acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`), `--permission-prompts host|none`, `--disable-slash-commands`, `--append-system-prompt`, `--model`, `--fallback-model` (a comma-separated list, used when the model is overloaded or unavailable, retrying the primary at the start of each user turn), `--effort` (`low` to `max`), `--setting-sources`, `--plugin-dir`, `--bare` (never the subscription sign-in), `--safe-mode` (turns MCP servers off); `claude auth status --json`. In the binary: `--append-system-prompt-file`, `--max-turns`, the `init` event's `tools`, `mcp_servers`, `model`, and `permissionMode`, `rate_limit_event`, `total_cost_usd`, `cache_read_input_tokens`, `MCP_TIMEOUT`, `MCP_TOOL_TIMEOUT`, `ENABLE_TOOL_SEARCH`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `CLAUDE_CODE_DISABLE_CLAUDE_MDS` (which skips the instruction files), `CLAUDE_CODE_DISABLE_AUTO_MEMORY`, `CLAUDE_CONFIG_DIR`, the `init` event's `agents`, `skills`, `plugins`, `memory_paths`, and `analytics_disabled`, and the `result` event's `modelUsage`. `~/.local/bin/claude` links to `~/.local/share/claude/versions/2.1.323`.
- With `--input-format stream-json` and standard input open and idle for 6 seconds, Claude Code wrote no `init` event, only the user's own `SessionStart` hook events; plain `-p` ran that hook, and `--restricted` or `--setting-sources project` kept it from running.
- `codex exec --help` and `codex exec resume --help`: `--json`, the prompt from standard input with `-`, `--skip-git-repo-check`, `--ephemeral`, `--ignore-user-config` (sign-in still uses `CODEX_HOME`), `--ignore-rules`, `-C`, `-c`, `--enable`, `--disable`; `exec resume` has neither `-C` nor `-s`. `codex --strict-config -c … --disable … app-server --print-startup-config` in an empty `CODEX_HOME` validates keys, values, and feature names and starts nothing: it exits 1 with "Unknown feature flag: \<name>" for an unknown feature and with "startup configuration unavailable" for an unknown key or value, and it exits 0 for every `-c` argument under Codex with the values shown there and for `--disable daemon_auto_start`, `shell_tool`, `code_mode_host`, and `goals`. It also accepts the keys `model_reasoning_effort` and `mcp_servers.<name>.env`, and `default_tools_approval_mode` takes `auto`, `prompt`, `writes`, or `approve`. `codex delete <session>` deletes a saved session. `codex app-server daemon` starts, stops, and bootstraps a shared local app server. `--no-daemon` is a top-level option ("Run without the shared background server, even if it is already running"): `codex --no-daemon exec --help` and `codex --no-daemon exec resume --help` exit 0, `codex exec --no-daemon` is rejected, and the binary tells users to rerun with it "including resume or fork". `exec resume` accepts `-m`.
- With `[features]` setting `browser_use`, `computer_use`, and `shell_tool` to false in a scratch `CODEX_HOME`'s `config.toml`, `codex features list` reports all three as false; in an empty `CODEX_HOME` it reports them true, so it reports the states under the user's configuration. With one unknown key in `config.toml`, `codex --strict-config -c sandbox_mode="read-only" app-server --print-startup-config` exits 1 with "startup configuration unavailable"; in an empty `CODEX_HOME` it exits 0, also with `--no-daemon`. `-c mcp_servers.arch.args=["--session"]` alone fails the same way and passes with a `command`. In an empty `CODEX_HOME`, 136 features are not at stage `removed` (46 are), and the probe accepts a `--disable` for each of them. `features list` and the probe work signed out there.
- `~/.local/bin/codex` links to `~/.codex/packages/standalone/current/bin/codex`, and `current` links to `releases/0.164.0-aarch64-apple-darwin`, which the standalone installer switches when it updates. `~/.codex/AGENTS.md` exists on this Mac, empty.
- In an empty `CODEX_HOME`, `codex features list` reports as enabled, among others, `shell_tool`, `unified_exec`, `shell_snapshot`, `browser_use`, `browser_use_external`, `browser_use_full_cdp_access`, `in_app_browser`, `computer_use`, `code_mode_host`, `apps`, `plugins`, `remote_plugin`, `hooks`, `multi_agent`, `image_generation`, `view_image`, `skill_mcp_dependency_install`, `skill_search`, `tool_suggest`, `tool_call_mcp_elicitation`, `goals`, `sleep_tool`, and `daemon_auto_start`. In the binary: the event names `thread.started`, `turn.started`, `turn.completed`, `turn.failed`, `item.started`, `item.updated`, `item.completed`, the item types `agent_message`, `reasoning`, `mcp_tool_call`, `todo_list`, `command_execution`, `file_change`, `web_search`, the skill folders `~/.agents/skills` and `$CODEX_HOME/skills`.
- macOS 27.2 SDK: `LOCAL_PEERCRED`, `LOCAL_PEERPID`, `LOCAL_PEERTOKEN` (`sys/un.h`); `SecCodeCopyGuestWithAttributes`, `kSecGuestAttributeAudit`, `kSecGuestAttributePid`, `SecCodeCheckValidity`, `SecCodeCopyPath`, `SecCodeCopySigningInformation`, `kSecCodeInfoUnique` (`SecCode.h`); `audit_token_to_pid`, `audit_token_to_pidversion` (`libbsm.h`); `keySenderAuditTokenAttr` (`AEDataModel.h`); `KERN_PROC_PID` and `kinfo_proc`'s `kp_eproc.e_ppid` (`sys/sysctl.h`) and `p_starttime` (`sys/proc.h`). `libproc.h` says it "contains private interfaces to obtain process information".
- Arch: `CommandLineProcess` writes its input once and closes standard input; `CommandLineProvider` waits 120 seconds for first output and 60 between outputs; `AICommandLineConfiguration.locateExecutable(named:)` exists; `TerminalWindowController.show()` takes no command; `executeJavaScript(_:inWorld:completion:)` has no feature caller, runs in its own content world on WebKit and in the main world through the helper on Chromium, and returns a string; Chromium captures call `Page.captureScreenshot`; the bridge has no input methods, no file dialog handler, and no remote debugging setting; `BrowserSession.startRuntime` calls `permissionAnswers.follow(_:)` for every Persona's profile and `CEFBridgeRequestContext` sets content settings from it; `BrowserSession.closeTab` adds a tab to the closed list unless `remember` is false, which `session.json` saves up to 100 records of, and always logs it in `TabCloseLog`; `AISitePattern.defaultExclusions` is `file:` and `local-network`; `SearchEngine.resultsURL` gives the results address; the WebKit adapter asks the navigation delegate about every navigation, the Chromium adapter only about Shift-clicked links, and the bridge's `OnBeforeBrowse` receives `is_redirect`; `Scripting.swift` builds the sidebar order itself; small windows show `PageReaderColumn`; `session.json` is at version 13; `scripts/bundle_app.sh` signs with `codesign --force --deep`, with an Apple Development identity or ad hoc; Arch has no private window.

## Not verified

Each item names the task that checks it first. A differing result changes the design in this note and the affected task row.

- VII.9: whether `--restricted` keeps the subscription sign-in and honors `--mcp-config`; whether `--tools ""` with `ENABLE_TOOL_SEARCH=false` leaves Arch's MCP tools listed in `init` and callable; whether `--allowedTools "mcp__arch__*"` covers every tool of the server and `dontAsk` denies others without asking; whether `--verbose` is required; the stream-json input message, the interrupt request, and the `init` fields; whether `--max-turns` acts as described; whether the user's own instruction files and memory stay out with `--restricted` and the two `CLAUDE_CODE_DISABLE_*` variables; whether `init` lists built-in `agents` without tools, and which; whether `result`'s `modelUsage` names the model of each turn; the effect of the telemetry and timeout variables.
- VII.9: Codex's `--json` events and fields; whether `env_vars` passes the ticket; what `default_tools_approval_mode="approve"` does under `approval_policy="never"`; whether `arch-mcp` reaches the socket from Codex's read-only sandbox; whether `codex --no-daemon exec` and `exec resume` run in process while a shared daemon for the same `CODEX_HOME` is already running, so `arch-mcp` descends from the spawned `codex` and `lsof` on its process group shows no connection to the daemon, and leave no daemon; whether `developer_instructions` is honored; the `model_reasoning_effort` values; which keep-list features a turn needs; whether `history.persistence="none"` keeps the user's prompt history out; whether a non-empty `$CODEX_HOME/AGENTS.md` or `AGENTS.override.md` joins a turn, and whether an argument keeps it out; whether `codex delete` removes the thread.
- VII.10: whether SwiftPM names the executable after its product; whether `codesign --deep` seals the symbolic link in `Contents/Helpers`.
- VII.11: whether the code directory hash that `SecStaticCodeCreateWithPath` reads from the bundled file equals the one the running peer's code reports.
- VII.12: whether the WebKit adapter's navigation policy runs at each server redirect, and whether the Chromium adapter can answer every main frame navigation and redirect from `OnBeforeBrowse`. An engine that cannot ask before a hop leaves the hop to the read checks: its agent tab stops when the hop commits, and the page reaches no agent.
- VII.13: captures of agent tabs that no window shows on both engines; whether a click's event source process distinguishes hardware clicks from posted ones.
- VII.15: the skill folders each tool reads.
- The vendors' current terms for another app starting their CLI on the user's subscription (open decision 2).

## Risks

1. A site in an Act in Agent Tabs session's scope can disguise an irreversible control so that P4 misses it. The default mode asks before every action, the harness requires `request_approval`, and the user picks Act knowingly.
2. On Chromium, the agent's script runs in the page's main world, so a page can alter its own outline, the element facts P2 to P5 read, and the boxes that screenshots paint over. Until VI.6, Chromium agent tabs trust those facts only as far as the page's own content; navigation, downloads, dialogs, permissions, and links to other apps come from the engine and are not affected.
3. Outside clients with their own shell or network can be steered by page text. Arch marks it and warns in the grant sheet; the Agents Persona and Read Only defaults limit what such a client can read.
4. Programs running as the user can start the signed CLIs, read tickets, or post input events. Sealed grants, the ancestry check, Touch ID on grants outside the Agents Persona and on outside clients' sensitive approvals, and the click check raise the bar but are not a sandbox against the user's own account; Settings says so.
5. CLI flags, features, and events change between versions. Arch probes before trusting a version, checks Claude Code's start event, derives Codex's disables from its own list, watches both streams, and refuses rather than guesses. A release can still break sessions until Arch's presets are updated.
6. Codex keeps agent conversations, with page text, in its own folder until Arch deletes them. A crash before deletion leaves them there.
7. On Chromium, a site the user allowed the camera, microphone, or location keeps that access in agent tabs of the user's own Personas.
8. Chromium agent screenshots attach a DevTools client for the tab's life, which turns off Chromium's hung-page timeouts for that tab.
9. `ai.json` is not sealed; a program that edits it can remove site exclusions that agents also obey.
10. Approval fatigue in Ask Before Acting may lead users to Act in Agent Tabs; grouping per page and per site keeps the count down.
11. An agent session can use much of the user's plan, and Arch shows only what the tool reports.
12. Whether the socket fits "Arch runs no servers" depends on interpretation (decision 1, open decision 1).
13. Typing sends data to the page's site as the agent types, since the page's scripts read each field. In Act in Agent Tabs on sites in scope, and after Allow on This Page or Allow on \<site> for a `type` card, a page that steered the agent, often the attached tab itself, receives whatever the agent types there without another card. The card says so, and Ask Before Acting is the default.
14. Address checks cover what an address carries, not every route: an agent steered by a page can still leak a little by which of the page's own links it follows, and the search engine receives the terms the agent searches for. The panel shows each followed link and each search as a step.

## Open decisions

These need the user's decision; everything else above is decided.

1. Decision 1 reads the Unix domain socket as local inter-process communication, not as a server under the plan's Goals. If the user reads the rule more strictly, the channel moves to the Apple Events fallback before VII.11, with the consent and attribution limits that section names.
2. The vendors' terms for another app starting Claude Code or Codex on the user's subscription were not read. The design relies on the plan's Goals: Arch is for internal use and no distribution is planned. The user checks the current terms before any distribution.
3. Decision 16 gives in-app sessions Arch's skills as `guide` topics rather than as the CLIs' native skills, which the request may have meant. If the user wants native skills there, VII.9 first checks how each CLI can be pointed at a skill folder that only the session reads (Claude Code's `--plugin-dir` is a candidate) without loading the user's own skills; VII.15 then writes the entry skill and the topics there and turns on only the CLI's skill tool, and the start check allows exactly those skills.
