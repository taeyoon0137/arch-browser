// Plugin identifiers, palette matching, and the manager: which plugins it registers, when it starts their code, and what an invocation carries.
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

@MainActor
@Suite(.serialized) struct PluginManagerTests {
    private let tab = PluginTab(id: UUID(), spaceID: UUID(), title: "Example", url: URL(string: "https://example.org/")!, engine: .chromium, isPinned: false, isSelected: true)

    init() {
        Recorder.reset()
    }

    @Test func registersEachIdentifierOnce() {
        let manager = PluginManager(persona: UUID(), builtIns: [RecordingPlugin.self, RecordingPlugin.self, DisabledPlugin.self])
        #expect(manager.plugins.map(\.id.rawValue) == ["org.example.recording", "org.example.disabled"])
        #expect(manager.plugins.map(\.isEnabled) == [true, false])
        #expect(manager.contributions.paletteCommands(matching: "record").map(\.plugin.rawValue) == ["org.example.recording"])
    }

    @Test func startsAPluginOnceAtItsFirstCommand() async {
        let persona = UUID()
        let manager = PluginManager(persona: persona, builtIns: [RecordingPlugin.self])
        #expect(Recorder.activations.isEmpty)
        let ref = PluginCommandRef(plugin: RecordingPlugin.manifest.id, command: "record")
        async let first: Void = manager.run(ref, PluginInvocation(tab: tab))
        async let second: Void = manager.run(ref, PluginInvocation(tab: nil))
        _ = await (first, second)
        #expect(Recorder.activations == [persona])
        #expect(Recorder.runs.count == 2)
    }

    @Test func runsOnlyListedCommandsOfEnabledPlugins() async {
        let manager = PluginManager(persona: UUID(), builtIns: [RecordingPlugin.self, DisabledPlugin.self])
        await manager.run(PluginCommandRef(plugin: RecordingPlugin.manifest.id, command: "unlisted"), PluginInvocation(tab: tab))
        await manager.run(PluginCommandRef(plugin: DisabledPlugin.manifest.id, command: "record"), PluginInvocation(tab: tab))
        #expect(Recorder.activations.isEmpty)
        #expect(Recorder.runs.isEmpty)
    }

    @Test func hidesTitlesAndAddressesWithoutTabs() async throws {
        let manager = PluginManager(persona: UUID(), builtIns: [RecordingPlugin.self])
        await manager.run(PluginCommandRef(plugin: RecordingPlugin.manifest.id, command: "record"), PluginInvocation(tab: tab))
        let received = try #require(Recorder.runs.first ?? nil)
        #expect(received.title == nil && received.url == nil)
        #expect(received.id == tab.id && received.engine == .chromium)
    }

    @Test func passesTitlesAndAddressesWithTabs() async throws {
        let manager = PluginManager(persona: UUID(), builtIns: [TabsPlugin.self])
        await manager.run(PluginCommandRef(plugin: TabsPlugin.manifest.id, command: "record"), PluginInvocation(tab: tab))
        #expect(try #require(Recorder.runs.first ?? nil) == tab)
    }

    @Test func startsAgainAfterAFailedActivation() async {
        let manager = PluginManager(persona: UUID(), builtIns: [FailingPlugin.self])
        let ref = PluginCommandRef(plugin: FailingPlugin.manifest.id, command: "record")
        await manager.run(ref, PluginInvocation(tab: nil))
        await manager.run(ref, PluginInvocation(tab: nil))
        #expect(Recorder.activations.count == 2)
        #expect(Recorder.runs.isEmpty)
    }

    @Test func contextChecksTheGrant() throws {
        let context = ScopedPluginContext(pluginID: RecordingPlugin.manifest.id, personaID: UUID(), grant: PluginGrant(requestedBy: RecordingPlugin.manifest))
        #expect(throws: PluginError.permissionDenied(.clipboard)) { try context.copyToClipboard("text") }
    }

    @Test func pageAddressPluginAsksForWhatItUses() {
        #expect(PageAddressPlugin.manifest.permissions == [.tabs, .clipboard])
        #expect(PageAddressPlugin.manifest.contributions.commands.map(\.id) == ["copy"])
    }

    @Test func pageAddressPluginFailsWithoutAPage() async throws {
        let plugin = PageAddressPlugin()
        try await plugin.activate(in: ScopedPluginContext(pluginID: PageAddressPlugin.manifest.id, personaID: UUID(), grant: PluginGrant(requestedBy: PageAddressPlugin.manifest)))
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

/// What the test plugins saw: the Persona of each activation and the tab of each run.
@MainActor
private enum Recorder {
    static var activations: [PersonaID] = []
    static var runs: [PluginTab?] = []

    static func reset() {
        activations = []
        runs = []
    }
}

/// A manifest with one command, `record`.
private func recordingManifest(_ id: String, permissions: Set<PluginPermission> = []) -> PluginManifest {
    PluginManifest(id: PluginID(rawValue: id)!, name: id, version: "1", summary: "", permissions: permissions,
                   contributions: PluginContributions(commands: [PluginCommand(id: "record", title: "Record")]))
}

@MainActor
private class RecordingPlugin: BuiltInPlugin {
    class var manifest: PluginManifest { recordingManifest("org.example.recording") }
    class var isOnByDefault: Bool { true }

    required init() {}

    func activate(in context: any PluginContext) async throws {
        Recorder.activations.append(context.personaID)
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
private final class FailingPlugin: RecordingPlugin {
    override class var manifest: PluginManifest { recordingManifest("org.example.failing") }

    override func activate(in context: any PluginContext) async throws {
        Recorder.activations.append(context.personaID)
        throw CancellationError()
    }
}
