// What the web extension tests share: the sample extension, whether this Mac runs web extensions, temporary folders, a plugin manager whose secrets stay out of the Keychain, a host that records what the runtime asks of the browser, and an engine that records what the runtime checks and loads.
import AppKit
import ARCHEngine
import ARCHEngineWebKit
@testable import Extensions
import Foundation
@testable import Plugins
import Testing

/// The sample web extension's package folder.
let sampleExtensionFolder = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Sample", isDirectory: true).absoluteURL

/// Whether this Mac runs web extensions, as WebKit does from macOS 15.4.
let systemRunsWebExtensions = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0))

/// A folder of its own for one test's files, removed when the test ends.
final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchExtensionsTests-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a package of `files`, by package path, into a folder of its own named `name`.
    func package(_ name: String, _ files: [String: String]) throws -> URL {
        let root = url.appendingPathComponent("Packages/\(name)", isDirectory: true)
        for (path, text) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        return root
    }
}

/// Keeps no secrets, so that removing a plugin never touches the Keychain.
final class NoSecrets: PluginSecretStore {
    func secret(service: String, account: String) throws -> String? { nil }
    func setSecret(_ secret: String?, service: String, account: String) throws {}
    func containsSecret(service: String, account: String) throws -> Bool { false }
    func secretCount(service: String, accountPrefix: String) throws -> Int { 0 }
    func removeSecrets(service: String?, accountPrefix: String) throws {}
}

@MainActor
extension PluginManager {
    /// A manager of a new Persona in `folder` whose web extensions run in `runtime`.
    static func withWebExtensions(_ runtime: WebExtensionRuntime, in folder: TemporaryFolder) -> PluginManager {
        PluginManager(persona: UUID(), directory: folder.url, builtIns: [], runtimes: [runtime], secretStore: NoSecrets())
    }

    /// Stages and installs the package with everything it asks for.
    @discardableResult
    func installEverything(from source: URL, isEnabled: Bool = true) async throws -> InstalledPlugin {
        let package = try await stage(source)
        try install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: isEnabled)
        return try #require(plugins.first { $0.id == package.manifest.id })
    }
}

/// A browser that gives the runtime its engines and records the popups and sheets the runtime asks it to show and the tabs and windows it asks it to open. Sheets get the answer the test chose; a tab opens as `openedTab`, and a window as `openedWindow`.
@MainActor
final class RecordingHost: WebExtensionHost {
    var engines: [EngineKind: any EngineExtensions] = [:]
    /// The version of each engine's extension runtime, `1` for an engine the test does not name.
    var versions: [EngineKind: String] = [:]
    /// Engines that the host lists but whose profiles do not start, as an engine that fails when the runtime first needs it.
    var enginesThatDoNotStart: Set<EngineKind> = []
    var tabs: [UUID: any EngineWebContents] = [:]
    /// WebKit's popovers.
    private(set) var popups: [NSPopover] = []
    /// The popup pages that a popover of the app's would show.
    private(set) var popupPages: [any EngineExtensionPopupView] = []
    private(set) var sheets: [NSAlert] = []
    var sheetAnswer = NSApplication.ModalResponse.alertFirstButtonReturn
    /// Each tab request: the address, engine, Persona, window, whether active, and the index.
    private(set) var openedTabs: [(url: URL?, engine: EngineKind, persona: PersonaID, window: UUID?, active: Bool, index: Int?)] = []
    var openedTab: (any EngineWebContents)?
    /// Each window request: the addresses, engine, and whether focused.
    private(set) var openedWindows: [(urls: [URL], engine: EngineKind, focused: Bool)] = []
    var openedWindow: UUID?
    /// Each store install that the runtime started: the identifier, the Persona, and the tab.
    private(set) var storeInstalls: [(id: String, persona: PersonaID, tab: any EngineWebContents)] = []

    var extensionRuntimeVersions: [EngineKind: String] {
        Dictionary(uniqueKeysWithValues: engines.keys.map { ($0, versions[$0] ?? "1") })
    }

    func extensionEngines(in persona: PersonaID) -> [EngineKind: any EngineExtensions] {
        engines.filter { !enginesThatDoNotStart.contains($0.key) }
    }
    func webContents(ofTab id: UUID) -> (any EngineWebContents)? { tabs[id] }
    func activate(_ tab: any EngineWebContents) {}
    func close(_ tab: any EngineWebContents) {}

    func present(_ popup: EngineExtensionPopup, for tab: (any EngineWebContents)?) -> Bool {
        switch popup {
        case let .popover(popover): popups.append(popover)
        case let .view(page): popupPages.append(page)
        }
        return true
    }

    func openTab(_ url: URL?, in engine: EngineKind, persona: PersonaID, window windowID: UUID?, active: Bool, index: Int?, completion: @escaping ((any EngineWebContents)?) -> Void) {
        openedTabs.append((url, engine, persona, windowID, active, index))
        completion(openedTab)
    }

    func openWindow(with urls: [URL], in engine: EngineKind, persona: PersonaID, focused: Bool, completion: @escaping (UUID?) -> Void) {
        openedWindows.append((urls, engine, focused))
        completion(openedWindow)
    }

    func presentSheet(_ alert: NSAlert, for tab: (any EngineWebContents)?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        sheets.append(alert)
        completion(sheetAnswer)
    }

    func installFromWebStore(_ id: String, persona: PersonaID, tab: any EngineWebContents) {
        storeInstalls.append((id, persona, tab))
    }
}

/// An engine that records what the runtime checks, loads, unloads, deletes, and runs the actions of, and when it is told to stop what it has not loaded, refuses in its check the packages whose manifests give a name in `refusedNames`, and refuses to load the identifiers in `refused`. Every extension it loaded has an action for every tab. Its asynchronous calls change its records on the main actor, as the adapters change their state on the main thread, so the tests read them there without a race.
final class RecordingEngine: EngineExtensions {
    weak var delegate: (any EngineExtensionsDelegate)?
    private(set) var loaded: [String: EngineExtension] = [:]
    /// How often each identifier loaded.
    private(set) var loadCounts: [String: Int] = [:]
    private(set) var checkCount = 0
    private(set) var removedData: [String] = []
    /// The loads and storage deletions in order, as `load <id>` and `removeData <id>`.
    private(set) var loadsAndRemovals: [String] = []
    /// The identifiers whose actions ran, in order.
    private(set) var performed: [String] = []
    /// The identifiers that the user allowed on a tab's site, in order.
    private(set) var grantedSiteAccess: [String] = []
    /// The identifiers unloaded, in order, whether or not they were loaded.
    private(set) var unloads: [String] = []
    /// Called with each identifier as it unloads, for a test that checks what is true at that moment.
    var onUnload: ((String) -> Void)?
    /// For each call of `stopUnloadedExtensions()`, the identifiers loaded at that moment.
    private(set) var stopsWhileLoaded: [Set<String>] = []
    /// Whether the actions say that the engine kept the extension from the tab's site.
    var actionsWantSiteAccess = false
    var refusedNames: Set<String> = []
    var refused: Set<String> = []
    /// Runs as each check starts, for a test that acts while a package is checked.
    var onCheck: (@MainActor () -> Void)?

    @MainActor
    func check(_ packageURL: URL) async throws {
        checkCount += 1
        onCheck?()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))) as? [String: Any]
        if let name = manifest?["name"] as? String, refusedNames.contains(name) { throw RecordingEngineError.refused }
    }

    @MainActor
    func load(_ extension: EngineExtension) async throws {
        guard !refused.contains(`extension`.id) else { throw RecordingEngineError.refused }
        loaded[`extension`.id] = `extension`
        loadCounts[`extension`.id, default: 0] += 1
        loadsAndRemovals.append("load \(`extension`.id)")
    }

    func unload(_ id: String) {
        loaded[id] = nil
        unloads.append(id)
        onUnload?(id)
    }

    @MainActor
    func removeData(of id: String) async {
        removedData.append(id)
        loadsAndRemovals.append("removeData \(id)")
    }

    func stopUnloadedExtensions() {
        stopsWhileLoaded.append(Set(loaded.keys))
    }

    func action(of id: String, for tab: any EngineWebContents) -> EngineExtensionAction? {
        loaded[id] == nil ? nil : EngineExtensionAction(label: "Action", icon: nil, badgeText: "", isEnabled: true, wantsSiteAccess: actionsWantSiteAccess)
    }

    func performAction(of id: String, for tab: any EngineWebContents) {
        performed.append(id)
    }

    func grantSiteAccess(of id: String, for tab: any EngineWebContents) {
        grantedSiteAccess.append(id)
    }

    func setWindows(_ windows: [EngineExtensionWindow], focusedWindowID: UUID?) {}
}

enum RecordingEngineError: LocalizedError {
    case refused

    var errorDescription: String? { "The engine refused it." }
}

/// A WebKit profile of its own with a persistent store, in whose tabs WebKit runs content scripts, as it does in no private profile.
@MainActor
final class WebKitProfile {
    private static let configuration = EngineApplicationConfiguration(userDataDirectory: FileManager.default.temporaryDirectory, cacheDirectory: FileManager.default.temporaryDirectory)
    private let application: any EngineApplication
    private let browser: any EngineBrowser
    let context: any EngineBrowserContext

    private init(storage: UUID) throws {
        application = try WebKitEngine().makeApplication(configuration: Self.configuration)
        var created: (any EngineBrowserContext)?
        application.createBrowserContext(storageIdentifier: storage) { created = try? $0.get() }
        context = try #require(created)
        browser = application.createBrowser(context: context)
    }

    func makeTab(at url: URL? = nil) -> WebKitWebContents {
        // The profile's browser makes WebKit web contents.
        browser.createWebContents(EngineWebContentsConfiguration(initialURL: url)) as! WebKitWebContents
    }

    /// Runs `body` with a new profile, then deletes the profile's website data and its extensions' data. WebKit deletes a store only while nothing in the process uses it, so `body` keeps everything that holds the profile, and the deletion waits up to five seconds for WebKit to let the store go. A store that is still in use then fails the test, as a tab that outlives `body` in the suite's own properties keeps it.
    static func run(_ body: (WebKitProfile) async throws -> Void) async throws {
        let storage = UUID()
        var failure: (any Error)?
        do {
            try await body(WebKitProfile(storage: storage))
        } catch {
            failure = error
        }
        var removed = false
        for _ in 0..<50 {
            removed = await removeData(of: storage)
            if removed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if !removed { Issue.record("WebKit kept the website data store \(storage.uuidString), which something that outlives the test still uses.") }
        // WebKit also keeps a state file for each extension it loaded, which no public call removes, in a folder named after the store.
        let webKitFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/\(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)")
        try? FileManager.default.removeItem(at: webKitFolder.appendingPathComponent("WebExtensions/\(storage.uuidString)"))
        if let failure { throw failure }
    }

    private static func removeData(of storage: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            WebKitEngine().removeStoredData(forStorage: storage, configuration: configuration) { continuation.resume(returning: $0) }
        }
    }
}

/// Waits up to `seconds` for `condition`, checking every tenth of a second, and reports whether it held.
@MainActor
func eventually(within seconds: Double = 10, _ condition: () async throws -> Bool) async rethrows -> Bool {
    for _ in 0..<Int(seconds * 10) {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return try await condition()
}
