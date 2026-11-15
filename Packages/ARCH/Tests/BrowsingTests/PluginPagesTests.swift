// Plugins' page scripts in the session's tabs (`docs/plugins.md`, Page scripts): a tab where a `whenInvoked` plugin has access takes the plugin's scripts after its Persona's, except while its web contents shares its script list with another tab's, as on WebKit a page that it opens does, and a web contents that the tab gets afterwards takes none of them.
import ARCHEngine
import Foundation
import LiveFolders
import Plugins
import Testing
@testable import Browsing

/// Reaches example.org only in a tab where the user runs its command.
@MainActor
private final class TabAccessPlugin: BuiltInPlugin {
    static let id = PluginID(rawValue: "org.example.tab-access")!
    static var manifest: PluginManifest {
        let sites = [try! MatchPattern("https://example.org/*")]
        return PluginManifest(id: id, name: "Tab Access", version: "1", summary: "", sites: sites, siteAccess: .whenInvoked,
                              contributions: PluginContributions(commands: [PluginCommand(id: "go", title: "Go")], pageScripts: [PluginPageScript(matches: sites, source: "")]))
    }

    static var isOnByDefault: Bool { true }

    init() {}

    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}
}

@MainActor @Suite struct PluginPagesTests {
    private let world = "ARCHPlugin.org.example.tab-access"

    /// The plugin's scripts among the page's.
    private func accessWorlds(of page: PageDouble) -> [String] {
        page.pageScripts.map(\.world).filter { $0 == world }
    }

    @Test func aTabWithAccessTakesItsScriptsOnlyWhileItsListIsItsOwn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPluginPagesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(registry: registry, userDataDirectory: directory, builtInPlugins: [TabAccessPlugin.self], cefVersion: nil,
                                         sessionSeal: .fixture, liveFolderAddresses: InMemoryLiveFolderKeychain())
        let space = try #require(session.spaces.first)
        let tab = session.openTab(url: URL(string: "https://example.org/x"), in: space.id, select: false)
        let page = try #require(tab.webContents as? PageDouble)
        let plugins = session.plugins(in: tab.personaID)
        #expect(accessWorlds(of: page).isEmpty)
        await plugins.run(PluginCommandRef(plugin: TabAccessPlugin.id, command: "go"), PluginInvocation(tab: session.pluginTab(tab)))
        #expect(accessWorlds(of: page) == [world])
        #expect(page.pageScripts == TabUnloading.pageScripts(withPluginScripts: plugins.pageScripts(forTab: tab.id)))

        // A page that the tab opens shares its list, so the list leaves out the access's scripts, which the opened page's documents would run too.
        let opened = PageDouble(url: URL(string: "https://example.org/opened"))
        opened.listOwner = page
        tab.webContents(page, didCreateNewWebContents: opened, targetURL: opened.url, disposition: .newBackgroundTab)
        let openedTab = try #require(session.tabs.first { $0.webContents === opened })
        #expect(accessWorlds(of: page).isEmpty && plugins.tabPageScripts[tab.id] != nil)
        // A change to the access while they share leaves it out too.
        await plugins.run(PluginCommandRef(plugin: TabAccessPlugin.id, command: "go"), PluginInvocation(tab: session.pluginTab(tab)))
        #expect(accessWorlds(of: page).isEmpty)
        // Once the opened page's tab closes, the tab's list takes them again.
        #expect(session.closeTab(openedTab))
        #expect(accessWorlds(of: page) == [world])

        // A web contents that the tab gets afterwards ends the access, so a later change to the tabs gives it none of its scripts.
        let replacement = PageDouble(url: URL(string: "https://example.org/x"))
        tab.webContents(page, didCreateReplacement: replacement)
        #expect(tab.webContents === replacement)
        _ = session.openTab(url: URL(string: "https://example.org/other"), in: space.id, select: false)
        #expect(accessWorlds(of: replacement).isEmpty)
    }
}
