<!--
  README.md is generated from resources/README.preset.md.
  Edits made directly to README.md are lost on regeneration.
  To change the content, edit resources/README.preset.md and run ./scripts/readme_update.sh.
-->

<!-- Hero Image -->
<!--
  To add a hero image, add resources/hero.png (or .jpg).
  Light/dark variants go in resources/hero.light.png and resources/hero.dark.png.
  After adding images, run ./scripts/readme_update.sh; existing images are embedded into resources/readme-hero.svg as base64.
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
</p>
<p align="center">
  <a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-%23F05138?logo=swift&logoColor=%23FFFFFF" alt="Swift" /></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-%23000000?logo=apple&logoColor=%23FFFFFF" alt="macOS" /></a>
  <a href="https://www.chromium.org/"><img src="https://img.shields.io/badge/Chromium-%234285F4?logo=googlechrome&logoColor=%23FFFFFF" alt="Chromium" /></a>
</p>

- [🧭 Role](#-role)
- [🚀 Getting started](#-getting-started)
- [📚 Docs](#-docs)
- [🛠️ Scripts](#️-scripts)
- [🗂️ Repository structure](#️-repository-structure)

<a id="role"></a>

## 🧭 Role

Arch is a sidebar-first macOS browser with its own implementation: spaces, pinned tabs, split view, a command bar, customizations for each site, notes, and media controls.

The core goals are:

- Write every feature from scratch. `docs/features.md` lists the planned features and the status of each.
- Use Chromium packaged through the Chromium Embedded Framework (CEF) as the primary engine. Use WebKit as the secondary engine. Support both through one engine protocol. Allow engine switching per profile and per tab.
- Keep features lightweight. Delegate autofill to Apple Passwords or 1Password. On both engines, use macOS system frameworks for every part of the platform user experience.
- Run no servers. Use iCloud or other replacements for sync and other features that need a server.

Out of scope:

- Our own hosted services, including accounts, sync servers, and telemetry.
- A built-in password or payment manager.
- All AI features.
- Public distribution. The project is for internal use.

<a id="getting-started"></a>

## 🚀 Getting started

The repository is at an early stage. It contains the engine abstraction and the WebKit adapter. Write feature modules one feature at a time, using `docs/features.md`. `swift build` builds the engine modules.

```bash
swift build
```

After cloning, enable the commit message hook once:

```bash
git config core.hooksPath .githooks
```

<a id="docs"></a>

## 📚 Docs

- [`docs/plan.md`](./docs/plan.md): read this first for goals, approach, current state, working rules, build steps, engine plan, and next steps.
- [`docs/engine-protocol.md`](./docs/engine-protocol.md): the protocols in `ARCHEngine`, adapter modules, capability tiers, and engine switching.
- [`docs/features.md`](./docs/features.md): planned features with the implementation approach and status of each.

<a id="scripts"></a>

## 🛠️ Scripts

<!--
  README.md is a generated artifact.
  To change it, edit resources/README.preset.md and run ./scripts/readme_update.sh.
  Update the generator script when placeholders, paths, or section structure change.
-->

| Command | Description |
| :-- | :-- |
| `./scripts/readme_update.sh` | Regenerates `README.md` and `resources/readme-hero.svg` from `resources/README.preset.md` and `resources/readme-hero.preset.svg`. |

<a id="repository-structure"></a>

## 🗂️ Repository structure

```plaintext
arch-browser
├── .githooks/
│   └── commit-msg                  # Commit subject format hook
├── Packages/
│   ├── ARCH/Sources/               # Feature modules, starting with Browsing
│   ├── ARCHApp/Sources/            # App target and CEF helper executable
│   └── ARCHKit/Sources/
│       ├── ARCHEngine/             # Engine protocols, registry, and selection
│       ├── ARCHEngineChromium/     # Chromium adapter using CEF
│       ├── ARCHEngineWebKit/       # WebKit adapter
│       └── CEFBridge/              # Objective-C++ bridge to the CEF C++ API
├── docs/                           # Design documents
├── resources/
│   ├── README.preset.md            # README source of truth
│   ├── hero.jpg                    # Hero image
│   ├── readme-hero.preset.svg      # Hero wrapper source
│   └── readme-hero.svg             # Generated hero SVG
├── scripts/
│   └── readme_update.sh            # README generator
├── .gitattributes                  # Line ending and attribute rules
├── .gitignore                      # Git exclusions
├── AGENTS.md                       # Agent working instructions (source of truth)
├── CLAUDE.md                       # Symbolic link to AGENTS.md
├── Package.swift                   # Package manifest (maintained by hand)
└── README.md                       # Generated artifact
```
