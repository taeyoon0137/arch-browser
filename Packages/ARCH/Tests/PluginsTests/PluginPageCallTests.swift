// Plugins' page calls (`docs/plugins.md`, Plugins and the context; JavaScript API for script plugins): `runPageScript(_:in:)` running a built-in plugin's script text or a script plugin's package file once in the tab's main frame, in the plugin's world with its channel as `arch`, and returning what the script returns; refusing another Persona's tab, a page outside the granted sites, a tab without a page or whose document changed, a document that the page's own check finds outside the sites, scripts the plugin may not run, and for a plugin with `ai` a page on a site excluded from AI, also one the page moved to while the script ran; what a script throws; `postMessage(_:toTab:)` under the same rules; and `arch.pages.run` and `post` in the background script, with the time a page run takes not counted toward the hang limit, and none of them in a panel.
import AI
import ARCHEngine
import Events
import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Plugins

/// A page that runs the scripts the engine would run in its main frame in a JavaScriptCore context of its own, with `location` for its address and a channel whose `send` records what the scripts send, and records the values posted to its worlds.
private final class ScriptedPage: EngineWebContents {
    /// The address of the document that scripts run in.
    var address: String
    /// Runs before each script, as a navigation that comes while the engine runs it.
    var onRun: (() -> Void)?
    /// Whether the engine fails each run, as for a page with no document to run in.
    var fails = false
    /// How long the engine takes to answer each run.
    var delay: TimeInterval = 0
    private(set) var worlds: [String] = []
    private(set) var posts: [(json: String, world: String)] = []
    let context = JSContext()!

    init(_ address: String) {
        self.address = address
        context.evaluateScript("var sent = []; const channel = { send: (value) => { sent.push(value); return Promise.resolve(); }, onMessage: () => {} };")
    }

    func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {
        worlds.append(world)
        onRun?()
        guard !fails else { return completion(.failure(CocoaError(.featureUnsupported))) }
        context.setObject(pageLocation(address), forKeyedSubscript: "location" as NSString)
        let result = context.evaluateScript("(\(script))(channel)")
        let reply = result?.isString == true ? result?.toString() : nil
        guard delay > 0 else { return completion(.success(reply)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { completion(.success(reply)) }
    }

    func postPageScriptMessage(_ json: String, toWorld world: String) {
        posts.append((json, world))
    }

    let engineKind = EngineKind.webKit
    var url: URL? { URL(string: address) }
    let title = ""
    let favicon: NSImage? = nil
    let isLoading = false
    let canGoBack = false
    let canGoForward = false
    let restorableState: Data? = nil
    let isAudible = false
    let isCapturingMedia = false
    let isInPictureInPicture = false
    var zoomFactor = 1.0
    lazy var view = NSView()
    let navigationController: any EngineNavigationController = NavigationStub()
    let mediaSession: any EngineMediaSession = MediaStub()
    weak var uiDelegate: (any EngineWebContentsUIDelegate)?
    weak var navigationDelegate: (any EngineWebContentsNavigationDelegate)?
    weak var pageScriptDelegate: (any EnginePageScriptDelegate)?
    let closingStopsDownloads = false
    let devTools: (any EngineDevTools)? = nil

    func find(_ text: String, forward: Bool, matchCase: Bool, completion: @escaping (EngineFindResult) -> Void) {}
    func stopFind() {}
    func setPageScripts(_ scripts: [EnginePageScript]) {}
    func readableContent(limit: Int, completion: @escaping (Result<EngineReadableContent, Error>) -> Void) {}
    func captureViewport(completion: @escaping (NSImage?) -> Void) {}
    func captureFullPage(completion: @escaping (NSImage?) -> Void) {}
    func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {}
    func exitFullscreen() {}
    func tryToClose(completion: @escaping (Bool) -> Void) {}

    private final class MediaStub: EngineMediaSession {
        weak var delegate: (any EngineMediaSessionDelegate)?
        let playbackState = EngineMediaPlaybackState.none
        let position: EngineMediaPosition? = nil
        let metadata: EngineMediaMetadata? = nil
        let canGoToNextTrack = false
        let canGoToPreviousTrack = false
        func play() {}
        func pause() {}
        func nextTrack() {}
        func previousTrack() {}
    }

    private final class NavigationStub: EngineNavigationController, EngineBackForwardList {
        var backForwardList: any EngineBackForwardList { self }
        let backList: [any EngineBackForwardListItem] = []
        func load(_ request: URLRequest) {}
        func reload() {}
        func reloadWithoutCache() {}
        func stop() {}
        func goBack() {}
        func goForward() {}
        func go(to item: any EngineBackForwardListItem) {}
    }
}

/// The parts of `location` that the page's check reads, as a browser writes them for `address`.
private func pageLocation(_ address: String) -> [String: String] {
    let url = URL(string: address)!
    let path = url.path()
    return ["protocol": url.scheme!.lowercased() + ":", "hostname": url.host()?.lowercased() ?? "", "pathname": path.isEmpty ? "/" : path, "href": address]
}

/// The Persona's tabs and their pages, which the tests set.
@MainActor
private final class PageHost: PluginBrowserHost {
    var tabs: [PluginTab] = []
    var pages: [UUID: ScriptedPage] = [:]

    func tabs(in persona: PersonaID) -> [PluginTab] { tabs }
    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool { false }
    func webContents(forTab id: UUID) -> (any EngineWebContents)? { pages[id] }

    /// A tab whose engine committed a document at `address` and whose page runs scripts there.
    @discardableResult
    func show(_ address: String) -> PluginTab {
        let tab = PluginTab(id: UUID(), spaceID: UUID(), title: "Page", url: URL(string: address)!, engine: .webKit, isPinned: false, isSelected: true,
                            documentID: UUID(), documentURL: URL(string: address)!)
        tabs.append(tab)
        pages[tab.id] = ScriptedPage(address)
        return tab
    }
}

/// Reaches example.org and the local network; `AIPageCallsPlugin` also asks for `ai`.
@MainActor
private class PageCallsPlugin: BuiltInPlugin {
    class var id: PluginID { PluginID(rawValue: "org.example.page-calls")! }
    class var permissions: Set<PluginPermission> { [] }
    static var manifest: PluginManifest {
        PluginManifest(id: id, name: "Page Calls", version: "1", summary: "", permissions: permissions,
                       sites: [try! MatchPattern("https://example.org/*"), try! MatchPattern("http://localhost/*")], contributions: PluginContributions())
    }

    static var isOnByDefault: Bool { true }

    required init() {}

    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}
}

@MainActor
private final class AIPageCallsPlugin: PageCallsPlugin {
    override class var id: PluginID { PluginID(rawValue: "org.example.page-calls-ai")! }
    override class var permissions: Set<PluginPermission> { [.ai] }
}

@MainActor
@Suite struct PluginPageCallTests {
    private let folder = TemporaryFolder()
    private let host = PageHost()

    private func manager(ai: AIService? = nil) -> PluginManager {
        PluginManager(persona: UUID(), directory: folder.url, builtIns: [PageCallsPlugin.self, AIPageCallsPlugin.self], secretStore: MemorySecretStore(),
                      browserHost: host, ai: ai)
    }

    private func context(_ type: PageCallsPlugin.Type, in manager: PluginManager) throws -> ScopedPluginContext {
        manager.makeContext(for: try #require(manager.plugins.first { $0.id == type.id }))
    }

    @Test func runsAScriptInThePluginsWorldAndReturnsWhatItReturns() async throws {
        let manager = manager()
        let context = try context(PageCallsPlugin.self, in: manager)
        let tab = host.show("https://example.org/a")
        let page = try #require(host.pages[tab.id])
        #expect(try await context.runPageScript(.source(#"arch.send("hi"); return { href: location.href, list: [1, "a", true, null] };"#), in: tab.id) == .object([
            "href": .string("https://example.org/a"), "list": .array([.number(1), .string("a"), .bool(true), .null]),
        ]))
        #expect(page.worlds == ["ARCHPlugin.org.example.page-calls"])
        #expect(page.context.evaluateScript("JSON.stringify(sent)")?.toString() == #"["hi"]"#)
        for source in ["", "return undefined;", "return () => 1;", "return Symbol();"] {
            #expect(try await context.runPageScript(.source(source), in: tab.id) == .null, "\(source)")
        }
    }

    @Test func refusesTabsAndPagesOutsideTheGrant() async throws {
        let manager = manager()
        let context = try context(PageCallsPlugin.self, in: manager)
        let script = PluginScript.source("return 1;")
        let unknown = UUID()
        await #expect(throws: PluginError.notGranted(unknown)) { _ = try await context.runPageScript(script, in: unknown) }
        let other = host.show("https://other.example/")
        await #expect(throws: PluginError.siteNotGranted(URL(string: "https://other.example/")!)) { _ = try await context.runPageScript(script, in: other.id) }
        // The engine has committed no document yet.
        var blank = host.show("https://example.org/b")
        blank.documentURL = nil
        host.tabs[host.tabs.count - 1] = blank
        await #expect(throws: PluginError.noPage) { _ = try await context.runPageScript(script, in: blank.id) }
        let unloaded = host.show("https://example.org/c")
        host.pages[unloaded.id]?.fails = true
        await #expect(throws: PluginError.noPage) { _ = try await context.runPageScript(script, in: unloaded.id) }
        let gone = host.show("https://example.org/d")
        host.pages[gone.id] = nil
        await #expect(throws: PluginError.noPage) { _ = try await context.runPageScript(script, in: gone.id) }
        #expect(host.pages.values.allSatisfy { $0.worlds.isEmpty || $0.fails })

        context.end()
        await #expect(throws: PluginError.stopped) { _ = try await context.runPageScript(script, in: other.id) }
    }

    /// The page's own check catches a document that changed after the call checked the tab, and the call catches a tab that moved to another document while the script ran.
    @Test func runsAndReturnsOnlyInTheDocumentItChecked() async throws {
        let manager = manager()
        let context = try context(PageCallsPlugin.self, in: manager)
        let tab = host.show("https://example.org/a")
        let page = try #require(host.pages[tab.id])
        page.address = "https://other.example/"
        await #expect(throws: PluginError.siteNotGranted(URL(string: "https://example.org/a")!)) { _ = try await context.runPageScript(.source("ran = true; return 1;"), in: tab.id) }
        #expect(page.context.evaluateScript("typeof ran")?.toString() == "undefined")

        page.address = "https://example.org/a"
        page.onRun = { [host] in host.tabs[0].documentID = UUID() }
        await #expect(throws: PluginError.noPage) { _ = try await context.runPageScript(.source("return 1;"), in: tab.id) }
    }

    @Test func reportsWhatTheScriptThrew() async throws {
        let manager = manager()
        let context = try context(PageCallsPlugin.self, in: manager)
        let tab = host.show("https://example.org/a")
        let cases = [
            (#"throw new TypeError("bad");"#, "TypeError: bad"),
            (#"throw new Error("plain");"#, "plain"),
            (#"throw "text";"#, "text"),
            ("const cycle = {}; cycle.cycle = cycle; return cycle;", "The script returned a value that JSON cannot hold."),
        ]
        for (source, message) in cases {
            await #expect(throws: PluginError.pageScriptFailed(message), "\(source)") { _ = try await context.runPageScript(.source(source), in: tab.id) }
        }
    }

    @Test func runsOnlyScriptsThePluginMayRun() async throws {
        let manager = manager()
        let context = try context(PageCallsPlugin.self, in: manager)
        let tab = host.show("https://example.org/a")
        // A built-in plugin has no package.
        await #expect(throws: PluginError.self) { _ = try await context.runPageScript(.file("read.js"), in: tab.id) }
        // A source that closes the function it runs in would run outside the page's check.
        await #expect(throws: PluginError.invalidPageScript("The script does not parse as the body of a function, as a page script must.")) {
            _ = try await context.runPageScript(.source("})(channel); }, (channel) => { ((arch) => {"), in: tab.id)
        }
        #expect(host.pages[tab.id]?.worlds.isEmpty == true)
    }

    /// A plugin with `ai` could send what a script read to a model as text, so it reaches no page on a site excluded from AI, which new settings make the local network.
    @Test func aPluginWithAIReachesNoPageOnSitesExcludedFromAI() async throws {
        let manager = manager(ai: AIService(directory: folder.url.appendingPathComponent("AI", isDirectory: true)))
        defer { manager.close() }
        let withAI = try context(AIPageCallsPlugin.self, in: manager)
        let withoutAI = try context(PageCallsPlugin.self, in: manager)
        let local = host.show("http://localhost:8080/")
        let localURL = URL(string: "http://localhost:8080/")!
        await #expect(throws: PluginError.siteNotGranted(localURL)) { _ = try await withAI.runPageScript(.source("return 1;"), in: local.id) }
        #expect(throws: PluginError.siteNotGranted(localURL)) { try withAI.postMessage(.string("hi"), toTab: local.id) }
        #expect(host.pages[local.id]?.worlds == [] && host.pages[local.id]?.posts.isEmpty == true)
        #expect(try await withoutAI.runPageScript(.source("return 1;"), in: local.id) == .number(1))

        // A single-page site can move to an excluded address within its document while the script runs.
        let open = host.show("https://example.org/a")
        let index = host.tabs.count - 1
        host.pages[open.id]?.onRun = { [host] in host.tabs[index].url = localURL }
        await #expect(throws: PluginError.siteNotGranted(localURL)) { _ = try await withAI.runPageScript(.source("return 1;"), in: open.id) }
        #expect(try await withoutAI.runPageScript(.source("return 1;"), in: open.id) == .number(1))
    }

    @Test func postsValuesToThePluginsPageScripts() throws {
        let manager = manager()
        let context = try context(PageCallsPlugin.self, in: manager)
        let tab = host.show("https://example.org/a")
        try context.postMessage(.object(["n": .number(1)]), toTab: tab.id)
        #expect(host.pages[tab.id]?.posts.map(\.json) == [#"{"n":1}"#] && host.pages[tab.id]?.posts.map(\.world) == ["ARCHPlugin.org.example.page-calls"])
        let other = host.show("https://other.example/")
        #expect(throws: PluginError.siteNotGranted(URL(string: "https://other.example/")!)) { try context.postMessage(.null, toTab: other.id) }
        let unknown = UUID()
        #expect(throws: PluginError.notGranted(unknown)) { try context.postMessage(.null, toTab: unknown) }
        context.end()
        #expect(throws: PluginError.stopped) { try context.postMessage(.null, toTab: tab.id) }
        #expect(host.pages[tab.id]?.posts.count == 1 && host.pages[other.id]?.posts.isEmpty == true)
    }
}

/// A script plugin's background script calls `arch.pages`, and its panel cannot.
@MainActor
@Suite struct ScriptPluginPageCallTests {
    private let folder = TemporaryFolder()
    private let host = PageHost()
    private let id = PluginID(rawValue: "org.example.page-reader")!

    /// Installs the plugin, enabled with its sites, in a manager whose hang limit is `hang`.
    private func manager(hang: TimeInterval = 10) async throws -> PluginManager {
        let root = folder.url.appendingPathComponent("Packages/PageReader", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = [
            "plugin.json": #"{"id": "org.example.page-reader", "name": "Page Reader", "version": "1", "apiVersion": 1, "summary": "Reads.", "sites": ["https://example.org/*"], "background": "b.js", "contributes": {"commands": [{"id": "read", "title": "Read"}], "sidebarItems": [{"id": "panel", "title": "Panel", "symbol": "sidebar.right", "panel": "panel.html"}]}}"#,
            "b.js": """
            const outcome = async (attempt) => {
              try {
                const result = await attempt();
                return result === undefined ? "done" : result;
              } catch (error) {
                return error.message;
              }
            };
            arch.commands.onRun("read", async (invocation) => {
              const id = invocation.tab.id;
              await arch.storage.set("read", {
                value: await outcome(() => arch.pages.run(id, "read.js")),
                missing: await outcome(() => arch.pages.run(id, "missing.js")),
                closing: await outcome(() => arch.pages.run(id, "close.js")),
                other: await outcome(() => arch.pages.run("\(UUID().uuidString)", "read.js")),
                posted: await outcome(() => arch.pages.post(id, { hello: "page" })),
              });
            });
            """,
            "read.js": "return { href: location.href, sends: typeof arch.send };",
            "close.js": "}",
            "panel.html": #"<!doctype html><meta charset="utf-8">"#,
        ]
        for (path, text) in files {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        let manager = PluginManager(persona: UUID(), directory: folder.url, builtIns: [], secretStore: MemorySecretStore(),
                                    scriptLimits: ScriptPluginLimits(hang: hang, idle: 30), browserHost: host)
        let package = try await manager.stage(root)
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        return manager
    }

    private func read(in manager: PluginManager, on tab: PluginTab) async throws -> PluginValue? {
        await manager.run(PluginCommandRef(plugin: id, command: "read"), PluginInvocation(tab: tab))
        return manager.makeContext(for: try #require(manager.plugins.first)).storage.value(forKey: "read")
    }

    @Test func theBackgroundScriptRunsPackageFilesInPagesAndPostsToThem() async throws {
        let manager = try await manager()
        defer { manager.close() }
        let tab = host.show("https://example.org/a")
        #expect(try await read(in: manager, on: tab) == .object([
            "value": .object(["href": .string("https://example.org/a"), "sends": .string("function")]),
            "missing": .string("invalidPageScript"), "closing": .string("invalidPageScript"), "other": .string("notGranted"), "posted": .string("done"),
        ]))
        let page = try #require(host.pages[tab.id])
        #expect(page.worlds == ["ARCHPlugin.org.example.page-reader"])
        #expect(page.posts.map(\.json) == [#"{"hello":"page"}"#] && page.posts.map(\.world) == ["ARCHPlugin.org.example.page-reader"])
    }

    /// A page that takes longer than the hang limit to run the script holds up Arch's answer, not the background script. The limit leaves the background document time to load while other tests run.
    @Test func aPageRunDoesNotCountTowardTheHangLimit() async throws {
        let manager = try await manager(hang: 1.5)
        defer { manager.close() }
        let tab = host.show("https://example.org/a")
        host.pages[tab.id]?.delay = 3
        guard case let .object(read)? = try await read(in: manager, on: tab) else {
            Issue.record("The command stored nothing.")
            return
        }
        #expect(read["value"] == .object(["href": .string("https://example.org/a"), "sends": .string("function")]))
        #expect(manager.plugins.first?.failure == nil)
    }

    @Test func aPanelHasNoPageCalls() async throws {
        let manager = try await manager()
        defer { manager.close() }
        let tab = host.show("https://example.org/a")
        let item = try #require(manager.contributions.sidebarItems.first)
        let panel = try #require(await manager.panel(for: item) as? ScriptPluginPanel)
        let webView = try #require(panel.view as? WKWebView)
        panel.viewWillAppear()
        defer { panel.viewDidDisappear() }
        #expect(await eventually { !webView.isLoading && webView.url != nil })
        let script = """
        const call = (name, args) => window.webkit.messageHandlers.arch.postMessage(JSON.stringify({ call: name, args })).then(() => "answered", (error) => error.message);
        return `${typeof arch.pages} ${await call("pages.run", ["\(tab.id.uuidString)", "read.js"])} ${await call("pages.post", ["\(tab.id.uuidString)", 1])}`;
        """
        #expect(try await webView.callAsyncJavaScript(script, contentWorld: .page) as? String == "undefined invalidCall invalidCall")
        #expect(host.pages[tab.id]?.worlds.isEmpty == true && host.pages[tab.id]?.posts.isEmpty == true)
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
