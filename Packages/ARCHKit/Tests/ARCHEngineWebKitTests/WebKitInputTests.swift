// Trusted input on WebKit: a page in a window receives the input's clicks, keys, and text with `isTrusted` true, as the user's own, and text also reaches a page that no window shows; a key that comes back to the web view goes no further; and input that could reach the app's menus, or that needs the key window or a window at all, is refused. The windows are never ordered in, so none is key and none is on screen; wheel turns and pointer moves, which WebKit delivers only to a window on screen or the key window, are checked from the bundle (`docs/agents.md`, check 69). Every wait ends with a failure after a few seconds. The tests use a private profile and load no page from the network.
import AppKit
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing

@MainActor @Suite(.timeLimit(.minutes(1))) struct WebKitInputTests {
    private let browser: any EngineBrowser
    /// Keeps the tests' windows, which nothing else holds while they are not ordered in.
    private let windows = Windows()

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        let application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder)) as? WebKitApplication)
        browser = application.createBrowser(context: application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent()))
    }

    /// Records every event of these types that reaches the document, with whether it is trusted.
    private static let page = """
        <!doctype html><title>Input</title>
        <style>
          body { margin: 0; }
          #field { position: absolute; left: 10px; top: 10px; width: 200px; height: 30px; }
          #button { position: absolute; left: 10px; top: 60px; width: 120px; height: 40px; }
        </style>
        <input id="field"><button id="button">Go</button>
        <script>
          window.events = [];
          for (const type of ["mouseover", "mousemove", "mousedown", "mouseup", "click", "dblclick", "keydown", "keyup", "beforeinput", "input"]) {
            document.addEventListener(type, (event) => events.push({ type, trusted: event.isTrusted, target: event.target.id, key: event.key ?? null }), true);
          }
        </script>
        """

    @Test func aClickReachesThePageAsTrustedInput() async throws {
        let (tab, _) = try await loadedTab()
        try #require(tab.input).click(at: CGPoint(x: 70, y: 80), count: 2, modifiers: [])
        let events = try await events(in: tab, until: "dblclick")
        // The pointer move fires `mousemove` only in the key window, which the test's window is not; the press makes the button the hovered element.
        #expect(events.map(\.type).filter { $0 != "mouseover" } == ["mousedown", "mouseup", "click", "mousedown", "mouseup", "click", "dblclick"])
        #expect(events.allSatisfy { $0.trusted && $0.target == "button" })
    }

    /// At twice the page's size, a CSS pixel takes two points, so the button's center lies at twice its place in the page.
    @Test func aClickFollowsThePagesZoom() async throws {
        let (tab, _) = try await loadedTab()
        tab.zoomFactor = 2
        let center = try await evaluate("(() => { const box = document.getElementById('button').getBoundingClientRect(); return JSON.stringify([box.x + box.width / 2, box.y + box.height / 2]) })()", in: tab) as? String
        let point = try JSONDecoder().decode([Double].self, from: Data(try #require(center).utf8))
        #expect(point == [70, 80])
        try #require(tab.input).click(at: CGPoint(x: point[0] * tab.zoomFactor, y: point[1] * tab.zoomFactor), count: 1, modifiers: [])
        let clicks = try await events(in: tab, until: "click").filter { $0.type == "click" }
        #expect(clicks.count == 1 && clicks.allSatisfy { $0.trusted && $0.target == "button" })
    }

    @Test func typedTextReachesTheFieldAsTrustedInput() async throws {
        let (tab, _) = try await loadedTab()
        let input = try #require(tab.input)
        try input.click(at: CGPoint(x: 110, y: 25), count: 1, modifiers: [])
        _ = try await events(in: tab, until: "click")
        try input.insertText("Héllo 가")
        let typing = try await events(in: tab, until: "input").filter { $0.type == "beforeinput" || $0.type == "input" }
        #expect(typing.map(\.type) == ["beforeinput", "input"])
        #expect(typing.allSatisfy { $0.trusted && $0.target == "field" })
        #expect(try await evaluate("document.getElementById('field').value", in: tab) as? String == "Héllo 가")
    }

    @Test func textReachesAFocusedFieldThatNoWindowShows() async throws {
        let (tab, _) = try await loadedTab()
        let input = try #require(tab.input)
        try input.click(at: CGPoint(x: 110, y: 25), count: 1, modifiers: [])
        _ = try await events(in: tab, until: "click")
        tab.view.removeFromSuperview()
        try input.insertText("text")
        let typing = try await events(in: tab, until: "input").filter { $0.type == "input" }
        #expect(typing.count == 1 && typing.allSatisfy { $0.trusted && $0.target == "field" })
    }

    /// No window is key, so a key goes to the web view while it is its window's first responder.
    @Test func aKeyReachesTheFocusedPageAsTrustedInputAndComesBackNoFurther() async throws {
        let (tab, window) = try await loadedTab()
        let input = try #require(tab.input)
        let webView = try #require(tab.webView as? WebKitWebView)
        try input.click(at: CGPoint(x: 110, y: 25), count: 1, modifiers: [])
        _ = try await events(in: tab, until: "click")
        // Focusing the field made the web view the window's first responder.
        #expect(window.firstResponder === webView)
        window.makeFirstResponder(nil)
        #expect(throws: EngineInputError.notFocused) { try input.press(.escape, modifiers: []) }
        window.makeFirstResponder(webView)
        try input.press(.escape, modifiers: [.shift])
        let sent = try #require(webView.sentKeyDowns.last)
        let keys = try await events(in: tab, until: "keyup").filter { $0.type.hasPrefix("key") }
        #expect(keys.map(\.type) == ["keydown", "keyup"])
        #expect(keys.allSatisfy { $0.trusted && $0.target == "field" && $0.key == "Escape" })
        // WebKit hands a key down that the page leaves unhandled back to the application, which sends it to the window's first responder, as here; the web view drops it.
        window.sendEvent(sent)
        try input.press(.enter, modifiers: [])
        let enter = try await events(in: tab, until: "keyup", key: "Enter").filter { $0.type == "keydown" }
        #expect(enter.map(\.key) == ["Escape", "Enter"])
        #expect(!webView.sentKeyDowns.contains { $0 === sent })
    }

    @Test func inputThatCouldReachTheAppOrAMenuIsRefused() async throws {
        let (tab, window) = try await loadedTab()
        let input = try #require(tab.input)
        window.makeFirstResponder(tab.webView)
        #expect(throws: EngineInputError.unsupported) { try input.press(.character("w"), modifiers: [.command]) }
        #expect(throws: EngineInputError.unsupported) { try input.press(.tab, modifiers: [.control]) }
        #expect(throws: EngineInputError.unsupported) { try input.press(.character("a"), modifiers: []) }
        #expect(throws: EngineInputError.unsupported) { try input.click(at: CGPoint(x: 70, y: 80), count: 1, modifiers: [.control]) }
        #expect(throws: EngineInputError.unsupported) { try input.click(at: CGPoint(x: 70, y: 80), count: 4, modifiers: []) }
        #expect(throws: EngineInputError.notFocused) { try input.movePointer(to: CGPoint(x: 70, y: 80), modifiers: []) }
        // A line break of its own would submit the field's form.
        #expect(throws: EngineInputError.unsupported) { try input.insertText("a\nb") }
        #expect(throws: EngineInputError.unsupported) { try input.insertText("\r") }
    }

    @Test func pointerEventsAndKeysNeedAWindowAndAPointInThePage() async throws {
        let (tab, window) = try await loadedTab()
        let input = try #require(tab.input)
        #expect(throws: EngineInputError.outsideView) { try input.click(at: CGPoint(x: -1, y: 10), count: 1, modifiers: []) }
        #expect(throws: EngineInputError.outsideView) { try input.scroll(at: CGPoint(x: 10, y: window.contentLayoutRect.height), deltaX: 0, deltaY: 10, modifiers: []) }
        tab.view.removeFromSuperview()
        #expect(throws: EngineInputError.notInWindow) { try input.click(at: CGPoint(x: 70, y: 80), count: 1, modifiers: []) }
        #expect(throws: EngineInputError.notInWindow) { try input.scroll(at: CGPoint(x: 70, y: 80), deltaX: 0, deltaY: 10, modifiers: []) }
        #expect(throws: EngineInputError.notInWindow) { try input.movePointer(to: CGPoint(x: 70, y: 80), modifiers: []) }
        #expect(throws: EngineInputError.notInWindow) { try input.press(.enter, modifiers: []) }
    }

    /// A tab whose view fills a window that is never ordered in, once the page has loaded.
    private func loadedTab() async throws -> (WebKitWebContents, NSWindow) {
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.all.append(window)
        let content = try #require(window.contentView)
        tab.view.frame = content.bounds
        content.addSubview(tab.view)
        tab.webView.loadHTMLString(Self.page, baseURL: nil)
        for _ in 0..<50 {
            if (try? await evaluate("document.readyState === 'complete' && Array.isArray(window.events)", in: tab)) as? Bool == true { return (tab, window) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WaitError("The page did not load within 5 seconds.")
    }

    private struct RecordedEvent: Decodable {
        var type: String
        var trusted: Bool
        var target: String
        var key: String?
    }

    /// The events the page recorded, once one of `type`, for `key` when it names one, is among them; fails after 5 seconds without one.
    private func events(in tab: WebKitWebContents, until type: String, key: String? = nil) async throws -> [RecordedEvent] {
        var events: [RecordedEvent] = []
        for _ in 0..<50 {
            events = try await recordedEvents(in: tab)
            if events.contains(where: { $0.type == type && (key == nil || $0.key == key) }) { return events }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WaitError("The page recorded no \(type) event within 5 seconds; it recorded \(events.map(\.type)).")
    }

    private func recordedEvents(in tab: WebKitWebContents) async throws -> [RecordedEvent] {
        let json = try await evaluate("JSON.stringify(events)", in: tab) as? String ?? "[]"
        return try JSONDecoder().decode([RecordedEvent].self, from: Data(json.utf8))
    }

    /// Evaluates an expression in the page, failing when WebKit has not answered within 3 seconds.
    private func evaluate(_ script: String, in tab: WebKitWebContents) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            func finish(_ result: Result<Any?, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            tab.webView.evaluateJavaScript(script) { value, error in finish(error.map { .failure($0) } ?? .success(value)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(.failure(WaitError("The page did not answer `\(script)` within 3 seconds."))) }
        }
    }

    private final class Windows {
        var all: [NSWindow] = []
    }

    private struct WaitError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
