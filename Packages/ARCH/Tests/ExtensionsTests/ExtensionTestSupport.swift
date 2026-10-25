// What the web extension tests share: the sample extension, temporary folders, a plugin manager whose secrets stay out of the Keychain, a host that records what the runtime asks of the browser, and an engine that records what the runtime loads.
import AppKit
import ARCHEngine
import ARCHEngineWebKit
@testable import Extensions
import Foundation
@testable import Plugins
import Testing

/// The sample web extension's package folder.
let sampleExtensionFolder = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Sample", isDirectory: true).absoluteURL

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

/// A browser that gives the runtime its engines and records the popups and sheets the runtime asks it to show. Sheets get the answer the test chose.
@MainActor
final class RecordingHost: WebExtensionHost {
    var engines: [any EngineExtensions] = []
    var tabs: [UUID: any EngineWebContents] = [:]
    private(set) var popups: [NSPopover] = []
    private(set) var sheets: [NSAlert] = []
    var sheetAnswer = NSApplication.ModalResponse.alertFirstButtonReturn

    func extensionEngines(in persona: PersonaID) -> [any EngineExtensions] { engines }
    func webContents(ofTab id: UUID) -> (any EngineWebContents)? { tabs[id] }
    func activate(_ tab: any EngineWebContents) {}
    func close(_ tab: any EngineWebContents) {}

    func present(_ popup: NSPopover, for tab: (any EngineWebContents)?) -> Bool {
        popups.append(popup)
        return true
    }

    func presentSheet(_ alert: NSAlert, for tab: (any EngineWebContents)?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        sheets.append(alert)
        completion(sheetAnswer)
    }
}

/// An engine that records what the runtime loads, unloads, and deletes, and refuses to load the identifiers in `refused`.
final class RecordingEngine: EngineExtensions {
    weak var delegate: (any EngineExtensionsDelegate)?
    private(set) var loaded: [String: EngineExtension] = [:]
    private(set) var removedData: [String] = []
    var refused: Set<String> = []

    func load(_ extension: EngineExtension) async throws {
        guard !refused.contains(`extension`.id) else { throw RecordingEngineError.refused }
        loaded[`extension`.id] = `extension`
    }

    func unload(_ id: String) {
        loaded[id] = nil
    }

    func removeData(of id: String) async {
        removedData.append(id)
    }

    func action(of id: String, for tab: any EngineWebContents) -> EngineExtensionAction? {
        loaded[id] == nil ? nil : EngineExtensionAction(label: "Action", icon: nil, badgeText: "", isEnabled: true)
    }

    func performAction(of id: String, for tab: any EngineWebContents) {}

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
    private let browserDelegate = NoBrowserDelegate()
    let context: any EngineBrowserContext

    private init(storage: UUID) throws {
        application = try WebKitEngine().makeApplication(configuration: Self.configuration)
        var created: (any EngineBrowserContext)?
        application.createBrowserContext(EngineBrowserContextAttributes(id: EngineBrowserContextID(rawValue: storage.uuidString), userVisibleName: "Test", type: .regular,
                                                                        storageIdentifier: storage)) { created = try? $0.get() }
        context = try #require(created)
        browser = application.createBrowser(EngineBrowserCreateParams(initialBounds: .zero), context: context, delegate: browserDelegate, window: nil)
    }

    func makeTab() -> WebKitWebContents {
        // The profile's browser makes WebKit web contents.
        browser.createWebContents(EngineWebContentsConfiguration()) as! WebKitWebContents
    }

    /// Runs `body` with a new profile, then deletes the profile's website data and its extensions' data. WebKit deletes a store only while nothing in the process uses it, so `body` keeps everything that holds the profile, and the deletion waits for WebKit to let the store go.
    static func run(_ body: (WebKitProfile) async throws -> Void) async throws {
        let storage = UUID()
        var failure: (any Error)?
        do {
            try await body(WebKitProfile(storage: storage))
        } catch {
            failure = error
        }
        for _ in 0..<50 where await !removeData(of: storage) {
            try await Task.sleep(for: .milliseconds(100))
        }
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

    private final class NoBrowserDelegate: EngineBrowserDelegate {}
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
