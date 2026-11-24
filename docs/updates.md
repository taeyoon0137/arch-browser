# App Updates

Arch updates itself with Sparkle, the open-source macOS update framework (row 37 in `docs/features.md`). Every update comes from GitHub Releases in the public repository `taeyoon0137/arch-browser`. Arch runs no update server. Its checks send no system profile, and Arch keeps no analytics.

## Design

- `Package.swift` pins Sparkle to 2.10.1 as a dependency of the `Arch` app target only. SwiftPM fetches Sparkle's release and tools (`generate_keys`, `sign_update`, `generate_appcast`) into `.build/artifacts/sparkle/Sparkle/`.
- `AppUpdates` in the app shell owns Sparkle's `SPUStandardUpdaterController`. Only an app bundle whose Info.plist names the feed and public key gets one. A build run outside a bundle, or a bundle without the key, has no updater, menu item, or update controls in Settings.
- The app menu has Check for Updates… after About Arch. Sparkle's controller handles it and enables it when no check is running.
- Settings ▸ General ends with Updates. Check for updates automatically turns Sparkle's scheduled checks on or off. The Version row shows the short version, build number, and Check Now. The footer shows the last check's time. `Preferences` holds these controls in `AppUpdateControls`, which the app shell connects to Sparkle, so the module does not depend on Sparkle.
- `scripts/bundle_app.sh` writes these Info.plist keys:

| Key | Value |
|---|---|
| `SUFeedURL` | `https://github.com/taeyoon0137/arch-browser/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | The EdDSA public key, when one is set |
| `SUEnableAutomaticChecks` | true, so Sparkle checks without first asking for permission |
| `SUScheduledCheckInterval` | 86400 seconds, one day |
| `SUEnableSystemProfiling` | false; the updater also sets `sendsSystemProfile` to false at start |

- The feed address always serves the latest release's appcast, so each appcast lists only its release. Sparkle compares `sparkle:version`, the build number (`CFBundleVersion`, the build's time in UTC as YYYYMMDDHHMM), which increases with each build.
- A check downloads the appcast from GitHub. When the appcast lists a newer build, Sparkle downloads the archive, checks its EdDSA signature against `SUPublicEDKey`, and installs it only if the signature matches.

## The bundle

`scripts/bundle_app.sh` copies `Sparkle.framework`, with its `Installer.xpc` and `Downloader.xpc` services, the `Autoupdate` helper, and `Updater.app`, into `Contents/Frameworks`. SwiftPM links the app against `@rpath/Sparkle.framework`, so the script adds `@executable_path/../Frameworks` to the executable's run paths and removes the run paths that point into the build folder.

The script first signs the bundle with `--deep`, which signs the helper apps and CEF framework. It then copies Sparkle's framework into the bundle and signs it from the inside out with the same identity and the hardened runtime, following Sparkle's documentation: the two XPC services (only the downloader keeps its entitlements), `Autoupdate`, `Updater.app`, and the framework. A final signing seals the app, with the provisioning profile's entitlements if it has a profile. Ad-hoc signing follows the same steps. The script ends with `codesign --verify --deep --strict`. With `ARCH_HARDENED_RUNTIME=1`, the script signs each part with the hardened runtime instead, as Notarization describes.

## Keys

Sparkle's EdDSA (ed25519) key pair signs and checks the update archives.

- The private key stays with the maintainer and never goes into the repository, a build, or a release. The release pipeline reads the `ARCH_SPARKLE_PRIVATE_KEY` secret. `release_app.sh` gets its location from `ARCH_SPARKLE_KEY_FILE` or `ARCH_SPARKLE_KEY_ACCOUNT`, set in the environment or in git-ignored `.release.env`. The repository does not record the key's location.
- The public key is the default value of `SPARKLE_PUBLIC_KEY` in `scripts/bundle_app.sh`. `ARCH_SPARKLE_PUBLIC_KEY` overrides it for one run.
- If the private key is lost, installed copies can never update again. Keep a copy safe outside the repository, such as in an encrypted backup.

## Release pipeline

Each push to `main` releases Arch. `main` only fast-forwards to `develop` (`AGENTS.md`, Branches), so each push publishes the tested code from `develop`. `.github/workflows/release.yml` runs on a GitHub-hosted Apple silicon runner with Xcode 27, using the `xcode-27` label or the label set in the repository variable `ARCH_RELEASE_RUNNER`. It also runs from the Actions tab (`workflow_dispatch`). Releases run one at a time.

1. It stops with an error naming each missing secret listed below.
2. It selects the newest Xcode 27, downloads the pinned CEF with `ARCH_CHROMIUM_TOKEN`, and runs `swift build -c release`.
3. It creates a keychain for the job, imports the Developer ID identity and Apple's Developer ID intermediate certificate, and stores the notary credentials there under the profile `arch-release`.
4. It runs `ARCH_HARDENED_RUNTIME=1 ./scripts/bundle_app.sh release` with the Developer ID identity and provisioning profile, giving the app the Production CloudKit environment.
5. It runs `./scripts/release_app.sh --publish` with `ARCH_NOTARY_PROFILE`, `ARCH_NOTARY_KEYCHAIN`, and `ARCH_SPARKLE_KEY_FILE`. The script notarizes and staples the app, signs the archive, tags the pushed commit `v<version>-<build>`, and publishes the release with the job's `GITHUB_TOKEN`.
6. It deletes the keychain and key files even if a step fails.

The version is `VERSION` in `scripts/bundle_app.sh`; change it on `develop` before releasing a new version. The tag uses the build time as its build number, giving each release a new tag.

The workflow reads these repository secrets (Settings ▸ Secrets and variables ▸ Actions). GitHub never displays their values, even in logs:

| Secret | Contents |
|---|---|
| `ARCH_CHROMIUM_TOKEN` | A fine-grained personal access token with read access only to the contents of `taeyoon0137/arch-chromium`, for its engine releases |
| `ARCH_DEVELOPER_ID_P12` | The Developer ID Application certificate and private key, exported as a .p12 file and base64-encoded |
| `ARCH_DEVELOPER_ID_P12_PASSWORD` | The .p12 file's export password |
| `ARCH_PROVISIONING_PROFILE` | The Developer ID provisioning profile for `xyz.taeyoon.arch`, with iCloud and push, encoded in base64 |
| `ARCH_NOTARY_KEY` | An App Store Connect API key (.p8) with the Developer role |
| `ARCH_NOTARY_KEY_ID` | That key's ID |
| `ARCH_NOTARY_ISSUER` | The issuer ID above the App Store Connect key list |
| `ARCH_SPARKLE_PRIVATE_KEY` | The Sparkle private key exported by `generate_keys -x` |

`./scripts/set_release_secrets.sh` sets them with the GitHub CLI without printing a value. It exports the Developer ID Application identity from the Keychain with a new random password, takes the Developer ID provisioning profile that lists its certificate from Xcode's profile folder, and exports the Sparkle key named in `.release.env`. It asks for the App Store Connect key file, its key ID, the issuer ID, and the token, and deletes its temporary files on exit.

## Release steps

To release from this Mac, follow the same steps manually:

1. Commit the change and push it to GitHub. A release's tag points to the build's commit, so the script will not publish a build with uncommitted changes.
2. Build and bundle the release configuration with `swift build -c release` and then `./scripts/bundle_app.sh release`. For notarization, use `ARCH_HARDENED_RUNTIME=1 ./scripts/bundle_app.sh release` instead.
3. Run `./scripts/release_app.sh` to check the result. It copies the app to `build/release/<build number>/`. With `ARCH_NOTARY_PROFILE` set, it notarizes and staples the copy. It then creates `Arch-<version>-<build>.zip` with `ditto -c -k --keepParent` and signs the zip with `sign_update`, which reads the private key specified by `ARCH_SPARKLE_KEY_FILE` or `ARCH_SPARKLE_KEY_ACCOUNT` (Keys). The script checks the signature against the app's `SUPublicEDKey` and writes `appcast.xml`. Without `--publish`, it prints the `gh release create` command it would run.
4. Run `./scripts/release_app.sh --publish` to publish `v<version>-<build>` as the latest release of `taeyoon0137/arch-browser`, with the zip and `appcast.xml` as its assets.

The script stops before uploading if the app lacks a feed or public key, its signature fails verification, or the archive's signature does not match the app's public key.

## Notarization

Gatekeeper blocks downloaded apps that are not notarized. Sparkle removes the quarantine attribute from updates it installs, but the first download from the release page keeps it, so Gatekeeper checks that copy. `scripts/release_app.sh` notarizes only when `ARCH_NOTARY_PROFILE` names a `notarytool` keychain profile; otherwise, it warns and continues without notarization.

Notarization requires the hardened runtime and a secure timestamp on every executable. Sparkle's parts always have the hardened runtime. The rest of the bundle gets it only with `ARCH_HARDENED_RUNTIME=1`, which is off by default to keep the everyday build unchanged until a hardened build has been tested in the app. With `ARCH_NOTARY_PROFILE` set, `scripts/release_app.sh` checks every Mach-O file in the bundle and stops before notarizing if any lacks the hardened runtime, listing those files and the command to run first.

With `ARCH_HARDENED_RUNTIME=1`, `scripts/bundle_app.sh` drops `--deep` and signs each part from the inside out with `--options runtime --timestamp`: the CEF framework's libraries in `Libraries`, the CEF framework, the five helper apps, `arch-cli`, Sparkle's parts, and last the app. It writes the helpers' entitlements to `build/ArchHelperJIT.entitlements` and adds the app's keys to `build/Arch.entitlements`. The entitlements follow Chromium's own macOS signing configuration:

| Executable | Entitlements | Reason |
|---|---|---|
| `Arch` | The provisioning profile's (iCloud, push), `com.apple.security.device.audio-input`, `com.apple.security.device.camera`, `com.apple.security.personal-information.location` | Pages may use the microphone, camera, and location after the user allows them; the hardened runtime denies access without these keys. Bluetooth, USB, and printing have no hardened runtime key. |
| `Arch Helper`, `Arch Helper (Renderer)`, `Arch Helper (GPU)` | `com.apple.security.cs.allow-jit` | V8 and WebAssembly in the renderer, and SwiftShader in the GPU process, compile code into memory mapped with `MAP_JIT`. The app sets CEF's `browser_subprocess_path` to `Arch Helper`, so it runs every subprocess, renderers included. |
| `Arch Helper (Plugin)`, `Arch Helper (Alerts)`, `arch-cli`, the CEF framework and its libraries | None | The alerts helper compiles no code, as in Chromium. The pinned Chromium never launches the Plugin helper. |

No executable gets `com.apple.security.cs.allow-unsigned-executable-memory`: every part that writes code maps it with `MAP_JIT`. None gets `com.apple.security.cs.disable-library-validation`, because the script signs the frameworks with the app's identity. The app gets no `allow-jit`: WebKit pages run in the system's WebKit processes, and plugins' JavaScriptCore syntax checks in the app run without its compiler. A hardened build requires a signing identity and stops instead of falling back to ad-hoc signing, because library validation rejects ad-hoc frameworks and the notary service accepts only Developer ID.

The default build keeps the linker's ad-hoc signatures on the CEF framework's libraries, because `--deep` signs only nested code in standard locations. The hardened build signs them too.

## User steps

These steps require the user's action, credentials, or approval:

1. Keep a safe copy of the private key separate from the release Mac.
2. Install one hardened build, made with `swift build -c release` and `ARCH_HARDENED_RUNTIME=1 ./scripts/bundle_app.sh release`, and use it for a day before making the hardened runtime the default. Check that pages load and run scripts on Chromium and WebKit, that WebGL and video play, that a page can use the camera, the microphone, and location after you allow them, that iCloud sync and notifications work, that plugin scripts report syntax errors, that `arch-cli` answers, and that Check for Updates… runs.
3. To release from this Mac, store a notary profile once with `xcrun notarytool store-credentials <profile name>`, using an app-specific password or an App Store Connect API key, and set `ARCH_NOTARY_PROFILE=<profile name>` when releasing from a hardened build.
4. For the release pipeline, create the App Store Connect API key and the token, then run `./scripts/set_release_secrets.sh` (Release pipeline). It also needs the Developer ID Application identity and the Developer ID provisioning profile on this Mac.
5. Approve the first release: a push to `main` or `./scripts/release_app.sh --publish`.
6. Once a newer release exists, test Check for Updates… and Settings ▸ General ▸ Updates in an installed copy (V.12 in `docs/plan.md`).
