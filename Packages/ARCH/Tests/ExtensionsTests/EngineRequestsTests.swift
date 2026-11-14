// What the web extension runtime does for the requests that Chromium's extension runtime makes, against recording engines: the tabs and windows it opens through the host, the engines' own prompts, the store's install button, which starts Arch's store install only from a store page, allowing an extension on a site, the key it writes into a package without one so that Chromium names the extension as Arch does, `.crx` packages and the links they may hold, when an engine may stop what it kept from an earlier launch, and the popup sizes the presenter keeps.
import AppKit
import ARCHEngine
import CryptoKit
@testable import Extensions
import Foundation
@testable import Plugins
import Security
import Testing

@MainActor
@Suite(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
struct EngineRequestsTests {
    private let folder = TemporaryFolder()
    private let host = RecordingHost()
    private let persona = UUID()
    private let webKit = RecordingEngine()
    private let chromium = RecordingEngine()
    private let runtime: WebExtensionRuntime
    private let manager: PluginManager

    init() {
        host.engines = [.webKit: webKit, .chromium: chromium]
        runtime = WebExtensionRuntime(persona: persona, host: host, nativeMessagingHosts: folder.url)
        manager = PluginManager(persona: persona, directory: folder.url, builtIns: [], runtimes: [runtime], secretStore: NoSecrets())
    }

    /// Installs a package with everything it asks for and waits until Chromium's stand-in has loaded it.
    private func installLoaded(_ name: String, _ manifest: String) async throws -> InstalledPlugin {
        let installed = try await manager.installEverything(from: folder.package(name, ["manifest.json": manifest]))
        #expect(await eventually { chromium.loaded[WebExtensionManifest.extensionID(of: installed.id)] != nil })
        return installed
    }

    // MARK: Identifiers

    @Test func writesTheKeyThatGivesChromiumArchsIdentifier() async throws {
        let source = try folder.package("plain", ["manifest.json": #"{"manifest_version": 3, "name": "Plain", "version": "1"}"#])
        let installed = try await manager.installEverything(from: source)
        let id = WebExtensionManifest.extensionID(of: installed.id)
        #expect(await eventually { chromium.loaded[id] != nil })
        // The key's bytes are the source's path, so its digest, Chromium's identifier, is the one Arch derived from that path.
        let packageURL = try #require(installed.packageURL)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))) as? [String: Any])
        let key = try #require(manifest["key"] as? String)
        #expect(Data(base64Encoded: key) == Data(source.standardizedFileURL.path.utf8))
        #expect(try WebExtensionManifest.extensionID(key: key, source: folder.url) == id)
        #expect(try WebExtensionManifest(packageAt: packageURL, source: source).manifest.id == installed.id)
        // The rest of the manifest stays as it was, and a package with a key keeps it.
        #expect(manifest["name"] as? String == "Plain" && manifest.count == 4)
        // An update brings a new copy without the key, which gets it again before it loads.
        let update = try await manager.stage(source)
        try manager.install(update, grant: PluginGrant(requestedBy: update.manifest), isEnabled: true)
        #expect(await eventually { chromium.loadCounts[id] == 2 })
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))) as? [String: Any]
        #expect(updated?["key"] as? String == key)
        let keyed = try await installLoaded("keyed", #"{"manifest_version": 3, "name": "Keyed", "version": "1", "key": "a2V5"}"#)
        let keyedManifest = try String(contentsOf: #require(keyed.packageURL).appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(keyedManifest == #"{"manifest_version": 3, "name": "Keyed", "version": "1", "key": "a2V5"}"#)
    }

    @Test func stagesACRXFileWithItsKey() async throws {
        let package = try folder.package("crx", ["manifest.json": #"{"manifest_version": 3, "name": "Packed", "version": "2"}"#, "background.js": ""])
        let archive = folder.url.appendingPathComponent("packed.zip")
        try compress(package, to: archive)
        let publicKey = CRXFile.developer.publicKey
        let crx = folder.url.appendingPathComponent("Packed.crx")
        try CRXFile.data(archive: Data(contentsOf: archive)).write(to: crx)
        let staged = try await manager.stage(crx)
        // The extension has the identifier of the file's key, which its manifest now carries, and the developer's signature proves it.
        #expect(staged.manifest.id.rawValue == "extension." + WebExtensionManifest.extensionID(ofBytes: publicKey))
        #expect(staged.proof == .developer)
        #expect(staged.files == ["background.js", "manifest.json"])
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: staged.rootURL.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["key"] as? String == publicKey.base64EncodedString())
        manager.discard(staged)
        #expect(runtime.packageTypes(for: .chromium).contains(PluginPackage.crxType) && !runtime.packageTypes(for: .webKit).contains(PluginPackage.crxType))
        // The header's key replaces another key in the manifest, as Chromium writes it.
        let keyedPackage = try folder.package("keyed crx", ["manifest.json": #"{"manifest_version": 3, "name": "Keyed", "version": "2", "key": "b3RoZXIga2V5"}"#])
        let keyedArchive = folder.url.appendingPathComponent("keyed.zip")
        try compress(keyedPackage, to: keyedArchive)
        let keyedCRX = folder.url.appendingPathComponent("Keyed.crx")
        try CRXFile.data(archive: Data(contentsOf: keyedArchive)).write(to: keyedCRX)
        let keyed = try await manager.stage(keyedCRX)
        #expect(keyed.manifest.id == staged.manifest.id && keyed.manifest.name == "Keyed")
        let keyedManifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: keyed.rootURL.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(keyedManifest["key"] as? String == publicKey.base64EncodedString() && keyedManifest.count == 4)
        manager.discard(keyed)
        // Chromium no longer installs the format before version 3.
        var old = try Data(contentsOf: crx)
        old[4] = 2
        try old.write(to: crx)
        await #expect(throws: PluginError.invalidPackage("Packed.crx is a .crx file of format version 2, which Chromium no longer installs.")) { try await manager.stage(crx) }
    }

    /// A `.crx` file whose archive holds only a link to a package elsewhere is refused before its key is written, so the manifest the link leads to stays as it was.
    @Test func refusesACRXFileThatLinksOutOfItsPackage() async throws {
        let outside = try folder.package("outside", ["manifest.json": #"{"manifest_version": 3, "name": "Outside", "version": "1", "key": "b3V0c2lkZQ=="}"#])
        let linkOnly = folder.url.appendingPathComponent("link only", isDirectory: true)
        try FileManager.default.createDirectory(at: linkOnly, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkOnly.appendingPathComponent("ext"), withDestinationURL: outside)
        let archive = folder.url.appendingPathComponent("link.zip")
        try compress(linkOnly, to: archive)
        let crx = folder.url.appendingPathComponent("Link.crx")
        try CRXFile.data(archive: Data(contentsOf: archive)).write(to: crx)
        let manifest = outside.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifest)
        await #expect(throws: PluginError.invalidPackage("The package is a symbolic link, which could lead to files outside Arch.")) { try await manager.stage(crx) }
        #expect(try Data(contentsOf: manifest) == before)
    }

    // MARK: Launch

    @Test func stopsWhatAnEngineKeptOnlyOnceThePassHasLoadedEverything() async throws {
        let first = try await installLoaded("first", #"{"manifest_version": 3, "name": "First", "version": "1"}"#)
        let second = try await installLoaded("second", #"{"manifest_version": 3, "name": "Second", "version": "1"}"#)
        manager.close()
        // At the next launch both load in one pass, and only then may the engine stop what it runs from the last launch.
        let relaunched = RecordingEngine()
        host.engines = [.webKit: RecordingEngine(), .chromium: relaunched]
        let nextRuntime = WebExtensionRuntime(persona: persona, host: host, nativeMessagingHosts: folder.url)
        let nextManager = PluginManager(persona: persona, directory: folder.url, builtIns: [], runtimes: [nextRuntime], secretStore: NoSecrets())
        await nextRuntime.waitForEngines()
        let ids = [first, second].map { WebExtensionManifest.extensionID(of: $0.id) }
        #expect(relaunched.stopsWhileLoaded.first == Set(ids))
        // Each load says when the package was installed, so that Chromium keeps its copy only of a package installed before it started.
        #expect(relaunched.loaded[ids[0]]?.installedAt == first.installedAt && relaunched.loaded[ids[1]]?.installedAt == second.installedAt)
        nextManager.close()
    }

    // MARK: Tabs and windows

    @Test func opensTabsAndWindowsInTheCallingEngine() async throws {
        _ = try await installLoaded("opener", #"{"manifest_version": 3, "name": "Opener", "version": "1"}"#)
        let window = UUID()
        var opened: (any EngineWebContents)?? = .none
        runtime.extensions(chromium, openTabWith: URL(string: "https://example.org/"), inWindow: window, active: true, index: 2) { opened = .some($0) }
        #expect(host.openedTabs.count == 1 && opened != nil)
        let request = try #require(host.openedTabs.first)
        #expect(request.url == URL(string: "https://example.org/") && request.engine == .chromium && request.persona == persona && request.window == window && request.active && request.index == 2)
        host.openedWindow = window
        var openedWindow: UUID?
        runtime.extensions(chromium, openWindowWith: [URL(string: "https://example.com/")!], focused: false) { openedWindow = $0 }
        #expect(openedWindow == window && host.openedWindows.first?.engine == .chromium && host.openedWindows.first?.focused == false)
        // An engine that the runtime did not attach opens nothing.
        let stranger = RecordingEngine()
        runtime.extensions(stranger, openTabWith: nil, inWindow: nil, active: false, index: nil) { opened = .some($0) }
        #expect(host.openedTabs.count == 1)
    }

    // MARK: Prompts

    @Test func asksTheEnginesQuestions() async throws {
        let installed = try await installLoaded("asker", #"{"manifest_version": 3, "name": "Asker", "version": "1", "optional_host_permissions": ["https://example.com/*"]}"#)
        let id = WebExtensionManifest.extensionID(of: installed.id)
        var answer: Bool?
        runtime.extensions(chromium, extension: id, asks: EngineExtensionPrompt(kind: .permissions(["Read and change your data on example.com"]), tab: nil)) { answer = $0 }
        #expect(await eventually { answer != nil })
        #expect(answer == true)
        #expect(host.questions.last == WebExtensionQuestion(kind: .enginePermissions, extensionName: "Asker", pluginID: installed.id, items: ["Read and change your data on example.com"],
                                                            keeps: "The extension gets this access on Chromium tabs. Chromium keeps it until you remove the extension, though access to websites can end sooner, as after an update that leaves some of the extension\u{2019}s websites out.",
                                                            confirmsNext: false))
        host.answer = false
        answer = nil
        runtime.extensions(chromium, extension: id, asks: EngineExtensionPrompt(kind: .reload(["Asker"]), tab: nil)) { answer = $0 }
        #expect(answer == false)
        #expect(host.questions.last == WebExtensionQuestion(kind: .reload, extensionName: "", message: "\u{201C}Asker\u{201D} can run on this page once it loads again."))
        #expect(WebExtensionEnginePrompt.reloadQuestion(names: []).message == "The extension can run on this page once it loads again.")
        // A question from an extension that the engine did not load is refused without asking.
        let questions = host.questions.count
        answer = nil
        runtime.extensions(chromium, extension: "unknown", asks: EngineExtensionPrompt(kind: .permissions([]), tab: nil)) { answer = $0 }
        #expect(answer == false && host.questions.count == questions)
    }

    @Test func refusesRunTimeNativeMessagingAndConfirmsEveryWebsite() async throws {
        let messenger = try await installLoaded("messenger", #"{"manifest_version": 3, "name": "M", "version": "1", "optional_permissions": ["nativeMessaging"]}"#)
        var answer: Bool?
        runtime.extensions(chromium, extension: WebExtensionManifest.extensionID(of: messenger.id), asks: EngineExtensionPrompt(kind: .permissions(["Communicate with cooperating native applications"]), tab: nil)) { answer = $0 }
        #expect(answer == false && host.questions.isEmpty)
        // An entry with arguments, which Chromium reads, leaves the list's other names in sight.
        let mixed = try await installLoaded("mixed", #"{"manifest_version": 3, "name": "X", "version": "1", "optional_permissions": ["nativeMessaging", {"usb": []}]}"#)
        answer = nil
        runtime.extensions(chromium, extension: WebExtensionManifest.extensionID(of: mixed.id), asks: EngineExtensionPrompt(kind: .permissions(["Communicate with cooperating native applications"]), tab: nil)) { answer = $0 }
        #expect(answer == false && host.questions.isEmpty)
        let everywhere = try #require(WebExtensionManifest.optionalAccess(ofPackageAt: try folder.package("everywhere", [
            "manifest.json": #"{"manifest_version": 3, "name": "E", "version": "1", "optional_permissions": ["cookies"], "optional_host_permissions": ["<all_urls>"]}"#,
        ])))
        #expect(everywhere.permissions == ["cookies"] && everywhere.grant.confirmationReason(for: "E") != nil)
        // Optional lists that do not read leave nothing that a request could be checked against.
        for (name, lists) in [("unread", #""optional_permissions": [1]"#), ("unread-hosts", #""optional_host_permissions": "<all_urls>""#)] {
            let package = try folder.package(name, ["manifest.json": #"{"manifest_version": 3, "name": "U", "version": "1", "# + lists + "}"])
            #expect(WebExtensionManifest.optionalAccess(ofPackageAt: package) == nil)
        }
    }

    @Test func confirmsEveryWebsiteThatTheInstallLeftOut() async throws {
        let manifest = #"{"manifest_version": 3, "name": "W", "version": "1", "host_permissions": ["<all_urls>"]}"#
        // Chromium withholds the sites the install left out and lets `permissions.request()` ask for them again, so every website needs confirming.
        let withheld = try await manager.stage(folder.package("withheld", ["manifest.json": manifest]))
        try manager.install(withheld, grant: PluginGrant(permissions: [], sites: []), isEnabled: true)
        let leftOut = try #require(manager.plugins.first { $0.id == withheld.manifest.id })
        #expect(try #require(WebExtensionManifest.runTimeAccess(of: leftOut)).grant.confirmationReason(for: "W") != nil)
        // With every website granted at install, nothing is left to ask for.
        let granted = try await installLoaded("granted", manifest.replacingOccurrences(of: #""W""#, with: #""G""#))
        #expect(try #require(WebExtensionManifest.runTimeAccess(of: granted)).sites.isEmpty)
    }

    @Test func refusesTheStoresInstallAndStartsArchsOwnFromAStorePage() throws {
        // Store pages on a host that stands in for the store's, so that this file names no store host.
        runtime.storePageReader = { WebStore.extensionID(in: $0, pageHosts: ["store.example"]) }
        let id = WebExtensionManifest.extensionID(ofBytes: Data("store extension".utf8))
        // Before the Persona has any extension, a profile's start makes the runtime the engine's delegate, which the store's button asks.
        runtime.profileDidStart(with: chromium, of: .chromium)
        let delegate = try #require(chromium.delegate)
        #expect(delegate === runtime)
        let storeTab = PageStub(url: URL(string: "https://store.example/detail/sample-name/\(id)"))
        var answer: Bool?
        delegate.extensions(chromium, extension: id.uppercased(), asks: EngineExtensionPrompt(kind: .install, tab: storeTab)) { answer = $0 }
        #expect(answer == false && host.storeInstalls.count == 1)
        let started = try #require(host.storeInstalls.first)
        #expect(started.id == id && started.persona == persona && started.tab === storeTab)
        // Another page, no tab, and an identifier that is not one are refused and start nothing.
        let otherTab = PageStub(url: URL(string: "https://example.org/detail/sample-name/\(id)"))
        for (asking, tab) in [(id, otherTab), (id, PageStub(url: nil)), (id, nil), ("", storeTab), (String(id.dropLast()), storeTab)] as [(String, PageStub?)] {
            answer = nil
            delegate.extensions(chromium, extension: asking, asks: EngineExtensionPrompt(kind: .install, tab: tab)) { answer = $0 }
            #expect(answer == false, "\(asking) \(String(describing: tab?.url))")
        }
        #expect(host.storeInstalls.count == 1 && host.questions.isEmpty && chromium.loaded.isEmpty)
    }

    // MARK: Site access

    @Test func allowsAnExtensionOnTheTabsSite() async throws {
        try await WebKitProfile.run { profile in
            host.engines = [.webKit: webKit]
            let tab = profile.makeTab()
            let installed = try await manager.installEverything(from: folder.package("waiter", [
                "manifest.json": #"{"manifest_version": 3, "name": "Waiter", "version": "1", "action": {}}"#,
            ]))
            // An extension without an action shows only while the engine keeps it from the tab's site, as Chromium gives it an action then.
            let quiet = try await manager.installEverything(from: folder.package("quiet", [
                "manifest.json": #"{"manifest_version": 3, "name": "Quiet", "version": "1", "content_scripts": [{"matches": ["https://example.org/*"], "js": ["a.js"]}]}"#,
                "a.js": "",
            ]))
            #expect(await eventually { webKit.loaded[WebExtensionManifest.extensionID(of: quiet.id)] != nil && webKit.loaded[WebExtensionManifest.extensionID(of: installed.id)] != nil })
            #expect(runtime.actions(for: tab).map(\.id) == [installed.id])
            webKit.actionsWantSiteAccess = true
            let items = runtime.actions(for: tab)
            #expect(items.map(\.id) == [installed.id, quiet.id] && items.allSatisfy(\.wantsSiteAccess))
            runtime.grantSiteAccess(of: installed.id, for: tab)
            runtime.grantSiteAccess(of: quiet.id, for: tab)
            #expect(webKit.grantedSiteAccess == [WebExtensionManifest.extensionID(of: installed.id), WebExtensionManifest.extensionID(of: quiet.id)])
        }
    }

    // MARK: Popups

    @Test func keepsPopupsWithinTheirLimits() {
        #expect(ExtensionPopupPresenter.clamped(CGSize(width: 10, height: 1000)) == CGSize(width: 25, height: 600))
        #expect(ExtensionPopupPresenter.clamped(CGSize(width: 320, height: 240)) == CGSize(width: 320, height: 240))
        #expect(ExtensionPopupPresenter.clamped(CGSize(width: 900, height: 0)) == CGSize(width: 800, height: 25))
    }
}

/// Writes the `.zip` archive of the package folder, as the Finder's Compress makes it.
func compress(_ folder: URL, to archive: URL) throws {
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", folder.path, archive.path]
    try ditto.run()
    ditto.waitUntilExit()
    #expect(ditto.terminationStatus == 0)
}

/// Writes `.crx` files of format version 3, as Chromium packs extensions, signed by the keys a test chooses, and the parts of such a file, which a test may change after signing.
enum CRXFile {
    /// A key that signs `.crx` files: RSA, as Chromium's packer makes, or P-256, as the Web Store's publisher key is. Security and CryptoKit keys are safe to share across threads.
    struct Key: @unchecked Sendable {
        /// DER `SubjectPublicKeyInfo`.
        let publicKey: Data
        /// Whether the proof goes into the header's RSA proofs (field 2) rather than its ECDSA proofs (field 3).
        let isRSA: Bool
        private let sign: (Data) -> Data

        /// The SHA-256 digest of the public key, as the verifier takes a publisher key.
        var digest: Data { Data(SHA256.hash(data: publicKey)) }

        /// The same key filed among the RSA proofs, as a damaged file could have a P-256 key.
        var filedAsRSA: Key { Key(publicKey: publicKey, isRSA: true, sign: sign) }

        /// The PKCS #1 v1.5 or DER ECDSA signature of `message` over its SHA-256 digest.
        func signature(of message: Data) -> Data { sign(message) }

        /// A new 2048-bit RSA key, which stays out of the Keychain.
        static func rsa() -> Key {
            let attributes = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048] as CFDictionary
            let privateKey = SecKeyCreateRandomKey(attributes, nil)!
            let pkcs1 = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
            // SubjectPublicKeyInfo: the algorithm rsaEncryption with no parameters, then the PKCS #1 key as a bit string without unused bits.
            let algorithm = der(0x30, der(0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])) + der(0x05, Data()))
            return Key(publicKey: der(0x30, algorithm + der(0x03, Data([0]) + pkcs1)), isRSA: true) { message in
                SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)! as Data
            }
        }

        /// A new P-256 key.
        static func p256() -> Key {
            let privateKey = P256.Signing.PrivateKey()
            return Key(publicKey: privateKey.publicKey.derRepresentation, isRSA: false) { message in
                try! privateKey.signature(for: message).derRepresentation
            }
        }

        /// A DER element with a length of one, two, or three bytes, enough for these keys.
        private static func der(_ tag: UInt8, _ contents: Data) -> Data {
            let count = contents.count
            let length: [UInt8] = count < 0x80 ? [UInt8(count)] : count < 0x100 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 0xFF)]
            return Data([tag] + length) + contents
        }
    }

    /// The developer's key of the tests' files, made once for the run, as RSA keys take a moment.
    static let developer = Key.rsa()
    /// A publisher key that tests pass as the Web Store's.
    static let publisher = Key.p256()

    /// A file's header and archive, with the signatures made when the parts were.
    struct Parts {
        var proofs: [(key: Key, signature: Data)]
        /// The `SignedData` message, with the identifier.
        var signedHeader: Data
        var archive: Data
        /// Header fields that no proof signs and Arch does not read, such as `verified_contents` (4), between the proofs and the signed header.
        var unsignedFields = Data()

        /// What each proof signs: the context, the signed header's length as a 32-bit little-endian number, the signed header, and the archive.
        var message: Data { Data("CRX3 SignedData\0".utf8) + littleEndian(UInt32(signedHeader.count)) + signedHeader + archive }

        /// The file: `Cr24`, the version, and the header's length, then the header and the archive.
        var data: Data {
            let proofFields = proofs.map { field($0.key.isRSA ? 2 : 3, field(1, $0.key.publicKey) + field(2, $0.signature)) }
            let header = proofFields.reduce(Data(), +) + unsignedFields + field(10000, signedHeader)
            return Data("Cr24".utf8) + littleEndian(3) + littleEndian(UInt32(header.count)) + header + archive
        }
    }

    /// The parts of a file whose identifier is that of the first key's, or `crxID`, signed by each key.
    static func parts(archive: Data, signedBy keys: [Key] = [developer], crxID: Data? = nil) -> Parts {
        let identifier = crxID ?? Data(SHA256.hash(data: keys[0].publicKey).prefix(16))
        var parts = Parts(proofs: [], signedHeader: field(1, identifier), archive: archive)
        parts.proofs = keys.map { ($0, $0.signature(of: parts.message)) }
        return parts
    }

    /// A file whose identifier is that of the first key's, signed by each key.
    static func data(archive: Data, signedBy keys: [Key] = [developer]) -> Data {
        parts(archive: archive, signedBy: keys).data
    }

    fileprivate static func littleEndian(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) })
    }

    /// A length-delimited protocol buffer field.
    static func field(_ number: Int, _ value: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(value.count)) + value
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }
}

/// A tab as far as the store button's tests need one: its address.
private final class PageStub: EngineWebContents {
    let url: URL?
    init(url: URL?) {
        self.url = url
    }

    let engineKind = EngineKind.chromium
    let title = ""
    let favicon: NSImage? = nil
    let isLoading = false
    let canGoBack = false
    let canGoForward = false
    let restorableState: Data? = nil
    let isAudible = false
    let isCapturingMedia = false
    let isInPictureInPicture = false
    var zoomFactor = 1.0
    lazy var view = NSView()
    let navigationController: any EngineNavigationController = NavigationStub()
    let mediaSession: any EngineMediaSession = MediaStub()
    weak var uiDelegate: (any EngineWebContentsUIDelegate)?
    weak var navigationDelegate: (any EngineWebContentsNavigationDelegate)?
    weak var pageScriptDelegate: (any EnginePageScriptDelegate)?
    let closingStopsDownloads = false
    let devTools: (any EngineDevTools)? = nil

    func find(_ text: String, forward: Bool, matchCase: Bool, completion: @escaping (EngineFindResult) -> Void) {}
    func stopFind() {}
    func setPageScripts(_ scripts: [EnginePageScript]) {}
    func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {}
    func postPageScriptMessage(_ json: String, toWorld world: String) {}
    func readableContent(limit: Int, completion: @escaping (Result<EngineReadableContent, Error>) -> Void) {}
    func captureViewport(completion: @escaping (NSImage?) -> Void) {}
    func captureFullPage(completion: @escaping (NSImage?) -> Void) {}
    func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {}
    func exitFullscreen() {}
    func tryToClose(completion: @escaping (Bool) -> Void) {}

    private final class MediaStub: EngineMediaSession {
        weak var delegate: (any EngineMediaSessionDelegate)?
        let playbackState = EngineMediaPlaybackState.none
        let position: EngineMediaPosition? = nil
        let metadata: EngineMediaMetadata? = nil
        let canGoToNextTrack = false
        let canGoToPreviousTrack = false
        func play() {}
        func pause() {}
        func nextTrack() {}
        func previousTrack() {}
    }

    private final class NavigationStub: EngineNavigationController, EngineBackForwardList {
        var backForwardList: any EngineBackForwardList { self }
        let backList: [any EngineBackForwardListItem] = []
        func load(_ request: URLRequest) {}
        func reload() {}
        func reloadWithoutCache() {}
        func stop() {}
        func goBack() {}
        func goForward() {}
        func go(to item: any EngineBackForwardListItem) {}
    }
}
