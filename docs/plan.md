# Arch Browser Development Plan

This plan gives the context needed to continue work in another session or on another Mac.

## Goals

- Build a sidebar-first macOS browser with its own implementation. `docs/features.md` lists every planned feature and its status.
- Run no servers of our own. Use alternatives such as iCloud for features that need servers, including sync (`docs/features.md`, sections 5 and 6).
- Keep features lightweight. Delegate autofill to Apple Passwords or 1Password. On both engines, use macOS system frameworks for every feature that is part of the platform user experience. Follow the Platform integration table in `docs/features.md`.
- Exclude all AI features. This implementation contains no AI code or extension point for AI.
- Use ARCH prefixes throughout: `ARCH*` for packages, `Arch` for the app module, and `ARCHKit` for the core layer.
- The browser is for internal use. No distribution is planned. Manage replacement names, images, fonts, and similar items outside this repository.

## Approach

- Write new code for each feature. Start from a row in `docs/features.md`. Design the smallest module that delivers the feature and add it to `Package.swift`.
- Design type names, module boundaries, method signatures, and file layout for Arch. A row in `docs/features.md` describes what a feature does, not how to build it.
- Add engine protocol members only when a feature needs them. The current protocols are a starting point, not a list of requirements to implement.
- AI is out of scope. For features that combine AI and non-AI capabilities, keep only the non-AI part.
- Use the system framework whenever macOS provides the user experience. Do not build or retain an engine-specific version. Keep Chromium's existing native integrations. Route the remaining engine events to these frameworks and disable the engine's equivalent user interface.

## Current State

| Area | Status |
|---|---|
| Engine abstraction | `ARCHEngine` protocols are complete. `ARCHEngineWebKit` implements loading, reloading, stopping, back and forward navigation, find, script execution, style injection, viewport snapshots, and PDF export. Its delegate bridge handles navigation, user interface (UI), and key-value observing (KVO) events. Browser creation and restoration, the back-forward list, full-page capture, printing, media, downloads, history, and content blocking remain stubs. Work on `ARCHEngineChromium` has not started. |
| Feature code | None yet. Every row in `docs/features.md` has the status "not started". |
| Build | `swift build` builds both engine modules. There are no third-party dependencies. |
| Documentation | Engine design in `docs/engine-protocol.md` and the feature list in `docs/features.md`. |

## Repository Layout

```
Package.swift                         Package manifest (maintained by hand)
Packages/ARCHKit/Sources/ARCHEngine        Engine protocols, value types, registry, selection
Packages/ARCHKit/Sources/ARCHEngineWebKit  WebKit adapter (secondary and debug engine)
Packages/ARCHKit/Sources/ARCHEngineChromium Planned Chromium adapter using the Chromium Embedded Framework (CEF)
Packages/ARCH/Sources/<Feature>            Feature modules, one per feature as they are written
docs/                                 Design documents
resources/                            README source and hero image
scripts/readme_update.sh              README generation
```

## Working Rules

1. Write new code for each feature, with interfaces, names, and layout designed for Arch.
2. Maintain `Package.swift` by hand. Add one target per new module.
3. Exclude all AI features. Do not add AI code or extension points for AI.
4. Write documentation, comments, and commit messages in English.
5. Document the current state only. Do not include a change history.

## Build Procedure

```bash
swift build
```

## Engine Plan

| Engine | Role | Work location |
|---|---|---|
| Chromium through the Chromium Embedded Framework (CEF) in Chrome style (`ARCHEngineChromium`) | Primary engine. All Chrome features, including extensions, DevTools, PDFs, and sessions (Chrome style coverage needs verification). Prebuilt macOS arm64 binaries track current Chromium. Build CEF from source for engine patches required by macOS integration. | This Mac for the prebuilt framework; another Mac with enough free disk space for the patched source build |
| WebKit (`ARCHEngineWebKit`) | Secondary and debugging engine. It uses the system framework and needs no source download. | This Mac |

### Bring Up the Chromium Engine

1. Download the newest stable CEF standard distribution for macOS arm64 from `cef-builds.spotifycdn.com` (156.0.7 on Chromium 156.0.8078.17 at the time of writing). Place `Chromium Embedded Framework.framework` and the helper apps in `Frameworks/`, which Git ignores.
2. Create `ARCHEngineChromium` as an Objective-C++ (ObjC++) bridge over the CEF C++ API in Chrome style. Expose the browser process lifecycle, profiles, browsers, navigation, downloads, extensions, and DevTools. Map the bridge one-to-one to the `ARCHEngine` protocols (tiers 1 and 2 in `docs/engine-protocol.md`). Import it into the Swift adapter through a `systemLibrary` target.
3. Compare Chromium's native macOS integrations with the Platform integration table in `docs/features.md`. Check Now Playing and media keys, notifications, file dialogs, passkeys, Handoff, and AppleScript. List the gaps.
4. For gaps that need engine changes, such as picture-in-picture (PiP) through AVKit (`AVPictureInPictureController` fed from decoded video frames), build CEF from source. Use a Mac with at least 150GB of free disk space and a full Xcode installation. 32GB of memory is recommended. The first build takes several hours on an M-series Mac (needs verification). Apply the patches on that Mac and replace the prebuilt framework with the patched build.
5. Disable Chromium's password, card, and address storage for autofill. Use Apple Passwords for passwords and passkeys. Use 1Password for cards and addresses.

### Implement the WebKit Adapter on This Mac

1. Check `WebKitDelegateBridge` against the `ARCHEngine` delegate protocols. Add the missing callbacks.
2. Add a dedicated browsing history store and implement downloads with `WKDownload`. Add media sessions with playback state and PiP. Restore sessions with `interactionState`.
3. Connect the first feature module to `EngineRegistry` to select the engine. Add a debug menu.

## Next Steps

1. Complete the WebKit adapter using the steps above.
2. Implement the app target, starting with windows, the sidebar, and the command bar (rows 1, 5, 7, and 11 in `docs/features.md`).
3. Use the prebuilt CEF framework to bring up the Chromium engine.
4. Replace names, images, and fonts.
