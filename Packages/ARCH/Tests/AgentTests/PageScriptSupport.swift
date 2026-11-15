// What the page script tests share: a WebKit web view without a window, or in one that is never ordered in for trusted input, over a non-persistent store, sized as a window's page and loaded with a fixture page at an https address, so that no request leaves the test and the page's origin is its own; and a tool host over the fake browser host whose agent tab is that web view.
import AgentControl
import AppKit
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing
@testable import Agent

@MainActor final class FixturePage {
    let contents: WebKitWebContents
    let url: URL
    /// The window that holds the web view, never ordered in, so that none is key and none is on screen.
    private(set) var window: NSWindow?

    private static let browser: any EngineBrowser = {
        let folder = FileManager.default.temporaryDirectory
        let application = try! WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder)) as! WebKitApplication
        return application.createBrowser(context: application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent()))
    }()

    /// Loads `Fixtures/<name>.html` at `https://fixture.example/<name>.html`, with `pageScripts`, in a window when `inWindow`.
    init(_ name: String, pageScripts: [EnginePageScript] = [], inWindow: Bool = false) async throws {
        url = URL(string: "https://fixture.example/\(name).html")!
        contents = try #require(Self.browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        contents.view.setFrameSize(NSSize(width: 1024, height: 768))
        if inWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(contents.view)
            self.window = window
        }
        contents.setPageScripts(pageScripts)
        let file = try #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
        contents.webView.loadHTMLString(try String(contentsOf: file, encoding: .utf8), baseURL: url)
        try await eventually { !self.contents.webView.isLoading && self.contents.webView.url == self.url }
        // The frames' documents load after the page's.
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Runs JavaScript in the page's own world and returns its value.
    func evaluate(_ script: String) async throws -> Any? {
        try await contents.webView.evaluateJavaScript(script)
    }

    /// Waits up to five seconds for `condition`.
    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition())
    }
}

/// A fake `EngineInput` over a tab's real one: it records each call, fails each with `failure` when set, runs `before` as a step of the page's that comes between Arch's checks and the input, as a page's timer would, and with `sendsNothing` sends nothing, as when the input lands where no listener of the page's document is.
final class RecordingInput: EngineInput {
    enum Call: Equatable {
        case move(CGPoint)
        case click(CGPoint, count: Int, modifiers: EngineInputModifiers)
        case scroll(CGPoint, deltaX: Double, deltaY: Double)
        case press(EngineKey, EngineInputModifiers)
        case text(String)
    }

    private let inner: any EngineInput
    private(set) var calls: [Call] = []
    var failure: EngineInputError?
    var before: (() -> Void)?
    var sendsNothing = false

    init(_ inner: any EngineInput) {
        self.inner = inner
    }

    func movePointer(to point: CGPoint, modifiers: EngineInputModifiers) throws {
        try send(.move(point)) { try $0.movePointer(to: point, modifiers: modifiers) }
    }

    func click(at point: CGPoint, count: Int, modifiers: EngineInputModifiers) throws {
        try send(.click(point, count: count, modifiers: modifiers)) { try $0.click(at: point, count: count, modifiers: modifiers) }
    }

    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double, modifiers: EngineInputModifiers) throws {
        try send(.scroll(point, deltaX: deltaX, deltaY: deltaY)) { try $0.scroll(at: point, deltaX: deltaX, deltaY: deltaY, modifiers: modifiers) }
    }

    func press(_ key: EngineKey, modifiers: EngineInputModifiers) throws {
        try send(.press(key, modifiers)) { try $0.press(key, modifiers: modifiers) }
    }

    func insertText(_ text: String) throws {
        try send(.text(text)) { try $0.insertText(text) }
    }

    private func send(_ call: Call, _ forward: (any EngineInput) throws -> Void) throws {
        calls.append(call)
        if let failure { throw failure }
        before?()
        if !sendsNothing { try forward(inner) }
    }
}

/// A grant's tool host whose agent tab t1 shows a fixture page in WebKit, with short waits. With `trustedInput`, the page is in a window with the agents' target check, and the tab's trusted input is a `RecordingInput` over WebKit's at the page's zoom.
@MainActor final class PageFixture {
    let host = FakeHost()
    let state = AgentGrantState()
    var grant: AgentGrant
    var toolHost: AgentToolHost
    let page: FixturePage
    let tabID = UUID()
    private(set) var input: RecordingInput?

    init(_ name: String = "form", level: AgentAccessLevel = .actInAgentTabs, shared: Bool = false, trustedInput: Bool = false, zoomFactor: Double = 1) async throws {
        page = try await FixturePage(name, pageScripts: trustedInput ? [AgentPageScripts.targetCheck] : [], inWindow: trustedInput)
        grant = AgentGrant(client: AgentClientIdentity(key: .signed(identifier: "com.example.claude", team: "ABCDE12345"), name: "claude", executablePath: "/usr/local/bin/claude",
                                                       host: "Terminal", isInterpreter: false),
                           personaID: FakeHost.defaultPersona.id, spaceID: host.spaces(in: FakeHost.defaultPersona.id)[0].id, level: level, scopes: AgentGrantScopes(),
                           expiry: .whenArchQuits, grantedAt: Date())
        toolHost = AgentToolHost(host: host, allowsAI: { $0.host != "excluded.example" })
        toolHost.scriptWait = 3
        toolHost.settleWait = 0.3
        toolHost.settlePause = 0.05
        toolHost.answerWait = 2
        toolHost.approvalWindow = 5
        toolHost.inputCheckWait = 0.5
        host.tabs.append(AgentTabInfo(id: tabID, spaceID: grant.spaceID, title: page.contents.title, url: page.url, isLoading: false, engine: .webKit,
                                      agentOwnerID: shared ? nil : grant.id))
        host.webContents[tabID] = page.contents
        if trustedInput {
            page.contents.zoomFactor = zoomFactor
            let input = RecordingInput(try #require(page.contents.input))
            host.inputs[tabID] = AgentTabInput(input: input, zoomFactor: zoomFactor)
            self.input = input
        }
        _ = state.handles.tabs.handle(for: tabID)
        if shared {
            state.handles.sharedTabIDs.append(tabID)
            state.handles.actingSharedTabIDs.insert(tabID)
        }
    }

    func call(_ name: String, _ arguments: [String: AgentJSON] = [:]) async -> AgentToolResult {
        await toolHost.run(AgentToolCall(name: name, arguments: arguments), for: grant, state: state).result
    }

    /// The snapshot's outline lines, inside its untrusted block.
    func outline(_ arguments: [String: AgentJSON] = [:]) async -> [String] {
        let result = await call("snapshot", ["tab": "t1"].merging(arguments) { $1 })
        #expect(result.status == .ok, "\(result.text)")
        guard let block = result.structured?["outline"]?.stringValue else { return [] }
        return block.components(separatedBy: "\n").dropFirst().map { $0.replacingOccurrences(of: "</untrusted>", with: "") }
    }

    /// The ref of the first outline line that contains `text`.
    func ref(_ text: String, in lines: [String]) -> String? {
        guard let line = lines.first(where: { $0.contains(text) }), let match = line.firstMatch(of: try! Regex(#"\[(f[0-9]+)?e[0-9]+\]"#)) else { return nil }
        return String(line[match.range].dropFirst().dropLast())
    }

    /// Changes the page's address without a new document, as `history.pushState` does, and reports it as `Browsing` reports an agent tab's address, so that the host sees a page that changed before any document finished loading.
    func changeAddress(to path: String) async throws {
        _ = try await page.evaluate("history.pushState(null, '', '\(path)'); 0")
        let url = try #require(URL(string: path, relativeTo: page.url)?.absoluteURL)
        if let index = host.tabs.firstIndex(where: { $0.id == tabID }) { host.tabs[index].url = url }
        toolHost.tab(tabID, of: grant.id, didReport: .addressChanged(url), state: state)
    }

    /// Answers the next card that waits, as the user would.
    func answerNextCard(_ answer: AgentApprovalAnswer) async throws -> AgentApproval {
        try await waitUntil { !self.toolHost.approvals.pending.isEmpty }
        let card = try #require(toolHost.approvals.pending.first)
        await toolHost.approvals.answer(card.id, with: answer)
        return card
    }
}

/// A list's strings, from a result's structured value.
func strings(_ value: AgentJSON?) -> [String] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap(\.stringValue)
}
