// Site access modes (`docs/plugins.md`, Permissions; Page scripts): a manifest's `siteAccess`, the grant that keeps it in `plugins.json` where builds before it cannot read it, the review's first offer, the sentences and the confirmation for it, and a `whenInvoked` plugin reaching a tab's pages only after one of its commands ran there, on the host of that page, while the tab still showed the document the command ran on: its page scripts run in that page at once, again at a later command, and once in a document, and in the tab's later documents on the host, its page calls, page script values, and the tab's title and address reach it there, and the access ends when the tab commits a document of another host, gets another page, or closes, or the plugin is switched off.
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Plugins

/// Reaches example.org and its subdomains only where the user runs its command, whose invocation it keeps in its storage, and answers its page script's values.
@MainActor
private final class InvokedPlugin: BuiltInPlugin {
    static let id = PluginID(rawValue: "org.example.invoked")!
    static let sites = [try! MatchPattern("https://*.example.org/*")]
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "Invoked", version: "1", summary: "", sites: sites, siteAccess: .whenInvoked,
                       contributions: PluginContributions(commands: [PluginCommand(id: "go", title: "Go")],
                                                          pageScripts: [PluginPageScript(matches: sites, source: "globalThis.runs = (globalThis.runs || 0) + 1;")]))
    }

    static var isOnByDefault: Bool { true }
    private var context: (any PluginContext)?

    init() {}

    func activate(in context: any PluginContext) async throws {
        self.context = context
    }

    func run(_ command: String, _ invocation: PluginInvocation) async throws {
        try context?.storage.setValue(.string(invocation.tab?.url?.absoluteString ?? "none"), forKey: "invokedAt")
    }

    func receive(_ message: PluginPageMessage) async throws -> PluginValue? {
        .string("heard")
    }
}

/// Reaches example.org in every page it covers.
@MainActor
private final class ListedPlugin: BuiltInPlugin {
    static let id = PluginID(rawValue: "org.example.listed")!
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "Listed", version: "1", summary: "", sites: InvokedPlugin.sites,
                       contributions: PluginContributions(pageScripts: [PluginPageScript(matches: InvokedPlugin.sites, source: "")]))
    }

    static var isOnByDefault: Bool { true }

    init() {}

    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}
}

@MainActor
@Suite struct PluginSiteAccessTests {
    private let folder = TemporaryFolder()
    private let persona = UUID()
    private let bus = BrowserEventBus()
    private let host = PageHost()
    private let world = "ARCHPlugin.org.example.invoked"

    private func manager() -> PluginManager {
        PluginManager(persona: persona, directory: folder.url, builtIns: [InvokedPlugin.self, ListedPlugin.self], secretStore: MemorySecretStore(),
                      events: bus, browserHost: host)
    }

    private func context(in manager: PluginManager) throws -> ScopedPluginContext {
        manager.makeContext(for: try #require(manager.plugins.first { $0.id == InvokedPlugin.id }))
    }

    private func invoke(_ manager: PluginManager, on tab: PluginTab) async {
        await manager.run(PluginCommandRef(plugin: InvokedPlugin.id, command: "go"), PluginInvocation(tab: tab))
    }

    /// What the page script's runs left in the page: how often it ran, or nil when it never did.
    private func runs(in page: ScriptedPage?) -> Int32? {
        guard let value = page?.context.evaluateScript("globalThis.runs"), !value.isUndefined else { return nil }
        return value.toInt32()
    }

    private func message(from address: String) -> EnginePageScriptMessage {
        EnginePageScriptMessage(world: world, frameURL: URL(string: address), isMainFrame: true, json: #""hi""#)
    }

    @Test func aPluginReachesNoPageBeforeOneOfItsCommandsRunsInTheTab() async throws {
        let manager = manager()
        defer { manager.close() }
        let context = try context(in: manager)
        let tab = host.show("https://a.example.org/x")
        #expect(manager.contributions.pageScripts.map(\.world) == ["ARCHPlugin.org.example.listed"])
        #expect(manager.pageScripts(forTab: tab.id) == manager.contributions.pageScripts && manager.tabPageScripts.isEmpty)
        let address = try #require(tab.url)
        #expect(!manager.pageScriptsCover(address, of: InvokedPlugin.id) && manager.pageScriptsCover(address, of: ListedPlugin.id))
        #expect(try context.tabs().map(\.url) == [nil] && context.tabs().map(\.title) == [nil])
        await #expect(throws: PluginError.siteNotGranted) { _ = try await context.runPageScript(.source("return 1;"), in: tab.id) }
        #expect(throws: PluginError.siteNotGranted) { try context.postMessage(.number(1), toTab: tab.id) }
        #expect(await manager.receive(message(from: "https://a.example.org/x"), from: tab) == nil)
        #expect(host.pages[tab.id]?.worlds.isEmpty == true && runs(in: host.pages[tab.id]) == nil)
    }

    @Test func runningACommandGivesTheTabAccessOnItsHostAndRunsThePageScriptsThere() async throws {
        let manager = manager()
        defer { manager.close() }
        let context = try context(in: manager)
        let tab = host.show("https://a.example.org/x")
        let sameHost = host.show("https://a.example.org/y")
        await invoke(manager, on: tab)
        // The plugin sees the tab it ran on, and its page script ran in the page at once.
        #expect(context.storage.value(forKey: "invokedAt") == .string("https://a.example.org/x"))
        #expect(host.pages[tab.id]?.worlds == [world] && runs(in: host.pages[tab.id]) == 1)
        #expect(manager.tabPageScripts.keys.sorted() == [tab.id] && manager.tabPageScripts[tab.id]?.map(\.world) == [world])
        #expect(manager.pageScripts(forTab: tab.id) == manager.contributions.pageScripts + (manager.tabPageScripts[tab.id] ?? []))
        #expect(manager.pageScripts(forTab: sameHost.id) == manager.contributions.pageScripts)
        #expect(try context.tabs().map(\.url) == [tab.url, nil])
        #expect(try await context.runPageScript(.source("return location.href;"), in: tab.id) == .string("https://a.example.org/x"))
        try context.postMessage(.number(1), toTab: tab.id)
        #expect(host.pages[tab.id]?.posts.map(\.world) == [world])
        await #expect(throws: PluginError.siteNotGranted) { _ = try await context.runPageScript(.source("return 1;"), in: sameHost.id) }
        #expect(await manager.receive(message(from: "https://a.example.org/x"), from: tab) == #""heard""#)
        #expect(await manager.receive(message(from: "https://a.example.org/x"), from: sameHost) == nil)
        // A frame of another host in the tab is outside the access, although the granted sites cover it.
        #expect(await manager.receive(message(from: "https://b.example.org/frame"), from: tab) == nil)
        // Running a command again in the same document leaves the access as it is, and the scripts run once in a document.
        await invoke(manager, on: tab)
        #expect(runs(in: host.pages[tab.id]) == 1)
    }

    /// The access is for the document the user ran the command on: a command whose tab shows another document by the time it runs, as one that a page loads while its context menu is open, gives no access and does not run, nor does one on a host that no match pattern can name.
    @Test func aCommandRunsOnlyWithAccessToTheDocumentItRanOn() async throws {
        let manager = manager()
        defer { manager.close() }
        let context = try context(in: manager)
        let tab = host.show("https://a.example.org/x")
        var stale = tab
        stale.documentID = UUID()
        await invoke(manager, on: stale)
        #expect(manager.tabPageScripts.isEmpty && runs(in: host.pages[tab.id]) == nil && context.storage.value(forKey: "invokedAt") == nil)
        // The page moved to another host of the granted sites while the user chose the item on the first.
        host.tabs[0].url = URL(string: "https://mail.example.org/")
        host.tabs[0].documentURL = URL(string: "https://mail.example.org/")
        host.tabs[0].documentID = UUID()
        host.pages[tab.id]?.address = "https://mail.example.org/"
        await invoke(manager, on: tab)
        #expect(manager.tabPageScripts.isEmpty && runs(in: host.pages[tab.id]) == nil && context.storage.value(forKey: "invokedAt") == nil)
        await #expect(throws: PluginError.siteNotGranted) { _ = try await context.runPageScript(.source("return 1;"), in: tab.id) }
        // The granted sites cover a host with `_`, which no match pattern can name.
        let unnamed = host.show("https://a_b.example.org/x")
        await invoke(manager, on: unnamed)
        #expect(manager.tabPageScripts.isEmpty && runs(in: host.pages[unnamed.id]) == nil && context.storage.value(forKey: "invokedAt") == nil)
        // A page outside the granted sites gives no access, and the command runs there without its address.
        let outside = host.show("https://other.example/")
        await invoke(manager, on: outside)
        #expect(manager.tabPageScripts.isEmpty && context.storage.value(forKey: "invokedAt") == .string("none"))
    }

    /// A later command in the tab runs the scripts at once again, so a document that did not run them, as one that began while WebKit's flags switched plugins' page runs off, runs them then; each runs once in a document, whether the command or the tab's list ran it first.
    @Test func aLaterCommandRunsTheScriptsInADocumentThatDidNotRunThem() async throws {
        let manager = manager()
        defer { manager.close() }
        let tab = host.show("https://a.example.org/x")
        let page = try #require(host.pages[tab.id])
        page.needsGesture = true
        await invoke(manager, on: tab)
        #expect(manager.tabPageScripts[tab.id] != nil && runs(in: page) == nil)
        page.needsGesture = false
        await invoke(manager, on: tab)
        await invoke(manager, on: tab)
        #expect(runs(in: page) == 1)
        let script = try #require(manager.tabPageScripts[tab.id]?.first)
        page.executeJavaScriptWithoutUserGesture(script.source, inWorld: script.world) { _ in }
        #expect(runs(in: page) == 1)
    }

    /// The tab's scripts check the access's host, so a later document of another host that the granted sites cover runs none of them.
    @Test func theTabsScriptsRunOnlyOnTheHostOfTheAccess() async throws {
        let manager = manager()
        defer { manager.close() }
        let tab = host.show("https://a.example.org/x")
        await invoke(manager, on: tab)
        let script = try #require(manager.tabPageScripts[tab.id]?.first)
        for (address, expected) in [("https://a.example.org/later", Int32(1)), ("https://b.example.org/", nil), ("https://other.example/", nil)] {
            let page = ScriptedPage(address)
            page.executeJavaScriptWithoutUserGesture(script.source, inWorld: script.world) { _ in }
            #expect(runs(in: page) == expected, "\(address)")
        }
    }

    @Test func theAccessEndsWhenTheTabLeavesTheHostGetsAnotherPageOrThePluginIsSwitchedOff() async throws {
        let manager = manager()
        defer { manager.close() }
        let context = try context(in: manager)
        let tab = host.show("https://a.example.org/x")
        await invoke(manager, on: tab)
        // Another host that the granted sites cover ends the access, which coming back does not restore.
        for address in ["https://b.example.org/", "https://a.example.org/x"] {
            host.tabs[0].url = URL(string: address)
            host.tabs[0].documentURL = URL(string: address)
            await #expect(throws: PluginError.siteNotGranted) { _ = try await context.runPageScript(.source("return 1;"), in: tab.id) }
            #expect(manager.tabPageScripts.isEmpty, "\(address)")
        }
        await invoke(manager, on: host.tabs[0])
        #expect(manager.tabPageScripts[tab.id] != nil)
        // A new page, as after unloading or a change of engine.
        host.pages[tab.id] = ScriptedPage("https://a.example.org/x")
        #expect(throws: PluginError.siteNotGranted) { try context.postMessage(.number(1), toTab: tab.id) }
        #expect(manager.tabPageScripts.isEmpty)
        await invoke(manager, on: host.tabs[0])
        #expect(manager.tabPageScripts[tab.id] != nil && runs(in: host.pages[tab.id]) == 1)
        manager.setEnabled(false, for: InvokedPlugin.id)
        #expect(manager.tabPageScripts.isEmpty)
        manager.setEnabled(true, for: InvokedPlugin.id)
        let restarted = try self.context(in: manager)
        await #expect(throws: PluginError.siteNotGranted) { _ = try await restarted.runPageScript(.source("return 1;"), in: tab.id) }
    }

    /// The Persona's events end the access that a tab loses, so the session drops the tab's scripts without waiting for a plugin's next call.
    @Test func eventsOfTheTabEndTheAccessItLost() async throws {
        let manager = manager()
        defer { manager.close() }
        let first = host.show("https://a.example.org/x")
        let second = host.show("https://a.example.org/y")
        await invoke(manager, on: first)
        await invoke(manager, on: second)
        #expect(Set(manager.tabPageScripts.keys) == [first.id, second.id])
        let ref = { (tab: PluginTab) in BrowserTabRef(id: tab.id, personaID: persona, spaceID: tab.spaceID, kind: .open, engine: .webKit, url: tab.url) }
        host.tabs[0].documentURL = URL(string: "https://other.example/")
        bus.post(.pageLoaded(tab: ref(first), isRestore: false, isFirstLoadAfterOpen: false))
        #expect(await eventually { manager.tabPageScripts.keys.sorted() == [second.id] })
        bus.post(.tabClosed(tab: ref(second), reason: .user))
        #expect(await eventually { manager.tabPageScripts.isEmpty })
    }

    @Test func theGrantKeepsItsSiteAccessWhereEarlierBuildsCannotReadIt() throws {
        let sites = [try MatchPattern("https://example.org/*")]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let invoked = PluginGrant(permissions: [.tabs], sites: sites, siteAccess: .whenInvoked)
        let listed = PluginGrant(permissions: [.tabs], sites: sites)
        #expect(String(decoding: try encoder.encode(invoked), as: UTF8.self) == #"{"permissions":["tabs"],"sitesWhenInvoked":["https://example.org/*"]}"#)
        #expect(String(decoding: try encoder.encode(listed), as: UTF8.self) == #"{"permissions":["tabs"],"sites":["https://example.org/*"]}"#)
        #expect(try JSONDecoder().decode(PluginGrant.self, from: encoder.encode(invoked)) == invoked)
        #expect(try JSONDecoder().decode(PluginGrant.self, from: encoder.encode(listed)) == listed)
        /// The grant as builds before site access modes read it.
        struct EarlierGrant: Decodable {
            var permissions: Set<PluginPermission>
            var sites: [MatchPattern]
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EarlierGrant.self, from: encoder.encode(invoked)) }
    }

    @Test func theReviewOffersEveryWebsiteOneTabAtATimeAndTheGrantNeverExceedsTheManifest() throws {
        let everySite = [try MatchPattern("<all_urls>")]
        let commands = PluginContributions(commands: [PluginCommand(id: "go", title: "Go")])
        let id = try #require(PluginID(rawValue: "org.example.offer"))
        let broad = PluginManifest(id: id, name: "A", version: "1", summary: "", sites: everySite, contributions: commands)
        #expect(PluginGrant(offeredBy: broad, kind: .script).siteAccess == .whenInvoked)
        #expect(PluginGrant(offeredBy: broad, kind: .webExtension).siteAccess == .listedSites)
        #expect(PluginGrant(requestedBy: broad).siteAccess == .listedSites)
        var withoutCommands = broad
        withoutCommands.contributions = PluginContributions()
        #expect(PluginGrant(offeredBy: withoutCommands, kind: .script).siteAccess == .listedSites)
        var narrow = broad
        narrow.sites = [try MatchPattern("https://example.org/*")]
        #expect(PluginGrant(offeredBy: narrow, kind: .script).siteAccess == .listedSites)
        var asking = narrow
        asking.siteAccess = .whenInvoked
        #expect(PluginGrant(offeredBy: asking, kind: .script).siteAccess == .whenInvoked)

        let listedGrant = PluginGrant(permissions: [], sites: narrow.sites)
        #expect(listedGrant.limited(to: asking, kind: .script).siteAccess == .whenInvoked)
        let invokedGrant = PluginGrant(permissions: [], sites: narrow.sites, siteAccess: .whenInvoked)
        #expect(invokedGrant.limited(to: narrow, kind: .script).siteAccess == .whenInvoked)
        #expect(invokedGrant.limited(to: narrow, kind: .webExtension).siteAccess == .listedSites)
        // An update starts as the installed grant reaches its sites, unless the manifest asks for less.
        let installed = InstalledPlugin(kind: .script, manifest: narrow, grant: invokedGrant, isEnabled: true)
        #expect(PluginGrant(updating: installed, to: narrow).siteAccess == .whenInvoked)
        #expect(PluginGrant(updating: InstalledPlugin(kind: .script, manifest: narrow, grant: listedGrant, isEnabled: true), to: asking).siteAccess == .whenInvoked)
    }

    @Test func theGrantStatesItsSiteAccessAndAsksNoConfirmationForEveryWebsiteOneTabAtATime() throws {
        let sentence = "Only in a tab where you use one of its commands, until the tab leaves the website"
        let everySite = [try MatchPattern("<all_urls>")]
        #expect(PluginGrant(permissions: [], sites: everySite, siteAccess: .whenInvoked).summaries == ["Run scripts on pages from every website", sentence])
        #expect(PluginGrant(permissions: [], sites: everySite).summaries == ["Run scripts on pages from every website"])
        #expect(PluginGrant(permissions: [.clipboard], sites: [], siteAccess: .whenInvoked).summaries == ["Write text to the clipboard"])
        #expect(PluginGrant(permissions: [], sites: everySite, siteAccess: .whenInvoked).confirmationReason(for: "A") == nil)
        #expect(PluginGrant(permissions: [.nativeMessaging], sites: everySite, siteAccess: .whenInvoked).confirmationReason(for: "A")
            == "let \u{201C}A\u{201D} exchange messages with apps on this Mac")
        #expect(PluginGrant(permissions: [], sites: everySite).confirmationReason(for: "A") == "let \u{201C}A\u{201D} run scripts on every website")
        let manifest = PluginManifest(id: try #require(PluginID(rawValue: "org.example.sentences")), name: "A", version: "1", summary: "", sites: everySite,
                                      contributions: PluginContributions())
        let installed = InstalledPlugin(kind: .script, manifest: manifest, grant: PluginGrant(permissions: [], sites: everySite, siteAccess: .whenInvoked), isEnabled: true)
        #expect(installed.accessSummaries == ["Run scripts on pages from every website", sentence])
    }

    private let manifest = #"{"id": "org.example.access", "name": "Access", "version": "1", "apiVersion": 1, "summary": "Reaches pages.", "sites": ["https://example.org/*"]"#

    private func writePackage(_ files: [String: String]) throws -> URL {
        let root = folder.url.appendingPathComponent("Packages/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    @Test func aManifestAsksForSiteAccessAndTheInstallKeepsIt() async throws {
        let manager = manager()
        let commands = #", "background": "b.js", "contributes": {"commands": [{"id": "go", "title": "Go"}]}"#
        let package = try await manager.stage(try writePackage(["plugin.json": manifest + #", "siteAccess": "whenInvoked""# + commands + "}", "b.js": ""]))
        #expect(package.manifest.siteAccess == .whenInvoked)
        let listed = try await manager.stage(try writePackage(["plugin.json": manifest + #", "siteAccess": "listedSites""# + commands + "}", "b.js": ""]))
        #expect(listed.manifest.siteAccess == .listedSites)
        let refusals: [(String, PluginError)] = [
            (manifest + #", "siteAccess": "whenInvoked"}"#, .invalidPackage("plugin.json: siteAccess whenInvoked needs contributes.commands.")),
            (manifest + #", "siteAccess": "always"}"#, .invalidPackage("plugin.json: siteAccess must be listedSites or whenInvoked.")),
        ]
        for (text, error) in refusals {
            await #expect(throws: error) { try await manager.stage(try writePackage(["plugin.json": text])) }
        }
        manager.discard(package)
        // The review's choice of a plugin that asks for its sites as listed lasts.
        let id = try manager.install(listed, grant: PluginGrant(permissions: [], sites: listed.manifest.sites, siteAccess: .whenInvoked), isEnabled: true)
        #expect(manager.plugins.first { $0.id == id }?.grant.siteAccess == .whenInvoked)
        let list = try String(contentsOf: folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/plugins.json"), encoding: .utf8)
        #expect(list.contains("sitesWhenInvoked"))
        manager.close()
        let reopened = self.manager()
        defer { reopened.close() }
        #expect(reopened.plugins.first { $0.id == id }?.grant == PluginGrant(permissions: [], sites: listed.manifest.sites, siteAccess: .whenInvoked))
    }
}

/// Polls the main actor until the condition holds or ten seconds pass.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
