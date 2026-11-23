# App Updates

Arch updates itself the way other Mac apps do, with Sparkle, the open-source macOS update framework (row 37 in `docs/features.md`). Every update comes from the GitHub Releases of the public repository `taeyoon0137/arch-browser`. Arch runs no update server of its own. Its checks send no system profile, and Arch keeps no analytics.

## Design

- `Package.swift` adds Sparkle 2.10.1, an exact version, as a dependency of the `Arch` app target only. SwiftPM fetches Sparkle's release with its tools (`generate_keys`, `sign_update`, `generate_appcast`) into `.build/artifacts/sparkle/Sparkle/`.
- `AppUpdates` in the app shell owns Sparkle's `SPUStandardUpdaterController`. Only an app bundle whose Info.plist names the feed and the public key gets one. A build run outside a bundle, or a bundle made without the key, has no updater, no menu item, and no update controls in Settings.
- The app menu has Check for Updates… after About Arch. Sparkle's controller is its target and enables it while no check runs.
- Settings ▸ General ends with Updates. Check for updates automatically turns Sparkle's scheduled checks on or off. The Version row shows the short version and the build number, with Check Now. The footer says when the last check was. `Preferences` holds these controls in `AppUpdateControls`, which the app shell connects to Sparkle, so the module does not depend on Sparkle.
- `scripts/bundle_app.sh` writes these Info.plist keys:

| Key | Value |
|---|---|
| `SUFeedURL` | `https://github.com/taeyoon0137/arch-browser/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | The EdDSA public key, when one is set |
| `SUEnableAutomaticChecks` | true, so Sparkle checks without first asking for permission |
| `SUScheduledCheckInterval` | 86400 seconds, one day |
| `SUEnableSystemProfiling` | false; the updater also sets `sendsSystemProfile` to false at start |

- The feed address always gives the appcast of the latest release, so each release's appcast lists that release alone. Sparkle compares `sparkle:version`, the build number (`CFBundleVersion`, the build's time in UTC as YYYYMMDDHHMM), which grows with each build.
- A check downloads the appcast from GitHub. When the appcast lists a newer build, Sparkle downloads the archive, checks its EdDSA signature against `SUPublicEDKey`, and installs it only if the signature matches.

## The bundle

`scripts/bundle_app.sh` copies `Sparkle.framework`, with its `Installer.xpc` and `Downloader.xpc` services, the `Autoupdate` helper, and `Updater.app`, into `Contents/Frameworks`. SwiftPM links the app against `@rpath/Sparkle.framework`, so the script adds `@executable_path/../Frameworks` to the executable's run paths and removes the run paths that point into the build folder.

Signing keeps the order it had before Sparkle. The script signs the bundle with `--deep`, which signs the helper apps and the CEF framework. Then it copies Sparkle's framework into the bundle and signs it from the inside out with the same identity and the hardened runtime, as Sparkle's documentation does: the two XPC services (only the downloader keeps its entitlements), `Autoupdate`, `Updater.app`, and the framework. A last signing seals the app, with the provisioning profile's entitlements when it has a profile. Ad-hoc signing goes through the same steps. The script ends with `codesign --verify --deep --strict`. With `ARCH_HARDENED_RUNTIME=1`, the script signs every part itself with the hardened runtime instead, as Notarization describes.

## Keys

Sparkle's EdDSA (ed25519) key pair signs and checks the update archives.

- The private key stays with the maintainer and never goes into the repository, a build, or a release. `release_app.sh` reads where it is from `ARCH_SPARKLE_KEY_FILE` or `ARCH_SPARKLE_KEY_ACCOUNT`, set in the environment or in `.release.env`, which git ignores. The repository does not say where the key is kept.
- The public key is the default of `SPARKLE_PUBLIC_KEY` in `scripts/bundle_app.sh`. `ARCH_SPARKLE_PUBLIC_KEY` overrides it for one run.
- Losing the private key means installed copies can never update again. A further copy belongs in a safe place outside the repository, such as an encrypted backup.

## Release steps

1. Commit the change and push it to GitHub. A release's tag points at the build's commit, so the script publishes no build of uncommitted changes.
2. Build and bundle the release configuration with `swift build -c release` and then `./scripts/bundle_app.sh release`. A release to notarize needs `ARCH_HARDENED_RUNTIME=1 ./scripts/bundle_app.sh release` instead.
3. Run `./scripts/release_app.sh` to check the result. It copies the app to `build/release/<build number>/`. With `ARCH_NOTARY_PROFILE` set, it notarizes and staples the copy. Then it makes `Arch-<version>-<build>.zip` with `ditto -c -k --keepParent` and signs the zip with `sign_update`, which reads the private key from where `ARCH_SPARKLE_KEY_FILE` or `ARCH_SPARKLE_KEY_ACCOUNT` says (Keys). The script then checks the signature against the app's `SUPublicEDKey` and writes `appcast.xml`. Without `--publish`, it prints the `gh release create` command it would run.
4. Run `./scripts/release_app.sh --publish` to create the release `v<version>-<build>` as the latest release of `taeyoon0137/arch-browser`, with the zip and `appcast.xml` as its assets.

The script stops before uploading when the app has no feed or public key, when its signature does not verify, or when the archive's signature does not match the app's public key.

## Notarization

Gatekeeper blocks a downloaded app that is not notarized. Sparkle removes the quarantine attribute from the update it installs, but a first download from the release page carries it, and Gatekeeper checks that copy. `scripts/release_app.sh` notarizes only when `ARCH_NOTARY_PROFILE` names a `notarytool` keychain profile, and otherwise warns and goes on without it.

Notarization requires the hardened runtime and a secure timestamp on every executable. Sparkle's parts always have the hardened runtime. The rest of the bundle gets it only with `ARCH_HARDENED_RUNTIME=1`, which is off by default, so the installed everyday build stays as it was until a hardened build has been checked in the app. With `ARCH_NOTARY_PROFILE` set, `scripts/release_app.sh` checks every Mach-O file in the bundle and stops before notarizing when any lacks the hardened runtime, naming those files and the command to run first.

With `ARCH_HARDENED_RUNTIME=1`, `scripts/bundle_app.sh` drops `--deep` and signs each part from the inside out with `--options runtime --timestamp`: the CEF framework's libraries in `Libraries`, the CEF framework, the five helper apps, `arch-cli`, Sparkle's parts, and last the app. It writes the helpers' entitlements to `build/ArchHelperJIT.entitlements` and adds the app's keys to `build/Arch.entitlements`. The entitlements follow Chromium's own macOS signing configuration:

| Executable | Entitlements | Reason |
|---|---|---|
| `Arch` | The provisioning profile's (iCloud, push), `com.apple.security.device.audio-input`, `com.apple.security.device.camera`, `com.apple.security.personal-information.location` | Pages may use the microphone, the camera, and location after the user allows them, and the hardened runtime denies these without the keys. Bluetooth, USB, and printing have no hardened runtime key. |
| `Arch Helper (Renderer)`, `Arch Helper (GPU)` | `com.apple.security.cs.allow-jit` | V8 and WebAssembly in the renderer, and SwiftShader in the GPU process, compile code into memory mapped with `MAP_JIT`. |
| `Arch Helper`, `Arch Helper (Plugin)`, `Arch Helper (Alerts)`, `arch-cli`, the CEF framework and its libraries | None | The utility processes and the alerts helper compile no code, as in Chromium. The pinned Chromium never launches the Plugin helper. |

No executable gets `com.apple.security.cs.allow-unsigned-executable-memory`, because every part that writes code maps it with `MAP_JIT`, or `com.apple.security.cs.disable-library-validation`, because the script signs the frameworks with the app's own identity. The app gets no `allow-jit`: WebKit pages run in the system's WebKit processes, and the plugins' JavaScriptCore syntax checks in the app run without its compiler. A hardened build needs a signing identity and stops instead of falling back to ad-hoc signing, since library validation refuses ad-hoc frameworks and the notary service accepts only Developer ID.

The default build leaves the CEF framework's libraries with the linker's ad-hoc signatures, because `--deep` signs only nested code in the standard places. The hardened build signs them too.

## User steps

These steps need the user's own hands, credentials, or approval:

1. Keep a copy of the private key in a safe place apart from the release Mac.
2. Install one hardened build, made with `swift build -c release` and `ARCH_HARDENED_RUNTIME=1 ./scripts/bundle_app.sh release`, and use it for a day before making the hardened runtime the default. Check that pages load and run scripts on Chromium and WebKit, that WebGL and video play, that a page can use the camera, the microphone, and location after you allow them, that iCloud sync and notifications work, that plugin scripts report syntax errors, that `arch-cli` answers, and that Check for Updates… runs.
3. For notarization, store a profile once with `xcrun notarytool store-credentials <profile name>`, using an app-specific password or an App Store Connect API key, and set `ARCH_NOTARY_PROFILE=<profile name>` when releasing from a hardened build.
4. Approve and run the first `./scripts/release_app.sh --publish`.
5. In an installed copy, check Check for Updates… and Settings ▸ General ▸ Updates once a newer release exists (V.12 in `docs/plan.md`).
