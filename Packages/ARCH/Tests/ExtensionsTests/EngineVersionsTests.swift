// Engine versions of one web extension plugin: the pairing rule at staging, the review's choice, update targets, entry identifiers of versions that share an identifier, pairs made from the review and by hand, their switch, failures, actions, and palette command, separation, removal of one version, records the build ignores, and when a plugin asks for another engine's version. A recording engine stands in for Chromium.
import AppKit
import ARCHEngine
@testable import Extensions
import Foundation
@testable import Plugins
import Testing

@MainActor
@Suite(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
struct EngineVersionsTests {
    private let folder = TemporaryFolder()
    private let host = RecordingHost()
    private let persona = UUID()
    private let webKit = RecordingEngine()
    private let chromium = RecordingEngine()
    /// A public key as Base64 text, which gives packages one identifier.
    private let key = Data("reader key".utf8).base64EncodedString()

    init() {
        host.engines = [.webKit: webKit, .chromium: chromium]
        host.versions = [.webKit: "W1", .chromium: "C1"]
    }

    /// The engine identifier of the packages with `key`.
    private var keyID: String { WebExtensionManifest.extensionID(ofBytes: Data(base64Encoded: key)!) }

    /// A manager of the test's Persona, as a launch makes it, whose web extensions run in a new runtime with the host's engines.
    private func launch() -> (PluginManager, WebExtensionRuntime) {
        let runtime = WebExtensionRuntime(persona: persona, host: host, nativeMessagingHosts: folder.url)
        return (PluginManager(persona: persona, directory: folder.url, builtIns: [], runtimes: [runtime], secretStore: NoSecrets()), runtime)
    }

    /// Writes a package into its own folder, or over the one of the same name.
    private func package(_ folderName: String, name: String, version: String = "1", key: String? = nil, author: Any? = nil, homepage: String? = nil,
                         permissions: [String] = [], action: Bool = false) throws -> URL {
        var manifest: [String: Any] = ["manifest_version": 3, "name": name, "version": version, "permissions": permissions]
        if let key { manifest["key"] = key }
        if let author { manifest["author"] = author }
        if let homepage { manifest["homepage_url"] = homepage }
        if action { manifest["action"] = ["default_title": name] }
        return try folder.package(folderName, ["manifest.json": String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self)])
    }

    private var listURL: URL { folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/plugins.json") }

    private func list() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: listURL)) as? [String: Any])
    }

    private func editList(_ edit: (inout [String: Any]) -> Void) throws {
        var list = try list()
        edit(&list)
        try JSONSerialization.data(withJSONObject: list).write(to: listURL)
    }

    private func plugin(_ id: PluginID, in manager: PluginManager) throws -> InstalledPlugin {
        try #require(manager.plugins.first { $0.id == id })
    }

    /// Installs "Reader", which only WebKit runs, and then "Reader for Chromium" with the same key, which only Chromium runs, as its Chromium version. Returns the two plugins' identifiers.
    private func installComplementaryPair(in manager: PluginManager, chromiumPermissions: [String] = []) async throws -> (webKit: PluginID, chromium: PluginID) {
        chromium.refusedNames.insert("Reader")
        webKit.refusedNames.insert("Reader for Chromium")
        let reader = try await manager.installEverything(from: package("reader", name: "Reader", key: key, action: true))
        let other = try await manager.stage(package("reader-chromium", name: "Reader for Chromium", key: key, permissions: chromiumPermissions, action: true))
        #expect(other.counterpart == reader.id && other.joinableEngines == [.chromium] && other.suggestedEngine == .chromium && other.updates == reader.id)
        let id = try manager.install(other, grant: PluginGrant(requestedBy: other.manifest), isEnabled: false, asVersionOf: reader.id, for: .chromium)
        return (reader.id, id)
    }

    // MARK: Pairing rule

    @Test func matchesByIdentifierAndByNameWithADeveloperField() async throws {
        let (manager, _) = launch()
        let reader = try await manager.installEverything(from: package("reader", name: "Reader", key: key, author: "Dev@Example.org", homepage: "https://www.example.org/reader/"))
        let tool = try await manager.installEverything(from: package("tool", name: "Tool", homepage: "https://github.com/a/tool"))
        func counterpart(_ name: String, key: String? = nil, author: Any? = nil, homepage: String? = nil) async throws -> PluginID? {
            let staged = try await manager.stage(package("candidate", name: name, key: key, author: author, homepage: homepage))
            manager.discard(staged)
            return staged.counterpart
        }
        // By identifier, whatever the name.
        #expect(try await counterpart("Another Name", key: key) == reader.id)
        // By name, without case and spaces at either end, with a developer field that matches and none that differs.
        #expect(try await counterpart(" reader ", author: "dev@example.org") == reader.id)
        #expect(try await counterpart("Reader", author: ["email": "DEV@example.org"]) == reader.id)
        #expect(try await counterpart("Reader", homepage: "http://example.org/reader") == reader.id)
        // Not by name alone, nor with a developer field that differs.
        #expect(try await counterpart("Reader") == nil)
        #expect(try await counterpart("Reader", author: "dev@example.org", homepage: "https://example.org/other") == nil)
        // Two projects on one hosting site differ by their paths.
        #expect(try await counterpart("Tool", homepage: "https://github.com/b/tool") == nil)
        #expect(try await counterpart("Tool", homepage: "https://github.com/a/tool/") == tool.id)
    }

    @Test func checksAPluginThePackageCouldJoinBeforeMatchingIt() async throws {
        let (first, _) = launch()
        let reader = try await first.installEverything(from: package("reader", name: "Reader", author: "dev@example.org"), isEnabled: false)
        first.close()
        try editList { list in
            var entries = list["installed"] as! [[String: Any]]
            entries[0]["engineChecks"] = nil
            list["installed"] = entries
        }
        chromium.refusedNames = ["Reader"]
        webKit.refusedNames = ["Reader for Chromium"]
        let (second, runtime) = launch()
        await runtime.waitForEngines()
        #expect(try plugin(reader.id, in: second).engineChecks.isEmpty)
        let staged = try await second.stage(package("other", name: "Reader for Chromium", author: "dev@example.org"))
        // The name differs, so the package names another extension; with the same name, the check comes first and decides the engines to join for.
        #expect(staged.counterpart == nil)
        second.discard(staged)
        let same = try await second.stage(package("same", name: "Reader", author: "dev@example.org"))
        #expect(try plugin(reader.id, in: second).engineChecks == [.webKit: true, .chromium: false])
        #expect(same.counterpart == reader.id && same.joinableEngines.isEmpty)
        second.discard(same)
    }

    @Test func startsTheChoiceOnUpdateWhenBothEnginesRunBothPackages() async throws {
        let (manager, runtime) = launch()
        let reader = try await manager.installEverything(from: package("reader", name: "Reader", key: key))
        await runtime.waitForEngines()
        let staged = try await manager.stage(package("reader-chromium", name: "Reader", key: key))
        #expect(staged.counterpart == reader.id && staged.joinableEngines == [.webKit, .chromium] && staged.suggestedEngine == nil && staged.updates == reader.id)
        // Installing it as the Chromium version still works: each engine loads its own version under the one identifier.
        let id = try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: false, asVersionOf: reader.id, for: .chromium)
        #expect(id.rawValue == reader.id.rawValue + ".chromium")
        await runtime.waitForEngines()
        #expect(manager.engineVersions == [PluginEngineVersions([.webKit: reader.id, .chromium: id])])
        #expect(try webKit.loaded[keyID]?.packageURL == reader.packageURL && chromium.loaded[keyID]?.packageURL == plugin(id, in: manager).packageURL)
        // WebKit's copy kept running.
        #expect(webKit.loadCounts[keyID] == 1 && chromium.loadCounts[keyID] == 2)
        #expect(try plugin(id, in: manager).isEnabled && manager.plugins.count == 2)
    }

    @Test func updatesAsBeforeWithoutAnEngineToJoinFor() async throws {
        host.engines = [.webKit: webKit]
        let (manager, _) = launch()
        let reader = try await manager.installEverything(from: package("reader", name: "Reader", key: key, author: "dev@example.org"))
        let update = try await manager.stage(package("reader-2", name: "Reader", version: "2", key: key, author: "dev@example.org"))
        #expect(update.counterpart == reader.id && update.joinableEngines.isEmpty && update.updates == reader.id)
        try manager.install(update, grant: PluginGrant(requestedBy: update.manifest), isEnabled: true)
        #expect(manager.plugins.map(\.manifest.version) == ["2"])
        // Another identifier with the same name and developer installs as its own plugin, and dismisses nothing.
        let other = try await manager.stage(package("other", name: "Reader", author: "dev@example.org"))
        #expect(other.counterpart == reader.id && other.joinableEngines.isEmpty && other.updates == nil)
        let id = try manager.install(other, grant: PluginGrant(requestedBy: other.manifest), isEnabled: true)
        #expect(manager.plugins.count == 2 && manager.plugins.allSatisfy { $0.dismissedVersionNotes.isEmpty } && id == other.manifest.id)
    }

    @Test func takesTheMatchInstalledFirstAndDismissesNotesOfSeparatePlugins() async throws {
        let (manager, _) = launch()
        let first = try await manager.installEverything(from: package("first", name: "Reader", author: "dev@example.org"))
        let staged = try await manager.stage(package("second", name: "Reader", author: "dev@example.org"))
        #expect(staged.counterpart == first.id && staged.joinableEngines == [.webKit, .chromium])
        // Installed as a separate plugin, each one's note for the engines the other runs on is dismissed.
        let second = try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: true)
        #expect(try plugin(first.id, in: manager).dismissedVersionNotes == [.webKit, .chromium])
        #expect(try plugin(second, in: manager).dismissedVersionNotes == [.webKit, .chromium])
        let third = try await manager.stage(package("third", name: "Reader", author: "dev@example.org"))
        #expect(third.counterpart == first.id)
        manager.discard(third)
    }

    // MARK: Versions that share an identifier

    @Test func pairsVersionsThatShareAnIdentifier() async throws {
        let (manager, runtime) = launch()
        let (reader, version) = try await installComplementaryPair(in: manager, chromiumPermissions: ["nativeMessaging"])
        #expect(version.rawValue == "extension.\(keyID).chromium")
        await runtime.waitForEngines()
        // The version takes the pair's switch, and each engine loads its own version.
        #expect(try plugin(version, in: manager).isEnabled && plugin(version, in: manager).counterpart == reader && plugin(reader, in: manager).pairEngine == .webKit)
        #expect(try webKit.loaded[keyID]?.packageURL == plugin(reader, in: manager).packageURL)
        #expect(try chromium.loaded[keyID]?.packageURL == plugin(version, in: manager).packageURL)
        // Each engine's calls reach that engine's version: only the Chromium version has native messaging.
        var reply: Result<Data, any Error>?
        runtime.extensions(webKit, extension: keyID, sendNativeMessage: Data("{}".utf8), toApplication: "org.example.echo") { reply = $0 }
        #expect(throws: PluginError.permissionDenied(.nativeMessaging)) { try reply?.get() }
        runtime.extensions(chromium, extension: keyID, sendNativeMessage: Data("{}".utf8), toApplication: "org.example.echo") { reply = $0 }
        #expect(throws: NativeMessagingError.notFound("org.example.echo")) { try reply?.get() }
        // A request at run time names the pair and the version that asks.
        runtime.extensions(chromium, extension: keyID, requests: [.permission("cookies")], in: nil) { _ in }
        #expect(host.sheets.last?.messageText == "Allow the Chromium version of \u{201C}Reader\u{201D} more access?")
        runtime.extensions(webKit, extension: keyID, requests: [.permission("cookies")], in: nil) { _ in }
        #expect(host.sheets.last?.messageText == "Allow the WebKit version of \u{201C}Reader\u{201D} more access?")
        manager.close()

        // A new manager lists both versions and the pair.
        let (second, _) = launch()
        #expect(second.plugins.map(\.id) == [reader, version] && second.engineVersions == [PluginEngineVersions([.webKit: reader, .chromium: version])])
        second.close()

        // A build before engine versions dropped the record: the version is paired again from its identifier.
        try editList { $0["engineVersions"] = nil }
        let (third, _) = launch()
        #expect(third.engineVersions == [PluginEngineVersions([.webKit: reader, .chromium: version])])
        #expect(try list()["engineVersions"] as? [[String: String]] == [["webKit": reader.rawValue, "chromium": version.rawValue]])

        // An update from the Chromium version's place goes to it.
        let update = try await third.stage(package("reader-chromium", name: "Reader for Chromium", version: "2", key: key))
        #expect(update.updates == version && update.updateChoices.isEmpty && update.counterpart == nil)
        try third.install(update, grant: PluginGrant(requestedBy: update.manifest), isEnabled: true)
        #expect(third.plugins.map(\.manifest.version) == ["1", "2"] && third.engineVersions.count == 1)
    }

    @Test func refusesAPackageWithTheEntryIdentifierOfAVersion() async throws {
        let (manager, _) = launch()
        let (reader, version) = try await installComplementaryPair(in: manager)
        // A script plugin may name itself `extension.<identifier>.chromium`, which the Chromium version's entry has while its package names `extension.<identifier>`.
        let script = try folder.package("script", ["plugin.json": #"{"id": "\#(version.rawValue)", "name": "Tools", "version": "1", "apiVersion": 1, "summary": "T."}"#])
        await #expect(throws: PluginError.invalidPackage("A version of an installed plugin has the identifier \(version.rawValue).")) { try await manager.stage(script) }
        #expect(try plugin(version, in: manager).kind == .webExtension && manager.engineVersions == [PluginEngineVersions([.webKit: reader, .chromium: version])])
    }

    @Test func warnsThatAVersionUnderItsCounterpartsIdentifierTakesOverItsCopy() async throws {
        let (manager, runtime) = launch()
        // Both engines run "Reader", so Chromium has its copy, which keeps its data under the identifier.
        let reader = try await manager.installEverything(from: package("reader", name: "Reader", key: key))
        await runtime.waitForEngines()
        #expect(chromium.loaded[keyID] != nil)
        // From the plugin's own place, nothing warns.
        let same = try await manager.stage(package("reader", name: "Reader", version: "2", key: key))
        #expect(manager.versionTakeover(for: same, joining: reader.id, for: .chromium) == nil)
        manager.discard(same)
        let staged = try await manager.stage(package("elsewhere", name: "Reader", version: "2", key: key))
        #expect(staged.joinableEngines == [.webKit, .chromium])
        #expect(manager.versionTakeover(for: staged, joining: reader.id, for: .chromium)
            == "\u{201C}Reader\u{201D}, which you installed from reader, has this package's identifier, so as its Chromium version the package takes over the data that \u{201C}Reader\u{201D} keeps on Chromium tabs. Join only if both come from the same developer.")
        let id = try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: true, asVersionOf: reader.id, for: .chromium)
        await runtime.waitForEngines()
        // Chromium runs the version under the identifier it knew "Reader" by, with the data that "Reader"'s copy left there.
        #expect(try chromium.loaded[keyID]?.packageURL == plugin(id, in: manager).packageURL && chromium.removedData.isEmpty && webKit.loaded[keyID]?.packageURL == reader.packageURL)

        // A plugin whose package Chromium refuses has no copy there to take over.
        let notesKey = Data("notes key".utf8).base64EncodedString()
        chromium.refusedNames = ["Notes"]
        webKit.refusedNames = ["Notes for Chromium"]
        let notes = try await manager.installEverything(from: package("notes", name: "Notes", key: notesKey))
        let notesVersion = try await manager.stage(package("notes-chromium", name: "Notes for Chromium", key: notesKey))
        #expect(notesVersion.suggestedEngine == .chromium && manager.versionTakeover(for: notesVersion, joining: notes.id, for: .chromium) == nil)
        manager.discard(notesVersion)
    }

    @Test func sendsAnUpdateToTheSameSourceThenTheSameAnswersThenTheChoice() async throws {
        let (manager, _) = launch()
        let (reader, version) = try await installComplementaryPair(in: manager)
        let fromSource = try await manager.stage(package("reader", name: "Reader for Chromium", version: "2", key: key))
        #expect(fromSource.updates == reader && fromSource.updateChoices.isEmpty)
        manager.discard(fromSource)
        // From another place, the answers decide: WebKit alone runs "Reader", as it runs the WebKit version.
        let sameAnswers = try await manager.stage(package("elsewhere", name: "Reader", version: "2", key: key))
        #expect(sameAnswers.updates == reader && sameAnswers.updateChoices.isEmpty)
        manager.discard(sameAnswers)
        // Both engines run this one, so the review chooses.
        let either = try await manager.stage(package("elsewhere", name: "Reader Everywhere", version: "2", key: key))
        #expect(either.updates == reader && either.updateChoices == [reader, version])
        var chosen = either
        chosen.updates = version
        try manager.install(chosen, grant: PluginGrant(requestedBy: chosen.manifest), isEnabled: true)
        #expect(try plugin(version, in: manager).manifest.name == "Reader Everywhere" && plugin(reader, in: manager).manifest.version == "1")
    }

    @Test func refusesAnUpdateThatLeavesAVersionOnNoEngine() async throws {
        let (manager, _) = launch()
        let (_, version) = try await installComplementaryPair(in: manager)
        // From the Chromium version's place, but a package that Chromium refuses.
        let update = try await manager.stage(package("reader-chromium", name: "Reader", version: "2", key: key))
        #expect(update.updates == version)
        let refusal = "Chromium cannot run this package, and the other version of \u{201C}Reader\u{201D} runs on WebKit tabs."
        #expect(manager.updateRefusal(for: update) == refusal)
        #expect(throws: PluginError.invalidPackage(refusal)) { try manager.install(update, grant: PluginGrant(requestedBy: update.manifest), isEnabled: true) }
        #expect(try plugin(version, in: manager).manifest.version == "1")
        manager.discard(update)
    }

    @Test func refusesAVersionThatCannotJoin() async throws {
        let (manager, _) = launch()
        chromium.refusedNames = ["Reader", "Refused"]
        let reader = try await manager.installEverything(from: package("reader", name: "Reader"))
        let refused = try await manager.stage(package("refused", name: "Refused"))
        #expect(manager.versionRefusal(for: refused, joining: reader.id, for: .chromium) == "Chromium cannot run this extension: The engine refused it.")
        #expect(throws: PluginError.self) { try manager.install(refused, grant: PluginGrant(requestedBy: refused.manifest), isEnabled: true, asVersionOf: reader.id, for: .chromium) }
        // A package with the identifier of another installed plugin cannot join here.
        let other = try await manager.installEverything(from: package("other", name: "Other", key: key))
        let sameKey = try await manager.stage(package("same-key", name: "Other", version: "2", key: key))
        #expect(manager.versionRefusal(for: sameKey, joining: reader.id, for: .chromium)?.hasPrefix("Another installed plugin has this package's identifier") == true)
        #expect(manager.plugins.map(\.id) == [reader.id, other.id] && manager.engineVersions.isEmpty)
        manager.discard(refused)
        manager.discard(sameKey)
    }

    // MARK: Pairs

    @Test func switchesBothVersionsAndKeepsAFailureToOne() async throws {
        let (manager, runtime) = launch()
        let (reader, version) = try await installComplementaryPair(in: manager)
        // The version took the pair's switch, which turns both versions on or off.
        #expect(manager.plugins.allSatisfy { $0.isEnabled })
        manager.setEnabled(false, for: version)
        #expect(manager.plugins.allSatisfy { !$0.isEnabled })
        await runtime.waitForEngines()
        #expect(webKit.loaded.isEmpty && chromium.loaded.isEmpty)
        manager.setEnabled(true, for: reader)
        #expect(manager.plugins.allSatisfy { $0.isEnabled })
        await runtime.waitForEngines()
        // One version's failure to start switches it off alone, with why, while the other keeps running.
        chromium.refused = [keyID]
        manager.setEnabled(false, for: reader)
        await runtime.waitForEngines()
        manager.setEnabled(true, for: reader)
        await runtime.waitForEngines()
        #expect(try !plugin(version, in: manager).isEnabled && plugin(version, in: manager).failure == "Arch could not start it on Chromium tabs: The engine refused it.")
        #expect(try plugin(reader, in: manager).isEnabled && webKit.loaded[keyID] != nil && chromium.loaded.isEmpty)
        // The pair's switch brings it back.
        chromium.refused = []
        manager.setEnabled(false, for: reader)
        manager.setEnabled(true, for: reader)
        await runtime.waitForEngines()
        #expect(try plugin(version, in: manager).isEnabled && chromium.loaded[keyID] != nil)

        // A version that joins a switched-off plugin is off too.
        let otherKey = Data("off key".utf8).base64EncodedString()
        chromium.refusedNames.insert("Off")
        webKit.refusedNames.insert("Off for Chromium")
        let off = try await manager.installEverything(from: package("off", name: "Off", key: otherKey), isEnabled: false)
        let staged = try await manager.stage(package("off-chromium", name: "Off for Chromium", key: otherKey))
        let offVersion = try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: true, asVersionOf: off.id, for: .chromium)
        #expect(try !plugin(offVersion, in: manager).isEnabled)
    }

    @Test func listsAPairOnceAndRunsTheVersionForTheTab() async throws {
        try await WebKitProfile.run { profile in
            let tab = profile.makeTab()
            let tabID = UUID()
            host.tabs[tabID] = tab
            // The suite's host outlives the profile, so it lets the tab go for WebKit to delete the profile's store.
            defer { host.tabs[tabID] = nil }
            let (manager, runtime) = launch()
            // The Chromium version comes first, so the pair takes its name and place.
            webKit.refusedNames = ["Reader for Chromium"]
            chromium.refusedNames = ["Reader"]
            let first = try await manager.installEverything(from: package("reader-chromium", name: "Reader for Chromium", action: true))
            let webKitVersion = try await manager.stage(package("reader", name: "Reader", action: true))
            let id = try manager.install(webKitVersion, grant: PluginGrant(requestedBy: webKitVersion.manifest), isEnabled: true, asVersionOf: first.id, for: .webKit)
            await runtime.waitForEngines()
            let webKitID = WebExtensionManifest.extensionID(of: webKitVersion.manifest.id)
            let items = runtime.actions(for: tab)
            #expect(items.map(\.id) == [first.id] && items.first?.name == "Reader for Chromium" && items.first?.action != nil)
            #expect(items.first?.engines == [.webKit, .chromium] && items.first?.asksForVersion == false)
            #expect(runtime.performAction(of: first.id, for: tab) && webKit.performed == [webKitID] && chromium.performed.isEmpty)
            // The palette lists the pair's command once and runs it with the version for the tab's engine.
            let commands = manager.contributions.paletteCommands(matching: "Reader")
            #expect(commands.map(\.plugin) == [first.id])
            let command = try #require(commands.first)
            await manager.run(PluginCommandRef(plugin: command.plugin, command: command.item.id),
                              PluginInvocation(tab: PluginTab(id: tabID, spaceID: nil, title: nil, url: nil, engine: .webKit, isPinned: false, isSelected: true)))
            #expect(webKit.performed == [webKitID, webKitID])
            // While the version installed first is off after failing to start, the other one stands for the pair.
            chromium.refused = [WebExtensionManifest.extensionID(of: first.id)]
            manager.setEnabled(false, for: first.id)
            await runtime.waitForEngines()
            manager.setEnabled(true, for: first.id)
            await runtime.waitForEngines()
            #expect(try !plugin(first.id, in: manager).isEnabled && plugin(id, in: manager).isEnabled)
            #expect(manager.contributions.paletteCommands(matching: "Reader").map(\.plugin) == [id])
            #expect(runtime.actions(for: tab).map(\.id) == [first.id] && runtime.performAction(of: first.id, for: tab))
            manager.close()
        }
    }

    @Test func namesAPairsActionAfterItsVersionInstalledFirst() async throws {
        try await WebKitProfile.run { profile in
            let tab = profile.makeTab()
            let (manager, runtime) = launch()
            // Only the version installed second has an action, and the popover still lists the pair under the first one's identifier and name.
            webKit.refusedNames = ["Reader for Chromium"]
            chromium.refusedNames = ["Reader"]
            let first = try await manager.installEverything(from: package("reader", name: "Reader"))
            let chromiumVersion = try await manager.stage(package("reader-chromium", name: "Reader for Chromium", action: true))
            _ = try manager.install(chromiumVersion, grant: PluginGrant(requestedBy: chromiumVersion.manifest), isEnabled: true, asVersionOf: first.id, for: .chromium)
            await runtime.waitForEngines()
            let items = runtime.actions(for: tab)
            #expect(items.map(\.id) == [first.id] && items.first?.name == "Reader" && items.first?.action != nil)
            manager.close()
        }
    }

    @Test func joinsByHandAndRefusesAJoinThatLeavesAVersionWithoutAnEngine() async throws {
        let (first, _) = launch()
        webKit.refusedNames = ["B"]
        let a = try await first.installEverything(from: package("a", name: "A"))
        let b = try await first.installEverything(from: package("b", name: "B"), isEnabled: false)
        first.close()
        // A record that names an engine this build does not know stays in the file and is ignored.
        try editList { $0["engineVersions"] = [["webKit": a.id.rawValue, "future": "extension.future"]] }
        let (manager, _) = launch()
        #expect(manager.engineVersions.isEmpty)
        #expect(manager.proposedJoin(of: a.id, with: b.id) == PluginEngineVersions([.webKit: a.id, .chromium: b.id]))
        #expect(throws: PluginError.self) { try manager.join(PluginEngineVersions([.webKit: a.id, .chromium: a.id])) }
        #expect(throws: PluginError.self) { try manager.join(PluginEngineVersions([.webKit: b.id, .chromium: a.id])) }
        try manager.join(PluginEngineVersions([.webKit: a.id, .chromium: b.id]))
        // The pair takes the switch of the version installed first, and the join drops the ignored record that named one of its plugins.
        #expect(manager.engineVersions == [PluginEngineVersions([.webKit: a.id, .chromium: b.id])] && manager.plugins.allSatisfy { $0.isEnabled })
        #expect(try list()["engineVersions"] as? [[String: String]] == [["webKit": a.id.rawValue, "chromium": b.id.rawValue]])
        #expect(manager.missingEngine(of: a.id) == nil && manager.versionEngines(of: a.id).isEmpty)
        #expect(throws: PluginError.self) { try manager.join(PluginEngineVersions([.webKit: a.id, .chromium: b.id])) }
    }

    @Test func offersNoJoinWhileAnEngineRunsNoExtensions() async throws {
        // With WebKit alone, as before Chromium runs extensions, Join With… lists nothing, and a join that gives Chromium a version is refused.
        host.engines = [.webKit: webKit]
        let (alone, _) = launch()
        let a = try await alone.installEverything(from: package("a", name: "A"))
        let b = try await alone.installEverything(from: package("b", name: "B"))
        #expect(alone.joinCandidates(of: a.id).isEmpty && alone.joinCandidates(of: b.id).isEmpty)
        #expect(throws: PluginError.invalidVersions("Chromium runs no web extensions on this Mac, so no version can run on it.")) {
            try alone.join(PluginEngineVersions([.webKit: b.id, .chromium: a.id]))
        }
        #expect(alone.engineVersions.isEmpty && alone.plugins.allSatisfy { $0.engines == [.webKit] })
        alone.close()

        // Once Chromium runs extensions, Join With… lists the other plugin, and a version that Chromium has not checked yet cannot join for it.
        host.engines = [.webKit: webKit, .chromium: chromium]
        let (manager, runtime) = launch()
        #expect(manager.joinCandidates(of: a.id).map(\.id) == [b.id])
        #expect(throws: PluginError.invalidVersions("Chromium has not checked \u{201C}A\u{201D} yet, so it cannot be the Chromium version.")) {
            try manager.join(PluginEngineVersions([.webKit: b.id, .chromium: a.id]))
        }
        await runtime.waitForEngines()
        // Both engines run both packages, so the choice starts with the version installed first on WebKit.
        #expect(manager.proposedJoin(of: b.id, with: a.id) == PluginEngineVersions([.webKit: a.id, .chromium: b.id]))
        try manager.join(PluginEngineVersions([.webKit: a.id, .chromium: b.id]))
        #expect(try plugin(a.id, in: manager).engines == [.webKit] && plugin(b.id, in: manager).engines == [.chromium] && manager.joinCandidates(of: a.id).isEmpty)
        manager.close()

        // A pair whose engine runs no extensions now says so in its version's row.
        host.engines = [.webKit: webKit]
        let (later, _) = launch()
        #expect(later.engineVersions.count == 1 && later.enginesNote(of: b.id) == "Chromium runs no web extensions on this Mac." && later.enginesNote(of: a.id) == "Runs on WebKit tabs.")
    }

    @Test func separatesVersionsButNotThoseThatShareAnIdentifier() async throws {
        let (manager, runtime) = launch()
        let a = try await manager.installEverything(from: package("a", name: "A"))
        let b = try await manager.installEverything(from: package("b", name: "B"), isEnabled: false)
        try manager.join(PluginEngineVersions([.webKit: a.id, .chromium: b.id]))
        await runtime.waitForEngines()
        let bID = WebExtensionManifest.extensionID(of: b.id)
        #expect(webKit.loaded[bID] == nil && chromium.loaded[bID] != nil)
        manager.setEnabled(false, for: b.id)
        try manager.separate(a.id)
        // Both stay installed with their switches, each on every engine its package runs on, and each one's note is dismissed for the other's engines.
        #expect(manager.engineVersions.isEmpty && manager.plugins.map(\.id) == [a.id, b.id] && manager.plugins.allSatisfy { !$0.isEnabled && $0.counterpart == nil })
        #expect(manager.plugins.allSatisfy { $0.dismissedVersionNotes == [.webKit, .chromium] })
        manager.setEnabled(true, for: b.id)
        await runtime.waitForEngines()
        #expect(webKit.loaded[bID] != nil && chromium.loaded[bID] != nil)

        let (reader, _) = try await installComplementaryPair(in: manager)
        #expect(throws: PluginError.self) { try manager.separate(reader) }
        #expect(manager.engineVersions.count == 1)
    }

    // MARK: Removal

    @Test func removesOneVersionAndKeepsTheOtherInThePairsPlace() async throws {
        let (manager, runtime) = launch()
        chromium.refusedNames = ["Reader"]
        webKit.refusedNames = ["Reader for Chromium"]
        let reader = try await manager.installEverything(from: package("reader", name: "Reader", key: key))
        let other = try await manager.installEverything(from: package("other", name: "Other"))
        let staged = try await manager.stage(package("reader-chromium", name: "Reader for Chromium", key: key, permissions: ["tabs"]))
        let version = try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: true, asVersionOf: reader.id, for: .chromium)
        await runtime.waitForEngines()
        let grant = try plugin(version, in: manager).grant
        try manager.remove(reader.id)
        await runtime.waitForEngines()
        // The other version keeps its grant, storage, and switch, takes the pair's place, and the record goes.
        #expect(try manager.plugins.map(\.id) == [version, other.id] && manager.engineVersions.isEmpty && list()["engineVersions"] == nil)
        let kept = try plugin(version, in: manager)
        #expect(kept.grant == grant && kept.isEnabled && kept.counterpart == nil)
        #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/\(version.rawValue)/package").path))
        // The removed version leaves WebKit with its storage there; Chromium keeps the other version's copy and storage.
        #expect(webKit.removedData == [keyID] && chromium.removedData.isEmpty && webKit.loaded[keyID] == nil && chromium.loaded[keyID] != nil)
        // The remaining version asks for a WebKit version again.
        #expect(manager.missingEngine(of: version) == .webKit)
        #expect(try (list()["installed"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [version.rawValue, other.id.rawValue])

        try manager.remove(version)
        await runtime.waitForEngines()
        #expect(chromium.removedData == [keyID] && chromium.loaded[keyID] == nil)
    }

    @Test func removesBothVersionsAndTheirStorage() async throws {
        let (manager, runtime) = launch()
        let (reader, version) = try await installComplementaryPair(in: manager)
        await runtime.waitForEngines()
        try manager.remove(version)
        try manager.remove(reader)
        await runtime.waitForEngines()
        #expect(manager.plugins.isEmpty && manager.engineVersions.isEmpty)
        #expect(webKit.removedData.contains(keyID) && chromium.removedData.contains(keyID) && webKit.loaded.isEmpty && chromium.loaded.isEmpty)
    }

    @Test func keepsRecordsAndEngineNamesThisBuildIgnores() async throws {
        let (first, _) = launch()
        let a = try await first.installEverything(from: package("a", name: "A"))
        first.close()
        try editList { list in
            list["engineVersions"] = [["webKit": a.id.rawValue, "chromium": "extension.missing"]]
            var entries = list["installed"] as! [[String: Any]]
            entries[0]["dismissedVersionNotes"] = ["future"]
            list["installed"] = entries
        }
        let (manager, _) = launch()
        #expect(manager.engineVersions.isEmpty && manager.plugins.first?.dismissedVersionNotes == [])
        manager.dismissVersionNote(of: a.id, for: .chromium)
        manager.setEnabled(false, for: a.id)
        let file = try list()
        #expect(file["engineVersions"] as? [[String: String]] == [["webKit": a.id.rawValue, "chromium": "extension.missing"]])
        #expect((file["installed"] as? [[String: Any]])?.first?["dismissedVersionNotes"] as? [String] == ["future", "chromium"])
    }

    // MARK: Guidance

    @Test func asksForAVersionOnlyWhereTheRuleSays() async throws {
        // With WebKit alone, as before Chromium runs extensions, nothing asks and nothing offers a version.
        host.engines = [.webKit: webKit]
        let (alone, _) = launch()
        let reader = try await alone.installEverything(from: package("reader", name: "Reader"))
        #expect(alone.missingEngine(of: reader.id) == nil && alone.versionEngines(of: reader.id).isEmpty)
        alone.close()

        // Chromium runs extensions but has not checked the package: it offers the version, and does not ask yet.
        host.engines = [.webKit: webKit, .chromium: chromium]
        chromium.refusedNames = ["Reader"]
        let (manager, runtime) = launch()
        #expect(manager.versionEngines(of: reader.id) == [.chromium] && manager.missingEngine(of: reader.id) == nil)
        await runtime.waitForEngines()
        #expect(manager.missingEngine(of: reader.id) == .chromium)

        // A dismissal lasts across launches and updates.
        manager.dismissVersionNote(of: reader.id, for: .chromium)
        #expect(manager.missingEngine(of: reader.id) == nil && manager.versionEngines(of: reader.id) == [.chromium])
        let update = try await manager.stage(package("reader", name: "Reader", version: "2"))
        try manager.install(update, grant: PluginGrant(requestedBy: update.manifest), isEnabled: true)
        manager.close()
        let (later, _) = launch()
        #expect(later.plugins.first?.dismissedVersionNotes == [.chromium] && later.missingEngine(of: reader.id) == nil)
        later.close()

        // A plugin that both engines run offers both versions and asks for none; a failure to start on Chromium makes it ask.
        chromium.refusedNames = []
        let (both, bothRuntime) = launch()
        let everywhere = try await both.installEverything(from: package("everywhere", name: "Everywhere"), isEnabled: false)
        #expect(both.versionEngines(of: everywhere.id) == [.webKit, .chromium] && both.missingEngine(of: everywhere.id) == nil)
        chromium.refused = [WebExtensionManifest.extensionID(of: everywhere.id)]
        both.setEnabled(true, for: everywhere.id)
        await bothRuntime.waitForEngines()
        #expect(both.missingEngine(of: everywhere.id) == .chromium)

        // A plugin that only Chromium runs asks for a WebKit version.
        webKit.refusedNames = ["Chromium Only"]
        let chromiumOnly = try await both.installEverything(from: package("chromium-only", name: "Chromium Only"))
        #expect(both.missingEngine(of: chromiumOnly.id) == .webKit && both.versionEngines(of: chromiumOnly.id) == [.webKit])
    }
}
