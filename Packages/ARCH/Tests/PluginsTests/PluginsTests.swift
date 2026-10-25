// Plugin identifiers, match patterns, shortcuts, the contribution index, values and storage, page scripts, and the manager: which plugins it registers and keeps switched on or off, when it starts and stops their code, what an invocation and a page script value carry, where each plugin's storage, settings, and secrets live, and the built-in Page Address plugin.
import AppKit
import ARCHEngine
import Foundation
import JavaScriptCore
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

@MainActor
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

@Suite struct PluginShortcutTests {
    @Test func readsModifiersAndKeys() throws {
        let shortcut = try PluginShortcut("Shift+CMD+C")
        #expect(shortcut.modifiers == [.shift, .cmd] && shortcut.key == "c")
        #expect(shortcut.description == "shift+cmd+c")
        #expect(shortcut.keyEquivalent == "C" && shortcut.modifierFlags == [.shift, .command])
        #expect(try PluginShortcut("cmd+shift+c") == shortcut)
        #expect(try PluginShortcut("opt+ctrl+r").description == "ctrl+opt+r")
        let keys: [(String, String)] = [("cmd+/", "/"), ("cmd+plus", "+"), ("ctrl+space", " "), ("ctrl+up", String(UnicodeScalar(NSUpArrowFunctionKey)!)),
                                        ("f5", String(UnicodeScalar(NSF5FunctionKey)!)), ("opt+f20", String(UnicodeScalar(NSF20FunctionKey)!))]
        for (text, key) in keys {
            #expect(try PluginShortcut(text).keyEquivalent == key, "\(text)")
        }
    }

    @Test func rejectsOtherText() {
        let texts = ["", "r", "shift+r", "opt+r", "cmd", "cmd+", "+", "cmd++", "cmd+cmd+r", "cmd+ab", "hyper+r", "cmd+f21", "cmd+f05", "cmd+é", "cmd+ ", "cmd+r+shift"]
        for text in texts {
            #expect(throws: PluginError.invalidShortcut(text), "\(text)") { try PluginShortcut(text) }
        }
    }
}

@MainActor
@Suite struct ContributionIndexTests {
    private let shortcut = try! PluginShortcut("ctrl+opt+r")
    private var index: PluginContributionIndex {
        PluginContributionIndex([
            installed("org.example.first", name: "First", contributions: PluginContributions(
                commands: [PluginCommand(id: "read", title: "Read", shortcut: shortcut), PluginCommand(id: "save", title: "Save")],
                menuItems: [
                    PluginMenuItem(command: "save", location: .pluginsMenu),
                    PluginMenuItem(command: "read", location: .tabContextMenu, title: "Read Tab"),
                    PluginMenuItem(command: "save", location: .pageContextMenu([.link, .selection])),
                    PluginMenuItem(command: "read", location: .pageContextMenu([.page])),
                    PluginMenuItem(command: "unlisted", location: .spaceMenu),
                ],
                sidebarItems: [
                    PluginSidebarItem(id: "panel", title: "Panel", symbol: "sidebar.right", action: .panel),
                    PluginSidebarItem(id: "save", title: "Save", symbol: "square.and.arrow.down", action: .command("save")),
                    PluginSidebarItem(id: "unlisted", title: "Unlisted", symbol: "questionmark", action: .command("unlisted")),
                ])),
            installed("org.example.second", name: "Second", contributions: PluginContributions(
                commands: [PluginCommand(id: "read", title: "Read Aloud", shortcut: shortcut)],
                menuItems: [PluginMenuItem(command: "read", location: .pluginsMenu), PluginMenuItem(command: "read", location: .spaceMenu)])),
            installed("org.example.off", name: "Off", contributions: PluginContributions(
                commands: [PluginCommand(id: "read", title: "Read")],
                menuItems: [PluginMenuItem(command: "read", location: .pluginsMenu)],
                sidebarItems: [PluginSidebarItem(id: "panel", title: "Panel", symbol: "sidebar.right", action: .panel)]), isEnabled: false),
        ])
    }

    private func titles(at location: PluginMenuLocation) -> [String] {
        index.menuSections(at: location).map { "\($0.pluginName): " + $0.items.map(\.title).joined(separator: ", ") }
    }

    @Test func groupsMenuItemsByPluginWithTheirCommandsTitles() {
        #expect(titles(at: .tabContextMenu) == ["First: Read Tab"])
        #expect(titles(at: .spaceMenu) == ["Second: Read Aloud"])
        let entry = index.menuSections(at: .tabContextMenu)[0].items[0]
        #expect(entry.command == PluginCommandRef(plugin: PluginID(rawValue: "org.example.first")!, command: "read"))
    }

    @Test func putsEveryShortcutInThePluginsMenu() {
        #expect(titles(at: .pluginsMenu) == ["First: Save, Read", "Second: Read Aloud"])
        #expect(index.menuSections(at: .pluginsMenu).flatMap(\.items).map(\.shortcut) == [nil, shortcut, shortcut])
    }

    @Test func showsPageContextItemsForTheContextsOfTheClick() {
        #expect(titles(at: .pageContextMenu([.page])) == ["First: Read"])
        #expect(titles(at: .pageContextMenu([.link, .image])) == ["First: Save"])
        #expect(titles(at: .pageContextMenu([.editable])).isEmpty)
    }

    @Test func listsTheSidebarItemsOfEnabledPlugins() {
        #expect(index.sidebarItems.map(\.id) == ["org.example.first/panel", "org.example.first/save"])
    }

    @Test func readsTheContextsOfAClick() {
        let link = URL(string: "https://example.org/")!
        let cases: [(EngineContextMenuElement, Set<PluginPageContext>)] = [
            (EngineContextMenuElement(), [.page]),
            (EngineContextMenuElement(linkURL: link, imageURL: link, selectedText: "words"), [.link, .image, .selection]),
            (EngineContextMenuElement(selectedText: " \n", isEditable: true), [.editable]),
            (EngineContextMenuElement(mediaURL: link), []),
        ]
        for (element, contexts) in cases {
            #expect(Set(element) == contexts)
        }
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
    private let secrets = MemorySecretStore()

    init() {
        Recorder.reset()
    }

    private func manager(persona: PersonaID = UUID(), _ builtIns: [any BuiltInPlugin.Type]) -> PluginManager {
        PluginManager(persona: persona, directory: folder.url, builtIns: builtIns, secretStore: secrets)
    }

    /// The context `type` would start with in a manager of its own.
    private func context(for type: any BuiltInPlugin.Type, in manager: PluginManager? = nil) throws -> ScopedPluginContext {
        let manager = manager ?? self.manager([type])
        return manager.makeContext(for: try #require(manager.plugins.first { $0.id == type.manifest.id }))
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
        #expect(Recorder.storageFiles.count == 2 && Recorder.storageFiles[0] === Recorder.storageFiles[1])
        // The failed instance's context no longer acts.
        #expect(throws: PluginError.stopped) { try Recorder.contexts[0].copyToClipboard("text") }
    }

    @Test func keepsStorageInThePersonasFolder() async throws {
        let personas = [UUID(), UUID()]
        let managers = personas.map { manager(persona: $0, [CountingPlugin.self]) }
        let ref = PluginCommandRef(plugin: CountingPlugin.manifest.id, command: "record")
        await managers[0].run(ref, PluginInvocation(tab: nil))
        await managers[0].run(ref, PluginInvocation(tab: nil))
        await managers[1].run(ref, PluginInvocation(tab: nil))
        for file in Recorder.storageFiles {
            file.saveChanges()
        }
        for (persona, runs) in zip(personas, [2.0, 1.0]) {
            let file = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/org.example.counting/storage.json")
            #expect(PluginStorageFile(fileURL: file).value(forKey: "runs") == .number(runs))
        }
    }

    @Test func passesValuesFromGrantedFramesAndReturnsTheReply() async throws {
        var tab = PluginTab(id: UUID(), spaceID: nil, title: "Other", url: URL(string: "https://other.example/")!, engine: .webKit, isPinned: false, isSelected: true)
        let world = PageScriptPlugin.manifest.id.pageScriptWorld
        let frameURL = URL(string: "https://example.org/docs/a")!
        let reply = await manager([PageScriptPlugin.self]).receive(EnginePageScriptMessage(world: world, frameURL: frameURL, isMainFrame: false, json: #"{"count": 2}"#), from: tab)
        #expect(reply == #"["echo",{"count":2}]"#)
        let message = try #require(Recorder.pageMessages.first)
        #expect(message.body == .object(["count": .number(2)]))
        #expect(message.frameURL == frameURL && !message.isMainFrame)
        // The grant covers the frame but not the tab's page.
        tab.title = nil
        tab.url = nil
        #expect(message.tab == tab)
    }

    @Test func dropsValuesThePluginMayNotReceive() async {
        let tab = PluginTab(id: UUID(), spaceID: nil, title: nil, url: nil, engine: .chromium, isPinned: false, isSelected: true)
        let world = PageScriptPlugin.manifest.id.pageScriptWorld
        let covered = URL(string: "https://example.org/")
        let messages = [
            EnginePageScriptMessage(world: world, frameURL: URL(string: "https://other.example/"), isMainFrame: true, json: "1"),
            EnginePageScriptMessage(world: world, frameURL: nil, isMainFrame: true, json: "1"),
            EnginePageScriptMessage(world: world, frameURL: covered, isMainFrame: true, json: "not json"),
            EnginePageScriptMessage(world: "ARCHPlugin.org.example.unknown", frameURL: covered, isMainFrame: true, json: "1"),
            EnginePageScriptMessage(world: DisabledPageScriptPlugin.manifest.id.pageScriptWorld, frameURL: covered, isMainFrame: true, json: "1"),
        ]
        let manager = manager([PageScriptPlugin.self, DisabledPageScriptPlugin.self])
        for message in messages {
            #expect(await manager.receive(message, from: tab) == nil, "\(message)")
        }
        #expect(Recorder.activations.isEmpty && Recorder.pageMessages.isEmpty)
    }

    @Test func contextChecksTheGrant() throws {
        let context = try context(for: RecordingPlugin.self)
        #expect(throws: PluginError.permissionDenied(.clipboard)) { try context.copyToClipboard("text") }
    }

    @Test func passesWhatTheUserClickedOnWhateverTheGrant() async throws {
        let space = UUID()
        let invocation = PluginInvocation(tab: tab, spaceID: space, linkURL: URL(string: "https://other.example/a"), imageURL: URL(string: "https://other.example/b.png"), selection: "words")
        await manager([RecordingPlugin.self]).run(PluginCommandRef(plugin: RecordingPlugin.manifest.id, command: "record"), invocation)
        let received = try #require(Recorder.invocations.first)
        #expect(received.tab?.url == nil)
        #expect(received.spaceID == space && received.linkURL == invocation.linkURL && received.imageURL == invocation.imageURL && received.selection == "words")
    }

    @Test func remembersPluginsSwitchedOnAndOffInEachPersona() throws {
        let persona = UUID()
        let first = manager(persona: persona, [RecordingPlugin.self, DisabledPlugin.self])
        first.setEnabled(false, for: RecordingPlugin.manifest.id)
        first.setEnabled(true, for: DisabledPlugin.manifest.id)
        #expect(first.plugins.map(\.isEnabled) == [false, true])
        #expect(first.contributions.paletteCommands(matching: "record").map(\.plugin) == [DisabledPlugin.manifest.id])
        let file = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/plugins.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(manager(persona: persona, [RecordingPlugin.self, DisabledPlugin.self]).plugins.map(\.isEnabled) == [false, true])
        // Another Persona has the plugins as they are by default.
        #expect(manager([RecordingPlugin.self, DisabledPlugin.self]).plugins.map(\.isEnabled) == [true, false])
    }

    @Test func keepsAnUnreadablePluginListAside() throws {
        let persona = UUID()
        let file = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/plugins.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(manager(persona: persona, [DisabledPlugin.self]).plugins.map(\.isEnabled) == [false])
        #expect(try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent("plugins.unreadable.json")) == Data("not json".utf8))
    }

    @Test func stopsAPluginSwitchedOffAndStartsANewOneSwitchedOn() async throws {
        let manager = manager([RecordingPlugin.self])
        let ref = PluginCommandRef(plugin: RecordingPlugin.manifest.id, command: "record")
        await manager.run(ref, PluginInvocation(tab: nil))
        manager.setEnabled(false, for: ref.plugin)
        await manager.run(ref, PluginInvocation(tab: nil))
        // The deactivation waits for the activation, which has ended, on the main actor.
        await Task.yield()
        #expect(Recorder.deactivations == 1)
        #expect(Recorder.invocations.count == 1)
        manager.setEnabled(true, for: ref.plugin)
        await manager.run(ref, PluginInvocation(tab: nil))
        #expect(Recorder.activations.count == 2 && Recorder.invocations.count == 2)
    }

    @Test func closesForAPersonaTheUserDeletes() async throws {
        let persona = UUID()
        let manager = manager(persona: persona, [RecordingPlugin.self])
        let ref = PluginCommandRef(plugin: RecordingPlugin.manifest.id, command: "record")
        await manager.run(ref, PluginInvocation(tab: nil))
        try context(for: RecordingPlugin.self, in: manager).storage.setValue(.bool(true), forKey: "a")
        manager.close()
        // The deactivation waits for the activation, which has ended, on the main actor.
        await Task.yield()
        #expect(Recorder.deactivations == 1)
        #expect(manager.plugins.isEmpty && manager.contributions.paletteCommands(matching: "record").isEmpty)
        // What the instance left running cannot act, and nothing starts the plugin again.
        #expect(throws: PluginError.stopped) { try Recorder.contexts[0].storage.setValue(.number(1), forKey: "key") }
        await manager.run(ref, PluginInvocation(tab: nil))
        #expect(Recorder.activations.count == 1)
        // The change that had not reached the file never does.
        try await Task.sleep(for: .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/org.example.recording/storage.json").path))
    }

    @Test func removesTheDataOfADeletedPersona() throws {
        let deleted = UUID(), kept = UUID()
        let setting = try #require(SettingsPlugin.manifest.contributions.settings.first { $0.kind == .secret })
        for persona in [deleted, kept] {
            let manager = manager(persona: persona, [SettingsPlugin.self])
            // Writes `plugins.json` in the Persona's folder.
            manager.setEnabled(false, for: SettingsPlugin.manifest.id)
            try manager.setSecret("token", of: setting, for: SettingsPlugin.manifest.id)
        }
        #expect(PluginManager.removeData(ofPersona: deleted, in: folder.url, secretStore: secrets))
        let plugins = folder.url.appendingPathComponent("Plugins", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: plugins.appendingPathComponent(deleted.uuidString).path))
        #expect(FileManager.default.fileExists(atPath: plugins.appendingPathComponent(kept.uuidString).path))
        #expect(secrets.items == ["local.arch.browser.plugin.org.example.settings \(kept.uuidString)/secret": "token"])
        // Data that is gone counts as removed.
        #expect(PluginManager.removeData(ofPersona: deleted, in: folder.url, secretStore: secrets))
    }

    @Test func endsTheContextOfAStoppedInstance() async throws {
        let manager = manager([PanelPlugin.self])
        let ref = PluginCommandRef(plugin: PanelPlugin.manifest.id, command: "record")
        await manager.run(ref, PluginInvocation(tab: nil))
        manager.setEnabled(false, for: ref.plugin)
        manager.setEnabled(true, for: ref.plugin)
        await manager.run(ref, PluginInvocation(tab: nil))
        try #require(Recorder.contexts.count == 2)
        let (old, current) = (Recorder.contexts[0], Recorder.contexts[1])
        let item = manager.contributions.sidebarItems[0]
        // What the first instance left running cannot act, even on the items the new instance shares.
        old.setBadge("1", onSidebarItem: "panel")
        #expect(manager.badge(on: item) == nil)
        #expect(throws: PluginError.stopped) { try old.copyToClipboard("text") }
        #expect(throws: PluginError.stopped) { try old.storage.setValue(.number(1), forKey: "key") }
        #expect(throws: PluginError.stopped) { try old.secrets.setSecret("token", forKey: "key") }
        #expect(old.storage.allKeys().isEmpty && secrets.items.isEmpty)
        // The new instance acts, within its grant, and the old one still reads.
        current.setBadge("2", onSidebarItem: "panel")
        try current.storage.setValue(.number(2), forKey: "key")
        #expect(throws: PluginError.permissionDenied(.clipboard)) { try current.copyToClipboard("text") }
        #expect(manager.badge(on: item) == "2")
        #expect(old.storage.value(forKey: "key") == .number(2))
    }

    @Test func readsSettingsWithTheirDefaults() throws {
        let manager = manager([SettingsPlugin.self])
        let id = SettingsPlugin.manifest.id
        let settings = Dictionary(uniqueKeysWithValues: SettingsPlugin.manifest.contributions.settings.map { ($0.key, $0) })
        let context = try context(for: SettingsPlugin.self, in: manager)
        #expect(["toggle", "text", "number", "choice", "secret", "unknown"].map(context.setting) == [.bool(true), .string("a"), .number(5), .string("one"), nil, nil])
        try manager.setValue(.bool(false), of: settings["toggle"]!, for: id)
        try manager.setValue(.number(7), of: settings["number"]!, for: id)
        try manager.setValue(.string("two"), of: settings["choice"]!, for: id)
        #expect(["toggle", "number", "choice"].map(context.setting) == [.bool(false), .number(7), .string("two")])
        // A value that no longer suits the field reads as the default, and nil restores it.
        try manager.setValue(.number(11), of: settings["number"]!, for: id)
        try manager.setValue(.string("gone"), of: settings["choice"]!, for: id)
        try manager.setValue(nil, of: settings["toggle"]!, for: id)
        #expect(["toggle", "number", "choice"].map(context.setting) == [.bool(true), .number(5), .string("one")])
    }

    @Test func keepsSettingsApartFromThePluginsOwnKeys() throws {
        let persona = UUID()
        let manager = manager(persona: persona, [SettingsPlugin.self])
        try manager.setValue(.string("b"), of: SettingsPlugin.manifest.contributions.settings[1], for: SettingsPlugin.manifest.id)
        let storage = try #require(try context(for: SettingsPlugin.self, in: manager).storage as? ScopedPluginStorage).file
        try storage.setValue(.number(1), forKey: "text")
        #expect(throws: PluginError.reservedKey("arch.setting:text")) { try storage.setValue(.null, forKey: "arch.setting:text") }
        #expect(storage.allKeys() == ["text"] && storage.value(forKey: "arch.setting:text") == nil)
        storage.saveChanges()
        let file = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/org.example.settings/storage.json")
        #expect(try JSONDecoder().decode([String: PluginValue].self, from: Data(contentsOf: file)) == ["text": .number(1), "arch.setting:text": .string("b")])
    }

    @Test func keepsSecretsInTheKeychainOfEachPersona() throws {
        let persona = UUID()
        let manager = manager(persona: persona, [SettingsPlugin.self])
        let setting = try #require(SettingsPlugin.manifest.contributions.settings.first { $0.kind == .secret })
        let id = SettingsPlugin.manifest.id
        #expect(try !manager.hasSecret(setting, for: id))
        try manager.setSecret("token", of: setting, for: id)
        #expect(try manager.hasSecret(setting, for: id))
        #expect(try context(for: SettingsPlugin.self, in: manager).secrets.secret(forKey: "secret") == "token")
        #expect(secrets.items == ["local.arch.browser.plugin.org.example.settings \(persona.uuidString)/secret": "token"])
        #expect(try self.manager([SettingsPlugin.self]).hasSecret(setting, for: id) == false)
        try manager.setSecret(nil, of: setting, for: id)
        #expect(secrets.items.isEmpty)
    }

    @Test func setsBadgesOnlyOnThePluginsOwnSidebarItems() throws {
        let manager = manager([PanelPlugin.self])
        let context = try context(for: PanelPlugin.self, in: manager)
        let items = manager.contributions.sidebarItems
        context.setBadge("3", onSidebarItem: "panel")
        context.setBadge("1", onSidebarItem: "unlisted")
        #expect(items.map(manager.badge(on:)) == ["3", nil])
        context.setBadge("", onSidebarItem: "panel")
        #expect(manager.badge(on: items[0]) == nil)
        context.setBadge("2", onSidebarItem: "panel")
        manager.setEnabled(false, for: PanelPlugin.manifest.id)
        manager.setEnabled(true, for: PanelPlugin.manifest.id)
        #expect(manager.badge(on: items[0]) == nil)
    }

    @Test func opensThePanelsOfEnabledPlugins() async throws {
        let manager = manager([PanelPlugin.self])
        let items = manager.contributions.sidebarItems
        #expect(await manager.panel(for: items[0])?.title == "panel")
        #expect(Recorder.activations.count == 1)
        #expect(await manager.panel(for: items[1]) == nil)
        manager.setEnabled(false, for: PanelPlugin.manifest.id)
        #expect(await manager.panel(for: items[0]) == nil)
    }

    @Test func tellsWhichPagesThePageScriptsCover() {
        let manager = manager([PageScriptPlugin.self, DisabledPageScriptPlugin.self])
        let cases: [(PluginID, String, Bool)] = [
            (PageScriptPlugin.manifest.id, "https://example.org/a", true),
            (PageScriptPlugin.manifest.id, "https://other.example/a", false),
            (DisabledPageScriptPlugin.manifest.id, "https://example.org/a", false),
        ]
        for (id, address, covers) in cases {
            #expect(manager.pageScriptsCover(URL(string: address)!, of: id) == covers, "\(id) \(address)")
        }
    }
}

@MainActor
@Suite struct PageAddressPluginTests {
    private let tab = PluginTab(id: UUID(), spaceID: UUID(), title: "Example", url: URL(string: "https://example.org/")!, engine: .chromium, isPinned: false, isSelected: true)
    private let folder = TemporaryFolder()

    @Test func asksForWhatItUses() {
        let contributions = PageAddressPlugin.manifest.contributions
        #expect(PageAddressPlugin.manifest.permissions == [.tabs, .clipboard])
        #expect(contributions.commands.map(\.id) == ["copy"] && contributions.commands[0].shortcut?.description == "shift+cmd+c")
        #expect(contributions.menuItems.map(\.location) == [.pluginsMenu, .pageContextMenu([.page]), .tabContextMenu])
        #expect(contributions.settings.map(\.key) == ["markdown"])
    }

    @Test func failsWithoutAPage() async throws {
        let manager = PluginManager(persona: UUID(), directory: folder.url, builtIns: [PageAddressPlugin.self], secretStore: MemorySecretStore())
        let plugin = PageAddressPlugin()
        try await plugin.activate(in: manager.makeContext(for: manager.plugins[0]))
        var blank = tab
        blank.url = nil
        for page in [nil, blank] {
            await #expect(throws: PluginError.noPage) { try await plugin.run("copy", PluginInvocation(tab: page)) }
        }
    }

    @Test func writesMarkdownLinks() {
        let url = URL(string: "https://example.org/a_(b)")!
        #expect(PageAddressPlugin.markdownLink(title: #"Notes [draft] \ 1"#, url: url) == #"[Notes \[draft\] \\ 1](https://example.org/a_\(b\))"#)
        #expect(PageAddressPlugin.markdownLink(title: "Two\nLines", url: url) == #"[Two Lines](https://example.org/a_\(b\))"#)
        #expect(PageAddressPlugin.markdownLink(title: "", url: URL(string: "https://example.org/")!) == "[https://example.org/](https://example.org/)")
    }
}

@MainActor
@Suite struct PluginPageScriptTests {
    private let folder = TemporaryFolder()
    private let world = PluginID(rawValue: "org.example.page-script")!.pageScriptWorld

    private func manager() -> PluginManager {
        PluginManager(persona: UUID(), directory: folder.url, builtIns: [PageScriptPlugin.self, DisabledPageScriptPlugin.self], secretStore: MemorySecretStore())
    }

    @Test func runsTheScriptsOfEnabledPluginsInTheirWorlds() {
        let scripts = manager().contributions.pageScripts
        #expect(scripts.map(\.world) == ["ARCHPlugin.org.example.page-script", "ARCHPlugin.org.example.page-script"])
        #expect(scripts.map(\.injectionTime) == [.documentStart, .documentEnd])
        #expect(scripts.map(\.mainFrameOnly) == [true, false])
    }

    @Test func startsOnlyWhereThePatternsAndTheGrantCoverThePage() throws {
        let script = PluginPageScript(matches: [try MatchPattern("*://*/docs/*")], source: "ran = arch; // A final comment")
        let engineScript = try #require(script.engineScript(world: world, sites: [try MatchPattern("https://example.org/*"), try MatchPattern("https://*.a.example.org/*")]))
        let cases: [(String, Bool)] = [
            ("https://example.org/docs/a", true),
            ("https://a.example.org/docs/?q=1", true),
            ("https://b.a.example.org/docs/", true),
            ("https://b.example.org/docs/a", false),
            ("https://example.org/other", false),
            ("http://example.org/docs/a", false),
        ]
        // On Chromium, the guard of a document-end script runs after the page's scripts, which may have replaced built-ins and added properties to prototypes.
        let pageChanges = """
        Array.prototype.some = function () { return true; };
        String.prototype.slice = function () { return "https"; };
        String.prototype.indexOf = function () { return -1; };
        String.prototype.endsWith = function () { return true; };
        Object.prototype.host = "other.example";
        """
        for page in ["", pageChanges] {
            for (address, runs) in cases {
                let context = try #require(JSContext())
                context.setObject(location(address), forKeyedSubscript: "location" as NSString)
                context.evaluateScript("var ran = null; const channel = {};\n" + page)
                context.evaluateScript("(\(engineScript.source))(channel);")
                #expect(context.exception == nil, "\(address)")
                #expect(context.evaluateScript("ran === channel").toBool() == runs, "\(address)\(page.isEmpty ? "" : " after page changes")")
            }
        }
    }

    @Test func skipsTheAddressesItExcludes() throws {
        let sites = [try MatchPattern("https://example.org/*")]
        let script = PluginPageScript(matches: sites, excludes: [try MatchPattern("https://example.org/private/*")], source: "ran = arch;")
        let engineScript = try #require(script.engineScript(world: world, sites: sites))
        for (address, runs) in [("https://example.org/a", true), ("https://example.org/private/a", false)] {
            let context = try #require(JSContext())
            context.setObject(location(address), forKeyedSubscript: "location" as NSString)
            context.evaluateScript("var ran = null; const channel = {};")
            context.evaluateScript("(\(engineScript.source))(channel);")
            #expect(context.evaluateScript("ran === channel").toBool() == runs, "\(address)")
            #expect(script.covers(URL(string: address)!) == runs, "\(address)")
        }
    }

    @Test func leavesOutSourcesThatAreNotFunctionBodiesOnTheirOwn() throws {
        let sites = [try MatchPattern("https://example.org/*")]
        // Each closes brackets of the function it would run in; the first two would then run on every page.
        for source in ["})(channel); }, (channel) => { ran = channel; ((arch) => {", "})(channel); }, ran = 1, (channel) => { ((arch) => {", "}"] {
            #expect(PluginPageScript(matches: sites, source: source).engineScript(world: world, sites: sites) == nil, "\(source)")
        }
        for source in ["", "return;", "ran = arch; // A final comment", #"const brace = "}"; /* } */"#] {
            #expect(PluginPageScript(matches: sites, source: source).engineScript(world: world, sites: sites) != nil, "\(source)")
        }
    }

    @Test func pageMatcherAgreesWithMatchPatterns() throws {
        let patterns = try ["<all_urls>", "https://example.com/*", "*://*.example.com/*", "https://example.com/docs/*", "https://example.com/search*",
                            "https://example.com/*.pdf", "https://example.com/a*b*c", "https://example.com/a%20b", "https://example.com/x?", "http://localhost/"].map(MatchPattern.init)
        let addresses = ["http://example.com/", "https://example.com/", "https://EXAMPLE.com/a", "https://example.com", "https://example.com:8443/a",
                         "https://www.example.com/", "https://example.com.test/", "https://example.com@other.test/", "https://other.test/?example.com",
                         "https://a.b.example.com/", "https://badexample.com/", "https://example.com/docs/", "https://example.com/docs", "https://example.com/Docs/a",
                         "https://example.com/search?q=arch", "https://example.com/a/b.pdf#page=2", "https://example.com/a.pdf?download=1",
                         "https://example.com/a-b-b-c", "https://example.com/a-c-b", "https://example.com/a%20b", "https://example.com/x?", "https://example.com/x?#f",
                         "http://localhost/", "file:///Users/example/page.html", "about:blank", "data:text/plain,a"]
        let context = try #require(JSContext())
        let matcher = try #require(context.evaluateScript("(\(MatchPattern.javaScriptMatcher))"))
        for pattern in patterns {
            let literal = try #require(context.evaluateScript(MatchPattern.javaScriptLiteral([pattern])))
            for address in addresses {
                let pageResult = matcher.call(withArguments: [location(address), literal])?.toBool()
                #expect(pageResult == pattern.matches(URL(string: address)!), "\(pattern) \(address)")
            }
        }
        #expect(context.exception == nil)
    }
}

/// The parts of `location` that page scripts read, as a browser writes them for `address`.
private func location(_ address: String) -> [String: String] {
    let url = URL(string: address)!
    let path = url.path()
    return ["protocol": url.scheme!.lowercased() + ":", "hostname": url.host()?.lowercased() ?? "", "pathname": path.isEmpty ? "/" : path, "href": address]
}

private func installed(_ id: String, name: String, commands: [PluginCommand], isEnabled: Bool = true) -> InstalledPlugin {
    installed(id, name: name, contributions: PluginContributions(commands: commands), isEnabled: isEnabled)
}

private func installed(_ id: String, name: String, contributions: PluginContributions, isEnabled: Bool = true) -> InstalledPlugin {
    let manifest = PluginManifest(id: PluginID(rawValue: id)!, name: name, version: "1", summary: "", contributions: contributions)
    return InstalledPlugin(manifest: manifest, grant: PluginGrant(requestedBy: manifest), isEnabled: isEnabled)
}

/// Secrets in memory by service and account, so that tests never touch the Keychain.
final class MemorySecretStore: PluginSecretStore {
    private(set) var items: [String: String] = [:]

    func secret(service: String, account: String) throws -> String? {
        items[service + " " + account]
    }

    func setSecret(_ secret: String?, service: String, account: String) throws {
        items[service + " " + account] = secret
    }

    func containsSecret(service: String, account: String) throws -> Bool {
        items[service + " " + account] != nil
    }

    func removeSecrets(service: String?, accountPrefix: String) throws {
        items = items.filter { key, _ in
            let parts = key.split(separator: " ", maxSplits: 1)
            let isOfService = service.map { parts[0] == $0 } ?? parts[0].hasPrefix(PluginKeychain.servicePrefix)
            return !(isOfService && parts[1].hasPrefix(accountPrefix))
        }
    }
}

/// `depth` arrays, each holding the next, around `null`.
private func nested(_ depth: Int) -> PluginValue {
    (0..<depth).reduce(PluginValue.null) { value, _ in .array([value]) }
}

/// A folder of its own for one test's files, removed when the test ends.
final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPluginsTests-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What the test plugins saw: the context of each activation, each deactivation, the invocation of each run, and each page script value. Only `PluginManagerTests` uses it, because Swift Testing runs suites in parallel and `.serialized` orders the tests of one suite only.
@MainActor
private enum Recorder {
    static var contexts: [any PluginContext] = []
    static var deactivations = 0
    static var invocations: [PluginInvocation] = []
    static var pageMessages: [PluginPageMessage] = []

    /// The Persona of each activation.
    static var activations: [PersonaID] { contexts.map(\.personaID) }
    /// The file behind the storage of each activation.
    static var storageFiles: [PluginStorageFile] { contexts.compactMap { ($0.storage as? ScopedPluginStorage)?.file } }
    /// The tab of each run.
    static var runs: [PluginTab?] { invocations.map(\.tab) }

    static func reset() {
        contexts = []
        deactivations = 0
        invocations = []
        pageMessages = []
    }

    static func record(_ context: any PluginContext) {
        contexts.append(context)
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

    func deactivate() async {
        Recorder.deactivations += 1
    }

    func run(_ command: String, _ invocation: PluginInvocation) async throws {
        Recorder.invocations.append(invocation)
    }

    /// Replies `["echo", body]`.
    func receive(_ message: PluginPageMessage) async throws -> PluginValue? {
        Recorder.pageMessages.append(message)
        return .array([.string("echo"), message.body])
    }

    /// Declared here, so that subclasses can override the protocol's default.
    func panel(for sidebarItemID: String) -> NSViewController? {
        nil
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

/// Two page scripts on example.org, which its grant covers: one for every page at document start in the main frame, one for `/docs/` at document end in every frame.
private func pageScriptManifest(_ id: String) -> PluginManifest {
    PluginManifest(id: PluginID(rawValue: id)!, name: id, version: "1", summary: "", sites: [try! MatchPattern("https://example.org/*")],
                   contributions: PluginContributions(pageScripts: [
                       PluginPageScript(matches: [try! MatchPattern("https://example.org/*")], source: "arch.send(1);", runAt: .documentStart),
                       PluginPageScript(matches: [try! MatchPattern("https://example.org/docs/*")], source: "", runAt: .documentEnd, allFrames: true),
                   ]))
}

@MainActor
private class PageScriptPlugin: RecordingPlugin {
    override class var manifest: PluginManifest { pageScriptManifest("org.example.page-script") }
}

@MainActor
private final class DisabledPageScriptPlugin: PageScriptPlugin {
    override class var manifest: PluginManifest { pageScriptManifest("org.example.disabled-page-script") }
    override class var isOnByDefault: Bool { false }
}

/// One field of each kind.
@MainActor
private final class SettingsPlugin: RecordingPlugin {
    override class var manifest: PluginManifest {
        PluginManifest(id: PluginID(rawValue: "org.example.settings")!, name: "Settings", version: "1", summary: "", contributions: PluginContributions(settings: [
            PluginSetting(key: "toggle", title: "Toggle", kind: .toggle(default: true)),
            PluginSetting(key: "text", title: "Text", kind: .text(default: "a")),
            PluginSetting(key: "number", title: "Number", kind: .number(default: 5, range: 1...10)),
            PluginSetting(key: "choice", title: "Choice", kind: .choice(default: "one", options: ["one", "two"])),
            PluginSetting(key: "secret", title: "Secret", kind: .secret),
        ]))
    }
}

/// A sidebar item that opens a panel titled with the item's identifier, and one that runs `record`.
@MainActor
private final class PanelPlugin: RecordingPlugin {
    override class var manifest: PluginManifest {
        PluginManifest(id: PluginID(rawValue: "org.example.panel")!, name: "Panel", version: "1", summary: "", contributions: PluginContributions(
            commands: [PluginCommand(id: "record", title: "Record")],
            sidebarItems: [
                PluginSidebarItem(id: "panel", title: "Panel", symbol: "sidebar.right", action: .panel),
                PluginSidebarItem(id: "command", title: "Command", symbol: "play", action: .command("record")),
            ]))
    }

    override func panel(for sidebarItemID: String) -> NSViewController? {
        let panel = NSViewController()
        panel.title = sidebarItemID
        return panel
    }
}
