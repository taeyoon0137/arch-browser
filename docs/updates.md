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

Signing keeps the order it had before Sparkle. The script signs the bundle with `--deep`, which signs the helper apps and the CEF framework. Then it copies Sparkle's framework into the bundle and signs it from the inside out with the same identity and the hardened runtime, as Sparkle's documentation does: the two XPC services (only the downloader keeps its entitlements), `Autoupdate`, `Updater.app`, and the framework. A last signing seals the app, with the provisioning profile's entitlements when it has a profile. Ad-hoc signing goes through the same steps. The script ends with `codesign --verify --deep --strict`.

## Keys

Sparkle's EdDSA (ed25519) key pair signs and checks the update archives.

- The key pair was made on November 23 with CryptoKit, without the Keychain, so no dialog appeared. The private key is the Base64 of its 32-byte seed in `the key file` on the release Mac, readable only by the user. `release_app.sh` passes it to `sign_update --ed-key-file`. It never goes into the repository, a build, or a release.
- The public key is the default of `SPARKLE_PUBLIC_KEY` in `scripts/bundle_app.sh`. `ARCH_SPARKLE_PUBLIC_KEY` overrides it for one run.
- Losing the private key means installed copies can never update again. A copy belongs in a safe place outside the repository, such as an encrypted backup.

## Release steps

1. Commit the change and push it to GitHub. A release's tag points at the build's commit, so the script publishes no build of uncommitted changes.
2. Build and bundle the release configuration with `swift build -c release` and then `./scripts/bundle_app.sh release`.
3. Run `./scripts/release_app.sh` to check the result. It copies the app to `build/release/<build number>/`. With `ARCH_NOTARY_PROFILE` set, it notarizes and staples the copy. Then it makes `Arch-<version>-<build>.zip` with `ditto -c -k --keepParent` and signs the zip with `sign_update`, which reads the private key from the Keychain. `ARCH_SPARKLE_KEY_FILE` names a key file to use in its place. The script then checks the signature against the app's `SUPublicEDKey` and writes `appcast.xml`. Without `--publish`, it prints the `gh release create` command it would run.
4. Run `./scripts/release_app.sh --publish` to create the release `v<version>-<build>` as the latest release of `taeyoon0137/arch-browser`, with the zip and `appcast.xml` as its assets.

The script stops before uploading when the app has no feed or public key, when its signature does not verify, or when the archive's signature does not match the app's public key.

## Notarization

Gatekeeper blocks a downloaded app that is not notarized. Sparkle removes the quarantine attribute from the update it installs, but a first download from the release page carries it, and Gatekeeper checks that copy. `scripts/release_app.sh` notarizes only when `ARCH_NOTARY_PROFILE` names a `notarytool` keychain profile, and otherwise warns and goes on without it.

Notarization requires the hardened runtime on every executable. Sparkle's parts have it. `scripts/bundle_app.sh` does not yet sign the app and its Chromium helpers with the hardened runtime, which Chromium needs entitlements for, so the notary service may reject the app until that changes. The script warns when the app lacks it.

## User steps

These steps need the user's own hands, credentials, or approval:

1. Back up the private key file named under Keys to a safe place outside the repository.
2. For notarization, store a profile once with `xcrun notarytool store-credentials <profile name>`, using an app-specific password or an App Store Connect API key, and set `ARCH_NOTARY_PROFILE=<profile name>` when releasing.
3. Approve and run the first `./scripts/release_app.sh --publish`.
4. In an installed copy, check Check for Updates… and Settings ▸ General ▸ Updates once a newer release exists (V.12 in `docs/plan.md`).
