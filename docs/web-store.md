# Web Store installs design

## Purpose and scope

- This note describes the design for installing web extensions from the Web Store, Google's extension store for browsers built on Chromium, as `webExtension` plugins (`docs/plugins.md`, Web extensions as plugins). It covers queue tasks IV.26, IV.27, and IV.17 to IV.20 in `docs/plan.md` and row 44 of `docs/features.md`. The password managers that use it, 1Password and iCloud Passwords, are covered in `docs/password-managers.md` (IV.21, IV.22, and IV.13).
- The user installs an extension from its store page in a tab, from a store address or an extension identifier pasted into Settings or the palette, and from the install sheet. Arch downloads the package from Google's public update endpoint for that identifier, checks the CRX3 package's signatures and its identifier, stages it for review in the existing sheet, and installs it for the engines its package supports, as with a `.crx` file the user selects.
- This reverses the open decision in `docs/plugins.md` that allowed no direct installs from an online store. Arch still runs no server or vendor backend of its own: it calls Google's public endpoints, and only when the user acts.
- Arch's interface, code, and documents call the store the Web Store. Its page addresses name another browser product in their host names, which `AGENTS.md` allows only in the README's opening and in browser import. The user's step IV.27 adds an exception for them to `AGENTS.md`. Until then, this note and the queue describe those hosts without writing them, and IV.17, which needs them, waits. Afterwards they appear only in `WebStore.swift`, as constants that the tests also use, and in this note. The update endpoint's address names no browser product.
- This design uses no private API and needs no flag on `flags://`.

## Facts this design relies on

- An extension's identifier is 32 letters from `a` to `p`: the first 128 bits of the SHA-256 digest of its public key, each hexadecimal digit written as a letter (`docs/plugins.md`, Identifier).
- An extension's store page is `https://<store host>/detail/<slug>/<identifier>`, on the store's own host. The slug is optional, and a query or fragment may follow. Older addresses, `https://<older host>/webstore/detail/<slug>/<identifier>`, redirect there. The store's other pages, such as categories and search, contain no identifier. Both hosts name another browser product, so IV.17 writes them into `WebStore.swift` and here only after IV.27.
- Chromium's extension updater requests `https://clients2.google.com/service/update2/crx` with one `x` parameter per extension: a URL-encoded `id=<identifier>&v=<version>&installsource=ondemand&uc`, `v=0.0.0.0` for an extension it does not have, and `prodversion`, the browser's Chromium version, `acceptformat=crx3`, and the Mac's `os` and `arch` values. With `response=updatecheck`, the response is update protocol 2.0 XML: a `gupdate` element with an `app` element per identifier, each with `appid` and `status`, and an `updatecheck` element inside it with `status` (`ok` with `codebase`, `version`, `hash_sha256`, and `size`, `noupdate`, or an error such as `error-unknownApplication`). `codebase` is an HTTPS address of the package. The endpoint's required parameters have not been checked from this Mac: IV.17 checks them once with `curl` for a public extension and records the result here.
- A CRX3 file is `Cr24`, the format version 3, and the header's length, each a 32-bit little-endian number, then the header, a `CrxFileHeader` protocol buffer message, then a `.zip` archive. The header contains: `sha256_with_rsa` (2) and `sha256_with_ecdsa` (3), repeated `AsymmetricKeyProof`s, each a public key as DER `SubjectPublicKeyInfo` (1) and a signature (2); and `signed_header_data` (10000), a `SignedData` message whose `crx_id` (1) is the first 16 bytes of the developer key's SHA-256 digest. Each signature covers `CRX3 SignedData`, a zero byte, the length of `signed_header_data` as a 32-bit little-endian number, `signed_header_data`, and the archive: RSA PKCS #1 v1.5 or ECDSA P-256 over SHA-256.
- A store-published package also carries a proof by the store's publisher key, whose SHA-256 digest Chromium's verifier holds (`kPublisherKeyHash` in `components/crx_file/crx_verifier.cc`). IV.26 copies that digest from the Chromium source of the pinned CEF branch and confirms it against a package downloaded from the store.
- Currently, `CRXArchive` checks no signatures: it takes the header key whose digest matches `crx_id` and writes it into the manifest (`docs/plugins.md`, Identifier). The Chromium adapter refuses the store's install prompts without asking (`ChromiumExtensions.cefExtensionsShowPrompt`). Whether the store's page offers its own install button on Arch's engine needs verification.

## Decisions

1. Sources: a store page in a tab, a pasted store address or identifier, and the install sheet. On Chromium tabs, the store's own install button, if the store offers it, starts the same install (see Chromium's store button).
2. One path: every source calls `WebStoreInstaller.stage(_:in:)`, which downloads the current package for the identifier and stages it with the origin `webStore`, and every package goes through the review sheet. Nothing installs or updates without the review.
3. Proof: a store package must carry a valid developer proof for its identifier and a valid proof by the store's publisher key, and its identifier must match the request. A `.crx` file the user chooses must carry a valid developer proof. `plugins.json` records the proof in entries that earlier builds keep as they are (Package proof). This settles how Arch tells a real extension from a package that copies its `key` (`docs/plugins.md`, Open decisions), which the password managers' native apps need (`docs/password-managers.md`).
4. Updates: Arch checks the store for updates to extensions installed from it only when the user clicks Check for Updates in Settings ▸ Plugins and when Settings ▸ Plugins first shows a Persona in an app run. No timer, launch, or background check runs, and an update installs only through its review. Arch therefore adds no update service of its own (row 37).
5. Privacy: a request carries the identifiers and installed versions of the requested extensions, the Chromium version of Arch's engine, and the Mac's `os` and `arch`. It carries no cookies, language, install dates, or ping parameters. It uses an ephemeral `URLSession` without cookie storage or cache, as plugin fetches do.
6. Reviews from a tab open in Settings ▸ Plugins in the tab's Persona, like Install <Engine> Version… from the site settings popover, so every review appears in one place.
7. Personas: a plugin belongs to a whole Persona. With two or more Personas, the review sheet names it by the Persona / Space rule (`docs/windows-personas.md`, Persona rule 7), as the Clear Site Data sheet does: a review that starts from a tab or a window says "Installs in the Persona of “Work / Research” for all its spaces." with the tab's space or the window's current space, and a review started in Settings ▸ Plugins, which shows a Persona without a space, says "Installs in “Work” for all its spaces." Settings ▸ Plugins' picker lists Personas alone. The store row in the site settings popover and the palette names no Persona.

## Install flow

1. Resolve: `WebStore.extensionID(in:)` reads a store page's address, and `WebStore.extensionID(from:)` reads pasted text: a store address, or a bare identifier, ignoring case and trimming spaces at either end.
2. Ask: `WebStoreClient.releases(of:)` queries the endpoint for the identifier with `v=0.0.0.0` and returns its `WebStoreRelease`: the version, the package's address, its SHA-256 digest when the response provides one, and its size. An identifier unknown to the store is refused with "The Web Store has no extension with the identifier “…”."; another status with "The Web Store did not offer “…”: <status>.".
3. Compare: when the Persona has that extension version installed from the store, the sheet says "“1Password” 8.11.2 is installed, the Web Store's current version." with Done, and downloads nothing.
4. Download: into `Staging/<UUID>.crx` in the Persona's folder, from an HTTPS address only, stopping if it exceeds 256 MB. A file whose digest differs from the response's is deleted and refused with "The download from the Web Store is damaged. Try again."
5. Stage: `PluginManager.stage(_:origin:)` stages the file as a `.crx` file with the origin `webStore(<identifier>)`. It refuses a package without the store's publisher proof ("The package is not signed by the Web Store."), one whose identifier differs from the request ("The Web Store sent the package of another extension."), and a theme, whose manifest has `theme` ("“…” is a theme, which Arch does not use."). The engines check it like any web extension package (`docs/plugins.md`, Engine versions ▸ Coverage), and the downloaded file is deleted once the package is staged or refused.
6. Review: the subtitle says "Version 8.11.2 from the Web Store.". The review matches the package against installed plugins like any other package: an installed identifier makes it an update, with the warning about another source when the installed plugin came from a file, and it can join a plugin as an engine version. Install and Install and Enable work as for files, with Touch ID for every website or `nativeMessaging`.

Network failures show the system's message, such as "The Internet connection appears to be offline.". The sheet shows progress during the request and download, and Cancel stops the request and deletes the partial file.

## Entry points

- Settings ▸ Plugins: Install from Web Store… beside Install Plugin… opens a sheet with one field, "Web Store address or extension ID", whose Continue button becomes available once the text specifies an identifier. The sheet then shows progress and any failure, or is replaced by the review sheet.
- The install sheet: Install <Engine> Version… becomes a menu with From a File…, the existing open panel, and From the Web Store…, the store sheet. It does so in a plugin's Settings section, in the install sheet's last step, and in the Settings note. The store's package then becomes that engine's version, as with a file. The popover's Install <Engine> Version… still opens Settings, where the menu offers both.
- A tab on a store page: the extensions section of the site settings popover starts with a Web Store row: "Install This Extension…" or, when the tab's Persona has the identifier installed, "“1Password” is installed." The palette lists Install Extension from This Page while the window's tab is on a store page. Both call `BrowserSession.installFromWebStore` with the tab's Persona and space, which the app shell sets like `installEngineVersion`: it opens Settings ▸ Plugins at the Persona with the store sheet open for the identifier, and the review names the Persona with the space (Decision 7).
- The palette: typed text that `WebStore.extensionID(from:)` recognizes adds an Install from the Web Store row below the default row, which does the same in the window's Persona and current space.

### Chromium's store button

`EngineExtensionPrompt.Kind` gains `install`, which the Chromium adapter reports with the extension's identifier and the prompt's tab instead of silently refusing it. The runtime answers false, so Chromium never installs an extension outside Arch's plugin list, and, when the tab shows a store page, asks the host to start Arch's store install for the identifier in the tab's Persona, with the tab for its space (`WebExtensionHost.installFromWebStore(_:persona:tab:)`). A prompt without a store page in its tab is still refused. WebKit has no store install prompt.

## Package proof

- `PluginProof` is `developer`, for a valid developer proof, or `webStore`, for a valid developer proof and a valid proof by the store's publisher key. A package without either has no proof: folders, `.zip` archives, and plugins that AI writes.
- `CRXArchive` checks each proof: an RSA key through Security (`SecKeyCreateWithData` with the key's PKCS #1 bytes from the `SubjectPublicKeyInfo`, and `SecKeyVerifySignature` with `rsaSignatureMessagePKCS1v15SHA256`), and a P-256 key through CryptoKit (`P256.Signing.PublicKey(derRepresentation:)` and a DER signature over the SHA-256 digest). The developer proof is a valid proof by a key whose digest begins with `crx_id`. A `.crx` file without a developer proof is refused with "The signature of “…” does not match its contents.", as Chromium refuses it, whatever its origin.
- `plugins.json` keeps the proof in the install entry as `"proof": "developer"` or `"proof": "webStore"`. A proven `.crx` install names its file with `"signedSource": "<file URL>"`, and a store install its origin with `"webStore": "<identifier>"`, each in place of `source`. Builds before IV.26 read an entry only with `source` or `generated` and drop keys they do not know when they write one, so they keep these entries as they are, as entries they cannot read, and do not list those plugins, instead of rewriting them without the proof. An entry with `source` has no proof, even with a `proof` key: a `.crx` file installed before IV.26 counts as unproven until it is reinstalled, and the native app gate says so (`docs/password-managers.md`, Proof gate). A proof value unknown to this build counts as none and stays in the file.
- An update records its own proof. When an update has no proof but the installed plugin does, the review adds: "The installed version is signed by its developer; this package is not."

## Updates

- Check for Updates in Settings ▸ Plugins, shown while the Persona has extensions installed from the store, checks up to 25 per request, with their installed versions, and shows when it last checked in the run or why it failed. Settings ▸ Plugins also checks once per Persona per run, when it first shows the Persona.
- Only installs with the origin `webStore` are checked. Each version of a pair is checked under its engine identifier, which its package names.
- A newer version, by Chromium's version order (one to four dot-separated numbers, compared as numbers), appears in the plugin's section: "Version 8.12.0 is available from the Web Store." with Review Update…, which downloads it as in the install flow, stages it as an update of that plugin (`PluginPackage.updates`), and opens the review, with newly requested permissions and sites marked New. A version that is not newer shows nothing.
- The results last for the run and belong to the Persona's entry in `WebStoreInstaller.updates`, which is deleted with the Persona.

## Types

```swift
// Extensions, WebStore.swift: the store's addresses, which no other file names; written after IV.27.
public enum WebStore {
    /// The identifier of the extension whose store page `url` is, or nil for any other address.
    public static func extensionID(in url: URL) -> String?
    /// The identifier that typed or pasted text names: a store page's address or a bare identifier, without case and spaces at either end.
    public static func extensionID(from text: String) -> String?
    /// The update endpoint.
    static let updateEndpoint: URL
    /// The hosts of store pages, the current one first, from which the tests build their addresses.
    static let pageHosts: [String]
}

public struct WebStoreRelease: Equatable, Sendable {
    public let id: String
    public let version: String
    let package: URL
    let sha256: Data?
    let size: Int?
}

// Extensions, WebStoreClient.swift
public final class WebStoreClient: Sendable {
    /// `productVersion` is the Chromium version in the CEF version of Arch's engine, such as 156.0.8078.17, which the app shell reads without starting CEF.
    public init(productVersion: String, session: URLSession)
    /// Asks about each identifier, at most 25 to a request, with its installed version, or 0.0.0.0 for nil.
    func releases(of queries: [(id: String, version: String?)]) async throws -> [String: WebStoreRelease]
    /// Writes the package to `file`, which must not exist, checking its size and digest.
    func download(_ release: WebStoreRelease, to file: URL) async throws
}

// Extensions, WebStoreInstaller.swift: one per app, which the session owns.
@MainActor
public final class WebStoreInstaller: ObservableObject {
    public init(client: WebStoreClient)
    /// Downloads the current package of the identifier and stages it in the Persona of `plugins` with the origin `webStore`.
    public func stage(_ id: String, in plugins: PluginManager) async throws -> PluginPackage
    /// The newer versions found for each Persona's store installs in this run.
    @Published public private(set) var updates: [PersonaID: [PluginID: WebStoreRelease]]
    /// Asks about the Persona's store installs; `onlyOncePerRun` skips a Persona already checked in the run.
    public func checkForUpdates(in plugins: PluginManager, onlyOncePerRun: Bool) async throws
    public func stageUpdate(of plugin: PluginID, in plugins: PluginManager) async throws -> PluginPackage
    public func forget(_ persona: PersonaID)
}

// Plugins
public enum PluginProof: String, Sendable { case developer, webStore }
// PluginOrigin
case webStore(String)
// PluginPackage and InstalledPlugin
public let proof: PluginProof?
// PluginManager: stages a downloaded `.crx` file with its origin, refusing a store package without the store's proof or with another identifier.
public func stage(_ file: URL, origin: PluginOrigin) async throws -> PluginPackage

// ARCHEngine, EngineExtensionPrompt.Kind
case install

// Extensions, WebExtensionHost: `tab` gives the review its space.
func installFromWebStore(_ id: String, persona: PersonaID, tab: (any EngineWebContents)?)

// Browsing, BrowserSession
public let webStore: WebStoreInstaller
/// Set by the app shell: opens Settings ▸ Plugins at the Persona with the store sheet started for the identifier, and a review that names the Persona with the space, if any.
public var installFromWebStore: ((Persona.ID, Space.ID?, String) -> Void)?
```

`Preferences` gains a dependency on `Extensions` in `Package.swift` for the store sheet.

## Tests

- Proof (`PluginsTests`, IV.26): `.crx` files the test signs with a generated RSA key and a P-256 key stage with the proof `developer`; an added proof by a test publisher key, which the verifier takes as a parameter, gives `webStore`. A file whose archive or signed header changed after signing, whose signature uses another key, or whose `crx_id` matches no proof key is refused. Folders and `.zip` archives have no proof. `plugins.json` writes a proven `.crx` install with `signedSource` and `proof` and a store install with `webStore` and `proof`, never with `source`, and reads them back; an entry with `source` and a `proof` key has no proof; an unknown proof value survives a write. The test `CRXFile` in `EngineRequestsTests.swift` signs its files.
- Store (`ExtensionsTests`, IV.17), with a `URLProtocol` that answers for the endpoint, so no test reaches the network: `extensionID(in:)` reads both page forms with and without a slug, query, or fragment, and no identifiers from other store pages or hosts, with every store address built from `WebStore.pageHosts`, so that `WebStoreTests.swift` names no host; `extensionID(from:)` reads addresses and bare identifiers in any case and refuses 31 or 33 letters and letters past `p`. The request has the parameters above, one `x` per identifier, 25 to a request, and no cookie header. The response's statuses map to releases and messages, with several `app` elements in one response. A download is refused if it uses HTTP, exceeds the size limit, or has a different digest. A store package without the publisher proof, with another identifier, or with `theme` is refused; one with both proofs stages with the origin `webStore` and installs with it in `plugins.json`.
- Entry points (`ExtensionsTests` and `BrowsingTests`, IV.18): the palette's rows for a store address and for a bare identifier, the popover's Web Store row for a store page, installed or not, and the review's Persona sentence for a start from a tab, from the palette, and from Settings ▸ Plugins.
- Chromium's store button (`ExtensionsTests`, IV.19): a recording engine's install prompt on a store page is answered false and reaches the host with the identifier, the Persona, and the tab; one on another page is answered false and does not reach the host.
- Updates (`ExtensionsTests`, IV.20): one request for the Persona's store installs with their versions and none for file installs; the automatic check runs once per Persona per run, and Check for Updates runs every time; only newer versions show; Review Update stages an update of that plugin; deleting a Persona drops its results.

## Checks with the app

Run from the bundle launched through `open`, using a test Persona or a fresh Application Support folder:

1. Settings ▸ Plugins ▸ Install from Web Store… with a public extension's store address shows its review with "from the Web Store", installs it, and it runs on the engines its review names.
2. On a store page in a WebKit tab and in a Chromium tab, the site settings popover's Web Store row and the palette's Install Extension from This Page open the same review in the tab's Persona. On Chromium, note whether the store offers its own install button and whether it opens the review.
3. Check for Updates finds nothing for a current extension. After the `version` in the installed copy's `manifest.json` is lowered while Arch is not running, it offers Review Update….
4. A pasted theme identifier is refused with its message.

## Risks

1. The endpoint is Google's, undocumented for other browsers, and may change its parameters or refuse a `prodversion` it considers old. The failure appears as a message, and the `.crx` file path still works.
2. The store may serve some extensions only to browsers it recognizes. Such an extension fails at step 2 with the store's status.
3. The publisher key can change. A new key causes every store install to fail with "The package is not signed by the Web Store." until Arch carries the new digest.
4. Installed packages keep only the proof from their installation. Arch cannot detect whether the developer later loses a key to someone else.
