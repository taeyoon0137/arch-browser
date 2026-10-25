// Script plugins: reading and staging packages from folders and archives, the packages Arch refuses, the scheme handler, and the sample plugin in `Fixtures/Sample` installed, run in its sandboxed web view, stopped when idle or hung, updated, removed, and listed again at launch.
import ARCHEngine
import Foundation
import Testing
@testable import Plugins

/// The sample script plugin's package folder.
private let sampleFolder = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Sample", isDirectory: true).absoluteURL
private let sampleID = PluginID(rawValue: "org.example.sample")!

@MainActor
@Suite struct ScriptPluginPackageTests {
    private let folder = TemporaryFolder()

    private func manager() -> PluginManager {
        PluginManager(persona: UUID(), directory: folder.url, builtIns: [PageAddressPlugin.self], secretStore: MemorySecretStore())
    }

    @Test func readsTheManifestOfAFolder() async throws {
        let package = try await manager().stage(sampleFolder)
        let manifest = package.manifest
        #expect(manifest.id == sampleID && manifest.name == "Sample" && manifest.version == "1.0")
        #expect(manifest.permissions == [.clipboard] && manifest.sites.map(\.description) == ["https://example.org/*"])
        #expect(package.background == "background.js" && package.sourceURL == sampleFolder)
        #expect(package.files == ["background.js", "plugin.json", "scripts/page.js"])
        let contributions = manifest.contributions
        #expect(contributions.commands.map(\.id) == ["remember", "probe", "wait"])
        #expect(contributions.commands[0].shortcut?.description == "ctrl+opt+r" && contributions.commands[0].keywords == ["save"])
        #expect(contributions.menuItems.map(\.location) == [.pageContextMenu([.page, .link]), .tabContextMenu])
        #expect(contributions.sidebarItems.map(\.action) == [.command("remember")])
        #expect(contributions.settings.map(\.kind) == [.text(default: "Remembered"), .number(default: 5, range: 1...10)])
        let script = try #require(contributions.pageScripts.first)
        #expect(script.excludes.map(\.description) == ["https://example.org/private/*"] && script.runAt == .documentEnd && !script.allFrames)
        #expect(script.source.contains("arch.send"))
    }

    @Test func stagesArchivesWithAndWithoutTheirTopFolder() async throws {
        for keepsFolder in [true, false] {
            let archive = folder.url.appendingPathComponent("Sample-\(keepsFolder).zip")
            try runDitto(["-c", "-k"] + (keepsFolder ? ["--keepParent"] : []) + [sampleFolder.path, archive.path])
            let package = try await manager().stage(archive)
            #expect(package.manifest.id == sampleID && package.sourceURL == archive)
            #expect(package.files == ["background.js", "plugin.json", "scripts/page.js"])
        }
    }

    @Test func refusesPackagesArchCannotRun() async throws {
        let manifest = #"{"id": "org.example.bad", "name": "Bad", "version": "1", "apiVersion": 1, "summary": "Bad.""#
        let cases: [(String, [String: String], PluginError)] = [
            ("empty", [:], .invalidPackage("The package has no plugin.json at its top level.")),
            ("not JSON", ["plugin.json": "{"], .invalidPackage("plugin.json is not valid JSON.")),
            ("newer API", ["plugin.json": #"{"apiVersion": 2, "events": ["pageLoaded"]}"#], .unsupportedAPIVersion(2)),
            ("unread key", ["plugin.json": manifest + #", "events": ["pageLoaded"]}"#], .invalidPackage("plugin.json: events is not a field Arch reads.")),
            ("unknown permission", ["plugin.json": manifest + #", "permissions": ["notifications"]}"#],
             .invalidPackage("plugin.json: permissions lists “notifications”, which Arch does not grant.")),
            ("command without background", ["plugin.json": manifest + #", "contributes": {"commands": [{"id": "a", "title": "A"}]}}"#],
             .invalidPackage("plugin.json: commands need a background script.")),
            ("missing background", ["plugin.json": manifest + #", "background": "missing.js"}"#],
             .invalidPackage("plugin.json: background names “missing.js”, which is not a file of the package.")),
            ("script outside", ["plugin.json": manifest + #", "contributes": {"pageScripts": [{"matches": ["<all_urls>"], "js": ["../outside.js"]}]}}"#],
             .invalidPackage("plugin.json: contributes.pageScripts[0].js names “../outside.js”, which is not a file of the package.")),
            ("script that closes its function", ["plugin.json": manifest + #", "contributes": {"pageScripts": [{"matches": ["<all_urls>"], "js": ["a.js"]}]}}"#,
                                                 "a.js": "})(channel); }, (channel) => { ((arch) => {"],
             .invalidPackage("plugin.json: a.js does not parse as the body of a function, as a page script must.")),
            ("unlisted command", ["plugin.json": manifest + #", "background": "b.js", "contributes": {"commands": [{"id": "a", "title": "A"}], "menus": [{"command": "b", "location": "spaceMenu"}]}}"#, "b.js": ""],
             .invalidPackage("plugin.json: contributes.menus[0].command names “b”, which contributes.commands does not list.")),
            ("default out of range", ["plugin.json": manifest + #", "contributes": {"settings": [{"key": "a", "title": "A", "type": "number", "default": 0, "min": 1, "max": 2}]}}"#],
             .invalidPackage("plugin.json: contributes.settings[0].default does not suit a number setting.")),
            ("built-in identifier", ["plugin.json": #"{"id": "local.arch.browser.page-address", "name": "A", "version": "1", "apiVersion": 1, "summary": "A."}"#],
             .invalidPackage("A plugin built into Arch has the identifier local.arch.browser.page-address.")),
        ]
        let manager = manager()
        for (name, files, expected) in cases {
            let package = try writePackage(name, files)
            await #expect(throws: expected, "\(name)") { try await manager.stage(package) }
        }
        let linked = try writePackage("link", ["plugin.json": manifest + "}"])
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("passwd"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        await #expect(throws: PluginError.invalidPackage("The package has a symbolic link, passwd, which could lead to files outside it.")) { try await manager.stage(linked) }
        let notArchive = folder.url.appendingPathComponent("notes.txt")
        try Data("text".utf8).write(to: notArchive)
        await #expect(throws: PluginError.invalidPackage("notes.txt is not a folder or a .zip archive.")) { try await manager.stage(notArchive) }
        // A refused package leaves nothing in the staging folder.
        let staging = try FileManager.default.contentsOfDirectory(atPath: folder.url.appendingPathComponent("Plugins").path).map {
            folder.url.appendingPathComponent("Plugins/\($0)/Staging").path
        }
        #expect(try staging.allSatisfy { try FileManager.default.contentsOfDirectory(atPath: $0).isEmpty })
    }

    @Test func discardsStagedPackagesOnly() async throws {
        let manager = manager()
        let package = try await manager.stage(sampleFolder)
        manager.discard(try PluginPackage(at: sampleFolder, source: sampleFolder))
        #expect(FileManager.default.fileExists(atPath: sampleFolder.appendingPathComponent("plugin.json").path))
        manager.discard(package)
        #expect(!FileManager.default.fileExists(atPath: package.rootURL.path))
    }

    @Test func findsOnlyFilesOfThePackage() {
        #expect(PluginPackage.file("scripts/page.js", in: sampleFolder) != nil)
        for path in ["", "/plugin.json", "../Sample/plugin.json", "scripts/../plugin.json", "./plugin.json", "scripts//page.js", "scripts", "missing.js"] {
            #expect(PluginPackage.file(path, in: sampleFolder) == nil, "\(path)")
        }
    }

    @Test func servesThePackageWithThePolicy() throws {
        let handler = PluginSchemeHandler(package: try PluginPackage(at: sampleFolder, source: sampleFolder))
        let document = handler.response(for: URL(string: "arch-plugin://org.example.sample/")!)
        #expect(document.status == 200 && document.contentType == "text/html; charset=utf-8")
        #expect(String(decoding: document.body, as: UTF8.self) == #"<!doctype html><meta charset="utf-8"><script src="/background.js"></script>"#)
        let script = handler.response(for: URL(string: "arch-plugin://org.example.sample/scripts/page.js")!)
        #expect(script.status == 200 && script.contentType == "text/javascript; charset=utf-8" && !script.body.isEmpty)
        for address in ["arch-plugin://org.example.sample/../Sample/plugin.json", "arch-plugin://org.example.sample/%2E%2E/Sample/plugin.json",
                        "arch-plugin://org.example.other/plugin.json", "https://org.example.sample/plugin.json", "arch-plugin://org.example.sample/missing.js"] {
            #expect(handler.response(for: URL(string: address)!).status == 404, "\(address)")
        }
    }

    /// A package folder named `name` with the files' text at their paths.
    private func writePackage(_ name: String, _ files: [String: String]) throws -> URL {
        let root = folder.url.appendingPathComponent("Packages/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }
}

@MainActor
@Suite struct ScriptPluginRuntimeTests {
    private let folder = TemporaryFolder()
    private let secrets = MemorySecretStore()
    private let persona = UUID()
    private let tab = PluginTab(id: UUID(), spaceID: UUID(), title: "A", url: URL(string: "https://example.org/a")!, engine: .webKit, isPinned: false, isSelected: true)

    private func manager(_ limits: ScriptPluginLimits = .standard) -> PluginManager {
        PluginManager(persona: persona, directory: folder.url, builtIns: [], secretStore: secrets, scriptLimits: limits)
    }

    /// The sample plugin, installed enabled with its sites and without `clipboard`.
    private func installSample(in manager: PluginManager, from source: URL = sampleFolder) async throws {
        let package = try await manager.stage(source)
        try manager.install(package, grant: PluginGrant(permissions: [], sites: package.manifest.sites), isEnabled: true)
    }

    private func run(_ command: String, in manager: PluginManager, _ invocation: PluginInvocation = PluginInvocation(tab: nil)) async {
        await manager.run(PluginCommandRef(plugin: sampleID, command: command), invocation)
    }

    private func stored(_ key: String, in manager: PluginManager) throws -> PluginValue? {
        manager.makeContext(for: try #require(manager.plugins.first { $0.id == sampleID })).storage.value(forKey: key)
    }

    @Test func showsTheContributionsOfAnInstalledPlugin() async throws {
        let manager = manager()
        try await installSample(in: manager)
        let contributions = manager.contributions
        #expect(contributions.paletteCommands(matching: "save").map(\.pluginName) == ["Sample"])
        #expect(contributions.menuSections(at: .pageContextMenu([.link])).map(\.pluginName) == ["Sample"])
        #expect(contributions.menuSections(at: .tabContextMenu).flatMap(\.items).map(\.title) == ["Remember"])
        #expect(contributions.menuSections(at: .pluginsMenu).flatMap(\.items).map(\.shortcut?.description) == ["ctrl+opt+r"])
        #expect(contributions.sidebarItems.map(\.item.id) == ["remembered"])
        #expect(contributions.pageScripts.map(\.world) == ["ARCHPlugin.org.example.sample"])
        #expect(manager.pageScriptsCover(URL(string: "https://example.org/a")!, of: sampleID))
        #expect(!manager.pageScriptsCover(URL(string: "https://example.org/private/a")!, of: sampleID))
        let installed = try #require(manager.plugins.first)
        #expect(installed.origin == .file(sampleFolder) && installed.installedAt != nil && installed.grant.permissions.isEmpty)
    }

    @Test func runsCommandsInTheBackgroundScript() async throws {
        let manager = manager()
        try await installSample(in: manager)
        await run("remember", in: manager, PluginInvocation(tab: tab, linkURL: URL(string: "https://example.org/link")))
        #expect(try stored("remembered", in: manager) == .object([
            "label": .string("Remembered"), "url": .string("https://example.org/a"), "link": .string("https://example.org/link"), "runs": .number(1),
        ]))
        #expect(manager.badge(on: manager.contributions.sidebarItems[0]) == "1")
        await run("remember", in: manager)
        // The same start of the background script ran both commands.
        let remembered = try #require(try stored("remembered", in: manager)?.fields)
        #expect(remembered["runs"] == .number(2) && remembered["url"] == .null)
    }

    @Test func answersPageScriptValues() async throws {
        let manager = manager()
        try await installSample(in: manager)
        let message = EnginePageScriptMessage(world: sampleID.pageScriptWorld, frameURL: URL(string: "https://example.org/a"), isMainFrame: true, json: #"{"title":"A"}"#)
        let reply = try #require(await manager.receive(message, from: tab))
        #expect(try JSONDecoder().decode(PluginValue.self, from: Data(reply.utf8)) == .object([
            "echo": .object(["title": .string("A")]), "frame": .string("https://example.org/a"), "tab": .string(tab.id.uuidString),
        ]))
    }

    @Test func keepsTheBackgroundScriptInItsSandboxAndGrant() async throws {
        let manager = manager()
        try await installSample(in: manager)
        await run("probe", in: manager)
        #expect(try stored("probe", in: manager) == .object([
            "eval": .string("EvalError"), "fetch": .string("TypeError"), "copy": .string("permissionDenied"),
            "reservedKey": .string("reservedKey"), "removed": .string("allowed"),
        ]))
    }

    @Test func stopsWhenIdleAndStartsAgainAtTheNextUse() async throws {
        let manager = manager(ScriptPluginLimits(hang: 10, idle: 0.2))
        try await installSample(in: manager)
        await run("remember", in: manager)
        try await Task.sleep(for: .milliseconds(600))
        // The badge outlives the start that set it.
        #expect(manager.badge(on: manager.contributions.sidebarItems[0]) == "1")
        await run("remember", in: manager)
        let remembered = try #require(try stored("remembered", in: manager)?.fields)
        // A new start of the background script ran the second command.
        #expect(remembered["runs"] == .number(1))
    }

    @Test func switchesOffAPluginWhoseBackgroundHangsThreeTimes() async throws {
        let manager = manager(ScriptPluginLimits(hang: 2, idle: 30))
        try await installSample(in: manager)
        await run("wait", in: manager)
        // The hung start is gone, and the next command starts the background script again.
        await run("remember", in: manager)
        let remembered = try #require(try stored("remembered", in: manager)?.fields)
        #expect(remembered["runs"] == .number(1))
        await run("wait", in: manager)
        #expect(manager.plugins[0].isEnabled && manager.plugins[0].failure == nil)
        await run("wait", in: manager)
        #expect(!manager.plugins[0].isEnabled)
        #expect(manager.plugins[0].failure == "Arch switched the plugin off after it failed three times within five minutes. The background script left a call unanswered for 2 seconds.")
        manager.setEnabled(true, for: sampleID)
        #expect(manager.plugins[0].failure == nil)
    }

    @Test func updatesThePackageAndKeepsTheStorage() async throws {
        let manager = manager()
        try await installSample(in: manager)
        await run("remember", in: manager)
        let update = folder.url.appendingPathComponent("Update", isDirectory: true)
        try FileManager.default.copyItem(at: sampleFolder, to: update)
        let manifestURL = update.appendingPathComponent("plugin.json")
        try Data(String(decoding: try Data(contentsOf: manifestURL), as: UTF8.self).replacingOccurrences(of: #""version": "1.0""#, with: #""version": "2.0""#).utf8).write(to: manifestURL)
        let package = try await manager.stage(update)
        try manager.install(package, grant: PluginGrant(permissions: [], sites: []), isEnabled: true)
        #expect(manager.plugins.map(\.manifest.version) == ["2.0"] && manager.plugins[0].grant.sites.isEmpty && manager.plugins[0].origin == .file(update))
        // The new package's background script starts anew and finds the storage.
        await run("remember", in: manager)
        let remembered = try #require(try stored("remembered", in: manager)?.fields)
        #expect(remembered["runs"] == .number(1))
        #expect(try String(contentsOf: folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/org.example.sample/package/plugin.json"), encoding: .utf8).contains("2.0"))
    }

    @Test func removesThePackageStorageAndSecretsOfThePersona() async throws {
        let manager = manager()
        try await installSample(in: manager)
        let installed = try #require(manager.plugins.first)
        try manager.makeContext(for: installed).secrets.setSecret("token", forKey: "key")
        try secrets.setSecret("other", service: "local.arch.browser.plugin.org.example.sample", account: "\(UUID().uuidString)/key")
        try manager.setValue(.string("Kept"), of: installed.manifest.contributions.settings[0], for: sampleID)
        try manager.remove(sampleID)
        #expect(manager.plugins.isEmpty && manager.contributions.pageScripts.isEmpty)
        #expect(secrets.items.count == 1 && secrets.items.values.first == "other")
        let pluginFolder = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/org.example.sample")
        // The setting's pending write does not bring the folder back.
        try await Task.sleep(for: .milliseconds(700))
        #expect(!FileManager.default.fileExists(atPath: pluginFolder.path))
        #expect(self.manager().plugins.isEmpty)
    }

    @Test func listsInstalledPluginsAtLaunch() async throws {
        try await installSample(in: manager())
        let relaunched = manager()
        let installed = try #require(relaunched.plugins.first)
        #expect(relaunched.plugins.count == 1 && installed.isEnabled && installed.origin == .file(sampleFolder))
        #expect(installed.grant == PluginGrant(permissions: [], sites: installed.manifest.sites))
        await run("remember", in: relaunched)
        #expect(try stored("remembered", in: relaunched) != nil)
    }
}

private extension PluginValue {
    /// The fields of an object.
    var fields: [String: PluginValue]? {
        if case let .object(fields) = self { return fields }
        return nil
    }
}

private func runDitto(_ arguments: [String]) throws {
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = arguments
    try ditto.run()
    ditto.waitUntilExit()
    #expect(ditto.terminationStatus == 0)
}
