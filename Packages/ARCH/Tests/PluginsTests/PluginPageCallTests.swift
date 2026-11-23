// Tests plugins' page calls (`docs/plugins.md`, Plugins and the context; JavaScript API for script plugins).
// `runPageScript(_:in:)` runs a built-in plugin's script text or a script plugin's package file once in the tab's main frame.
// It runs in the plugin's world with its channel as `arch`. It returns the script's return value.
// It refuses another Persona's tab, a page outside the granted sites, and a tab without a page or whose document changed.
// It also refuses a document that the page's own check finds outside the sites and scripts the plugin may not run.
// A plugin with `ai` cannot reach a page on a site excluded from AI, even if the page moved there while the script ran.
// Tests also cover what a script throws. `postMessage(_:toTab:)` follows the same rules.
// The background script can use `arch.pages.run` and `post`. Time spent running a page script does not count toward the hang limit.
// A panel cannot use any of these calls.
import AI
import ARCHEngine
import Events
import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Plugins

/// Runs the engine's main-frame scripts in its own JavaScriptCore context, with `location` for its address.
/// The channel's `send` records what scripts send. The page records values posted to its worlds.
final class ScriptedPage: EngineWebContents {
    /// The address of the document that scripts run in.
    var address: String
    /// Runs before each script, as a navigation that comes while the engine runs it.
    var onRun: (() -> Void)?
    /// Whether the engine fails each run, as for a page with no document to run in.
    var fails = false
    /// Whether the engine answers runs at all.
    /// WebKit does not answer while a script loops.
    var answers = true
    /// Whether the engine needs the user's gesture to run a script or deliver a message.
    /// WebKit does while the flags switch plugins' page runs off.
    var needsGesture = false
    /// How long the engine takes to answer each run.
    var delay: TimeInterval = 0
    private(set) var worlds: [String] = []
    private(set) var posts: [(json: String, world: String)] = []
    let context = JSContext()!

    init(_ address: String) {
        self.address = address
        context.evaluateScript("var sent = []; const channel = { send: (value) => { sent.push(value); return Promise.resolve(); }, onMessage: () => {} };")
    }

    /// Plugins' page calls never run a script with the user's gesture.
    func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {
        Issue.record("A page call ran a script with the user's gesture.")
        completion(.failure(CocoaError(.featureUnsupported)))
    }

    func executeJavaScriptWithoutUserGesture(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {
        guard !needsGesture else { return completion(.failure(EngineUserGestureError())) }
        worlds.append(world)
        onRun?()
        guard answers else { return }
        let reply: Result<String?, Error>
        if fails {
            reply = .failure(CocoaError(.featureUnsupported))
        } else {
            context.setObject(pageLocation(address), forKeyedSubscript: "location" as NSString)
            let result = context.evaluateScript("(\(script))(channel)")
            reply = .success(result?.isString == true ? result?.toString() : nil)
        }
        guard delay > 0 else { return completion(reply) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { completion(reply) }
    }

    func postPageScriptMessage(_ json: String, toWorld world: String) throws {
        guard !needsGesture else { throw EngineUserGestureError() }
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
func pageLocation(_ address: String) -> [String: String] {
    let url = URL(string: address)!
    let path = url.path()
    return ["protocol": url.scheme!.lowercased() + ":", "hostname": url.host()?.lowercased() ?? "", "pathname": path.isEmpty ? "/" : path, "href": address]
}

/// The Persona's tabs and their pages, which the tests set.
@MainActor
final class PageHost: PluginBrowserHost {
    var tabs: [PluginTab] = []
    var pages: [UUID: ScriptedPage] = [:]

    func tabs(in persona: PersonaID) -> [PluginTab] { tabs }
    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool { false }
    func webContents(forTab id: UUID) -> (any EngineWebContents)? { pages[id] }
    func selectedTab(in persona: PersonaID) -> UUID? { nil }
    func openTab(_ url: URL, _ options: PluginOpenTabOptions, in persona: PersonaID, cause: BrowserEventCause) throws -> UUID { throw PluginError.closed }
    func closeTab(_ id: UUID, cause: BrowserEventCause) {}
    func selectTab(_ id: UUID, cause: BrowserEventCause) {}
    func moveTab(_ id: UUID, to place: PluginTabPlace, cause: BrowserEventCause) throws -> Bool { false }

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

/// Reaches example.org and the local network.
/// `AIPageCallsPlugin` also asks for `ai`.
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

    private func manager(ai: AIService? = nil, hang: TimeInterval = 10) -> PluginManager {
        PluginManager(persona: UUID(), directory: folder.url, builtIns: [PageCallsPlugin.self, AIPageCallsPlugin.self], secretStore: MemorySecretStore(),
                      scriptLimits: ScriptPluginLimits(hang: hang, idle: 30), browserHost: host, ai: ai)
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
        await #expect(throws: PluginError.siteNotGranted) { _ = try await context.runPageScript(script, in: other.id) }
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

    /// The page's own check catches a document that changed after the call checked the tab.
    /// The call catches a tab that moved to another document while the script ran.
    @Test func runsAndReturnsOnlyInTheDocumentItChecked() async throws {
        let manager = manager()
        let context = try context(PageCallsPlugin.self, in: manager)
        let tab = host.show("https://example.org/a")
        let page = try #require(host.pages[tab.id])
        page.address = "https://other.example/"
        await #expect(throws: PluginError.siteNotGranted) { _ = try await context.runPageScript(.source("ran = true; return 1;"), in: tab.id) }
        #expect(page.context.evaluateScript("typeof ran")?.toString() == "undefined")

        page.address = "https://example.org/a"
        page.onRun = { [host] in host.tabs[0].documentID = UUID() }
        await #expect(throws: PluginError.noPage) { _ = try await context.runPageScript(.source("return 1;"), in: tab.id) }
    }

    /// WebKit waits for a page as long as a script loops in it.
    /// A run waits for the page only until the hang limit.
    /// Stopping the instance ends the wait at once.
    @Test func aRunThatThePageLeavesUnansweredEnds() async throws {
        let manager = manager(hang: 0.3)
        let context = try context(PageCallsPlugin.self, in: manager)
        let tab = host.show("https://example.org/a")
        let page = try #require(host.pages[tab.id])
        page.answers = false
        let started = ContinuousClock.now
        await #expect(throws: PluginError.timedOut) { _ = try await context.runPageScript(.source("return 1;"), in: tab.id) }
        #expect(ContinuousClock.now - started >= .seconds(0.3))
        // An engine that fails the run after waiting as long, as Chromium's does, also times out.
        page.answers = true
        page.fails = true
        page.delay = 0.3
        await #expect(throws: PluginError.timedOut) { _ = try await context.runPageScript(.source("return 1;"), in: tab.id) }

        // The context holds its manager weakly.
        // The test does not reach this manager's limit.
        // An engine that fails the run sooner leaves no page.
        // Ending the context ends a run's wait.
        let unlimited = self.manager(hang: 10)
        let ending = try self.context(PageCallsPlugin.self, in: unlimited)
        page.delay = 0.05
        await #expect(throws: PluginError.noPage) { _ = try await ending.runPageScript(.source("return 1;"), in: tab.id) }
        page.answers = false
        let run = Task { try await ending.runPageScript(.source("return 1;"), in: tab.id) }
        try await Task.sleep(for: .milliseconds(50))
        let stop = ContinuousClock.now
        ending.end()
        await #expect(throws: PluginError.stopped) { _ = try await run.value }
        #expect(ContinuousClock.now - stop < .seconds(5))
        withExtendedLifetime(unlimited) {}
    }

    /// A run or message with the user's gesture would give the page's handlers user activation.
    /// An engine that cannot run the script or deliver the message without it does neither.
    /// WebKit does neither while the flags switch plugins' page runs off.
    @Test func runsNothingWhereTheEngineWouldGiveTheUsersGesture() async throws {
        let manager = manager()
        let context = try context(PageCallsPlugin.self, in: manager)
        let tab = host.show("https://example.org/a")
        let page = try #require(host.pages[tab.id])
        page.needsGesture = true
        await #expect(throws: PluginError.pageRunUnavailable) { _ = try await context.runPageScript(.source("ran = true; return 1;"), in: tab.id) }
        #expect(page.worlds.isEmpty && page.context.evaluateScript("typeof ran")?.toString() == "undefined")
        #expect(throws: PluginError.pageRunUnavailable) { try context.postMessage(.number(1), toTab: tab.id) }
        #expect(page.posts.isEmpty)
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

    /// A plugin with `ai` could send what a script read to a model as text.
    /// It cannot reach a page on a site excluded from AI.
    /// New settings exclude the local network.
    @Test func aPluginWithAIReachesNoPageOnSitesExcludedFromAI() async throws {
        let manager = manager(ai: AIService(directory: folder.url.appendingPathComponent("AI", isDirectory: true)))
        defer { manager.close() }
        let withAI = try context(AIPageCallsPlugin.self, in: manager)
        let withoutAI = try context(PageCallsPlugin.self, in: manager)
        let local = host.show("http://localhost:8080/")
        let localURL = URL(string: "http://localhost:8080/")!
        await #expect(throws: PluginError.siteNotGranted) { _ = try await withAI.runPageScript(.source("return 1;"), in: local.id) }
        #expect(throws: PluginError.siteNotGranted) { try withAI.postMessage(.string("hi"), toTab: local.id) }
        #expect(host.pages[local.id]?.worlds == [] && host.pages[local.id]?.posts.isEmpty == true)
        #expect(try await withoutAI.runPageScript(.source("return 1;"), in: local.id) == .number(1))

        // A single-page site can move to an excluded address within its document while the script runs.
        let open = host.show("https://example.org/a")
        let index = host.tabs.count - 1
        host.pages[open.id]?.onRun = { [host] in host.tabs[index].url = localURL }
        await #expect(throws: PluginError.siteNotGranted) { _ = try await withAI.runPageScript(.source("return 1;"), in: open.id) }
        #expect(try await withoutAI.runPageScript(.source("return 1;"), in: open.id) == .number(1))
        // What a script throws can hold the page's text as well.
        let throwing = PluginScript.source(#"throw new Error("the page's text");"#)
        host.tabs[index].url = URL(string: "https://example.org/a")
        await #expect(throws: PluginError.siteNotGranted) { _ = try await withAI.runPageScript(throwing, in: open.id) }
        #expect(host.pages[open.id]?.worlds.count == 3)
        await #expect(throws: PluginError.pageScriptFailed("the page's text")) { _ = try await withoutAI.runPageScript(throwing, in: open.id) }
    }

    @Test func postsValuesToThePluginsPageScripts() throws {
        let manager = manager()
        let context = try context(PageCallsPlugin.self, in: manager)
        let tab = host.show("https://example.org/a")
        try context.postMessage(.object(["n": .number(1)]), toTab: tab.id)
        #expect(host.pages[tab.id]?.posts.map(\.json) == [#"{"n":1}"#] && host.pages[tab.id]?.posts.map(\.world) == ["ARCHPlugin.org.example.page-calls"])
        let other = host.show("https://other.example/")
        #expect(throws: PluginError.siteNotGranted) { try context.postMessage(.null, toTab: other.id) }
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
            "plugin.json": #"{"id": "org.example.page-reader", "name": "Page Reader", "version": "1", "apiVersion": 1, "summary": "Reads.", "sites": ["https://example.org/*"], "background": "b.js", "contributes": {"commands": [{"id": "read", "title": "Read"}, {"id": "twice", "title": "Read Twice"}, {"id": "unanswered", "title": "Read and Wait"}], "sidebarItems": [{"id": "panel", "title": "Panel", "symbol": "sidebar.right", "panel": "panel.html"}]}}"#,
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
            arch.commands.onRun("twice", async (invocation) => {
              const read = () => outcome(() => arch.pages.run(invocation.tab.id, "read.js"));
              await arch.storage.set("twice", [await read(), await read()]);
            });
            arch.commands.onRun("unanswered", async (invocation) => {
              await arch.storage.set("unanswered", await outcome(() => arch.pages.run(invocation.tab.id, "read.js")));
              await new Promise(() => {});
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

    /// Runs the command on the tab and returns what it stored under its name.
    private func run(_ command: String = "read", in manager: PluginManager, on tab: PluginTab) async throws -> PluginValue? {
        await manager.run(PluginCommandRef(plugin: id, command: command), PluginInvocation(tab: tab))
        return manager.makeContext(for: try #require(manager.plugins.first)).storage.value(forKey: command)
    }

    @Test func theBackgroundScriptRunsPackageFilesInPagesAndPostsToThem() async throws {
        let manager = try await manager()
        defer { manager.close() }
        let tab = host.show("https://example.org/a")
        #expect(try await run(in: manager, on: tab) == .object([
            "value": .object(["href": .string("https://example.org/a"), "sends": .string("function")]),
            "missing": .string("invalidPageScript"), "closing": .string("invalidPageScript"), "other": .string("notGranted"), "posted": .string("done"),
        ]))
        let page = try #require(host.pages[tab.id])
        #expect(page.worlds == ["ARCHPlugin.org.example.page-reader"])
        #expect(page.posts.map(\.json) == [#"{"hello":"page"}"#] && page.posts.map(\.world) == ["ARCHPlugin.org.example.page-reader"])
    }

    /// Page runs that together take longer than the hang limit hold up Arch's answers, not the background script. The limit leaves the background document time to load while other tests run.
    @Test func aPageRunDoesNotCountTowardTheHangLimit() async throws {
        let manager = try await manager(hang: 3)
        defer { manager.close() }
        let tab = host.show("https://example.org/a")
        host.pages[tab.id]?.delay = 2
        let value = PluginValue.object(["href": .string("https://example.org/a"), "sends": .string("function")])
        #expect(try await run("twice", in: manager, on: tab) == .array([value, value]))
    }

    /// A run that the page leaves unanswered rejects at the hang limit, as on a WebKit page while a script loops.
    /// The background script's own wait then counts again.
    /// A command that keeps waiting fails when it reaches the limit again.
    @Test func aRunThatThePageLeavesUnansweredEndsAtTheHangLimit() async throws {
        let manager = try await manager(hang: 3)
        defer { manager.close() }
        let tab = host.show("https://example.org/a")
        host.pages[tab.id]?.answers = false
        let started = ContinuousClock.now
        #expect(try await run("unanswered", in: manager, on: tab) == .string("timedOut"))
        let waited = ContinuousClock.now - started
        #expect(waited >= .seconds(6) && waited < .seconds(20), "\(waited)")
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
