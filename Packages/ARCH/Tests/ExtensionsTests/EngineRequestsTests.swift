// What the web extension runtime does for the requests that Chromium's extension runtime makes, against recording engines: the tabs and windows it opens through the host, the engines' own prompts, allowing an extension on a site, the key it writes into a package without one so that Chromium names the extension as Arch does, `.crx` packages, when an engine may stop what it kept from an earlier launch, and the popup sizes the presenter keeps.
import AppKit
import ARCHEngine
import CryptoKit
@testable import Extensions
import Foundation
@testable import Plugins
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
        try zip(package, to: archive)
        let publicKey = Data("a developer's public key".utf8)
        let crx = folder.url.appendingPathComponent("Packed.crx")
        try CRXFile.data(publicKey: publicKey, archive: Data(contentsOf: archive)).write(to: crx)
        let staged = try await manager.stage(crx)
        // The extension has the identifier of the file's key, which its manifest now carries.
        #expect(staged.manifest.id.rawValue == "extension." + WebExtensionManifest.extensionID(ofBytes: publicKey))
        #expect(staged.files == ["background.js", "manifest.json"])
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: staged.rootURL.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["key"] as? String == publicKey.base64EncodedString())
        manager.discard(staged)
        #expect(runtime.packageTypes(for: .chromium).contains(PluginPackage.crxType) && !runtime.packageTypes(for: .webKit).contains(PluginPackage.crxType))
        // Chromium no longer installs the format before version 3.
        var old = try Data(contentsOf: crx)
        old[4] = 2
        try old.write(to: crx)
        await #expect(throws: PluginError.invalidPackage("Packed.crx is a .crx file of format version 2, which Chromium no longer installs.")) { try await manager.stage(crx) }
    }

    private func zip(_ folder: URL, to archive: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", folder.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
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

    @Test func asksTheEnginesQuestionsWithSheets() async throws {
        let installed = try await installLoaded("asker", #"{"manifest_version": 3, "name": "Asker", "version": "1", "optional_host_permissions": ["https://example.com/*"]}"#)
        let id = WebExtensionManifest.extensionID(of: installed.id)
        var answer: Bool?
        runtime.extensions(chromium, extension: id, asks: EngineExtensionPrompt(kind: .permissions(["Read and change your data on example.com"]), tab: nil)) { answer = $0 }
        #expect(await eventually { answer != nil })
        #expect(answer == true && host.sheets.last?.messageText == "Allow \u{201C}Asker\u{201D} more access?")
        #expect(host.sheets.last?.informativeText.hasPrefix("Read and change your data on example.com\n\nThe extension gets this access on Chromium tabs.") == true)
        host.sheetAnswer = .alertSecondButtonReturn
        answer = nil
        runtime.extensions(chromium, extension: id, asks: EngineExtensionPrompt(kind: .reload(["Asker"]), tab: nil)) { answer = $0 }
        #expect(answer == false && host.sheets.last?.messageText == "Reload This Page?")
        // The store's install prompt is refused without a sheet, as is a question from an extension that the engine did not load.
        let sheets = host.sheets.count
        answer = nil
        runtime.extensions(chromium, extension: id, asks: EngineExtensionPrompt(kind: .install, tab: nil)) { answer = $0 }
        #expect(answer == false)
        runtime.extensions(chromium, extension: "unknown", asks: EngineExtensionPrompt(kind: .permissions([]), tab: nil)) { answer = $0 }
        #expect(answer == false && host.sheets.count == sheets)
    }

    @Test func refusesRunTimeNativeMessagingAndConfirmsEveryWebsite() async throws {
        let messenger = try await installLoaded("messenger", #"{"manifest_version": 3, "name": "M", "version": "1", "optional_permissions": ["nativeMessaging"]}"#)
        var answer: Bool?
        runtime.extensions(chromium, extension: WebExtensionManifest.extensionID(of: messenger.id), asks: EngineExtensionPrompt(kind: .permissions(["Communicate with cooperating native applications"]), tab: nil)) { answer = $0 }
        #expect(answer == false && host.sheets.isEmpty)
        let everywhere = WebExtensionManifest.optionalAccess(ofPackageAt: try folder.package("everywhere", [
            "manifest.json": #"{"manifest_version": 3, "name": "E", "version": "1", "optional_permissions": ["cookies"], "optional_host_permissions": ["<all_urls>"]}"#,
        ]))
        #expect(everywhere.permissions == ["cookies"] && everywhere.grant.confirmationReason(for: "E") != nil)
    }

    @Test func confirmsEveryWebsiteThatTheInstallLeftOut() async throws {
        let manifest = #"{"manifest_version": 3, "name": "W", "version": "1", "host_permissions": ["<all_urls>"]}"#
        // Chromium withholds the sites the install left out and lets `permissions.request()` ask for them again, so every website needs confirming.
        let withheld = try await manager.stage(folder.package("withheld", ["manifest.json": manifest]))
        try manager.install(withheld, grant: PluginGrant(permissions: [], sites: []), isEnabled: true)
        let leftOut = try #require(manager.plugins.first { $0.id == withheld.manifest.id })
        #expect(WebExtensionManifest.runTimeAccess(of: leftOut).grant.confirmationReason(for: "W") != nil)
        // With every website granted at install, nothing is left to ask for.
        let granted = try await installLoaded("granted", manifest.replacingOccurrences(of: #""W""#, with: #""G""#))
        #expect(WebExtensionManifest.runTimeAccess(of: granted).sites.isEmpty)
    }

    // MARK: Site access

    @Test func allowsAnExtensionOnTheTabsSite() async throws {
        try await WebKitProfile.run { profile in
            host.engines = [.webKit: webKit]
            webKit.actionsWantSiteAccess = true
            let tab = profile.makeTab()
            let installed = try await manager.installEverything(from: folder.package("waiter", [
                "manifest.json": #"{"manifest_version": 3, "name": "Waiter", "version": "1", "action": {}}"#,
            ]))
            #expect(await eventually { runtime.actions(for: tab).first?.wantsSiteAccess == true })
            runtime.grantSiteAccess(of: installed.id, for: tab)
            #expect(webKit.grantedSiteAccess == [WebExtensionManifest.extensionID(of: installed.id)])
        }
    }

    // MARK: Popups

    @Test func keepsPopupsWithinTheirLimits() {
        #expect(ExtensionPopupPresenter.clamped(CGSize(width: 10, height: 1000)) == CGSize(width: 25, height: 600))
        #expect(ExtensionPopupPresenter.clamped(CGSize(width: 320, height: 240)) == CGSize(width: 320, height: 240))
        #expect(ExtensionPopupPresenter.clamped(CGSize(width: 900, height: 0)) == CGSize(width: 800, height: 25))
    }
}

/// Writes `.crx` files of format version 3, as Chromium packs extensions.
enum CRXFile {
    static func data(publicKey: Data, archive: Data) -> Data {
        let identifier = Data(SHA256.hash(data: publicKey).prefix(16))
        let proof = field(1, publicKey) + field(2, Data("signature".utf8))
        let header = field(2, proof) + field(10000, field(1, identifier))
        return Data("Cr24".utf8) + littleEndian(3) + littleEndian(UInt32(header.count)) + header + archive
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) })
    }

    /// A length-delimited protocol buffer field.
    private static func field(_ number: Int, _ value: Data) -> Data {
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
