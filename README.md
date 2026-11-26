<!--
  README.md is generated from resources/README.preset.md.
  Edits made directly to README.md are lost on regeneration.
  To change the content, edit resources/README.preset.md and run ./scripts/readme_update.sh.
-->

<!-- Hero Image -->
<!--
  The hero image comes from resources/assets/img_hero_light.png and resources/assets/img_hero_dark.png.
  After changing them, run ./scripts/readme_update.sh; it embeds both into resources/readme-hero.svg as base64.
-->
<p align="center">
  <a href="https://github.com/taeyoon0137/arch-browser">
    <img src="./resources/readme-hero.svg" alt="Arch hero image" width="100%" />
  </a>
</p>

<h1 align="center">Arch</h1>
<p align="center">Arch. Outlasting.</p>

<p align="center">
  <a href="./docs/plan.md"><img src="https://img.shields.io/badge/status-early-4D24E2" alt="status: early" /></a>
  <a href="https://techcrunch.com/2026/10/22/arc-browser-sunsets-december-22-as-the-browser-company-doubles-down-on-dia/"><img src="https://img.shields.io/badge/In%20Loving%20Memory-Arc%20Browser%20%C2%B7%20Dec%2022%2C%202026-555555?labelColor=F54F8D" alt="In Loving Memory: Arc Browser, December 22, 2026" /></a>
</p>
<p align="center">
  <a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-%23F05138?logo=swift&logoColor=%23FFFFFF" alt="Swift" /></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-%23000000?logo=apple&logoColor=%23FFFFFF" alt="macOS" /></a>
  <a href="https://www.chromium.org/"><img src="https://img.shields.io/badge/Chromium-%234285F4?logo=googlechrome&logoColor=%23FFFFFF" alt="Chromium" /></a>
</p>

Arch is inspired by [Arc](https://arc.net). We deeply regret that Arc's service ends on December 22, 2026. Arch started as an open-source home for the features we loved in Arc, so that the features we need can arrive quickly and anyone can customize the browser for themselves. Its defining features from the start are WebKit support alongside Chromium and the fullest possible use of Apple's native APIs.

We also recommend [Dia](https://www.diabrowser.com), the new browser from the team behind Arc, and we are cheering them on.

- [🧭 Role](#-role)
- [🚀 Getting started](#-getting-started)
- [📚 Docs](#-docs)
- [🛠️ Scripts](#️-scripts)
- [🗂️ Repository structure](#️-repository-structure)

<a id="role"></a>

## 🧭 Role

Arch is a sidebar-first macOS browser with its own implementation: Personas with their own spaces, pinned tabs, split view, a command bar, plugins, media controls, and your own agents working with your tabs.

The core goals are:

- Write every feature from scratch. `docs/features.md` lists the planned features and the status of each.
- Use Chromium packaged through the Chromium Embedded Framework (CEF) as the primary engine. Use WebKit as the secondary engine. Support both through one engine protocol. Allow engine switching per profile and per tab.
- Keep features lightweight. Delegate autofill to Apple Passwords or 1Password. On both engines, use macOS system frameworks for every part of the platform user experience.
- Run no servers. Use iCloud or other replacements for sync and other features that need a server.
- Offer AI features through providers the user connects with an API key or a signed-in command-line tool. The user chooses a provider and model for each feature. Ship no model or account.

Out of scope:

- Our own hosted services, including accounts, sync servers, and telemetry.
- A built-in password or payment manager.
- Distribution outside the repository's GitHub Releases, which Arch checks for updates.

<a id="getting-started"></a>

## 🚀 Getting started

The repository contains the engine abstraction, the WebKit adapter, the Chromium adapter built on the Chromium Embedded Framework (CEF), the first feature modules (`Agent`, `AgentControl`, `AI`, `Browsing`, `Events`, `Extensions`, `History`, `Hooks`, `Import`, `Plugins`, `Preferences`, `Sync`, and `Terminal`), the `Arch` app shell, and `arch-cli`, the agents' command-line tool. Feature modules are written one feature at a time, using `docs/features.md`.

Download the pinned CEF distribution once, build every target, then assemble the app bundle. The Chromium engine runs only from the bundle.

```bash
./scripts/setup_cef.sh
swift build
./scripts/bundle_app.sh
open build/Arch.app
```

The bridge needs the experimental DevTools, picture-in-picture, extension runtime, notification, password AutoFill, and link referrer APIs listed under Engine Plan in `docs/plan.md`. The pinned `arch-8078-8` includes these engine changes and the isolated script worlds that page scripts use. To try a local build of `arch-8078` before its release, install it with `ARCH_CEF_ARCHIVE=<path to the archive> ./scripts/setup_cef.sh`.

A bundle uses Sparkle to check the repository's GitHub Releases for updates once a day after the update signing key is set. `docs/updates.md` covers the key, releases with `./scripts/release_app.sh`, and notarization.

After cloning, enable the commit message hook once:

```bash
git config core.hooksPath .githooks
```

### Start a task from a tab

1. Right-click an open web tab or favorite in the sidebar, choose **Ask Agent About This Tab…**, and type your question. The tab you were reading stays selected. For a question from the command palette, the **Ask Agent** row shows which page it will share. If you close the panel during setup, return to the same space and choose **View ▸ Show Agent Panel** to resume your draft.
2. If the draft shows **Open Providers**, add an HTTP model with tool calling or a Claude Code or Codex preset. For a preset, sign in through Arch’s terminal. Return to the draft, review the tab and model, and choose **Start**. If the agent asks a question, choose a suggested answer, enter your own, or cancel.
3. Open **Shared Tabs** in the session to add or remove a tab. If the agent requests a tab, review the address in the panel before choosing **Share**. To continue a question from the page reader, choose **Continue as Agent Task**. The reader excerpt is shared unless you turn it off; you can preview it before starting.

<a id="docs"></a>

## 📚 Docs

- [`docs/plan.md`](./docs/plan.md): read this first for goals, approach, current state, working rules, build steps, engine plan, and next steps.
- [`docs/engine-protocol.md`](./docs/engine-protocol.md): the protocols in `ARCHEngine`, adapter modules, capability tiers, and engine switching.
- [`docs/features.md`](./docs/features.md): planned features with the implementation approach and status of each.
- [`docs/sync.md`](./docs/sync.md): the sync design: CloudKit record types, conflict handling, offline behavior, and what never syncs.
- [`docs/windows-personas.md`](./docs/windows-personas.md): the design for multiple windows, the small window, and Personas, with its implementation order.
- [`docs/plugins.md`](./docs/plugins.md): the plugin system design: kinds, contributions, permissions, sandboxing, lifecycle, storage, and the Swift API.
- [`docs/ai.md`](./docs/ai.md): the AI interface, providers, routing, page access, hooks, and plugins that AI writes.
- [`docs/agent-panel-design.md`](./docs/agent-panel-design.md): the agent panel layout by state and its review cases.
- [`docs/agents.md`](./docs/agents.md): the agents design (its control channel library, the endpoint with grants and sealed settings, agent tabs with the reading, navigating, snapshot, screenshot, and action tools, approvals in a first agent panel, the runner of sessions on the CLIs, in-app sessions with their composer and panel, `arch-cli`'s commands, and `arch-mcp` are built; its harness and skill text is written): sessions using the user’s Claude Code, Codex, or API-key model with tool calling, the local control channel, tools and page snapshots, approvals, harness and skills, `arch-cli`, and `arch-mcp`.
- [`docs/hooks.md`](./docs/hooks.md): the hooks design (browser events, the shared hook scheduler, model tiers, the hook registry, JavaScript and shell hook scripts, bounded API-key and CLI agent runs, the guided editor, and the Tidy Tab Names preset are built): browser events, hooks that run scripts, agent runs with model tiers and record levels, the agent hook editor with the Tidy Tab Names preset, and events and hooks for outside programs.
- [`docs/live-sources.md`](./docs/live-sources.md): the live sources design, awaiting the user's approval: sidebar folders filled by a scheduled hook from feeds, GitHub searches, and granted addresses, and the reusable parts it adds to hooks.
- [`docs/site-rules.md`](./docs/site-rules.md): site rules (phase 1 built): matching, destination routing, Settings and menus, toast and Undo, storage, and sync; Production schema deployment and checks in the app are pending.
- [`docs/import-browsers.md`](./docs/import-browsers.md): browser import: formats read, mapping to Personas, spaces, and favorites, permissions, and the import sheet.
- [`docs/web-store.md`](./docs/web-store.md): installing web extensions from the Web Store: package proof for `.crx` files, the client that downloads and stages store packages, the entry points, Chromium's store button, and updates (built), with the store's page addresses waiting for the user's step.
- [`docs/password-managers.md`](./docs/password-managers.md): the 1Password and iCloud Passwords plugins: finding native apps, the proof gate, installing Arch in `/Applications`, and the status in Settings (built), and the user's steps.
- [`docs/bookmarks.md`](./docs/bookmarks.md): the bookmarks design (saved pages, unloading, nested folders with their dragging, and the Bookmarks menu built): saved pages, unloading, nested folders, the Bookmarks menu, and the removed live folders.
- [`docs/updates.md`](./docs/updates.md): app updates through Sparkle from the repository's GitHub Releases: design, bundle signing, keys, release steps, notarization, and user steps.
- [`docs/localization.md`](./docs/localization.md): the interface's languages: string catalogs per module, Settings ▸ General ▸ Language, pages' `Accept-Language` on both engines, and how to add a string or a language.

<a id="scripts"></a>

## 🛠️ Scripts

<!--
  README.md is a generated artifact.
  To change it, edit resources/README.preset.md and run ./scripts/readme_update.sh.
  Update the generator script when placeholders, paths, or section structure change.
-->

| Command | Description |
| :-- | :-- |
| `./scripts/setup_cef.sh` | Downloads the pinned CEF distribution, a release of the private `taeyoon0137/arch-chromium` repository, with the GitHub CLI into `Frameworks/cef` and copies its wrapper sources into the `CEFBridge` target. Run once per checkout and again after the pin changes. `ARCH_CEF_ARCHIVE` installs a local archive instead, to try an engine build before its release (see Getting started). |
| `./scripts/bundle_app.sh` | Assembles `build/Arch.app` from the build products, the CEF framework, the Sparkle framework for updates, the helper apps, `arch-cli` with its `arch-mcp` link, the app icon, and the scripting definition, and signs it. Sparkle's parts are signed from the inside out. It runs `scripts/opaque_icon.swift` to prepare the icon. With a provisioning profile that suits the signing identity, it embeds the profile and gives the app the iCloud and push entitlements the profile grants. |
| `./scripts/release_app.sh` | Creates an update release from a built `build/Arch.app`: the zip archive, its Sparkle signature, and `appcast.xml` in `build/release/`. It notarizes the app when `ARCH_NOTARY_PROFILE` names a `notarytool` profile. Only `--publish` uploads them as the latest GitHub release; otherwise it prints what it would upload (`docs/updates.md`). |
| `./scripts/set_release_secrets.sh` | Sets the repository secrets of the release pipeline with the GitHub CLI: the Developer ID identity from the Keychain with a random password, the Developer ID provisioning profile, the Sparkle key, the App Store Connect API key, and the engine token. It prints no value (`docs/updates.md`, Release pipeline). |
| `./scripts/check_page_reads.py` | Checks Chromium's visible text and editable-field exclusion on a local fixture page with a temporary profile. `swift test` covers WebKit (`WebKitReadableContentTests`). Run after assembling the debug bundle. |
| `./scripts/check_engine_restore/run.py` | Checks that one pinned tab keeps its Chromium choice through a temporary WebKit fallback and a third launch. Run after assembling the debug bundle. It uses a disposable profile and a local page. |
| `./scripts/provision_app.sh` | Gets the development and Developer ID provisioning profiles for `xyz.taeyoon.arch` through Xcode's automatic signing of a stand-in project in a temporary folder, signed in with the Xcode account or an App Store Connect API key (`ARCH_ASC_KEY_ID`, `ARCH_ASC_ISSUER_ID`, `ARCH_ASC_KEY_PATH`), and reports each profile without the team. `--dry-run` prints the steps and the installed profiles. |
| `./scripts/install_app.sh` | Copies the signed `build/Arch.app` into `/Applications` as a real bundle for native apps, such as 1Password, that accept only browsers there. It refuses a bundle signed ad hoc or unsigned and replaces only an earlier Arch or a link. `ARCH_APP_SOURCE` and `ARCH_INSTALL_DIR` change the source and the destination folder. |
| `./scripts/readme_update.sh` | Regenerates `README.md` and `resources/readme-hero.svg` from `resources/README.preset.md` and `resources/readme-hero.preset.svg`. |
| `./scripts/check_markdown.py` | Finds Markdown that GitHub renders differently from the text in `README.md`, `AGENTS.md`, the README preset, and `docs/`: angle-bracket placeholders outside code, pipes inside code spans in table cells, and paired tildes or dollar signs in prose. `--fix` escapes the placeholders. |

<a id="repository-structure"></a>

## 🗂️ Repository structure

```plaintext
arch-browser
├── .github/workflows/              # Release pipeline, run by each push to main
├── .githooks/                      # Commit subject format hook
├── Packages/
│   ├── ARCH/Sources/               # Feature modules: Agent, AgentControl, AI, Browsing, Events, Extensions, History, Hooks, Import, Plugins, Preferences, Sync, Terminal
│   ├── ARCH/Tests/                 # Tests: AgentControlTests, AgentTests, AITests, BrowsingTests, EventsTests, ExtensionsTests, HistoryTests, HooksTests, ImportTests, PluginsTests, PreferencesTests, SyncTests, TerminalTests
│   ├── ARCHApp/Sources/            # App target, CEF helper executable, and arch-cli
│   ├── ARCHKit/Sources/
│   │   ├── ARCHEngine/             # Engine protocols, registry, and shared helpers
│   │   ├── ARCHEngineChromium/     # Chromium adapter using CEF
│   │   ├── ARCHEngineWebKit/       # WebKit adapter
│   │   ├── ARCHPrivateAPI/         # Private API registry and flags
│   │   └── CEFBridge/              # Objective-C++ bridge to the CEF C++ API
│   └── ARCHKit/Tests/              # Tests: ARCHEngineChromiumTests, ARCHEngineReadCheck, ARCHEngineTests, ARCHEngineWebKitTests, ARCHPrivateAPITests
├── docs/                           # Design documents
├── resources/                      # README source, hero images, and app icon
├── scripts/                        # Build, install, and README scripts (see Scripts)
├── .gitattributes                  # Line ending and attribute rules
├── .gitignore                      # Git exclusions
├── AGENTS.md                       # Agent working instructions (source of truth)
├── CLAUDE.md                       # Symbolic link to AGENTS.md
├── LICENSE                         # MIT License
├── Package.swift                   # Package manifest (maintained by hand)
└── README.md                       # Generated artifact
```
