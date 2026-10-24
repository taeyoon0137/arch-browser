// Plugin identifiers, match patterns, palette matching, values and storage, and the manager: which plugins it registers, when it starts their code, what an invocation carries, and where each plugin's storage lives.
import ARCHEngine
import Foundation
import Testing
@testable import Plugins

@Suite struct PluginIDTests {
    @Test func acceptsReverseDNSIdentifiers() {
        for id in ["org.example.reading-time", "local.arch.browser.page-address", "a.b", "Example2.x-y"] {
            #expect(PluginID(rawValue: id) != nil, "\(id)")
        }
        #expect(PluginID(rawValue: "a." + String(repeating: "b", count: 126)) != nil)
    }

    @Test func rejectsOtherText() {
        for id in ["", "plugin", ".", "..", "a..b", ".a.b", "a.b.", "a b.c", "a/b.c", "a_b.c", "café.example", "a." + String(repeating: "b", count: 127)] {
            #expect(PluginID(rawValue: id) == nil, "\(id)")
        }
    }

    @Test func ignoresCase() {
        #expect(PluginID(rawValue: "Org.Example.Notes")?.rawValue == "org.example.notes")
        #expect(PluginID(rawValue: "Org.Example.Notes") == PluginID(rawValue: "org.example.notes"))
    }
}

@Suite struct MatchPatternTests {
    @Test func printsPatternsInTheirWrittenForm() throws {
        for text in ["https://example.com/*", "*://*.example.org/docs/*", "http://localhost/", "*://*/*", "https://127.0.0.1/a*b"] {
            #expect(try MatchPattern(text).description == text)
        }
        #expect(try MatchPattern("HTTPS://*.Example.COM/Path").description == "https://*.example.com/Path")
        #expect(try MatchPattern("<all_urls>") == MatchPattern("*://*/*"))
    }

    @Test func rejectsOtherText() {
        let texts = ["", "<all_urls>/", "example.com/*", "https://example.com", "ftp://example.com/*", "file:///*", "https:///*",
                     "https://*example.com/*", "https://ex*ample.com/*", "https://*./*", "https://example.com:8080/*",
                     "https://user@example.com/*", "https://exa_mple.com/*", "https://café.example/*", "https://a..b/*"]
        for text in texts {
            #expect(throws: PluginError.invalidMatchPattern(text)) { try MatchPattern(text) }
        }
    }

    @Test func coversWebAddressesOnly() throws {
        let pattern = try MatchPattern("<all_urls>")
        for address in ["http://example.com/", "https://a.example.org/b?c#d"] {
            #expect(pattern.matches(URL(string: address)!), "\(address)")
        }
        for address in ["file:///Users/example/page.html", "ftp://example.com/", "about:blank", "data:text/plain,a", "arch://settings"] {
            #expect(!pattern.matches(URL(string: address)!), "\(address)")
        }
    }

    @Test func matchesSchemesAndHosts() throws {
        let cases: [(String, String, Bool)] = [
            ("https://example.com/*", "https://example.com/", true),
            ("https://example.com/*", "https://EXAMPLE.com/a", true),
            ("https://example.com/*", "https://example.com", true),
            ("https://example.com/*", "https://example.com:8443/a", true),
            ("https://example.com/*", "http://example.com/", false),
            ("https://example.com/*", "https://www.example.com/", false),
            ("https://example.com/*", "https://example.com.test/", false),
            ("https://example.com/*", "https://example.com@other.test/", false),
            ("https://example.com/*", "https://other.test/?example.com", false),
            ("*://*.example.com/*", "https://example.com/", true),
            ("*://*.example.com/*", "http://a.b.example.com/", true),
            ("*://*.example.com/*", "https://badexample.com/", false),
        ]
        for (pattern, address, expected) in cases {
            #expect(try MatchPattern(pattern).matches(URL(string: address)!) == expected, "\(pattern) \(address)")
        }
    }

    @Test func matchesPathsAndQueries() throws {
        let cases: [(String, String, Bool)] = [
            ("https://example.com/docs/*", "https://example.com/docs/", true),
            ("https://example.com/docs/*", "https://example.com/docs/a/b", true),
            ("https://example.com/docs/*", "https://example.com/docs", false),
            ("https://example.com/docs/*", "https://example.com/Docs/a", false),
            ("https://example.com/search*", "https://example.com/search?q=arch", true),
            ("https://example.com/search*", "https://example.com/searching", true),
            ("https://example.com/*.pdf", "https://example.com/a/b.pdf#page=2", true),
            ("https://example.com/*.pdf", "https://example.com/a.pdf?download=1", false),
            ("https://example.com/a*b*c", "https://example.com/a-b-b-c", true),
            ("https://example.com/a*b*c", "https://example.com/a-c-b", false),
            ("https://example.com/a%20b", "https://example.com/a%20b", true),
        ]
        for (pattern, address, expected) in cases {
            #expect(try MatchPattern(pattern).matches(URL(string: address)!) == expected, "\(pattern) \(address)")
        }
    }
}

@Suite struct PaletteMatchingTests {
    private let index = PluginContributionIndex([
        installed("org.example.address", name: "Address", commands: [PluginCommand(id: "copy", title: "Copy Page Address", keywords: ["url"])]),
        installed("org.example.off", name: "Off", commands: [PluginCommand(id: "copy", title: "Copy Everything")], isEnabled: false),
    ])

    @Test func matchesTheStartsOfWordsInTitlesAndKeywords() {
        for text in ["copy", "Copy page", "addr", "PAGE co", "url", " copy  ", "cöpy"] {
            #expect(index.paletteCommands(matching: text).map(\.item.title) == ["Copy Page Address"], "\(text)")
        }
    }

    @Test func needsEveryWord() {
        for text in ["", "  ", "opy", "copy tab", "-"] {
            #expect(index.paletteCommands(matching: text).isEmpty, "\(text)")
        }
    }

    @Test func namesThePlugin() throws {
        let command = try #require(index.paletteCommands(matching: "copy").first)
        #expect(command.pluginName == "Address")
        #expect(command.ref == PluginCommandRef(plugin: PluginID(rawValue: "org.example.address")!, command: "copy"))
    }
}

@Suite struct PluginValueTests {
    @Test func readsPlainJSON() throws {
        let json = #"{"null": null, "bool": true, "one": 1, "text": "a", "list": [false, 2.5, "b"], "nested": {"empty": {}}}"#
        let value = try JSONDecoder().decode(PluginValue.self, from: Data(json.utf8))
        #expect(value == .object([
            "null": .null, "bool": .bool(true), "one": .number(1), "text": .string("a"),
            "list": .array([.bool(false), .number(2.5), .string("b")]), "nested": .object(["empty": .object([:])]),
        ]))
        #expect(try JSONDecoder().decode(PluginValue.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func writesPlainJSON() throws {
        #expect(try String(decoding: JSONEncoder().encode(PluginValue.array([.null, .bool(true), .number(1), .string("a")])), as: UTF8.self) == #"[null,true,1,"a"]"#)
    }
}

@MainActor
@Suite struct PluginStorageTests {
    private let folder = TemporaryFolder()
    private var fileURL: URL { folder.url.appendingPathComponent("storage.json") }

    @Test func keepsValuesAcrossLaunches() throws {
        let storage = PluginStorageFile(fileURL: fileURL)
        try storage.setValue(.string("b"), forKey: "b")
        try storage.setValue(.object(["count": .number(2)]), forKey: "a")
        try storage.setValue(.null, forKey: "gone")
        try storage.setValue(nil, forKey: "gone")
        storage.saveChanges()
        let reopened = PluginStorageFile(fileURL: fileURL)
        #expect(reopened.allKeys() == ["a", "b"])
        #expect(reopened.value(forKey: "a") == .object(["count": .number(2)]))
        #expect(reopened.value(forKey: "gone") == nil)
    }

    @Test func writesOnceChangesSettle() async throws {
        let storage = PluginStorageFile(fileURL: fileURL)
        try storage.setValue(.bool(true), forKey: "a")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        try await Task.sleep(for: .seconds(1))
        #expect(PluginStorageFile(fileURL: fileURL).value(forKey: "a") == .bool(true))
    }

    @Test func refusesWritesPastTheQuota() throws {
        let storage = PluginStorageFile(fileURL: fileURL)
        // The key's byte and the value's quotes and characters fill the quota exactly.
        let full = PluginValue.string(String(repeating: "x", count: PluginStorageFile.quota - 3))
        try storage.setValue(full, forKey: "k")
        #expect(throws: PluginError.quotaExceeded) { try storage.setValue(.null, forKey: "j") }
        #expect(throws: PluginError.quotaExceeded) { try storage.setValue(.string(String(repeating: "x", count: PluginStorageFile.quota)), forKey: "k") }
        #expect(storage.value(forKey: "k") == full && storage.allKeys() == ["k"])
        try storage.setValue(.string("short"), forKey: "k")
        try storage.setValue(.null, forKey: "j")
        #expect(storage.allKeys() == ["j", "k"])
    }

    @Test func refusesNumbersJSONCannotHold() {
        let storage = PluginStorageFile(fileURL: fileURL)
        #expect(throws: (any Error).self) { try storage.setValue(.number(.infinity), forKey: "a") }
        #expect(storage.allKeys().isEmpty)
    }

    @Test func refusesValuesNestedDeeperThanTheFileHolds() throws {
        let storage = PluginStorageFile(fileURL: fileURL)
        #expect(throws: EncodingError.self) { try storage.setValue(nested(511), forKey: "deep") }
        #expect(storage.allKeys().isEmpty)
        try storage.setValue(nested(510), forKey: "deep")
        storage.saveChanges()
        #expect(PluginStorageFile(fileURL: fileURL).value(forKey: "deep") == nested(510))
    }

    @Test func movesAnUnreadableFileAside() throws {
        let copyURL = folder.url.appendingPathComponent("storage.unreadable.json")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        // The second file's copy replaces the first one's.
        for text in [#"{"a": 1e400}"#, "not json"] {
            try Data(text.utf8).write(to: fileURL)
            let storage = PluginStorageFile(fileURL: fileURL)
            #expect(storage.allKeys().isEmpty)
            try storage.setValue(.number(1), forKey: "a")
            storage.saveChanges()
            #expect(try Data(contentsOf: copyURL) == Data(text.utf8))
            #expect(PluginStorageFile(fileURL: fileURL).value(forKey: "a") == .number(1))
        }
    }
}

@MainActor
@Suite(.serialized) struct PluginManagerTests {
    private let tab = PluginTab(id: UUID(), spaceID: UUID(), title: "Example", url: URL(string: "https://example.org/")!, engine: .chromium, isPinned: false, isSelected: true)
    private let folder = TemporaryFolder()

    init() {
        Recorder.reset()
    }

    private func manager(persona: PersonaID = UUID(), _ builtIns: [any BuiltInPlugin.Type]) -> PluginManager {
        PluginManager(persona: persona, directory: folder.url, builtIns: builtIns)
    }

    private func context(for manifest: PluginManifest) -> ScopedPluginContext {
        ScopedPluginContext(pluginID: manifest.id, personaID: UUID(), grant: PluginGrant(requestedBy: manifest), storage: PluginStorageFile(fileURL: folder.url.appendingPathComponent("storage.json")))
    }

    @Test func registersEachIdentifierOnce() {
        let manager = manager([RecordingPlugin.self, RecordingPlugin.self, DisabledPlugin.self])
        #expect(manager.plugins.map(\.id.rawValue) == ["org.example.recording", "org.example.disabled"])
        #expect(manager.plugins.map(\.isEnabled) == [true, false])
        #expect(manager.contributions.paletteCommands(matching: "record").map(\.plugin.rawValue) == ["org.example.recording"])
    }

    @Test func startsAPluginOnceAtItsFirstCommand() async {
        let persona = UUID()
        let manager = manager(persona: persona, [RecordingPlugin.self])
        #expect(Recorder.activations.isEmpty)
        let ref = PluginCommandRef(plugin: RecordingPlugin.manifest.id, command: "record")
        async let first: Void = manager.run(ref, PluginInvocation(tab: tab))
        async let second: Void = manager.run(ref, PluginInvocation(tab: nil))
        _ = await (first, second)
        #expect(Recorder.activations == [persona])
        #expect(Recorder.runs.count == 2)
    }

    @Test func runsOnlyListedCommandsOfEnabledPlugins() async {
        let manager = manager([RecordingPlugin.self, DisabledPlugin.self])
        await manager.run(PluginCommandRef(plugin: RecordingPlugin.manifest.id, command: "unlisted"), PluginInvocation(tab: tab))
        await manager.run(PluginCommandRef(plugin: DisabledPlugin.manifest.id, command: "record"), PluginInvocation(tab: tab))
        #expect(Recorder.activations.isEmpty)
        #expect(Recorder.runs.isEmpty)
    }

    @Test func hidesTitlesAndAddressesWithoutTabs() async throws {
        let manager = manager([RecordingPlugin.self])
        await manager.run(PluginCommandRef(plugin: RecordingPlugin.manifest.id, command: "record"), PluginInvocation(tab: tab))
        let received = try #require(Recorder.runs.first ?? nil)
        #expect(received.title == nil && received.url == nil)
        #expect(received.id == tab.id && received.engine == .chromium)
    }

    @Test func passesTitlesAndAddressesWithTabs() async throws {
        let manager = manager([TabsPlugin.self])
        await manager.run(PluginCommandRef(plugin: TabsPlugin.manifest.id, command: "record"), PluginInvocation(tab: tab))
        #expect(try #require(Recorder.runs.first ?? nil) == tab)
    }

    @Test func passesTitlesAndAddressesOfGrantedSites() async throws {
        let manager = manager([SitesPlugin.self])
        var otherSite = tab
        otherSite.url = URL(string: "https://other.example/")
        for page in [tab, otherSite] {
            await manager.run(PluginCommandRef(plugin: SitesPlugin.manifest.id, command: "record"), PluginInvocation(tab: page))
        }
        #expect(Recorder.runs.map { $0?.url } == [tab.url, nil])
        #expect(Recorder.runs.map { $0?.title } == [tab.title, nil])
    }

    @Test func startsAgainAfterAFailedActivation() async {
        let manager = manager([FailingPlugin.self])
        let ref = PluginCommandRef(plugin: FailingPlugin.manifest.id, command: "record")
        await manager.run(ref, PluginInvocation(tab: nil))
        await manager.run(ref, PluginInvocation(tab: nil))
        #expect(Recorder.activations.count == 2)
        #expect(Recorder.runs.isEmpty)
        // The second start finds the first one's storage, with any changes that have not reached the file.
        #expect(Recorder.storages.count == 2 && Recorder.storages[0] === Recorder.storages[1])
    }

    @Test func keepsStorageInThePersonasFolder() async throws {
        let personas = [UUID(), UUID()]
        let managers = personas.map { manager(persona: $0, [CountingPlugin.self]) }
        let ref = PluginCommandRef(plugin: CountingPlugin.manifest.id, command: "record")
        await managers[0].run(ref, PluginInvocation(tab: nil))
        await managers[0].run(ref, PluginInvocation(tab: nil))
        await managers[1].run(ref, PluginInvocation(tab: nil))
        for storage in Recorder.storages {
            try #require(storage as? PluginStorageFile).saveChanges()
        }
        for (persona, runs) in zip(personas, [2.0, 1.0]) {
            let file = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/org.example.counting/storage.json")
            #expect(PluginStorageFile(fileURL: file).value(forKey: "runs") == .number(runs))
        }
    }

    @Test func contextChecksTheGrant() throws {
        let context = context(for: RecordingPlugin.manifest)
        #expect(throws: PluginError.permissionDenied(.clipboard)) { try context.copyToClipboard("text") }
    }

    @Test func pageAddressPluginAsksForWhatItUses() {
        #expect(PageAddressPlugin.manifest.permissions == [.tabs, .clipboard])
        #expect(PageAddressPlugin.manifest.contributions.commands.map(\.id) == ["copy"])
    }

    @Test func pageAddressPluginFailsWithoutAPage() async throws {
        let plugin = PageAddressPlugin()
        try await plugin.activate(in: context(for: PageAddressPlugin.manifest))
        var blank = tab
        blank.url = nil
        for page in [nil, blank] {
            await #expect(throws: PluginError.noPage) { try await plugin.run("copy", PluginInvocation(tab: page)) }
        }
    }
}

private func installed(_ id: String, name: String, commands: [PluginCommand], isEnabled: Bool = true) -> InstalledPlugin {
    let manifest = PluginManifest(id: PluginID(rawValue: id)!, name: name, version: "1", summary: "", contributions: PluginContributions(commands: commands))
    return InstalledPlugin(manifest: manifest, grant: PluginGrant(requestedBy: manifest), isEnabled: isEnabled)
}

/// `depth` arrays, each holding the next, around `null`.
private func nested(_ depth: Int) -> PluginValue {
    (0..<depth).reduce(PluginValue.null) { value, _ in .array([value]) }
}

/// A folder of its own for one test's files, removed when the test ends.
private final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPluginsTests-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What the test plugins saw: the Persona and storage of each activation and the tab of each run.
@MainActor
private enum Recorder {
    static var activations: [PersonaID] = []
    static var storages: [any PluginStorage] = []
    static var runs: [PluginTab?] = []

    static func reset() {
        activations = []
        storages = []
        runs = []
    }

    static func record(_ context: any PluginContext) {
        activations.append(context.personaID)
        storages.append(context.storage)
    }
}

/// A manifest with one command, `record`.
private func recordingManifest(_ id: String, permissions: Set<PluginPermission> = [], sites: [String] = []) -> PluginManifest {
    PluginManifest(id: PluginID(rawValue: id)!, name: id, version: "1", summary: "", permissions: permissions, sites: sites.map { try! MatchPattern($0) },
                   contributions: PluginContributions(commands: [PluginCommand(id: "record", title: "Record")]))
}

@MainActor
private class RecordingPlugin: BuiltInPlugin {
    class var manifest: PluginManifest { recordingManifest("org.example.recording") }
    class var isOnByDefault: Bool { true }

    required init() {}

    func activate(in context: any PluginContext) async throws {
        Recorder.record(context)
        // Gives a second command the chance to arrive while the plugin activates.
        await Task.yield()
    }

    func run(_ command: String, _ invocation: PluginInvocation) async throws {
        Recorder.runs.append(invocation.tab)
    }
}

@MainActor
private final class DisabledPlugin: RecordingPlugin {
    override class var manifest: PluginManifest { recordingManifest("org.example.disabled") }
    override class var isOnByDefault: Bool { false }
}

@MainActor
private final class TabsPlugin: RecordingPlugin {
    override class var manifest: PluginManifest { recordingManifest("org.example.tabs", permissions: [.tabs]) }
}

@MainActor
private final class SitesPlugin: RecordingPlugin {
    override class var manifest: PluginManifest { recordingManifest("org.example.sites", sites: ["https://example.org/*"]) }
}

@MainActor
private final class FailingPlugin: RecordingPlugin {
    override class var manifest: PluginManifest { recordingManifest("org.example.failing") }

    override func activate(in context: any PluginContext) async throws {
        Recorder.record(context)
        throw CancellationError()
    }
}

/// Counts its runs under the key `runs` in its storage.
@MainActor
private final class CountingPlugin: RecordingPlugin {
    override class var manifest: PluginManifest { recordingManifest("org.example.counting") }

    private var storage: (any PluginStorage)?

    override func activate(in context: any PluginContext) async throws {
        try await super.activate(in: context)
        storage = context.storage
    }

    override func run(_ command: String, _ invocation: PluginInvocation) async throws {
        let runs = if case let .number(runs)? = storage?.value(forKey: "runs") { runs } else { 0.0 }
        try storage?.setValue(.number(runs + 1), forKey: "runs")
    }
}
