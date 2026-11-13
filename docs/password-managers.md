# Password manager plugins design

## Purpose and scope

- This note describes the design for running the 1Password and iCloud Passwords extensions in Arch as web extension plugins on both engines: queue tasks IV.21, IV.22, and IV.13 in `docs/plan.md`, the user's steps IV.23 and IV.24, and row 39 of `docs/features.md`. Both extensions come from the Web Store (`docs/web-store.md`), and both reach a native app on the Mac through native messaging (`docs/plugins.md`, Web extensions as plugins).
- Arch handles the work that needs no outside action: finding the native apps' host manifests, which the vendors install only for browsers they know; distinguishing a real extension from a package that copies its identifier; installing Arch into `/Applications`; and showing status and guidance in Settings ▸ Plugins. The user adds Arch in 1Password and decides about Apple's list of browsers.
- Arch bundles no third-party code, reads other browsers' folders without changing them, and never changes 1Password's files or settings.
- Nothing here uses a private API or needs a flag on `flags://`.

## Facts this design relies on

Read on 2026-11-13 from files on this Mac, without changing them, and from Apple's public repository:

- 1Password 8.12.44 is installed at `/Applications/1Password.app`. Its host manifest `com.1password.1password.json` is in several other browsers' user host folders, also in folders of browsers that are not installed on this Mac, which hold nothing else. It names `/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport`, type `stdio`, and these `allowed_origins`: `hjlinigoblmkhjejkmbegnoaljkphmgo`, `bkpbhnjcbehoklfkljkkbbmipaphipgl`, `gejiddohjgogedgjnonbofjigllpkmbf`, `khgocmkkpikpnmmkgmdnfckapcdkgfaf`, `aeblfdkhhhdcdjpifhhbdiojplfjncoa`, and `dppgmdbiimibapkepcbdbmkaabgiofem`, each as `chrome-extension://<identifier>/`. IV.13's install will show which is the Web Store's 1Password extension; `aeblfdkhhhdcdjpifhhbdiojplfjncoa` is expected.
- Text in 1Password's helper shows that it validates the starting browser's code signature against known browsers and the user's approval list (`browsers.other-trusted-apps` in 1Password's settings). It refuses a browser outside `/Applications` (`NotInApplicationsDirectory`), a bundle reached through a symbolic link (`AppBundleIsSymlinked`), and an unsigned browser, and it checks that the helper runs in the browser's process tree. It has a service for adding a browser (`browser-addition`), so 1Password may ask the user to trust an unknown browser when it connects. One string names the hardened runtime for a client's signature; whether that applies to the browser or only to 1Password's own processes is unknown. The names of 1Password's settings and prompts need verification in IV.23.
- Apple's helper is `/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app` (bundle identifier `com.apple.PasswordManagerBrowserExtensionHelper`, version 27.2). Its host manifest `com.apple.passwordmanager.json` is in the system host folder of one other browser, as a symbolic link into the system's App cryptex, and allows `pejdijmoenmkgeppbflobdenhhabjlaj` and `mfbcdcnpokpoajjciilocoachedjkima`. Another copy, in another browser family's folder, uses that family's manifest format, which Arch does not read.
- Apple's `password-manager-resources` repository explains that from macOS 15.5, Apple turns its file `quirks/web-browser-extension-distribution-information.json` into launch environment constraints signed into that helper. The helper starts only for listed browsers, and a browser added to the list needs a macOS update to work. `codesign -d -vvvv` on the helper's executable shows the constraints: on this Mac they list browsers' signing identifiers, and Arch's is not among them.
- Each entry in that file has `long_name`, `short_name`, `supported_platforms`, `platform_specific_information` (for `Mac`, the required `bundle_identifier`, `code_signing_identifier`, and `code_signing_team_identifier`, and the optional `extensions_install_path_relative_to_user_library_directory` and native messaging process fields), and `supported_store_identifiers`, where `1` is the Web Store. The pull request template requires the browser's official website, a download link, and `codesign -d -vvvv` output from a copy downloaded there.
- Arch keeps its host manifests in `~/Library/Application Support/Arch/NativeMessagingHosts/`, which does not exist on this Mac; no vendor writes there. Chromium reads them through a link the engine creates at `NativeMessagingHosts` under its root cache path (`docs/plugins.md`, Native messaging).
- macOS protects another installed browser's data folder as its app data: reading it fails with `EPERM`, without a prompt (`docs/import-browsers.md`, Permissions). Vendor-created folders for uninstalled browsers were readable from a shell; IV.13 checks whether Arch can read them.
- `scripts/bundle_app.sh` writes `build/Arch.app` with the bundle identifier `xyz.taeyoon.arch`, signed with the first Apple Development identity on the Mac, or ad hoc without one. It does not enable the hardened runtime.
- Both engines start a native app from Arch's own process: Chromium's browser process is the app's main process under CEF, and `NativeMessaging` starts it with `Process`. The helper's parent is therefore Arch on both engines.

## Decisions

1. Install from the Web Store: both extensions install as store packages, so their identifiers are proven (`docs/web-store.md`, Package proof). A vendor package from a file works when its `.crx` signature verifies.
2. Host discovery: Arch reads the host folders listed by `BrowserSource.nativeMessagingHostFolders` in the `Import` module (`docs/import-browsers.md`, Native messaging hosts) without changing them, and links each valid manifest into its own `NativeMessagingHosts/` folder. Vendors install manifests only for browsers they know, so otherwise the user would have to copy them by hand and recopy them after every vendor change. A link follows the vendor's changes. Chromium follows manifest links, as it does for the system's manifest above. The user's own files in Arch's folder take precedence.
3. Proof gate: an extension reaches a native app through a discovered manifest only when Arch has proof of its identifier. A package can copy any extension's public `key` and thus its identifier, and the native app trusts the identifier that the browser passes it. Manifests the user puts in Arch's folder keep the current rule, since the user set them up for Arch.
4. `/Applications`: `scripts/install_app.sh` copies the signed `build/Arch.app` into `/Applications` as a real bundle, since 1Password refuses a browser outside `/Applications` or behind a link. A script fits the build procedure, which creates a new bundle with every build; copying from inside the app would replace a running app's bundle.
5. Signing: unchanged. If 1Password refuses Arch for the hardened runtime, a later task signs with it and the entitlements Chromium's helpers need.
6. Guidance: Settings ▸ Plugins shows, for each web extension with a native app, which app accepts it, whether Arch meets the app's known conditions, and the user's step for 1Password and iCloud Passwords. The two vendors' host names and guidance text are in `NativeAppGuide.swift`.
7. Apple's list: the entry and steps are below, with a placeholder for the team identifier. The template requires a public website and download link, and Arch plans no distribution (`docs/plan.md`, Goals), so opening the pull request is the user's decision (IV.24). Until a macOS update carries Arch in the helper's constraints, iCloud Passwords cannot work in Arch, and Settings says so.

## Host discovery

- `NativeMessagingHostLinks` keeps the links. The session creates one per app with Arch's folder and the folders the app shell passes from `BrowserSource.nativeMessagingHostFolders`. Each runtime calls `update()` before its first load per run of an enabled extension whose grant has `nativeMessaging`, and `update(force: true)` after installing or updating one. A Mac without such an extension never reads the folders.
- A pass reads each folder's `*.json` files in the list's order, each up to 64 KB. It keeps a manifest whose `name` matches its filename without `.json` and follows the naming rule, whose `type` is `stdio`, whose `path` is absolute and names an executable file, and whose `allowed_origins` can be read. For each name, the first folder with a valid manifest wins.
- In Arch's folder, the pass creates `<name>.json` as a symbolic link to that manifest, unless something else has that name: a regular file or a link outside the listed folders, which remains the user's. It replaces its own link when the winner moves and removes its own links whose names no longer have a winner. Arch's links are the links in its folder whose destination is a file directly in a listed folder.
- A folder that cannot be read because of a permission error is skipped and listed in `unreadableFolders`, which Settings shows (see Status). A missing folder is skipped silently.
- `hosts` keeps the winners by name, with the manifest's `description`, its `allowed_origins`, and the folder they came from, for the gate and Settings.

## Proof gate

- WebKit: `NativeMessaging` reaches a manifest through one of Arch's links only for an extension whose plugin has a proof; otherwise it fails with "Arch cannot prove that this extension is the one that 1Password BrowserSupport expects. Install it from the Web Store or from its signed .crx file.", naming the manifest's `description`.
- Chromium's own native messaging reads the links directly, so the gate acts on packages. Staging refuses a package without proof that asks for `nativeMessaging` while a discovered manifest lists its identifier, with the same sentence. A load pass switches off such an installed plugin with that sentence, as for a failure on every engine. Staging runs a pass first if none has run during the current run.
- A pair whose versions share an identifier passes only while both versions have a proof: a version without one cannot join such a counterpart, and the load pass switches off the version without one.

## Installing Arch into /Applications

`scripts/install_app.sh`, after `scripts/bundle_app.sh`:

1. Refuses a missing `build/Arch.app` or one signed ad hoc or without a team, with "1Password connects only to signed browsers. Set up an Apple Development identity or set ARCH_SIGN_IDENTITY, then run scripts/bundle_app.sh again." It prints neither the identity nor the team.
2. Refuses while Arch runs from the destination.
3. Copies the bundle with `ditto` to a temporary name in the destination, removes `Arch.app` there, whether a bundle or a link, and moves the copy into its place.
4. Checks the copy with `codesign --verify --deep --strict` and prints its path.

The destination is `/Applications`, or `ARCH_INSTALL_DIR` for checks. The Build Procedure adds `./scripts/install_app.sh` and `open /Applications/Arch.app` for password manager checks, and the README's Scripts table lists the script.

## Status and guidance in Settings ▸ Plugins

- A web extension plugin whose grant has `nativeMessaging` lists its native apps in its section: each manifest in Arch's folder or among the discovered hosts that allows its identifier, as "1Password BrowserSupport, set up for Arch" or "1Password BrowserSupport, set up for another browser", or "No native app on this Mac accepts this extension." Each folder that macOS kept Arch from reading adds "macOS kept Arch from reading the native app setup in <folder>."
- `ArchInstallation` reports Arch's location, whether it runs in `/Applications` and not through a link, and whether it is signed with a team, ad hoc, or unsigned. It reads signing information from `SecCodeCopySigningInformation` without showing or keeping the team. A plugin with a native app adds "Arch runs from <folder>; some native apps accept only browsers in the Applications folder." and "Arch is not signed by a developer team; some native apps accept only signed browsers." when those conditions hold.
- `NativeAppGuide` adds, for a host name it knows:
  - `com.1password.1password`: "1Password connects to a browser it does not list only after you allow it. When 1Password asks about Arch, allow it, or add Arch in 1Password's settings for browsers."
  - `com.apple.passwordmanager`: "iCloud Passwords starts its helper only for the browsers that macOS lists, which come with macOS updates." `HelperLaunchConstraints` reads `codesign -d -vvvv` of the helper off the main thread when the section first appears in a run and looks for the signing identifier of Arch's own signature. It adds "Arch is not among them on this Mac." or "Arch is among them on this Mac." Unreadable output gives neither sentence.
- WebKit tabs: `NativeMessaging` records each plugin's last outcome during the run, and the section shows it: "On WebKit tabs, 1Password BrowserSupport answered.", or "… ended without answering, as a native app does when it does not accept the browser.", or the failure message. Arch does not see Chromium's native messages, so it shows no outcome for Chromium tabs.
- Settings ▸ Plugins shows one Persona's plugins, so these lines name no Persona; Arch's folder is shared by every Persona.

## Steps that need the user

### 1Password (IV.23)

1. Run `./scripts/bundle_app.sh` and `./scripts/install_app.sh`, then open `/Applications/Arch.app`.
2. Install 1Password from the Web Store in each Persona that needs it, with Install and Enable, and confirm with Touch ID.
3. When 1Password asks whether to trust Arch, allow it. If it does not ask, open 1Password's settings for browsers and add `/Applications/Arch.app`.
4. Unlock 1Password and fill a login on a WebKit tab and on a Chromium tab.

### iCloud Passwords and Apple's list (IV.24)

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
4. After the merge, wait for a macOS update. Settings ▸ Plugins then says "Arch is among them on this Mac.", and iCloud Passwords can be checked as in IV.13.

## Tests

- Discovery (`ExtensionsTests`, IV.21), with temporary folders: a pass links each valid manifest, the first folder winning per name; it skips manifests whose name, type, path, or executable is wrong, files over 64 KB, and missing folders; it lists a folder it cannot read; it leaves the user's files and foreign links in Arch's folder; it replaces and removes its own links as the folders change; a runtime without a `nativeMessaging` grant runs no pass. `BrowserSource.nativeMessagingHostFolders` names user and system folders (`ImportTests`).
- Gate: on WebKit, an extension without proof cannot reach a discovered host and gets the message, while one with proof can, and any extension can reach a manifest the user put in Arch's folder that lists it. Staging refuses a package without proof that asks for `nativeMessaging` under a discovered host's identifier, a load pass switches off such an installed plugin with the reason, and a pair under a shared identifier passes only with both versions proven.
- Status (`ExtensionsTests`, IV.22): `ArchInstallation` for a bundle in `/Applications`, elsewhere, and reached through a link, and for signing information with a team, ad hoc, and none; the native app lines for a plugin; `NativeAppGuide` by host name; `HelperLaunchConstraints` on output written for the test, with and without Arch's signing identifier, and on unreadable output; outcomes recorded per plugin.
- `scripts/install_app.sh` (IV.22): `sh -n` passes; with `ARCH_INSTALL_DIR` set to a temporary folder, it installs a bundle signed with an Apple Development identity as a folder, replacing a link there, and refuses an ad hoc bundle.

## Checks with the app (IV.13)

Run from `/Applications/Arch.app` after IV.23's steps, with the screen unlocked:

1. Settings ▸ Plugins lists 1Password BrowserSupport for the 1Password plugin, through Arch's link, and records the identifier the store gave it; Arch reads the vendor's folders without a prompt, or the section names the folders macOS kept from it.
2. 1Password fills a login and saves a new one on a WebKit tab and on a Chromium tab, each engine with its own unlock (`docs/plugins.md`, One install, two runtimes). Record which engines run the store package; if one refuses it, record whether the vendor offers a package for that engine.
3. With Arch running from `build/Arch.app` instead, 1Password refuses it, and the section names the Applications folder.
4. iCloud Passwords installs from the store, and the section says whether Arch is among the helper's browsers; while it is not, the WebKit outcome says that the native app ended without answering. After IV.24, it fills a login on both engines.

## Risks

1. 1Password may require more than its text shows, such as the hardened runtime or a signature for distribution. The check records its requirements, and a later task changes the signing.
2. 1Password's approval list is tied to Arch's signature. A build signed with another identity is a browser 1Password does not know, and the user allows it again.
3. Apple's list needs a public Arch and a macOS update. Without both, iCloud Passwords stays unavailable, and the Passwords app and its AutoFill remain the way to reach those passwords.
4. A vendor may install its manifest only in a folder macOS protects. Discovery then finds nothing, and the user must copy the manifest into Arch's folder by hand.
5. `build/Arch.app` and `/Applications/Arch.app` share the bundle identifier and the Application Support folder, and links from other apps may open either. Checks name the copy they open.
