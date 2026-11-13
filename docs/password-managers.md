# Password manager plugins design

## Purpose and scope

- This note describes the design for running the 1Password and iCloud Passwords extensions in Arch as web extension plugins on both engines: queue tasks IV.21, IV.22, and IV.13 in `docs/plan.md`, the user's steps IV.23 and IV.24, the part of IV.14 that concerns iCloud Passwords, and row 39 of `docs/features.md`. Both extensions come from the Web Store (`docs/web-store.md`), and both reach a native app on the Mac through native messaging (`docs/plugins.md`, Web extensions as plugins).
- Arch handles the work that needs no outside action: finding the native apps' host manifests, which the vendors install only for browsers they know; distinguishing a real extension from a package that copies its identifier; installing Arch into `/Applications`; and showing status and guidance in Settings ▸ Plugins. The user adds Arch in 1Password, and for iCloud Passwords either obtains Apple's browser passkey entitlement (IV.14) or decides about Apple's list of browsers (IV.24).
- Arch bundles no third-party code, reads other browsers' folders without changing them, and never changes 1Password's files or settings.
- Nothing here uses a private API or needs a flag on `flags://`.

## Facts this design relies on

Read on 2026-11-13 from files on this Mac, without changing them, and from Apple's public repository:

- 1Password 8.12.44 is installed at `/Applications/1Password.app`. Its host manifest `com.1password.1password.json` is in several other browsers' user host folders, also in folders of browsers that are not installed on this Mac, which hold nothing else. It names `/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport`, type `stdio`, and these `allowed_origins`: `hjlinigoblmkhjejkmbegnoaljkphmgo`, `bkpbhnjcbehoklfkljkkbbmipaphipgl`, `gejiddohjgogedgjnonbofjigllpkmbf`, `khgocmkkpikpnmmkgmdnfckapcdkgfaf`, `aeblfdkhhhdcdjpifhhbdiojplfjncoa`, and `dppgmdbiimibapkepcbdbmkaabgiofem`, each as `chrome-extension://<identifier>/`. IV.13's install will show which is the Web Store's 1Password extension; `aeblfdkhhhdcdjpifhhbdiojplfjncoa` is expected.
- Text in 1Password's helper shows that it validates the starting browser's code signature against known browsers and the user's approval list (`browsers.other-trusted-apps` in 1Password's settings). It refuses a browser outside `/Applications` (`NotInApplicationsDirectory`), a bundle reached through a symbolic link (`AppBundleIsSymlinked`), and an unsigned browser, and it checks that the helper runs in the browser's process tree. It has a service for adding a browser (`browser-addition`), so 1Password may ask the user to trust an unknown browser when it connects. One string names the hardened runtime for a client's signature; whether that applies to the browser or only to 1Password's own processes is unknown. The names of 1Password's settings and prompts need verification in IV.23.
- Apple's helper is `/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app` (bundle identifier `com.apple.PasswordManagerBrowserExtensionHelper`, version 27.2). Its host manifest `com.apple.passwordmanager.json` is in the system host folder of one other browser, as a symbolic link into the system's App cryptex, and allows `pejdijmoenmkgeppbflobdenhhabjlaj` and `mfbcdcnpokpoajjciilocoachedjkima`. Another copy, in another browser family's folder, uses that family's manifest format, which Arch does not read.
- Apple's `password-manager-resources` repository explains that from macOS 15.5, Apple turns its file `quirks/web-browser-extension-distribution-information.json` into launch environment constraints signed into that helper, so a browser added to the list needs a macOS update to work. `codesign -d -vvvv` on the helper shows them as its parent launch constraints, an `$or-array` of conditions on the process that starts it. The first admits a parent whose entitlements set `com.apple.developer.web-browser.public-key-credential` to true, the browser passkey entitlement that IV.14 asks for, whether or not the browser is listed. Each of the others is an `$and` of a listed browser's signing identifiers and its team identifier. Arch meets none of them on this Mac. A browser signed with the entitlement therefore starts the helper without a list entry or a macOS update.
- Each entry in that file has `long_name`, `short_name`, `supported_platforms`, `platform_specific_information` (for `Mac`, the required `bundle_identifier`, `code_signing_identifier`, and `code_signing_team_identifier`, and the optional `extensions_install_path_relative_to_user_library_directory` and native messaging process fields), and `supported_store_identifiers`, where `1` is the Web Store. The pull request template requires the browser's official website, a download link, and `codesign -d -vvvv` output from a copy downloaded there.
- Arch keeps its host manifests in `~/Library/Application Support/Arch/NativeMessagingHosts/`, which does not exist on this Mac; no vendor writes there. Chromium reads them through a link the engine creates at `NativeMessagingHosts` under its root cache path (`docs/plugins.md`, Native messaging).
- macOS protects another installed browser's data folder as its app data: reading it fails with `EPERM`, without a prompt (`docs/import-browsers.md`, Permissions). Vendor-created folders for uninstalled browsers were readable from a shell; IV.13 checks whether Arch can read them.
- `scripts/bundle_app.sh` writes `build/Arch.app` with the bundle identifier `xyz.taeyoon.arch`, signed with the first Apple Development identity on the Mac, or ad hoc without one. It does not enable the hardened runtime.
- Both engines start a native app from Arch's own process: Chromium's browser process is the app's main process under CEF, and `NativeMessaging` starts it with `Process`. The helper's parent is therefore Arch on both engines.
- A Chromium profile can start the extensions it ran in an earlier launch before the runtime's first load pass of the run ends; the pass stops those it does not load once its loads end (`WebExtensionRuntime`, `profileDidStart(with:)` and `loadEnabledExtensions()`). An extension that the runtime unloads leaves Chromium at once.

## Decisions

1. Install from the Web Store: both extensions install as store packages, so their identifiers are proven (`docs/web-store.md`, Package proof). A vendor package from a file works when its `.crx` signature verifies.
2. Host discovery: Arch reads the host folders listed by `BrowserSource.nativeMessagingHostFolders` in the `Import` module (`docs/import-browsers.md`, Native messaging hosts) without changing them, and links each valid manifest into its own `NativeMessagingHosts/` folder. Vendors install manifests only for browsers they know, so otherwise the user would have to copy them by hand and recopy them after every vendor change. A link follows the vendor's changes. Chromium follows manifest links, as it does for the system's manifest above. The user's own files in Arch's folder take precedence, and a host whose native app is known not to start for Arch gets no link (Held hosts).
3. Proof gate: a version of an extension reaches a native app through one of Arch's own links only when Arch has proof of its identifier. A package can copy any extension's public `key` and thus its identifier, and the native app trusts the identifier that the browser passes it. A manifest the user puts in Arch's folder takes its name's place for both engines and keeps the current rule, since the user set it up for Arch. The gate never switches a whole plugin off: on Chromium, which reads the links itself, a gated version leaves only the Chromium engine, as for a failure to start there, and WebKit refuses each of its calls.
4. `/Applications`: `scripts/install_app.sh` copies the signed `build/Arch.app` into `/Applications` as a real bundle, since 1Password refuses a browser outside `/Applications` or behind a link. A script fits the build procedure, which creates a new bundle with every build; copying from inside the app would replace a running app's bundle. The script replaces only an earlier Arch or a link, and keeps the earlier bundle until the new one is in place.
5. Signing: unchanged. If 1Password refuses Arch for the hardened runtime, a later task signs with it and the entitlements Chromium's helpers need.
6. Guidance: Settings ▸ Plugins shows, for each web extension with a native app, which app accepts it, whether Arch meets the app's known conditions, and the user's step for 1Password and iCloud Passwords. The two vendors' host names and guidance text are in `NativeAppGuide.swift`.
7. iCloud Passwords: Apple's helper starts for a parent with the browser passkey entitlement or for a browser in Apple's list (Facts). IV.14 asks for the entitlement, which passkeys need on both engines anyway; with it, iCloud Passwords needs no list entry and no macOS update. Apple's list is the alternative if the entitlement is not granted (IV.24): the pull request template requires a public website and download link, and Arch plans no distribution (`docs/plan.md`, Goals), so opening the pull request is the user's decision. The entry and steps are below, with a placeholder for the team identifier. While Arch meets neither condition, Arch holds the helper's host, so neither engine starts the helper, and Settings says why.

## Host discovery

- `NativeMessagingHostLinks` keeps the links. The session creates one per app with Arch's folder and the folders the app shell passes from `BrowserSource.nativeMessagingHostFolders`. Passes run off the main thread. `update()` runs one only if none has run in the current run, and `update(force: true)` always runs one. They are called:
  - by each runtime, `update()` before its first load per run of an enabled extension whose grant has `nativeMessaging`, and `update(force: true)` after installing or updating one;
  - by staging, `update()` for a package that asks for `nativeMessaging`;
  - by Settings ▸ Plugins, `update()` when it first shows, in a run, the section of a plugin whose grant has `nativeMessaging`, enabled or not (Status).
  A Mac without such an extension never reads the folders.
- A pass reads each folder's `*.json` files in the list's order, each up to 64 KB. It keeps a manifest whose `name` matches its filename without `.json` and follows the naming rule, whose `type` is `stdio`, whose `path` is absolute and names an executable file, and whose `allowed_origins` can be read. For each name, the first folder with a valid manifest wins.
- In Arch's folder, the pass creates `<name>.json` as a symbolic link to that manifest, unless something else has that name: a regular file or a link outside the listed folders, which remains the user's. It replaces its own link when the winner moves and removes its own links whose names no longer have a winner. Arch's links are the links in its folder whose destination is a file directly in a listed folder.
- Order: a pass that would create a link or change a link's destination first gives the hosts it found to the session, which passes them to every Persona's runtime. Each runtime takes out of Chromium the versions that the gate would refuse under those links (Proof gate), and only when every runtime has done so does the pass create or change the links. Removing or keeping a link needs no such step. This covers a Persona that did not start the pass, such as one whose plugins did not change, and the first pass of a run in which a host is new.
- Held hosts: a host whose native app is known not to start for Arch is held. The pass keeps it in `hosts` with the reason, creates no link for it, and removes its own link under that name. For `com.apple.passwordmanager`, the pass asks `HelperLaunchConstraints` (Status) about the manifest's `path`, at most once per run, and holds the host while Arch meets none of the helper's parent launch constraints. When the constraints cannot be read, it holds nothing, since the helper enforces them itself. So neither engine starts the helper only for macOS to refuse it.
- A folder that cannot be read because of a permission error is skipped and listed in `unreadableFolders`, which Settings uses (see Status). A missing folder is skipped silently.
- `hosts` keeps the winners by name, with the manifest's `description`, its `allowed_origins`, the folder they came from, and whether the host is held and why, for the gate and Settings. `linkedHosts` gives the names under Arch's own links with the `allowed_origins` of the manifests behind them, which it reads from Arch's folder and those manifests when no pass has run in the current run.

## Proof gate

- The gate covers a name only while Arch's folder has one of Arch's own links under it. A user's file under a name is what both engines read, so it gates nothing, even when a discovered manifest elsewhere has the same name. A version of an extension is gated when its grant has `nativeMessaging`, its package has no proof, and the manifest behind one of Arch's links allows its identifier (`linkedHosts`).
- The gate's sentence names the manifest's `description`: "Arch cannot prove that this extension is the one that 1Password BrowserSupport expects. Install it from the Web Store or from its signed .crx file." For a version installed from a `.crx` file before Arch checked signatures, whose install entry has `source` (`docs/web-store.md`, Package proof), it is "Arch cannot prove that this extension is the one that 1Password BrowserSupport expects. It was installed before Arch checked signatures; install it again from its .crx file or from the Web Store."
- WebKit: `NativeMessaging` refuses a gated version's messages and ports to a name under one of Arch's links with the gate's sentence. The version keeps running on WebKit tabs.
- Chromium reads the links itself, so the gate acts on what Chromium runs. The load pass does not load a gated version in Chromium and takes it out where it is loaded, and the manager keeps the gate's sentence for the run as the version's failure on Chromium, as for a failure to start there. The version keeps running on its other engines; one that runs on no other engine goes off with that sentence, as one that failed on every engine does. A reinstall with proof, which is an update, clears the failure.
- As a Chromium profile starts, the runtime first unloads its gated versions by `linkedHosts`, so that a version the profile kept from an earlier launch stops before the load pass ends.
- Before a pass creates or changes a link, each runtime takes the versions that the new links would gate out of Chromium in the same way (Host discovery, Order).
- Review: the review of a package that the gate would refuse under Arch's current links shows the gate's sentence in its Chromium line instead of refusing the package. Staging runs `update()` first.
- Pairs: a version without proof cannot join a proven counterpart under an identifier that the gate covers, so that a proven plugin does not appear to vouch for an unproven package; each version of an existing pair is gated on its own.

## Installing Arch into /Applications

`scripts/install_app.sh`, after `scripts/bundle_app.sh`:

1. The source is `build/Arch.app`, or `ARCH_APP_SOURCE`. The script refuses a missing source, or one that `signed_with_team` refuses, with "1Password connects only to signed browsers. Set up an Apple Development identity or set ARCH_SIGN_IDENTITY, then run scripts/bundle_app.sh again." `signed_with_team` reads `codesign -dv` output on standard input and accepts only a signature with a team, not an ad hoc one or none. The script prints neither the identity nor the team.
2. It refuses while Arch runs from the destination.
3. `may_replace` allows replacing `Arch.app` in the destination only when it is missing, a symbolic link, or a bundle whose `CFBundleIdentifier` is `xyz.taeyoon.arch`. Anything else stays where it is, and the script ends with "<path> is not Arch (bundle identifier <identifier>). Move it elsewhere, then run the script again.", or without the parenthesis when it has no bundle identifier.
4. `replace_app` copies the source with `ditto` to a temporary name in the destination, removes a link there or moves an earlier bundle to a second temporary name, moves the copy into place, and only then deletes the earlier bundle, which is a copy of an earlier build. If a step fails, a trap deletes the temporary copy and moves the earlier bundle back. When macOS refuses the change for lack of the App Management permission (`Operation not permitted`), the script adds "macOS kept the script from changing <path>. Allow your terminal app in System Settings ▸ Privacy & Security ▸ App Management, then run the script again."
5. It checks the copy with `codesign --verify --deep --strict` and prints its path.

The destination is `/Applications`, or `ARCH_INSTALL_DIR` for checks. With `ARCH_INSTALL_FUNCTIONS_ONLY=1`, sourcing the script defines `signed_with_team`, `may_replace`, and `replace_app` and runs nothing, for the checks under Tests. The Build Procedure adds `./scripts/install_app.sh` and `open /Applications/Arch.app` for password manager checks, and the README's Scripts table lists the script.

## Status and guidance in Settings ▸ Plugins

- A web extension plugin whose grant has `nativeMessaging` lists its native apps in its section. Until a pass has ended in the current run, which the section starts (Host discovery), it says "Looking for native apps…". Then it lists each manifest in Arch's folder or among the discovered hosts that allows its identifier, as "1Password BrowserSupport, set up for Arch", "1Password BrowserSupport, set up for another browser", or, for a held host, "<description>, which macOS does not start for Arch on this Mac", or says "No native app on this Mac accepts this extension." Only in that last case, when a folder could not be read, it adds "macOS kept Arch from reading another browser's native app setup." It names no folder, since the folders name other browser products.
- `ArchInstallation` reports Arch's location, whether it runs in `/Applications` and not through a link, and whether it is signed with a team, ad hoc, or unsigned. It reads signing information from `SecCodeCopySigningInformation` without showing or keeping the team. A plugin with a native app adds "Arch runs from <folder>; some native apps accept only browsers in the Applications folder." and "Arch is not signed by a developer team; some native apps accept only signed browsers." when those conditions hold.
- `NativeAppGuide` adds, for a host name it knows:
  - `com.1password.1password`: "1Password connects to a browser it does not list only after you allow it. When 1Password asks about Arch, allow it, or add Arch in 1Password's settings for browsers."
  - `com.apple.passwordmanager`: "iCloud Passwords starts its helper only for the browsers that macOS lists, which come with macOS updates, and for browsers with Apple's browser passkey entitlement." `HelperLaunchConstraints` reads the helper's parent launch constraints from `codesign -d -vvvv` output, off the main thread and at most once per run, when a pass or the section first needs them. Arch meets them when its own signature, from `SecCodeCopySigningInformation`, matches one condition: a listed pair of signing identifier and team identifier, compared in memory and never shown or kept, or the entitlement condition, when its entitlements set `com.apple.developer.web-browser.public-key-credential` to true. It adds "Arch is among them on this Mac." or "Arch is not among them on this Mac." Unreadable output gives neither sentence.
- WebKit tabs: `NativeMessaging` records each plugin's last outcome during the run, and the section shows it: "On WebKit tabs, 1Password BrowserSupport answered.", or "… ended without answering, as a native app does when it does not accept the browser.", or, for a held host, "On WebKit tabs, Arch did not start <description>, which macOS does not start for Arch.", or the failure message. Arch does not see Chromium's native messages, so it shows no outcome for Chromium tabs.
- Settings ▸ Plugins shows one Persona's plugins, so these lines name no Persona; Arch's folder is shared by every Persona.

## Steps that need the user

### 1Password (IV.23)

1. Run `./scripts/bundle_app.sh` and `./scripts/install_app.sh`, then open `/Applications/Arch.app`.
2. Install 1Password from the Web Store in each Persona that needs it, with Install and Enable, and confirm with Touch ID.
3. When 1Password asks whether to trust Arch, allow it. If it does not ask, open 1Password's settings for browsers and add `/Applications/Arch.app`.
4. Unlock 1Password and fill a login on a WebKit tab and on a Chromium tab.

### iCloud Passwords (IV.14 or IV.24)

Either path makes macOS start the helper for Arch; Settings ▸ Plugins then says "Arch is among them on this Mac."

1. The passkey entitlement (IV.14), first: the Account Holder of an organization's developer account requests `com.apple.developer.web-browser.public-key-credential`, and Arch is signed with a provisioning profile that grants it. Arch then meets the helper's first condition on any Mac with this helper, with no list entry and no macOS update.
2. Apple's list (IV.24), only if the entitlement is not granted:
   1. Decide whether to publish Arch with an official website and a download link for a copy signed for distribution, as the pull request template requires.
   2. If so, fork `apple/password-manager-resources` and add this entry to `web_browsers` in `quirks/web-browser-extension-distribution-information.json`, with the team identifier from `codesign -d -vvvv` of the downloadable copy in place of the placeholder, and check its identifier against the entry's. The optional install path is omitted because Arch keeps extensions in each Persona's plugin folder.

      ```json
      {
          "long_name": "Arch",
          "short_name": "Arch",
          "supported_platforms": [
              "Mac"
          ],
          "platform_specific_information": {
              "Mac": {
                  "bundle_identifier": "xyz.taeyoon.arch",
                  "code_signing_identifier": "xyz.taeyoon.arch",
                  "code_signing_team_identifier": "<TEAM ID>"
              }
          },
          "supported_store_identifiers": [
              1
          ]
      }
      ```

   3. Run `tools/validate-json-schemas.sh`, open the pull request from its template, fill the web browser section with the name, website, download link, and the `codesign` output, and check only the statements that are true.
   4. After the merge, wait for a macOS update, then check iCloud Passwords as in IV.13.

## Tests

- Discovery (`ExtensionsTests`, IV.21), with temporary folders: a pass links each valid manifest, the first folder winning per name; it skips manifests whose name, type, path, or executable is wrong, files over 64 KB, and missing folders; it lists a folder it cannot read; it leaves the user's files and foreign links in Arch's folder; it replaces and removes its own links as the folders change; `update()` runs once per run and `update(force: true)` every time; a runtime without a `nativeMessaging` grant runs no pass; a held host gets no link and loses Arch's link, and a host with unreadable constraints is not held; `HelperLaunchConstraints` on output written for the test: a pair matching Arch's signing identifier and team, the identifier with another team, the entitlement condition with and without the entitlement in Arch's signing information, none, and unreadable output. Order, with two Personas and a recording Chromium engine: a host that appears during the run, and one that is new at the run's first pass, takes an unproven version under its identifier out of Chromium in the Persona that installed nothing before the link exists; removing a link does not wait for the runtimes. `BrowserSource.nativeMessagingHostFolders` names user and system folders (`ImportTests`).
- Gate: on WebKit, a version without proof cannot reach a host behind Arch's link and gets the gate's sentence, while one with proof can; any extension can reach a manifest the user put in Arch's folder that lists it, also when a discovered manifest elsewhere has that name and allows it. On Chromium, a gated version stays out of Chromium with the sentence as its Chromium failure and keeps running on WebKit, and one that runs only on Chromium goes off with it; a Chromium profile's start unloads gated versions before the load pass; the review shows the sentence in its Chromium line; an install entry with `source` and a `.crx` file gets the sentence that asks for a reinstall; a version without proof cannot join a proven counterpart under a gated identifier, and each version of a pair is gated on its own.
- Status (`ExtensionsTests`, IV.22): `ArchInstallation` for a bundle in `/Applications`, elsewhere, and reached through a link, and for signing information with a team, ad hoc, and none; the native app lines for a plugin, "Looking for native apps…" before the run's first pass and the pass the section starts for a plugin that is installed but off, a held host's line, and the unreadable folders sentence only without a native app; `NativeAppGuide` by host name and the `HelperLaunchConstraints` sentences; outcomes recorded per plugin.
- `scripts/install_app.sh` (IV.22): `sh -n` passes. With `ARCH_INSTALL_FUNCTIONS_ONLY=1`, `signed_with_team` accepts fixed `codesign -dv` text with a made-up team and refuses fixed text for an ad hoc and an unsigned bundle; in a temporary folder, `may_replace` allows a missing `Arch.app`, a link, and a minimal bundle with `CFBundleIdentifier` `xyz.taeyoon.arch`, and refuses one with another identifier and a folder without one; `replace_app` replaces a link and such a bundle, and after a failing move leaves the earlier bundle and no temporary copy. With `ARCH_APP_SOURCE` set to a minimal `.app` signed ad hoc and `ARCH_INSTALL_DIR` to a temporary folder, the script refuses it and leaves the destination unchanged, and with a destination bundle of another identifier it leaves that bundle in place. Installing a bundle signed by a team waits for IV.23 and IV.13.

## Checks with the app (IV.13)

Run from `/Applications/Arch.app` after IV.23's steps, with the screen unlocked:

1. `scripts/install_app.sh` installed the bundle signed by a team as a folder, replacing an earlier copy or a link, and `codesign --verify --deep --strict` passed.
2. Settings ▸ Plugins lists 1Password BrowserSupport for the 1Password plugin, through Arch's link, and records the identifier the store gave it; Arch reads the vendor's folders without a prompt, or the section says that macOS kept it from reading another browser's setup.
3. 1Password fills a login and saves a new one on a WebKit tab and on a Chromium tab, each engine with its own unlock (`docs/plugins.md`, One install, two runtimes). Record which engines run the store package; if one refuses it, record whether the vendor offers a package for that engine.
4. With Arch running from `build/Arch.app` instead, 1Password refuses it, and the section names the Applications folder.
5. iCloud Passwords installs from the store, and the section says whether Arch is among the helper's browsers. While it is not, Arch has no link for the helper's host, and the WebKit outcome says that macOS does not start it for Arch. After IV.14 or IV.24, it fills a login on both engines.

## Risks

1. 1Password may require more than its text shows, such as the hardened runtime or a signature for distribution. The check records its requirements, and a later task changes the signing.
2. 1Password's approval list is tied to Arch's signature. A build signed with another identity is a browser 1Password does not know, and the user allows it again.
3. iCloud Passwords needs IV.14's entitlement, which only an organization's Account Holder can request, or Apple's list, which needs a public Arch and a macOS update. Without either, it stays unavailable, and the Passwords app and its AutoFill remain the way to reach those passwords.
4. A vendor may install its manifest only in a folder macOS protects. Discovery then finds nothing, and the user must copy the manifest into Arch's folder by hand.
5. `build/Arch.app` and `/Applications/Arch.app` share the bundle identifier and the Application Support folder, and links from other apps may open either. Checks name the copy they open.
6. Apple may change the helper's constraints or how `codesign` prints them. Unreadable constraints hold no host, so the helper then decides itself, as before this design.
