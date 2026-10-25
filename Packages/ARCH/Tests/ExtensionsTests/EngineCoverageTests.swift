// Which engines run each web extension's package: the checks at staging, of the installed plugin a package updates, and before loads without a current answer, `engineChecks` in `plugins.json` with each engine's version and the names this build does not know, loading only where a package runs, failures to start kept to their engine, the kind unavailable only without an engine, and where the review sheet and Settings say a plugin runs. A recording engine stands in for Chromium.
import ARCHEngine
@testable import Extensions
import Foundation
@testable import Plugins
import Testing

@MainActor
@Suite(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
struct EngineCoverageTests {
    private let folder = TemporaryFolder()
    private let host = RecordingHost()
    private let persona = UUID()
    private let webKit = RecordingEngine()
    private let chromium = RecordingEngine()

    init() {
        host.engines = [.webKit: webKit, .chromium: chromium]
        host.versions = [.webKit: "W1", .chromium: "C1"]
    }

    /// The sample's engine identifier, which comes from its folder's path, as it has no key.
    private var sampleID: String { try! WebExtensionManifest.extensionID(key: nil, source: sampleExtensionFolder) }

    /// A manager of the test's Persona, as a launch makes it, whose web extensions run in a new runtime with the host's engines.
    private func launch() -> (PluginManager, WebExtensionRuntime) {
        let runtime = WebExtensionRuntime(persona: persona, host: host, nativeMessagingHosts: folder.url)
        return (PluginManager(persona: persona, directory: folder.url, builtIns: [], runtimes: [runtime], secretStore: NoSecrets()), runtime)
    }

    /// New engines for the next launch, at the versions given: WebKit's, then Chromium's.
    private func replaceEngines(webKit webKitVersion: String, chromium chromiumVersion: String) -> (RecordingEngine, RecordingEngine) {
        let engines = (RecordingEngine(), RecordingEngine())
        host.engines = [.webKit: engines.0, .chromium: engines.1]
        host.versions = [.webKit: webKitVersion, .chromium: chromiumVersion]
        return engines
    }

    private var listURL: URL { folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/plugins.json") }

    /// The first install entry of `plugins.json`.
    private func installEntry() throws -> [String: Any] {
        let list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: listURL)) as? [String: Any])
        return try #require((list["installed"] as? [[String: Any]])?.first)
    }

    private func editInstallEntry(_ edit: (inout [String: Any]) -> Void) throws {
        var list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: listURL)) as? [String: Any])
        var entries = try #require(list["installed"] as? [[String: Any]])
        edit(&entries[0])
        list["installed"] = entries
        try JSONSerialization.data(withJSONObject: list).write(to: listURL)
    }

    /// The entry's answers, as `engine: "runs version"`.
    private func fileChecks() throws -> [String: String] {
        let checks = try #require(try installEntry()["engineChecks"] as? [String: [String: Any]])
        return checks.mapValues { "\($0["runs"] as? Bool ?? false) \($0["version"] as? String ?? "")" }
    }

    @Test func recordsEachEngineCheckAtStagingAndInstall() async throws {
        chromium.refusedNames = ["Sample Extension"]
        let (manager, runtime) = launch()
        let package = try await manager.stage(sampleExtensionFolder)
        #expect(package.engineChecks == [.webKit: .runs, .chromium: .refused("Chromium cannot run this extension: The engine refused it.")])
        #expect(package.engineNotes == ["Runs on WebKit tabs.", "Chromium cannot run this extension: The engine refused it."])
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let installed = try #require(manager.plugins.first)
        #expect(installed.engineChecks == [.webKit: true, .chromium: false] && installed.engines == [.webKit])
        #expect(installed.enginesNote == "Runs on WebKit tabs.")
        #expect(try fileChecks() == ["webKit": "true W1", "chromium": "false C1"])
        await runtime.waitForEngines()
        // The install's answers are current, so the engines check nothing more before loading, and only WebKit loads it.
        #expect(webKit.checkCount == 1 && chromium.checkCount == 1)
        #expect(webKit.loaded[sampleID] != nil && chromium.loaded[sampleID] == nil)
    }

    @Test func refusesAPackageThatEveryEngineRefuses() async throws {
        webKit.refusedNames = ["Sample Extension"]
        chromium.refusedNames = ["Sample Extension"]
        let (manager, _) = launch()
        await #expect(throws: PluginError.invalidPackage("WebKit cannot run this extension: The engine refused it.")) { try await manager.stage(sampleExtensionFolder) }
        let staging = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/Staging").path
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging)) ?? []).isEmpty)
    }

    @Test func checksAgainBeforeALoadWithoutACurrentAnswer() async throws {
        let (first, firstRuntime) = launch()
        try await first.installEverything(from: sampleExtensionFolder)
        await firstRuntime.waitForEngines()
        first.close()

        // A macOS update changed WebKit's version: only WebKit checks the package again, and the answer is recorded with the new version.
        var (webKit, chromium) = replaceEngines(webKit: "W2", chromium: "C1")
        let (second, secondRuntime) = launch()
        #expect(second.plugins.first?.engineChecks == [.chromium: true])
        await secondRuntime.waitForEngines()
        #expect(webKit.checkCount == 1 && chromium.checkCount == 0)
        #expect(webKit.loaded[sampleID] != nil && chromium.loaded[sampleID] != nil)
        #expect(second.plugins.first?.engineChecks == [.webKit: true, .chromium: true] && second.plugins.first?.enginesNote == "Runs on WebKit and Chromium tabs.")
        #expect(try fileChecks() == ["webKit": "true W2", "chromium": "true C1"])
        // Recording the answer does not load the running copy again.
        #expect(webKit.loadCounts[sampleID] == 1 && chromium.loadCounts[sampleID] == 1)
        second.close()

        // An entry from a build before engine checks reads as checked by no engine, and each engine checks it before loading it.
        try editInstallEntry { $0["engineChecks"] = nil }
        (webKit, chromium) = replaceEngines(webKit: "W2", chromium: "C1")
        let (third, thirdRuntime) = launch()
        #expect(third.plugins.first?.engineChecks == [:] && third.plugins.first?.enginesNote == nil)
        await thirdRuntime.waitForEngines()
        #expect(webKit.checkCount == 1 && chromium.checkCount == 1)
        #expect(webKit.loadCounts[sampleID] == 1 && chromium.loadCounts[sampleID] == 1)
        #expect(try fileChecks() == ["webKit": "true W2", "chromium": "true C1"])
        // Other changes to the enabled plugins do not load it again either.
        try await third.installEverything(from: folder.package("other", ["manifest.json": #"{"manifest_version": 3, "name": "O", "version": "1"}"#]))
        await thirdRuntime.waitForEngines()
        #expect(webKit.loadCounts[sampleID] == 1 && chromium.loadCounts[sampleID] == 1)
    }

    @Test func checksTheInstalledPluginThatAPackageUpdatesAtStaging() async throws {
        let (first, _) = launch()
        try await first.installEverything(from: sampleExtensionFolder, isEnabled: false)
        first.close()
        try editInstallEntry { $0["engineChecks"] = nil }
        let (webKit, chromium) = replaceEngines(webKit: "W1", chromium: "C1")
        let (second, runtime) = launch()
        await runtime.waitForEngines()
        // Switched off, it is not checked until staging needs its answers.
        #expect(webKit.checkCount == 0 && second.plugins.first?.engineChecks == [:])
        let update = try await second.stage(sampleExtensionFolder)
        #expect(second.plugins.first?.engineChecks == [.webKit: true, .chromium: true])
        #expect(try fileChecks() == ["webKit": "true W1", "chromium": "true C1"])
        #expect(webKit.checkCount == 2 && chromium.checkCount == 2)
        #expect(update.engineChecks == [.webKit: .runs, .chromium: .runs])
        second.discard(update)
    }

    @Test func switchesOffAPluginThatNoEngineRunsAnyMore() async throws {
        let (first, firstRuntime) = launch()
        try await first.installEverything(from: sampleExtensionFolder)
        await firstRuntime.waitForEngines()
        first.close()
        let (webKit, chromium) = replaceEngines(webKit: "W2", chromium: "C2")
        webKit.refusedNames = ["Sample Extension"]
        chromium.refusedNames = ["Sample Extension"]
        let (second, runtime) = launch()
        await runtime.waitForEngines()
        let plugin = try #require(second.plugins.first)
        #expect(!plugin.isEnabled && plugin.failure == "WebKit cannot run this extension: The engine refused it.")
        #expect(plugin.engineChecks == [.webKit: false, .chromium: false] && plugin.enginesNote == "No engine on this Mac runs it.")
        #expect(webKit.loaded.isEmpty && chromium.loaded.isEmpty)
        #expect(try fileChecks() == ["webKit": "false W2", "chromium": "false C2"])
    }

    @Test func keepsAFailureToStartToItsEngine() async throws {
        chromium.refused = [sampleID]
        let (manager, runtime) = launch()
        let installed = try await manager.installEverything(from: sampleExtensionFolder)
        await runtime.waitForEngines()
        var plugin = try #require(manager.plugins.first)
        #expect(plugin.isEnabled && plugin.failure == nil)
        #expect(plugin.engineFailures == [.chromium: "Arch could not start it on Chromium tabs: The engine refused it."] && plugin.engines == [.webKit])
        #expect(plugin.enginesNote == "Runs on WebKit tabs.")
        #expect(webKit.loaded[sampleID] != nil && chromium.loaded[sampleID] == nil)
        // The failure lasts for the run only.
        #expect(try String(contentsOf: listURL, encoding: .utf8).contains("could not start") == false)

        // Switching the plugin on again tries the engine again.
        chromium.refused = []
        manager.setEnabled(false, for: installed.id)
        await runtime.waitForEngines()
        manager.setEnabled(true, for: installed.id)
        await runtime.waitForEngines()
        plugin = try #require(manager.plugins.first)
        #expect(plugin.engineFailures.isEmpty && plugin.engines == [.webKit, .chromium] && chromium.loaded[sampleID] != nil)

        // Failing on every engine it runs on switches it off with each engine's reason.
        webKit.refused = [sampleID]
        chromium.refused = [sampleID]
        manager.setEnabled(false, for: installed.id)
        await runtime.waitForEngines()
        manager.setEnabled(true, for: installed.id)
        await runtime.waitForEngines()
        plugin = try #require(manager.plugins.first)
        #expect(!plugin.isEnabled)
        #expect(plugin.failure == "Arch could not start it on WebKit tabs: The engine refused it.\nArch could not start it on Chromium tabs: The engine refused it.")
        #expect(webKit.loaded.isEmpty && chromium.loaded.isEmpty)
    }

    @Test func isUnavailableOnlyWithoutAnEngine() async throws {
        host.engines = [:]
        let (without, _) = launch()
        let package = try await without.stage(sampleExtensionFolder)
        #expect(package.engineChecks.isEmpty && package.engineNotes.isEmpty)
        try without.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        #expect(without.plugins.first?.unavailability == "No engine on this Mac runs web extensions.")
        #expect(try installEntry()["engineChecks"] == nil)
        without.close()

        // Chromium alone runs them, as on a Mac below macOS 15.4 after VI.1.
        host.engines = [.chromium: chromium]
        let (withChromium, runtime) = launch()
        #expect(withChromium.plugins.first?.unavailability == nil)
        await runtime.waitForEngines()
        #expect(chromium.loaded[sampleID] != nil && withChromium.plugins.first?.enginesNote == "Runs on Chromium tabs.")
    }

    @Test func keepsEngineNamesThisBuildDoesNotKnow() async throws {
        let (first, firstRuntime) = launch()
        let installed = try await first.installEverything(from: sampleExtensionFolder)
        await firstRuntime.waitForEngines()
        first.close()
        try editInstallEntry { entry in
            var checks = entry["engineChecks"] as? [String: Any] ?? [:]
            checks["future"] = ["runs": true, "version": "F1"]
            entry["engineChecks"] = checks
        }
        _ = replaceEngines(webKit: "W2", chromium: "C1")
        let (second, runtime) = launch()
        #expect(second.plugins.map(\.id) == [installed.id] && second.plugins.first?.engineChecks == [.chromium: true])
        // WebKit's new answer and a switch both write the file.
        await runtime.waitForEngines()
        second.setEnabled(false, for: installed.id)
        #expect(try fileChecks() == ["webKit": "true W2", "chromium": "true C1", "future": "true F1"])
    }
}
