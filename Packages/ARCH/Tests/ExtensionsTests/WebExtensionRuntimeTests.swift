// The web extension runtime: what it loads into the engines and with which grant, how it follows switching extensions on and off, updates, removals, and engines that refuse an extension, what a profile that starts while no extension is enabled stops, the questions about access an extension asks while it runs, and, below macOS 15.4, that it runs nothing.
import AppKit
import ARCHEngine
@testable import Extensions
@testable import Plugins
import Testing

@MainActor
@Suite(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
struct WebExtensionRuntimeTests {
    private let folder = TemporaryFolder()
    private let host = RecordingHost()
    private let engine = RecordingEngine()
    private let runtime: WebExtensionRuntime
    private let manager: PluginManager

    init() {
        host.engines = [.webKit: engine]
        runtime = WebExtensionRuntime(persona: UUID(), host: host, nativeMessagingHosts: folder.url)
        manager = PluginManager.withWebExtensions(runtime, in: folder)
    }

    /// The sample's engine identifier, which comes from its folder's path, as it has no key.
    private var sampleID: String { try! WebExtensionManifest.extensionID(key: nil, source: sampleExtensionFolder) }

    /// Installs the package with everything it asks for and waits until the runtime has loaded it, which it announces once the engine's load returns.
    @discardableResult
    private func installLoaded(from source: URL) async throws -> InstalledPlugin {
        var announcements = 0
        let subscription = runtime.objectWillChange.sink { announcements += 1 }
        defer { subscription.cancel() }
        let installed = try await manager.installEverything(from: source)
        let id = WebExtensionManifest.extensionID(of: installed.id)
        #expect(await eventually { announcements > 0 && engine.loaded[id] != nil })
        return installed
    }

    @Test func loadsEnabledExtensionsWithTheirGrant() async throws {
        let installed = try await manager.installEverything(from: sampleExtensionFolder)
        #expect(await eventually { engine.loaded[sampleID] != nil })
        let loaded = try #require(engine.loaded[sampleID])
        #expect(loaded.packageURL == installed.packageURL && loaded.permissions == ["storage", "tabs"] && loaded.sites == ["https://example.org/*"])
        #expect(engine.delegate === runtime)
        #expect(installed.unavailability == nil && manager.contributions.paletteCommands(matching: "sample").map(\.item.id) == [WebExtensionManifest.actionCommand])
    }

    @Test func grantsEveryWebPageAsAllURLs() async throws {
        let installed = try await installLoaded(from: folder.package("everywhere", [
            "manifest.json": #"{"manifest_version": 3, "name": "E", "version": "1", "host_permissions": ["<all_urls>", "https://example.org/*"]}"#,
        ]))
        #expect(engine.loaded[WebExtensionManifest.extensionID(of: installed.id)]?.sites == ["<all_urls>", "https://example.org/*"])
    }

    @Test func grantsOnlyTheSitesTheUserLeftIn() async throws {
        let package = try await manager.stage(sampleExtensionFolder)
        try manager.install(package, grant: PluginGrant(permissions: [], sites: []), isEnabled: true)
        #expect(await eventually { engine.loaded[sampleID] != nil })
        #expect(engine.loaded[sampleID]?.sites == [] && engine.loaded[sampleID]?.permissions == ["storage"])
    }

    @Test func followsSwitchingOffUpdatesAndRemoval() async throws {
        let installed = try await manager.installEverything(from: sampleExtensionFolder)
        #expect(await eventually { engine.loaded[sampleID] != nil })
        manager.setEnabled(false, for: installed.id)
        #expect(await eventually { engine.loaded[sampleID] == nil })
        manager.setEnabled(true, for: installed.id)
        #expect(await eventually { engine.loaded[sampleID] != nil })
        let update = try await manager.stage(sampleExtensionFolder)
        try manager.install(update, grant: PluginGrant(permissions: [], sites: update.manifest.sites), isEnabled: true)
        #expect(await eventually { engine.loaded[sampleID]?.permissions == ["storage"] })
        try manager.remove(installed.id)
        #expect(await eventually { engine.removedData == [sampleID] })
        #expect(engine.loaded.isEmpty)
    }

    @Test func stopsWhatAnEarlierLaunchRunsInAProfileThatStartsWhileNoExtensionIsEnabled() async throws {
        let installed = try await manager.installEverything(from: sampleExtensionFolder, isEnabled: false)
        let profile = RecordingEngine()
        runtime.profileDidStart(with: profile)
        #expect(profile.stopsWhileLoaded == [[]])
        manager.setEnabled(true, for: installed.id)
        #expect(await eventually { engine.loaded[sampleID] != nil })
        // With an extension enabled, the pass that loads it stops the rest once its loads end.
        let later = RecordingEngine()
        runtime.profileDidStart(with: later)
        #expect(later.stopsWhileLoaded.isEmpty)
    }

    @Test func switchesOffAnExtensionThatAnEngineRefuses() async throws {
        engine.refused = [sampleID]
        let installed = try await manager.installEverything(from: sampleExtensionFolder)
        #expect(await eventually { manager.plugins.first?.isEnabled == false })
        #expect(manager.plugins.first?.failure == "Arch could not start it on WebKit tabs: The engine refused it.")
        #expect(manager.contributions.paletteCommands(matching: installed.manifest.name).isEmpty)
    }

    @Test func listsActionsAndRunsThemForATab() async throws {
        try await WebKitProfile.run { profile in
            let tab = profile.makeTab()
            let installed = try await manager.installEverything(from: sampleExtensionFolder)
            #expect(await eventually { runtime.actions(for: tab).first?.action != nil })
            #expect(runtime.actions(for: tab).map(\.name) == ["Sample Extension"])
            #expect(runtime.performAction(of: installed.id, for: tab))
            manager.setEnabled(false, for: installed.id)
            #expect(await eventually { runtime.actions(for: tab).isEmpty })
            #expect(!runtime.performAction(of: installed.id, for: tab))
        }
    }

    @Test func asksAboutAccessAndConfirmsOnlyWhatReachesEverySite() async throws {
        try await installLoaded(from: sampleExtensionFolder)
        let access: Set<EngineExtensionAccess> = [.permission("cookies"), .permission("nativeMessaging"), .site("https://example.com/*"), .site("file:///*"),
                                                  .page(URL(string: "about:blank")!)]
        var allowed: Set<EngineExtensionAccess>?
        runtime.extensions(engine, extension: sampleID, requests: access, in: nil) { allowed = $0 }
        #expect(await eventually { allowed != nil })
        // Native messaging, which only the install grants, and sites and pages other than web pages are never asked about.
        #expect(allowed == [.permission("cookies"), .site("https://example.com/*")])
        #expect(host.sheets.first?.informativeText.hasPrefix("Use the extension API cookies\nRun scripts on pages from example.com\n") == true)
        host.sheetAnswer = .alertSecondButtonReturn
        runtime.extensions(engine, extension: sampleID, requests: [.permission("cookies")], in: nil) { allowed = $0 }
        #expect(allowed == [])
        #expect(WebExtensionAccessPrompt(requested: [.site("<all_urls>")], extensionName: "A").grant.confirmationReason(for: "A") != nil)
        #expect(WebExtensionAccessPrompt(requested: [.permission("cookies"), .site("https://example.com/*")], extensionName: "A").grant.confirmationReason(for: "A") == nil)
    }

    @Test func passesNativeMessagesOnlyWithTheGrant() async throws {
        try await installLoaded(from: sampleExtensionFolder)
        var reply: Result<Data, any Error>?
        runtime.extensions(engine, extension: sampleID, sendNativeMessage: Data("{}".utf8), toApplication: "org.example.echo") { reply = $0 }
        #expect(throws: PluginError.permissionDenied(.nativeMessaging)) { try reply?.get() }
        let messenger = try await installLoaded(from: folder.package("messenger", ["manifest.json": #"{"manifest_version": 3, "name": "M", "version": "1", "permissions": ["nativeMessaging"]}"#]))
        runtime.extensions(engine, extension: WebExtensionManifest.extensionID(of: messenger.id), sendNativeMessage: Data("{}".utf8), toApplication: "org.example.echo") { reply = $0 }
        // With the grant, the message reaches native messaging, which finds no host manifest in the test's folder.
        #expect(throws: NativeMessagingError.notFound("org.example.echo")) { try reply?.get() }
    }
}

/// Below macOS 15.4, where WebKit runs no web extensions.
@MainActor
@Suite(.enabled(if: !systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
struct UnavailableWebExtensionRuntimeTests {
    @Test func leavesEnabledExtensionsOutOfThePaletteAndTheTabs() async throws {
        let folder = TemporaryFolder()
        let runtime = WebExtensionRuntime(persona: UUID(), host: RecordingHost(), nativeMessagingHosts: folder.url)
        let manager = PluginManager.withWebExtensions(runtime, in: folder)
        let installed = try await manager.installEverything(from: sampleExtensionFolder)
        #expect(installed.unavailability == "Web extensions need macOS 15.4 or later.")
        #expect(manager.contributions.paletteCommands(matching: installed.manifest.name).isEmpty)
        try await WebKitProfile.run { profile in
            #expect(runtime.actions(for: profile.makeTab()).isEmpty)
        }
    }
}
