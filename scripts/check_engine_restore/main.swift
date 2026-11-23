// Run by run.py in three separate processes, sharing one disposable browser profile.
import AppKit
import ARCHEngine
@testable import ARCHEngineChromium
import ARCHEngineWebKit
@testable import Browsing
import CEFBridge
import CryptoKit
import Foundation

private struct CheckFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private let personaName = "Restore fixture"

@MainActor private final class RestoreCheck: NSObject, NSApplicationDelegate {
    let root = Bundle.main.bundleURL.deletingLastPathComponent()
    var fixture: URL { root.appendingPathComponent("fixture.html") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await check()
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("Engine restore check failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    private func check() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = Int(environment["ARCH_RESTORE_PHASE"] ?? ""), (1...3).contains(phase),
              let bundle = Bundle.main.bundleIdentifier, bundle.hasPrefix("xyz.taeyoon.arch.engine-restore-check."),
              bundle == environment["ARCH_RESTORE_BUNDLE"],
              CommandLine.arguments.contains("--use-mock-keychain") else {
            throw CheckFailure("Launch the check with scripts/check_engine_restore/run.py.")
        }
        try checkIsolation()
        try checkHidden()
        let expected: EngineKind = phase == 2 ? .webKit : .chromium
        let registry = EngineRegistry()
        registry.register(WebKitEngine())
        if expected == .chromium {
            let frameworks = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks")
            let framework = frameworks.appendingPathComponent("Chromium Embedded Framework.framework")
            let helper = frameworks.appendingPathComponent("Arch Helper.app/Contents/MacOS/Arch Helper")
            guard let chromium = ChromiumEngine(frameworkPath: framework.path, helperPath: helper.path) else {
                throw CheckFailure("The supplied app has no Chromium framework.")
            }
            registry.register(chromium)
        }
        let profile = root.appendingPathComponent("profile-alias", isDirectory: true)
        let keyData = try Data(contentsOf: root.appendingPathComponent("session-key"))
        guard keyData.count == 32 else { throw CheckFailure("Missing disposable session key.") }
        let session = try BrowserSession(registry: registry, userDataDirectory: profile, builtInPlugins: [], cefVersion: nil,
                                         sessionSeal: SessionStateSeal { SymmetricKey(data: keyData) },
                                         removeLiveFolderKeychainItems: {})
        let configuration = EngineApplicationConfiguration(userDataDirectory: profile, cacheDirectory: profile.appendingPathComponent("Cache"))
        let firstID = root.appendingPathComponent("first-id")
        let tab: Tab
        if phase == 1 {
            let persona = session.addPersona(named: personaName)
            guard let space = session.spaces.first(where: { $0.resolvedPersonaID == persona.id }) else { throw CheckFailure("The new Persona has no space.") }
            guard !FileManager.default.fileExists(atPath: configuration.chromiumProfile(forStorage: persona.id).path) else {
                throw CheckFailure("The first launch needs a fresh Chromium Persona directory.")
            }
            try checkInvalidProfilePaths(in: configuration.chromiumRootCache)
            tab = session.openTab(url: fixture, in: space.id, pinned: true, select: false, engine: .chromium)
            try tab.id.uuidString.write(to: firstID, atomically: true, encoding: .utf8)
        } else {
            let id = try String(contentsOf: firstID, encoding: .utf8)
            guard let saved = session.tabs.first(where: { $0.id.uuidString == id }), saved.isPinned, !saved.isLoaded else {
                throw CheckFailure("The saved pinned tab did not restore as an unloaded tab.")
            }
            guard FileManager.default.fileExists(atPath: configuration.chromiumProfile(forStorage: saved.personaID).path) else {
                throw CheckFailure("The original Chromium Persona directory is missing.")
            }
            tab = saved
            session.loadPage(of: tab)
        }

        guard session.personas.first(where: { $0.name == personaName && !$0.isDefault })?.id == tab.personaID else {
            throw CheckFailure("The pinned tab lost its non-default Persona.")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = tab.webContents.view
        defer { window.contentView = nil }
        try await waitForFixture(in: tab)
        let correctRenderer = expected == .chromium ? tab.webContents is ChromiumWebContents : tab.webContents is WebKitWebContents
        guard correctRenderer, tab.engineKind == expected, tab.preferredEngine == .chromium else {
            throw CheckFailure("Phase \(phase) used \(tab.engineKind.rawValue) and preferred \(tab.preferredEngine.rawValue).")
        }

        if expected == .chromium {
            let script = phase == 1
                ? "() => { localStorage.setItem('arch-restore-id', '\(tab.id)'); return localStorage.getItem('arch-restore-id'); }"
                : "() => localStorage.getItem('arch-restore-id')"
            let marker: String? = try await withCheckedThrowingContinuation { continuation in
                tab.webContents.executeJavaScript(script, inWorld: "ArchRestoreCheck") { continuation.resume(with: $0) }
            }
            guard marker == tab.id.uuidString else { throw CheckFailure("The named Chromium profile did not keep its fixture's local storage.") }
        }

        try session.saveNow().get()
        let record = try Data(contentsOf: profile.appendingPathComponent("session.json"))
        let snapshot = try JSONSerialization.jsonObject(with: record) as? [String: Any]
        let rows = snapshot?["tabs"] as? [[String: Any]]
        guard let row = rows?.first(where: { ($0["id"] as? String)?.lowercased() == tab.id.uuidString.lowercased() }),
              row["isPinned"] as? Bool == true, row["engine"] as? String == "chromium" else {
            throw CheckFailure("The saved tab lost its pin or Chromium choice.")
        }
        let result = ["id": tab.id.uuidString, "active": tab.engineKind.rawValue]
        let resultURL = root.appendingPathComponent("result-\(phase).json")
        session.finishWritesAtQuit()
        session.history.finishWrites()
        try checkHidden()
        try JSONEncoder().encode(result).write(to: resultURL)
        print("Phase \(phase) · \(tab.id) · \(type(of: tab.webContents)) · persisted chromium")
        fflush(stdout)
    }

    private func checkInvalidProfilePaths(in cache: URL) throws {
        let manager = FileManager.default
        let link = cache.appendingPathComponent("LinkedProfile")
        try manager.createSymbolicLink(at: link, withDestinationURL: root)
        let invalid = [root.appendingPathComponent("NotAProfile").path, cache.path + "/Default/../Escapes", link.path]
        guard invalid.allSatisfy({ ARCHCEFRequestContext(cachePath: $0) == nil }) else {
            throw CheckFailure("A path outside the cache root, a traversal, or a linked profile was accepted.")
        }
    }

    private func checkIsolation() throws {
        let manager = FileManager.default
        let home = root.appendingPathComponent("home", isDirectory: true).resolvingSymlinksInPath().path
        let temp = root.appendingPathComponent("temp", isDirectory: true).resolvingSymlinksInPath().path
        guard manager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == home else { throw CheckFailure("The home directory is not isolated.") }
        // Foundation may return the macOS per-user temp directory even with a private TMPDIR.
        guard let environmentTemp = ProcessInfo.processInfo.environment["TMPDIR"],
              URL(fileURLWithPath: environmentTemp).resolvingSymlinksInPath().path == temp else {
            throw CheckFailure("The fixture has no private temporary directory.")
        }
        guard manager.fileExists(atPath: fixture.path) else { throw CheckFailure("Missing local fixture.") }
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory, .libraryDirectory] {
            guard let url = manager.urls(for: directory, in: .userDomainMask).first,
                  url.resolvingSymlinksInPath().path.hasPrefix(home + "/") else { throw CheckFailure("Unisolated library path.") }
        }
    }

    private func checkHidden() throws {
        guard NSApp.activationPolicy() == .prohibited, !NSApp.isActive, !NSApp.windows.contains(where: \.isVisible) else {
            throw CheckFailure("The fixture must remain inactive with no visible windows.")
        }
    }

    private func waitForFixture(in tab: Tab) async throws {
        let deadline = ContinuousClock.now + .seconds(22)
        while ContinuousClock.now < deadline {
            try checkHidden()
            if tab.url?.standardizedFileURL == fixture.standardizedFileURL, tab.title == "Arch offline restore" {
                let result: Result<EngineReadableContent, Error> = await withCheckedContinuation { continuation in
                    tab.webContents.readableContent(limit: 1000) { continuation.resume(returning: $0) }
                }
                if (try? result.get().text.contains("Local renderer sentinel")) == true { return }
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw CheckFailure("The renderer did not read the offline page.")
    }
}

MainActor.assumeIsolated {
    let application = ARCHCEFApplication.shared
    application.setActivationPolicy(.prohibited)
    let delegate = RestoreCheck()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
