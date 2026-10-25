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
  <a href="${repositoryUrl}">
    <img src="../resources/readme-hero.svg" alt="Arch hero image" width="100%" />
  </a>
</p>

<h1 align="center">Arch</h1>
<p align="center">Arch. Outlasting.</p>

<p align="center">
  <a href="../docs/plan.md"><img src="https://img.shields.io/badge/status-early-4D24E2" alt="status: early" /></a>
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

Arch is a sidebar-first macOS browser with its own implementation: Personas with their own spaces, pinned tabs, split view, a command bar, plugins, and media controls.

The core goals are:

- Write every feature from scratch. `docs/features.md` lists the planned features and the status of each.
- Use Chromium packaged through the Chromium Embedded Framework (CEF) as the primary engine. Use WebKit as the secondary engine. Support both through one engine protocol. Allow engine switching per profile and per tab.
- Keep features lightweight. Delegate autofill to Apple Passwords or 1Password. On both engines, use macOS system frameworks for every part of the platform user experience.
- Run no servers. Use iCloud or other replacements for sync and other features that need a server.
- Offer AI features through providers the user connects with an API key or a signed-in command-line tool. The user chooses a provider and model for each feature. Ship no model or account.

Out of scope:

- Our own hosted services, including accounts, sync servers, and telemetry.
- A built-in password or payment manager.
- Public distribution. The project is for internal use.

<a id="getting-started"></a>

## 🚀 Getting started

The repository contains the engine abstraction, the WebKit adapter, the Chromium adapter built on the Chromium Embedded Framework (CEF), the first feature modules (`AI`, `Browsing`, `Extensions`, `History`, `Import`, `Plugins`, `Preferences`, and `Terminal`), and the `Arch` app shell. Feature modules are written one feature at a time, using `docs/features.md`.

Download the pinned CEF distribution once, build every target, then assemble the app bundle. The Chromium engine runs only from the bundle.

```bash
./scripts/setup_cef.sh
swift build
./scripts/bundle_app.sh
open build/Arch.app
```

After cloning, enable the commit message hook once:

```bash
git config core.hooksPath .githooks
```

<a id="docs"></a>

## 📚 Docs

- [`docs/plan.md`](../docs/plan.md): read this first for goals, approach, current state, working rules, build steps, engine plan, and next steps.
- [`docs/engine-protocol.md`](../docs/engine-protocol.md): the protocols in `ARCHEngine`, adapter modules, capability tiers, and engine switching.
- [`docs/features.md`](../docs/features.md): planned features with the implementation approach and status of each.
- [`docs/sync.md`](../docs/sync.md): the sync design: CloudKit record types, conflict handling, offline behavior, and what never syncs.
- [`docs/windows-personas.md`](../docs/windows-personas.md): the design for multiple windows, the small window, and Personas, with its implementation order.
- [`docs/plugins.md`](../docs/plugins.md): the plugin system design: kinds, contributions, permissions, sandboxing, lifecycle, storage, and the Swift API.
- [`docs/ai.md`](../docs/ai.md): the AI interface, providers, routing, page access, hooks, and plugins that AI writes.
- [`docs/import-browsers.md`](../docs/import-browsers.md): importing from other browsers: formats read, mapping to Personas, spaces, and favorites, permissions, and the import sheet.

<a id="scripts"></a>

## 🛠️ Scripts

<!--
  README.md is a generated artifact.
  To change it, edit resources/README.preset.md and run ./scripts/readme_update.sh.
  Update the generator script when placeholders, paths, or section structure change.
-->

| Command | Description |
| :-- | :-- |
| `./scripts/setup_cef.sh` | Downloads the pinned CEF distribution, a release of the private `taeyoon0137/arch-chromium` repository, with the GitHub CLI into `Frameworks/cef` and copies its wrapper sources into the `CEFBridge` target. Run once per checkout. |
| `./scripts/bundle_app.sh` | Assembles `build/Arch.app` from the build products, the CEF framework, the helper apps, the app icon, and the scripting definition. It runs `scripts/opaque_icon.swift` to prepare the icon. |
| `./scripts/readme_update.sh` | Regenerates `README.md` and `resources/readme-hero.svg` from `resources/README.preset.md` and `resources/readme-hero.preset.svg`. |

<a id="repository-structure"></a>

## 🗂️ Repository structure

```plaintext
arch-browser
├── .githooks/                      # Commit subject format hook
├── Packages/
│   ├── ARCH/Sources/               # Feature modules: AI, Browsing, Extensions, History, Import, Plugins, Preferences, Terminal
│   ├── ARCH/Tests/                 # Tests: AITests, BrowsingTests, ExtensionsTests, HistoryTests, ImportTests, PluginsTests, PreferencesTests, TerminalTests
│   ├── ARCHApp/Sources/            # App target and CEF helper executable
│   ├── ARCHKit/Sources/
│   │   ├── ARCHEngine/             # Engine protocols, registry, and shared helpers
│   │   ├── ARCHEngineChromium/     # Chromium adapter using CEF
│   │   ├── ARCHEngineWebKit/       # WebKit adapter
│   │   ├── ARCHPrivateAPI/         # Private API registry and flags
│   │   └── CEFBridge/              # Objective-C++ bridge to the CEF C++ API
│   └── ARCHKit/Tests/              # Tests: ARCHEngineTests, ARCHEngineWebKitTests
├── docs/                           # Design documents
├── resources/                      # README source, hero images, and app icon
├── scripts/                        # Build and README scripts (see Scripts)
├── .gitattributes                  # Line ending and attribute rules
├── .gitignore                      # Git exclusions
├── AGENTS.md                       # Agent working instructions (source of truth)
├── CLAUDE.md                       # Symbolic link to AGENTS.md
├── LICENSE                         # MIT License
├── Package.swift                   # Package manifest (maintained by hand)
└── README.md                       # Generated artifact
```
