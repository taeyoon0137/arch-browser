# Web Store installs design

## Purpose and scope

- This note describes the design for installing web extensions from the Web Store, Google's extension store for browsers built on Chromium, as `webExtension` plugins (`docs/plugins.md`, Web extensions as plugins). It covers queue tasks IV.27, IV.17, IV.19, and IV.20 in `docs/plan.md`, the package proof that IV.26 built, the client and staging that IV.17 built, the entry points that IV.18 built, and row 44 of `docs/features.md`. The password managers that use it, 1Password and iCloud Passwords, are covered in `docs/password-managers.md` (IV.21, IV.22, and IV.13).
- The user installs an extension from its store page in a tab, from a store address or an extension identifier pasted into Settings or the palette, and from the install sheet. Arch downloads the package from Google's public update endpoint for that identifier, checks the CRX3 package's signatures and its identifier, stages it for review in the existing sheet, and installs it for the engines its package supports, as with a `.crx` file the user selects.
- This reverses the open decision in `docs/plugins.md` that allowed no direct installs from an online store. Arch still runs no server or vendor backend of its own: it calls Google's public endpoints, and only when the user acts.
- Arch's interface, code, and documents call the store the Web Store. Its page addresses name another browser product in their host names, which `AGENTS.md` allows only in the README's opening and in browser import. The user's step IV.27 adds an exception for them to `AGENTS.md`. Until then, this note and the queue describe those hosts without writing them, and `WebStore.pageHosts` stays empty, so no address counts as a store page, while a pasted identifier and the rest of the install flow work; the rest of IV.17 then writes the hosts there and here. Afterwards they appear only in `WebStore.swift`, as constants that the tests also use, and in this note. The update endpoint's address names no browser product.
- This design uses no private API and needs no flag on `flags://`.

## Facts this design relies on

- An extension's identifier is 32 letters from `a` to `p`: the first 128 bits of the SHA-256 digest of its public key, each hexadecimal digit written as a letter (`docs/plugins.md`, Identifier).
- An extension's store page is `https://<store host>/detail/<slug>/<identifier>`, on the store's own host. The slug is optional, and a query or fragment may follow. Older addresses, `https://<older host>/webstore/detail/<slug>/<identifier>`, redirect there. The store's other pages, such as categories and search, contain no identifier. Both hosts name another browser product, so IV.17 writes them into `WebStore.swift` and here only after IV.27.
- Chromium's extension updater requests `https://clients2.google.com/service/update2/crx` with one `x` parameter per extension: a URL-encoded `id=<identifier>&v=<version>&installsource=ondemand&uc`, `v=0.0.0.0` for an extension it does not have, and `prodversion`, the browser's Chromium version, `acceptformat=crx3`, and the Mac's `os` and `arch` values. With `response=updatecheck`, the response is update protocol 2.0 XML: a `gupdate` element with an `app` element per identifier, each with `appid` and `status`, and an `updatecheck` element inside it with `status` (`ok` with `codebase`, `version`, `hash_sha256`, and `size`, `noupdate`, or an error such as `error-unknownApplication`). `codebase` is an HTTPS address of the package. An `app` whose `status` is an error has no `updatecheck`.
- On 2026-11-13, `curl` from this Mac asked the endpoint about 1Password (`aeblfdkhhhdcdjpifhhbdiojplfjncoa`) with `prodversion=156.0.8078.48` and no personal data. With the parameters above, `app` had `status="ok"` and `updatecheck` had `status="ok"`, `version="8.12.44.33"`, an HTTPS `codebase`, `hash_sha256`, and `size="18374695"`, beside what Arch ignores: the attributes `fp`, `protected`, and `cohort`, and a `daystart` element. Without `prodversion` or without `acceptformat=crx3`, `updatecheck` said `noupdate`, as it did with `prodversion=60.0.0.0` and with the current version as `v`; without `uc` in `x`, `app` had no `updatecheck`. Leaving out `os`, `arch`, `installsource=ondemand`, or `response=updatecheck` changed nothing, nor did an empty `Accept-Language` or a user agent in URLSession's form. An unknown identifier got `<app appid="…" status="error-unknownApplication"/>`, and two `x` parameters got both `app` elements in one answer, in the order asked. The package at `codebase` came without a redirect and had the answer's size and SHA-256 digest.
- URLSession sends the user's preferred languages as `Accept-Language` unless the request sets the header, and a request that sets it to an empty value sends it empty, as a local listener showed on 2026-11-13. It also sends a user agent of the app's name and version and the versions of CFNetwork and Darwin.
- A CRX3 file is `Cr24`, the format version 3, and the header's length, each a 32-bit little-endian number, then the header, a `CrxFileHeader` protocol buffer message, then a `.zip` archive. The header contains: `sha256_with_rsa` (2) and `sha256_with_ecdsa` (3), repeated `AsymmetricKeyProof`s, each a public key as DER `SubjectPublicKeyInfo` (1) and a signature (2); and `signed_header_data` (10000), a `SignedData` message whose `crx_id` (1) is the first 16 bytes of the developer key's SHA-256 digest. Each signature covers `CRX3 SignedData`, a zero byte, the length of `signed_header_data` as a 32-bit little-endian number, `signed_header_data`, and the archive: RSA PKCS #1 v1.5 or ECDSA P-256 over SHA-256.
- A store-published package also carries a proof by the store's publisher key, whose SHA-256 digest Chromium's verifier holds (`kPublisherKeyHash` in `components/crx_file/crx_verifier.cc`). In Chromium 156.0.8078.48, the Chromium of the pinned CEF branch, the digest is `61f7f2a6bfcf74cd0bc1fe2497cc9b04254c658f79f2145392867ea8366367cf`, of a P-256 key, which `CRXArchive.webStorePublisherKeyDigest` copies. Chromium's verifier requires every proof in the header to hold and one to be by the developer's key, and with the publisher format also one by the publisher key; it reads RSA proofs as PKCS #1 v1.5 with SHA-256.
- `components/test/data/crx_file/valid_publisher.crx3` in that source is a store package that Chromium's own tests accept with the publisher proof: two RSA proofs, one the developer's, and an ECDSA proof by the publisher key. On 2026-11-13, `CRXArchive` read it as `webStore` with the identifier `ojjgnpkioondelmggbekfhllhdaimnho`, `valid_no_publisher.crx3` and `valid_test_publisher.crx3`, whose third proof is by Chromium's test publisher key, as `developer`, and refused `unsigned.crx3`, as Chromium's tests expect. On 2026-11-13, `CRXArchive` read the package that the endpoint offered for 1Password (above) as `webStore` with its identifier, which confirms the digest against the endpoint, and a temporary test, not kept, staged it through `WebStoreClient` and `WebStoreInstaller` with the proof and origin `webStore`, leaving no download in `Staging/`, and got the unknown identifier's message for `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`.
- Since IV.26, `CRXArchive` checks the signatures and writes the developer's key into the manifest (Package proof; `docs/plugins.md`, Identifier). The Chromium adapter refuses the store's install prompts without asking (`ChromiumExtensions.cefExtensionsShowPrompt`). Whether the store's page offers its own install button on Arch's engine needs verification.

## Decisions

1. Sources: a store page in a tab, a pasted store address or identifier, and the install sheet. On Chromium tabs, the store's own install button, if the store offers it, starts the same install (see Chromium's store button).
2. One path: every source calls `WebStoreInstaller.stage(_:in:)`, which downloads the current package for the identifier and stages it with the origin `webStore`, and every package goes through the review sheet. Nothing installs or updates without the review.
3. Proof: a store package must carry a valid developer proof for its identifier and a valid proof by the store's publisher key, and its identifier must match the request. A `.crx` file the user chooses must carry a valid developer proof. Either must hold the web extension of the file's identifier, the only identifier its signatures prove. `plugins.json` records the proof in entries that earlier builds keep as they are (Package proof). This settles how Arch tells a real extension from a package that copies its `key` (`docs/plugins.md`, Open decisions), which the password managers' native apps need (`docs/password-managers.md`).
4. Updates: Arch checks the store for updates to extensions installed from it only when the user clicks Check for Updates in Settings ▸ Plugins and when Settings ▸ Plugins first shows a Persona in an app run. No timer, launch, or background check runs, and an update installs only through its review. Arch therefore adds no update service of its own (row 37).
5. Privacy: a request carries the identifiers and installed versions of the requested extensions, the Chromium version of Arch's engine, and the Mac's `os` and `arch`. It carries no cookies, language, install dates, or ping parameters: it sends an empty `Accept-Language` and keeps the system's user agent. It uses an ephemeral `URLSession` without cookie storage, cache, or stored credentials, as the AI providers' requests and site icons do.
6. Reviews from a tab open in Settings ▸ Plugins in the tab's Persona, like Install <Engine> Version… from the site settings popover, so every review appears in one place.
7. Personas: a plugin belongs to a whole Persona. With two or more Personas, the review sheet names it by the Persona / Space rule (`docs/windows-personas.md`, Persona rule 7), as the Clear Site Data sheet does: a review that starts from a tab or a window says "Installs in the Persona of “Work / Research” for all its spaces." with the tab's space or the window's current space, and a review started in Settings ▸ Plugins, which shows a Persona without a space, says "Installs in “Work” for all its spaces." Settings ▸ Plugins' picker lists Personas alone. The store row in the site settings popover and the palette names no Persona.

## Install flow

1. Resolve: `WebStore.extensionID(in:)` reads a store page's address, and `WebStore.extensionID(from:)` reads pasted text: a store address, or a bare identifier, ignoring case and trimming spaces at either end.
2. Ask: `WebStoreClient.releases(of:)` queries the endpoint for the identifier with `v=0.0.0.0` and returns its `WebStoreRelease`: the version, the package's address, its SHA-256 digest when the response provides one, and its size. An identifier unknown to the store is refused with "The Web Store has no extension with the identifier “…”."; another status, `noupdate` among them, with "The Web Store did not offer “…”: <status>."; an answer that is not the update protocol's XML, or an offer without its address or version, with "The Web Store's answer does not read."; and a status other than HTTP 200 with "The Web Store answered with HTTP status 503.". A client without a Chromium version asks nothing: "Arch cannot ask the Web Store without the version of its Chromium engine."
3. Compare: when the Persona has that extension version installed from the store, the sheet says "“1Password” 8.11.2 is installed, the Web Store's current version." with Done, and downloads nothing.
4. Download: into `Staging/<UUID>.crx` in the Persona's folder (`PluginManager.stagingDirectory`, which the manager clears at launch), from an HTTPS address only, following redirects only to HTTPS addresses ("The Web Store offered the package at an address without HTTPS."), and stopping once it exceeds 256 MB, or before it starts when the response's size does ("The package from the Web Store is larger than 256 MB."). A file whose size or digest differs from the response's is deleted and refused with "The download from the Web Store is damaged. Try again."
5. Stage: `PluginManager.stage(_:origin:)` stages the file as a `.crx` file with the origin `webStore(<identifier>)`. It refuses a package without the store's publisher proof ("The package is not signed by the Web Store."), one whose identifier differs from the request or that holds no web extension, such as a script plugin with `plugin.json` ("The Web Store sent the package of another extension."), and a theme, whose manifest has `theme` ("“…” is a theme, which Arch does not use."). The engines check it like any web extension package (`docs/plugins.md`, Engine versions ▸ Coverage), and the installer deletes the downloaded file once the package is staged or refused; `stage(_:origin:)` leaves it in place.
6. Review: the subtitle says "Version 8.11.2 from the Web Store.". The review matches the package against installed plugins like any other package: an installed identifier makes it an update, with the warning about another source when the installed plugin came from a file, and it can join a plugin as an engine version. Install and Install and Enable work as for files, with Touch ID for every website or `nativeMessaging`.

Network failures show the system's message, such as "The Internet connection appears to be offline.". The sheet shows progress during the request and download, and Cancel cancels the task of `stage(_:in:)`, which then throws `CancellationError`, at whatever step it comes, for the sheet to close without a message: it stops the request or the download, deletes the partial file, and discards a package that staging finished meanwhile. `stage(_:in:)` asks and downloads nothing for a Persona that the user deleted (`PluginManager.isClosed`) and throws `PluginError.closed`; a download under way when the Persona goes would run to its end, so the store sheet in Settings ▸ Plugins cancels its task when its Persona is deleted, as when the sheet closes.

## Entry points

Built in IV.18; the store page entry points find no store page until IV.27 (Purpose and scope).

- Settings ▸ Plugins: Install from Web Store… beside Install Plugin… opens the store sheet, `WebStoreInstallSheet`, the first step of `PluginInstallSheet`, with one field, "Web Store address or extension ID", whose Continue button becomes available once `WebStore.extensionID(from:)` reads an identifier in the text. While `stage(_:in:)` runs, the field is disabled and a spinner says "Getting the extension from the Web Store…"; a failure shows its message in red under the field, which the user can change and continue again; the installed message shows with Done; and a staged package's review takes the sheet's place.
- The install sheet: Install <Engine> Version… is a menu with From a File…, the open panel, and From the Web Store…, the store sheet. It is in a plugin's Settings section, in the install sheet's last step, where the store sheet takes the sheet's place, and in the Settings note. The store's package then becomes that engine's version, as with a file. The popover's Install <Engine> Version… still opens Settings with the open panel, and the plugin's section there offers both.
- A tab on a store page: the extensions section of the site settings popover starts with a Web Store row: "Install This Extension…" or, when the tab's Persona has a plugin of the identifier from any source, "“1Password” is installed." with the pair's name for a version of one (`WebStoreInstaller.installedPlugin(of:among:)`). The section shows for the row alone, with the note "Opens the extension's review in Settings before it installs." The palette lists Install Extension from This Page while the window's selected tab is on a store page that no internal page or preview panel covers, once the typed words begin the row's name or the text names the page's extension, as the page's address that ⌘L starts with does. Both call `BrowserSession.installFromWebStore` with the tab's Persona and space, or the window's current space for a favorite's tab, which the app shell sets like `installEngineVersion`: it opens Settings ▸ Plugins at the Persona with the store sheet started for the identifier, and the review names the Persona with the space (Decision 7).
- The palette: typed text that `WebStore.extensionID(from:)` recognizes adds an Install from the Web Store row right below the default row, which does the same in the window's Persona and current space; text that names the extension of the selected tab's store page shows Install Extension from This Page instead.
- Settings ▸ Plugins answers a start from a tab or the palette (`PluginsRequest`) in the Persona's list once no sheet of the list shows. The list shows the requested Persona first, as for Install <Engine> Version… from the popover.
- With two or more Personas, every review that Settings ▸ Plugins opens names the Persona (`PluginInstallSheet.personaSentence(persona:space:among:)`): from a tab or the palette, with the tab's or the window's space, and otherwise alone; the review of a plugin that AI wrote names none.

### Chromium's store button

`EngineExtensionPrompt.Kind` gains `install`, which the Chromium adapter reports with the extension's identifier and the prompt's tab instead of silently refusing it. The runtime answers false, so Chromium never installs an extension outside Arch's plugin list, and, when the tab shows a store page, asks the host to start Arch's store install for the identifier in the tab's Persona, with the tab for its space (`WebExtensionHost.installFromWebStore(_:persona:tab:)`). A prompt without a store page in its tab is still refused. WebKit has no store install prompt.

## Package proof

- `PluginProof` is `developer`, for a valid developer proof, or `webStore`, for a valid developer proof and a valid proof by the store's publisher key. A package without either has no proof: folders, `.zip` archives, and plugins that AI writes.
- `CRXArchive` checks each proof against one SHA-256 digest of the signed message: an RSA key through Security (`SecKeyCreateWithData` with the key's PKCS #1 bytes from the `SubjectPublicKeyInfo`, and `SecKeyVerifySignature` with `rsaSignatureDigestPKCS1v15SHA256`), and a P-256 key through CryptoKit (`P256.Signing.PublicKey(derRepresentation:)` and a DER signature over the digest). The developer proof is a valid proof by a key whose digest begins with `crx_id`. As in Chromium's verifier, every proof in the header must hold, and a key of the wrong type for its list fails. A `.crx` file whose proofs do not all hold is refused with "The signature of “Packed.crx” does not match its contents.", one where no proof's key has the identifier, or without `crx_id`, with "Packed.crx has no key for its extension's identifier.", and one whose header is not a protocol buffer message with "The header of Packed.crx does not read.", whatever its origin. Of a field that repeats where the message has one, the last counts, as protocol buffers read it. As Chromium's verifier does before it reads the header, `CRXArchive` also refuses, with "The header of Packed.crx does not read.", a header whose bytes hold the signature of a `.zip` archive's end of central directory record (`PK` 05 06), ZIP64 end of central directory locator (`PK` 06 07), or ZIP64 end of central directory record (`PK` 06 06), as an unzipper could take the header for the archive's end; Chromium 156 refuses the last behind a feature that is on by default, and Arch refuses it always.
- A `.crx` file's signatures prove the identifier of the web extension whose key staging writes into its `manifest.json`, and no other. Its package must therefore be that web extension: a file whose package is another kind, such as a script plugin with `plugin.json` at its top, beside a `manifest.json` or not, is refused with "Tool.crx holds no web extension.", and one whose extension has another identifier with "Tool.crx has no key for its extension's identifier."; with the origin `webStore`, either is refused with "The Web Store sent the package of another extension.". A script plugin comes in a folder or a `.zip` archive, without proof.
- `plugins.json` keeps the proof in the install entry as `"proof": "developer"` or `"proof": "webStore"`. A proven `.crx` install names its file with `"signedSource": "<file URL>"`, and a store install its origin with `"webStore": "<identifier>"`, each in place of `source`. Builds before IV.26 read an entry only with `source` or `generated` and drop keys they do not know when they write one, so they keep these entries as they are, as entries they cannot read, and do not list those plugins, instead of rewriting them without the proof. An entry with `source` has no proof, even with a `proof` key: a `.crx` file installed before IV.26 counts as unproven until it is reinstalled, and the native app gate says so (`docs/password-managers.md`, Proof gate). A proof value unknown to this build counts as none and stays in the file.
- An update records its own proof. When an update has no proof but the installed plugin does, the review adds: "The installed version is signed by its developer; this package is not."

## Updates

- Check for Updates in Settings ▸ Plugins, shown while the Persona has extensions installed from the store, checks up to 25 per request, with their installed versions, and shows when it last checked in the run or why it failed. Settings ▸ Plugins also checks once per Persona per run, when it first shows the Persona.
- Only installs with the origin `webStore` are checked. Each version of a pair is checked under its engine identifier, which its package names.
- A newer version, by Chromium's version order (one to four dot-separated numbers, compared as numbers), appears in the plugin's section: "Version 8.12.0 is available from the Web Store." with Review Update…, which downloads it as in the install flow, stages it as an update of that plugin (`PluginPackage.updates`), and opens the review, with newly requested permissions and sites marked New. A version that is not newer shows nothing.
- The results last for the run and belong to the Persona's entry in `WebStoreInstaller.updates`, which is deleted with the Persona.

## Types

```swift
// Extensions, WebStore.swift, built in IV.17: the store's addresses, which no other file names. `pageHosts` stays empty until IV.27.
public enum WebStore {
    /// The identifier of the extension whose store page `url` is, or nil for any other address.
    public static func extensionID(in url: URL) -> String?
    /// The identifier that typed or pasted text names: a store page's address, with or without `https://`, or a bare identifier, without case and spaces at either end.
    public static func extensionID(from text: String) -> String?
    /// The update endpoint.
    static let updateEndpoint: URL
    /// The hosts of store pages, the current one first, from which the tests build their addresses.
    static let pageHosts: [String]
    /// The path before the slug and identifier on each page host, in the same order: `detail`, and `webstore/detail` on the older host.
    static let pagePaths: [[String]]
    /// The readers with page hosts that the tests choose.
    static func extensionID(in url: URL, pageHosts: [String]) -> String?
    static func extensionID(from text: String, pageHosts: [String]) -> String?
    /// The text in lowercase when it is 32 letters from `a` to `p` in any case.
    static func identifier(_ text: some StringProtocol) -> String?
}

// Extensions, WebStoreClient.swift, built in IV.17
public struct WebStoreRelease: Equatable, Sendable {
    public let id: String
    public let version: String
    let package: URL
    let sha256: Data?
    let size: Int?
}

/// The store's answer for one identifier.
enum WebStoreAnswer: Equatable, Sendable {
    case release(WebStoreRelease)
    /// Nothing newer than the version asked about, also for an `app` without `updatecheck`.
    case noUpdate
    /// `error-unknownApplication`.
    case unknown
    /// Another status, which messages quote.
    case refused(String)
}

/// The messages of the install flow, as `LocalizedError`.
public enum WebStoreError: Error, Equatable, Sendable {
    case unknownExtension(String), notOffered(String, status: String), alreadyInstalled(name: String, version: String)
    case unreadableAnswer, httpStatus(Int), insecurePackage, packageTooLarge, damagedDownload, noEngineVersion
}

public final class WebStoreClient: Sendable {
    /// `productVersion` is the Chromium version in the CEF version of Arch's engine, such as 156.0.8078.48; requests go through an ephemeral session without cookies, cache, or stored credentials.
    public convenience init(productVersion: String)
    /// Tests pass a session from `makeSession(configuration:)` whose `URLProtocol` answers instead of the network, and a smaller limit.
    init(productVersion: String, session: URLSession, packageSizeLimit: Int = maximumPackageSize)
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession
    /// The version after `+chromium-` in a CEF version, four dot-separated numbers.
    public static func chromiumVersion(inCEFVersion cefVersion: String) -> String?
    /// The requests for the queries, 25 identifiers to each, with an empty `Accept-Language`.
    func requests(for queries: [(id: String, version: String?)]) -> [URLRequest]
    /// Asks about each identifier, at most 25 to a request, with its installed version, or 0.0.0.0 for nil; throws `noEngineVersion` without a Chromium version.
    func releases(of queries: [(id: String, version: String?)]) async throws -> [String: WebStoreAnswer]
    /// Reads the update protocol's XML with `XMLParser`.
    static func answers(in data: Data) throws -> [String: WebStoreAnswer]
    /// Writes the package to `file`, which must not exist, over HTTPS only, checking its size and digest; a failure or cancellation deletes the file.
    func download(_ release: WebStoreRelease, to file: URL) async throws
}

// Extensions, WebStoreInstaller.swift: one per app, which the session owns. `stage(_:in:)` built in IV.17 and `installedPlugin(of:among:)` in IV.18; IV.20 adds the rest and `ObservableObject`.
@MainActor
public final class WebStoreInstaller: ObservableObject {
    nonisolated public init(client: WebStoreClient)
    /// The plugin that holds the extension `id`, from the store or not, a version of a pair among them; nil also for text that is not an identifier.
    nonisolated public static func installedPlugin(of id: String, among plugins: [InstalledPlugin]) -> InstalledPlugin?
    /// Downloads the current package of the identifier into `PluginManager.stagingDirectory`, unless the Persona has that version installed from the store, and stages it in the Persona of `plugins` with the origin `webStore`. Throws `PluginError.closed` for a closed manager without asking, and `CancellationError` when its task is cancelled, leaving nothing staged.
    public func stage(_ id: String, in plugins: PluginManager) async throws -> PluginPackage
    /// The newer versions found for each Persona's store installs in this run.
    @Published public private(set) var updates: [PersonaID: [PluginID: WebStoreRelease]]
    /// Asks about the Persona's store installs; `onlyOncePerRun` skips a Persona already checked in the run.
    public func checkForUpdates(in plugins: PluginManager, onlyOncePerRun: Bool) async throws
    public func stageUpdate(of plugin: PluginID, in plugins: PluginManager) async throws -> PluginPackage
    public func forget(_ persona: PersonaID)
}

// Plugins, PluginManager, built in IV.17: `Staging/` in the Persona's folder, where the store's downloads wait, and whether the session closed the manager as it deleted the Persona.
public var stagingDirectory: URL
public private(set) var isClosed: Bool

// Plugins, built in IV.26
public enum PluginProof: String, Hashable, Sendable { case developer, webStore }
// PluginOrigin
case webStore(String)
// PluginPackage, and InstalledPlugin as a `var`
public let proof: PluginProof?
// PluginPackage: "The installed version is signed by its developer; this package is not." for an unsigned package that updates a plugin with a proof.
public func proofWarning(updating installed: InstalledPlugin) -> String?
// PluginManager: stages a downloaded `.crx` file with the origin `file` or `webStore`, refusing a store package without the store's proof, with another identifier, or for a theme; the file stays for the caller to delete.
public func stage(_ file: URL, origin: PluginOrigin) async throws -> PluginPackage
// CRXArchive, internal: the publisher key's digest, which `PluginManager`'s internal initializer takes as `publisherKeyDigest` for tests.
static let webStorePublisherKeyDigest: Data

// ARCHEngine, EngineExtensionPrompt.Kind
case install

// Extensions, WebExtensionHost: `tab` gives the review its space.
func installFromWebStore(_ id: String, persona: PersonaID, tab: (any EngineWebContents)?)

// Browsing, BrowserSession, built in IV.17: the app shell passes `ChromiumEngine.extensionRuntimeVersion`, the CEF version, read without starting CEF.
public let webStore: WebStoreInstaller
public init(registry: EngineRegistry = .shared, userDataDirectory: URL, builtInPlugins: [any BuiltInPlugin.Type], cefVersion: String?) throws
/// Built in IV.18. Set by the app shell: opens Settings ▸ Plugins at the Persona with the store sheet started for the identifier, and a review that names the Persona with the space, if any. `installEngineVersion` passes the tab's space too.
public var installFromWebStore: ((Persona.ID, Space.ID?, String) -> Void)?
public var installEngineVersion: ((Persona.ID, Space.ID?, PluginID, EngineKind) -> Void)?
/// Public for Settings ▸ Plugins' reviews.
public static func displayedPlace(ofPersona id: Persona.ID, space: Space?, among personas: [Persona]) -> String?

// Browsing, built in IV.18: what the entry points in tabs and the palette offer, from `WebStore`'s readers or, in tests, readers with hosts that stand in for the store's.
struct WebStoreReader { var page: (URL) -> String?; var text: (String) -> String?; static let store: WebStoreReader }
/// The popover's row on a store page, nil on another page.
enum WebStorePageRow: Equatable {
    case install(String), installed(String)
    init?(pageURL: URL?, installedName: (String) -> String?, reader: WebStoreReader = .store)
    var title: String
}
/// The palette's rows: `pageExtension` for Install Extension from This Page, `typedExtension` for Install from the Web Store.
struct PaletteWebStoreRows: Equatable {
    init(text: String, pageURL: URL?, reader: WebStoreReader = .store)
}

// Preferences, built in IV.18: the store sheet, the first step of `PluginInstallSheet`, which starts with `.review(_:)` or `.webStore(_:)` and names the Persona in its review.
struct WebStoreStart { var text: String; var versionOf: PluginID?; var engine: EngineKind?; var startsAtOnce: Bool }
struct WebStoreInstallSheet: View
static func personaSentence(persona: Persona.ID, space: Space?, among personas: [Persona]) -> String?  // PluginInstallSheet
// PreferencesWindowController
public func showWebStoreInstall(of id: String, in persona: Persona.ID, space: Space.ID?)
public func showPlugin(_ plugin: PluginID, in persona: Persona.ID, space: Space.ID?, installingVersionFor engine: EngineKind)
```

`Preferences` depends on `Extensions` in `Package.swift` for the store sheet, and `BrowsingTests` on `Extensions` for the readers with stand-in hosts.

## Tests

- Proof (`ExtensionsTests`, `CRXProofTests.swift`, built in IV.26): `.crx` files the test signs with a generated RSA key and a P-256 key stage with the proof `developer`; an added proof by a test publisher key, which the verifier and the manager take as a parameter, gives `webStore`. A file whose archive or signed header changed after signing, whose signature uses another key, with a second proof that does not hold or a P-256 key among the RSA proofs, whose `crx_id` matches no proof key, or whose header does not read or holds the signature of a `.zip` archive's end record is refused. Folders and `.zip` archives have no proof. A `.crx` file of a script plugin, with `plugin.json` alone or beside a `manifest.json`, stages nothing, and the same plugin stages from a folder without proof. `stage(_:origin:)` with `webStore` refuses a package without the store's proof, with another identifier, holding a script plugin, with `theme`, or as a folder, and stages the store's package with the origin `webStore`. `plugins.json` writes a proven `.crx` install with `signedSource` and `proof` and a store install with `webStore` and `proof`, never with `source`, and reads them back; an entry with `source` and a `proof` key has no proof and keeps the key; an unknown proof value survives a write. An unsigned update of a signed plugin gets the review's sentence and records no proof. The tests sit beside the web extension runtime, whose manifests `.crx` packages hold, and the test `CRXFile` in `EngineRequestsTests.swift` signs their files and those of the engine request tests.
- Store (`ExtensionsTests`, `WebStoreTests.swift`, built in IV.17), with `StoreStub`, a `URLProtocol` that answers every request of the tests' sessions, so no test reaches the network; the tests that use it run one at a time. `extensionID(in:)` reads both page forms with and without a slug, query, fragment, or trailing slash, in any case, and no identifier from the store's other pages, the other host's form, other hosts and schemes, extra path components, or identifiers that are not one, with store addresses built from hosts that stand in for the store's and from `WebStore.pageHosts` once it lists them, so that `WebStoreTests.swift` names no host; `extensionID(from:)` reads addresses with and without `https://` and bare identifiers in any case with spaces at either end, and refuses 31 or 33 letters, letters past `p` or with a mark, digits, and inner spaces. `chromiumVersion(inCEFVersion:)` reads the pinned CEF version's form and refuses others. The requests have the parameters above, one `x` per identifier with `v=0.0.0.0` or the installed version, 25 to a request, with an empty `Accept-Language`, and the session has no cookie storage, sets no cookies, accepts none, and has no cache or credential storage. The test checks the configuration because URLSession neither stores nor sends cookies through a `URLProtocol`, even with cookie storage; checking the cookies themselves would need a listener on the loopback address. The response's statuses map to answers, with several `app` elements in one response and answers only for the identifiers asked about; offers without an address or version, digests that are not one, and other documents do not read; a status other than 200 and a client without a Chromium version throw. A download matches, also after a redirect to another HTTPS address, and is refused without HTTPS, past the size limit, as the answer states it or as the body arrives, with a different digest or size, with another status, or after a redirect to HTTP, leaving no file. The installer stages the store's package with the origin and proof `webStore`, leaves no download in `Staging/`, and installs it with `webStore` in `plugins.json`; with that version installed it downloads nothing and gives the installed message, and a newer version stages as an update. It refuses an unknown identifier, `noupdate`, another status, an answer without the identifier, and text that is not an identifier with their messages, and a package without the publisher proof, for another identifier, of a theme, or with a different digest; cancelling its task while the endpoint answers, during the download, or while the engines check the package throws `CancellationError` and leaves nothing in `Staging/`, with each wait bounded so that a cancellation that never arrives fails the test. For a manager that closes while the endpoint answers, or that is closed, it throws `PluginError.closed` without downloading or asking.
- Entry points (built in IV.18): `BrowsingTests`, `WebStoreEntryTests.swift`, with store pages built from a host that stands in for the store's: the palette offers Install from the Web Store for a store address with or without `https://` and a bare identifier in any case, and nothing for other text, another host's address, or a letter past `p`; with a store page in the selected tab, its address, its identifier, and words that begin the row's name give Install Extension from This Page alone, another identifier gives Install from the Web Store, and other text, another page, or no page gives neither; the popover's row installs a store page's extension or names the installed plugin, and is nil off a store page. `ExtensionsTests`, `WebStoreTests.swift`: `installedPlugin(of:among:)` finds a plugin of the identifier installed from a `.crx` file, in any case, and nothing for another identifier or text that is not one. `PreferencesTests`, `PluginReviewPersonaTests.swift`: the review's Persona sentence with a space, for a start from a tab or the palette, without one, for Settings ▸ Plugins, and none with one Persona or for a Persona no longer listed.
- Chromium's store button (`ExtensionsTests`, IV.19): a recording engine's install prompt on a store page is answered false and reaches the host with the identifier, the Persona, and the tab; one on another page is answered false and does not reach the host.
- Updates (`ExtensionsTests`, IV.20): one request for the Persona's store installs with their versions and none for file installs; the automatic check runs once per Persona per run, and Check for Updates runs every time; only newer versions show; Review Update stages an update of that plugin; deleting a Persona drops its results.

## Checks with the app

Check 1 also covers the client with the Chromium version that the app shell passes; regression check 62 in `docs/plan.md` holds checks 1 and 2 with the entry points' details, and IV.13 runs them. Run from the bundle launched through `open`, using a test Persona or a fresh Application Support folder:

1. Settings ▸ Plugins ▸ Install from Web Store… with a public extension's store address, and with its bare identifier, shows its review with "from the Web Store", installs it, and it runs on the engines its review names. Cancel during the spinner leaves `Staging/` empty, and the identifier again says it is installed with Done. A plugin's Install <Engine> Version… ▸ From the Web Store… reviews the store's package as that engine's version.
2. On a store page in a WebKit tab and in a Chromium tab, the site settings popover's Web Store row and the palette's Install Extension from This Page open the same review in the tab's Persona, and a pasted identifier's Install from the Web Store opens it in the window's Persona. With two Personas, the review names "the Persona of “Work / Research”", and deleting the Persona while its store sheet downloads closes the sheet and leaves its `Staging/` empty. On Chromium, note whether the store offers its own install button and whether it opens the review. The store pages need IV.27.
3. Check for Updates finds nothing for a current extension. After the `version` in the installed copy's `manifest.json` is lowered while Arch is not running, it offers Review Update….
4. A pasted theme identifier is refused with its message.

## Risks

1. The endpoint is Google's, undocumented for other browsers, and may change its parameters or refuse a `prodversion` it considers old. The failure appears as a message, and the `.crx` file path still works.
2. The store may serve some extensions only to browsers it recognizes. Such an extension fails at step 2 with the store's status.
3. The publisher key can change. A new key causes every store install to fail with "The package is not signed by the Web Store." until Arch carries the new digest.
4. Installed packages keep only the proof from their installation. Arch cannot detect whether the developer later loses a key to someone else.
