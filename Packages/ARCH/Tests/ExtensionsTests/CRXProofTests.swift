// Package proof (`docs/web-store.md`, Package proof): the signatures of `.crx` files that `CRXFile` signs with RSA and P-256 keys, the developer's proof and the publisher's, the files refused as Chromium refuses them, staging only the web extension of a file's identifier, staging with the origin `webStore`, the proof in `plugins.json` with `signedSource` and `webStore`, entries this build keeps unchanged, and the review's warning for an unproven update. A test key stands in for the Web Store's publisher key, and a recording engine for Chromium.
import ARCHEngine
import CryptoKit
@testable import Extensions
import Foundation
@testable import Plugins
import Testing

@Suite struct CRXProofTests {
    private let archive = Data("the archive after the header".utf8)

    private func read(_ data: Data, publisherKeyDigest: Data = CRXArchive.webStorePublisherKeyDigest) throws -> CRXArchive {
        try CRXArchive(data, name: "Packed.crx", publisherKeyDigest: publisherKeyDigest)
    }

    @Test func provesTheDeveloperWithRSAAndP256Keys() throws {
        let crx = try read(CRXFile.data(archive: archive))
        #expect(crx.proof == .developer && crx.publicKey == CRXFile.developer.publicKey && crx.archive == archive)
        // The identifier is the first half of the developer key's digest, as Chromium and Arch's manifests write it.
        #expect(crx.extensionID == WebExtensionManifest.extensionID(ofBytes: CRXFile.developer.publicKey))
        let p256 = CRXFile.Key.p256()
        let signed = try read(CRXFile.data(archive: archive, signedBy: [p256]))
        #expect(signed.proof == .developer && signed.publicKey == p256.publicKey)
        // The developer's proof need not come first.
        #expect(try read(CRXFile.parts(archive: archive, signedBy: [CRXFile.publisher, CRXFile.developer], crxID: Data(SHA256.hash(data: CRXFile.developer.publicKey).prefix(16))).data).publicKey == CRXFile.developer.publicKey)
    }

    @Test func provesTheWebStoreWithThePublisherKey() throws {
        let data = CRXFile.data(archive: archive, signedBy: [CRXFile.developer, CRXFile.publisher])
        #expect(try read(data, publisherKeyDigest: CRXFile.publisher.digest).proof == .webStore)
        // Another key's proof proves only the developer: the test key is not the store's.
        #expect(try read(data).proof == .developer)
        #expect(CRXArchive.webStorePublisherKeyDigest.count == 32)
    }

    @Test func refusesFilesWhoseProofsDoNotHold() throws {
        let mismatch = PluginError.invalidPackage("The signature of \u{201C}Packed.crx\u{201D} does not match its contents.")
        // The archive changed after signing.
        var parts = CRXFile.parts(archive: archive)
        parts.archive[parts.archive.startIndex] ^= 1
        #expect(throws: mismatch) { try read(parts.data) }
        // The signed header changed after signing, with the same identifier.
        parts = CRXFile.parts(archive: archive)
        parts.signedHeader += CRXFile.field(2, Data("added".utf8))
        #expect(throws: mismatch) { try read(parts.data) }
        // The developer's key, but another key's signature.
        parts = CRXFile.parts(archive: archive)
        parts.proofs[0].signature = CRXFile.Key.rsa().signature(of: parts.message)
        #expect(throws: mismatch) { try read(parts.data) }
        // A second proof that does not hold refuses the file, as in Chromium, though the developer's holds.
        parts = CRXFile.parts(archive: archive, signedBy: [CRXFile.developer, CRXFile.publisher])
        parts.proofs[1].signature = CRXFile.publisher.signature(of: Data("something else".utf8))
        #expect(throws: mismatch) { try read(parts.data, publisherKeyDigest: CRXFile.publisher.digest) }
        // A P-256 key among the RSA proofs does not hold.
        parts = CRXFile.parts(archive: archive, signedBy: [CRXFile.developer, CRXFile.publisher])
        parts.proofs[1] = (CRXFile.publisher.filedAsRSA, parts.proofs[1].signature)
        #expect(throws: mismatch) { try read(parts.data) }
        // No proof's key has the identifier, or the signed header has none.
        let noKey = PluginError.invalidPackage("Packed.crx has no key for its extension\u{2019}s identifier.")
        #expect(throws: noKey) { try read(CRXFile.parts(archive: archive, crxID: Data(repeating: 7, count: 16)).data) }
        parts = CRXFile.parts(archive: archive)
        parts.signedHeader = Data()
        parts.proofs = [(CRXFile.developer, CRXFile.developer.signature(of: parts.message))]
        #expect(throws: noKey) { try read(parts.data) }
        // A header that is not a protocol buffer message.
        var data = CRXFile.data(archive: archive)
        data[12] = 0xFF
        #expect(throws: PluginError.invalidPackage("The header of Packed.crx could not be read.")) { try read(data) }
    }

    @Test func refusesHeadersWithTheSignatureOfAZipArchivesEnd() throws {
        // A field that no proof signs reads, but not with the signature of an end of central directory record, a ZIP64 locator, or a ZIP64 record, which Chromium refuses as an unzipper could take the header for the archive's end.
        var parts = CRXFile.parts(archive: archive)
        parts.unsignedFields = CRXFile.field(4, Data("PK contents".utf8))
        #expect(try read(parts.data).proof == .developer)
        for signature in CRXArchive.zipEndSignatures {
            parts.unsignedFields = CRXFile.field(4, Data("contents ".utf8) + Data(signature))
            #expect(throws: PluginError.invalidPackage("The header of Packed.crx could not be read.")) { try read(parts.data) }
        }
        #expect(CRXArchive.zipEndSignatures.map { Data($0) } == [Data("PK\u{05}\u{06}".utf8), Data("PK\u{06}\u{07}".utf8), Data("PK\u{06}\u{06}".utf8)])
    }

    @Test func readsThePKCS1KeyOfAnRSAKeyOnly() throws {
        let pkcs1 = try #require(CRXArchive.rsaPublicKey(inSubjectPublicKeyInfo: CRXFile.developer.publicKey))
        #expect(CRXFile.developer.publicKey.suffix(pkcs1.count) == pkcs1)
        #expect(CRXArchive.rsaPublicKey(inSubjectPublicKeyInfo: CRXFile.publisher.publicKey) == nil)
        #expect(CRXArchive.rsaPublicKey(inSubjectPublicKeyInfo: CRXFile.developer.publicKey.dropLast()) == nil)
        #expect(CRXArchive.rsaPublicKey(inSubjectPublicKeyInfo: Data()) == nil)
    }
}

@MainActor
@Suite(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
struct CRXProofStagingTests {
    private let folder = TemporaryFolder()
    private let host = RecordingHost()
    private let persona = UUID()

    init() {
        host.engines = [.webKit: RecordingEngine(), .chromium: RecordingEngine()]
    }

    /// A manager of the test's Persona, as a launch makes it, which takes the test publisher key for the Web Store's.
    private func launch() -> PluginManager {
        let runtime = WebExtensionRuntime(persona: persona, host: host, nativeMessagingHosts: folder.url)
        return PluginManager(persona: persona, directory: folder.url, builtIns: [], runtimes: [runtime], secretStore: NoSecrets(),
                             publisherKeyDigest: CRXFile.publisher.digest)
    }

    private var stagingURL: URL { folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/Staging") }
    private var listURL: URL { folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/plugins.json") }

    /// The developer key's engine identifier.
    private var extensionID: String { WebExtensionManifest.extensionID(ofBytes: CRXFile.developer.publicKey) }

    /// A `.crx` file named `name` of an extension with the manifest's fields, signed by the keys.
    private func crx(_ name: String, _ fields: String = #""manifest_version": 3, "name": "Packed", "version": "2""#,
                     signedBy keys: [CRXFile.Key] = [CRXFile.developer]) throws -> URL {
        try crx(name, files: ["manifest.json": "{\(fields)}"], signedBy: keys)
    }

    /// A `.crx` file named `name` of a package with the files, signed by the keys.
    private func crx(_ name: String, files: [String: String], signedBy keys: [CRXFile.Key]) throws -> URL {
        let package = try folder.package(name, files)
        let archive = folder.url.appendingPathComponent("\(name).zip")
        try compress(package, to: archive)
        let file = folder.url.appendingPathComponent("\(name).crx")
        try CRXFile.data(archive: Data(contentsOf: archive), signedBy: keys).write(to: file)
        return file
    }

    private func installEntries() throws -> [[String: Any]] {
        let list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: listURL)) as? [String: Any])
        return try #require(list["installed"] as? [[String: Any]])
    }

    private func editInstallEntry(_ edit: (inout [String: Any]) -> Void) throws {
        var list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: listURL)) as? [String: Any])
        var entries = try #require(list["installed"] as? [[String: Any]])
        edit(&entries[0])
        list["installed"] = entries
        try JSONSerialization.data(withJSONObject: list).write(to: listURL)
    }

    /// Whether staging left nothing behind.
    private var stagingIsEmpty: Bool { ((try? FileManager.default.contentsOfDirectory(atPath: stagingURL.path)) ?? []).isEmpty }

    @Test func stagesSignedFilesWithTheirProofAndOthersWithout() async throws {
        let manager = launch()
        let file = try crx("developer")
        let developer = try await manager.stage(file)
        #expect(developer.proof == .developer && developer.origin == .file(file.absoluteURL))
        manager.discard(developer)
        let store = try await manager.stage(crx("store", signedBy: [CRXFile.developer, CRXFile.publisher]))
        #expect(store.proof == .webStore && store.origin != .webStore(extensionID))
        manager.discard(store)
        // Folders and `.zip` archives have no proof.
        let source = try folder.package("plain", ["manifest.json": #"{"manifest_version": 3, "name": "Plain", "version": "1"}"#])
        let plain = try await manager.stage(source)
        #expect(plain.proof == nil)
        manager.discard(plain)
        let archive = folder.url.appendingPathComponent("plain.zip")
        try compress(source, to: archive)
        let zipped = try await manager.stage(archive)
        #expect(zipped.proof == nil)
        manager.discard(zipped)
        // A file whose signature does not hold stages nothing.
        var data = try Data(contentsOf: crx("broken"))
        data[data.endIndex - 1] ^= 1
        let broken = folder.url.appendingPathComponent("Broken.crx")
        try data.write(to: broken)
        await #expect(throws: PluginError.invalidPackage("The signature of \u{201C}Broken.crx\u{201D} does not match its contents.")) { try await manager.stage(broken) }
        #expect(stagingIsEmpty)
        manager.close()
    }

    @Test func stagesOnlyTheWebStoresOwnPackageForTheIdentifier() async throws {
        let manager = launch()
        let origin = PluginOrigin.webStore(extensionID)
        await #expect(throws: PluginError.invalidPackage("The package is not signed by the Web Store.")) { try await manager.stage(crx("unpublished"), origin: origin) }
        let published = try crx("published", signedBy: [CRXFile.developer, CRXFile.publisher])
        await #expect(throws: PluginError.invalidPackage("The Web Store sent the package of another extension.")) {
            try await manager.stage(published, origin: .webStore(String(repeating: "a", count: 32)))
        }
        let theme = try crx("theme", #""manifest_version": 3, "name": "Dusk", "version": "1", "theme": {"colors": {"frame": [0, 0, 0]}}"#,
                            signedBy: [CRXFile.developer, CRXFile.publisher])
        await #expect(throws: PluginError.invalidPackage("\u{201C}Dusk\u{201D} is a theme, which Arch does not use.")) { try await manager.stage(theme, origin: origin) }
        // A folder has no store proof, and a download has no other origins.
        let source = try folder.package("folder", ["manifest.json": #"{"manifest_version": 3, "name": "Folder", "version": "1"}"#])
        await #expect(throws: PluginError.invalidPackage("The package is not signed by the Web Store.")) { try await manager.stage(source, origin: origin) }
        await #expect(throws: PluginError.self) { try await manager.stage(published, origin: .bundled) }
        #expect(stagingIsEmpty)
        // The store's package for the identifier stages with the store as its origin and leaves the download for its caller.
        let package = try await manager.stage(published, origin: origin)
        #expect(package.origin == origin && package.proof == .webStore && package.manifest.id.rawValue == "extension." + extensionID)
        #expect(FileManager.default.fileExists(atPath: published.path))
        manager.discard(package)
        manager.close()
    }

    @Test func stagesFromACRXFileOnlyTheWebExtensionOfItsIdentifier() async throws {
        let manager = launch()
        // The signatures prove only the identifier of the web extension whose key they carry, not a script plugin's in `plugin.json`, alone or beside a `manifest.json`.
        let script = ["plugin.json": #"{"id": "com.example.tool", "name": "Tool", "version": "1", "apiVersion": 1, "summary": "T."}"#]
        await #expect(throws: PluginError.invalidPackage("tool.crx holds no web extension.")) {
            try await manager.stage(crx("tool", files: script, signedBy: [CRXFile.developer]))
        }
        let both = try crx("both", files: script.merging(["manifest.json": #"{"manifest_version": 3, "name": "Tool", "version": "1"}"#]) { $1 },
                           signedBy: [CRXFile.developer, CRXFile.publisher])
        await #expect(throws: PluginError.invalidPackage("both.crx holds no web extension.")) { try await manager.stage(both) }
        await #expect(throws: PluginError.invalidPackage("The Web Store sent the package of another extension.")) {
            try await manager.stage(both, origin: .webStore(extensionID))
        }
        #expect(stagingIsEmpty && manager.plugins.isEmpty)
        // The script plugin stages from a folder, without proof.
        let plain = try await manager.stage(folder.package("tool folder", script))
        #expect(plain.kind == .script && plain.proof == nil)
        manager.discard(plain)
        manager.close()
    }

    @Test func recordsTheProofInThePluginList() async throws {
        var manager = launch()
        let file = try crx("signed")
        #expect(try await manager.installEverything(from: file).proof == .developer)
        let storeKey = CRXFile.Key.p256()
        let storeID = WebExtensionManifest.extensionID(ofBytes: storeKey.publicKey)
        let staged = try await manager.stage(crx("store", #""manifest_version": 3, "name": "Store", "version": "1""#, signedBy: [storeKey, CRXFile.publisher]),
                                             origin: .webStore(storeID))
        try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: true)
        // A proven `.crx` install names its file with `signedSource`, and a store install its identifier with `webStore`, never with `source`, so that builds before proofs keep them as entries they cannot read.
        var entries = try installEntries()
        #expect(entries[0]["signedSource"] as? String == file.absoluteString && entries[0]["proof"] as? String == "developer" && entries[0]["source"] == nil)
        #expect(entries[1]["webStore"] as? String == storeID && entries[1]["proof"] as? String == "webStore" && entries[1]["source"] == nil)
        manager.close()
        // The next launch reads them back.
        manager = launch()
        #expect(manager.plugins.map(\.proof) == [.developer, .webStore])
        #expect(manager.plugins.map(\.origin) == [.file(file.absoluteURL), .webStore(storeID)])
        manager.close()
        // An entry with `source` has no proof, whatever its `proof` key says, and keeps the key.
        try editInstallEntry { $0["source"] = $0.removeValue(forKey: "signedSource") }
        manager = launch()
        let unproven = try #require(manager.plugins.first)
        #expect(unproven.proof == nil)
        manager.setEnabled(false, for: unproven.id)
        entries = try installEntries()
        #expect(entries[0]["source"] as? String == file.absoluteString && entries[0]["proof"] as? String == "developer" && entries[0]["signedSource"] == nil)
        manager.close()
        // A proof this build does not know counts as none and survives a write.
        try editInstallEntry { entry in
            entry["signedSource"] = entry.removeValue(forKey: "source")
            entry["proof"] = "notarized"
        }
        manager = launch()
        let unknown = try #require(manager.plugins.first)
        #expect(unknown.proof == nil && unknown.origin == .file(file.absoluteURL))
        manager.setEnabled(true, for: unknown.id)
        entries = try installEntries()
        #expect(entries[0]["proof"] as? String == "notarized" && entries[0]["signedSource"] as? String == file.absoluteString && entries[0]["source"] == nil)
        manager.close()
    }

    @Test func warnsWhenAnUnprovenPackageUpdatesAProvenPlugin() async throws {
        let manager = launch()
        let installed = try await manager.installEverything(from: crx("signed"))
        // A folder whose manifest carries the developer's public key claims the identifier without proving it.
        let key = CRXFile.developer.publicKey.base64EncodedString()
        let claim = try folder.package("claim", ["manifest.json": #"{"manifest_version": 3, "name": "Packed", "version": "3", "key": "\#(key)"}"#])
        let unproven = try await manager.stage(claim)
        #expect(unproven.updates == installed.id && unproven.proof == nil)
        #expect(unproven.proofWarning(updating: installed) == "The installed version is signed by its developer; this package is not.")
        manager.discard(unproven)
        let proven = try await manager.stage(crx("signed again", #""manifest_version": 3, "name": "Packed", "version": "3""#))
        #expect(proven.updates == installed.id && proven.proofWarning(updating: installed) == nil)
        manager.discard(proven)
        // An update records its own proof.
        let update = try await manager.stage(claim)
        try manager.install(update, grant: PluginGrant(requestedBy: update.manifest), isEnabled: true)
        #expect(manager.plugins.first?.proof == nil)
        let entry = try installEntries()[0]
        #expect(entry["source"] as? String == claim.absoluteString && entry["proof"] == nil && entry["signedSource"] == nil)
        // Without proof on either side, nothing warns.
        let next = try await manager.stage(claim)
        #expect(next.proofWarning(updating: try #require(manager.plugins.first)) == nil)
        manager.discard(next)
        manager.close()
    }
}
