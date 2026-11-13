// A page's file chooser on WebKit: a file input's click reaches the UI delegate as a request with the input's mode and, while the private API flags allow it, its accepted types; the page receives the files the delegate answers with, only the first for an input that takes one, a folder's files for a folder input, and a cancel for nil, also from a delegate that lets the completion go or from no delegate at all. A script's `click()` opens the chooser because `evaluateJavaScript` runs with a user gesture, in the page's world and in a world of the app's own, as `executeJavaScript(_:inWorld:completion:)` runs the agents' page script. The window is never ordered in. Every wait ends with a failure after a few seconds. The tests use a private profile and load no page from the network.
import AppKit
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing

@MainActor @Suite(.timeLimit(.minutes(1))) struct WebKitFileChooserTests {
    private let browser: any EngineBrowser
    /// Keeps the tests' windows, which nothing else holds while they are not ordered in.
    private let windows = Windows()
    /// The files the tests choose, written once per run: `a.txt`, `b.txt`, and `Shared/inner.txt`.
    private static let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WebKitFileChooserTests")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Shared"), withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "Shared/inner.txt"] {
            try? Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }()

    init() throws {
        let support = FileManager.default.temporaryDirectory
        let application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: support, cacheDirectory: support)) as? WebKitApplication)
        browser = application.createBrowser(context: application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent()))
    }

    /// Logs each input's `change`, with its files' names or, for a folder, their paths in it, and its `cancel`.
    private static let page = """
        <!doctype html><title>Files</title>
        <input type="file" id="one" accept="image/*, .PDF,Application/JSON, bogus"><input type="file" id="many" multiple><input type="file" id="folder" webkitdirectory>
        <script>
          window.log = [];
          for (const input of document.querySelectorAll("input")) {
            input.addEventListener("change", () => log.push(input.id + ":" + [...input.files].map((file) => file.webkitRelativePath || file.name).join(",")));
            input.addEventListener("cancel", () => log.push(input.id + ":cancel"));
          }
        </script>
        """

    @Test func aFileInputReportsItsChooserAndReceivesTheChosenFile() async throws {
        let tab = try await loadedTab()
        let recorder = ChooserRecorder(answer: [file("a.txt")])
        tab.uiDelegate = recorder
        try await open("one", in: tab)
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:a.txt")
        // WebKit lowercases the types, lists MIME types before extensions, and drops entries that are neither.
        let expectedTypes = WebKitFileChooserAPI.isAllowed ? ["image/*", "application/json", ".pdf"] : []
        #expect(recorder.requests == [EngineFileChooserRequest(mode: .openFile, acceptedTypes: expectedTypes)])
    }

    @Test func anInputForSeveralFilesReceivesThemAllAndOneForAFileOnlyTheFirst() async throws {
        let tab = try await loadedTab()
        let recorder = ChooserRecorder(answer: [file("a.txt"), file("b.txt")])
        tab.uiDelegate = recorder
        try await open("many", in: tab)
        #expect(try await logEntry(startingWith: "many:", in: tab) == "many:a.txt,b.txt")
        try await open("one", in: tab)
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:a.txt")
        #expect(recorder.requests.map(\.mode) == [.openFiles, .openFile])
    }

    @Test func aFolderInputAsksForAFolderAndReceivesTheFilesInIt() async throws {
        let tab = try await loadedTab()
        let recorder = ChooserRecorder(answer: [Self.folder.appendingPathComponent("Shared")])
        tab.uiDelegate = recorder
        try await open("folder", in: tab)
        #expect(try await logEntry(startingWith: "folder:", in: tab) == "folder:Shared/inner.txt")
        #expect(recorder.requests.map(\.mode) == [.openFolder])
    }

    @Test func noFileIsACancel() async throws {
        let tab = try await loadedTab()
        let recorder = ChooserRecorder(answer: nil)
        tab.uiDelegate = recorder
        try await open("one", in: tab)
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:cancel")
        recorder.answer = [URL(string: "https://example.com/a.txt")!]
        try await open("many", in: tab)
        #expect(try await logEntry(startingWith: "many:", in: tab) == "many:cancel")
    }

    /// WebKit raises an exception when it releases an open panel's completion that was never called, and opens no other panel until one is answered, so the adapter answers for a delegate that lets the completion go.
    @Test func aDelegateThatDropsTheCompletionLeavesThePageACancel() async throws {
        let tab = try await loadedTab()
        let recorder = ChooserRecorder(answer: nil, dropsCompletion: true)
        tab.uiDelegate = recorder
        try await open("one", in: tab)
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:cancel")
        recorder.dropsCompletion = false
        recorder.answer = [file("b.txt")]
        try await open("one", in: tab)
        #expect(try await logEntries(startingWith: "one:", count: 2, in: tab) == ["one:cancel", "one:b.txt"])
    }

    /// The agents' page script acts through DOM events in a world of its own, and on WebKit its `click()` gives the page a user gesture too.
    @Test func aScriptInAnAppWorldOpensTheChooserToo() async throws {
        let tab = try await loadedTab()
        let recorder = ChooserRecorder(answer: [file("a.txt")])
        tab.uiDelegate = recorder
        tab.executeJavaScript("(channel) => { document.getElementById('one').click(); }", inWorld: "arch.test") { _ in }
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:a.txt")
        #expect(recorder.requests.map(\.mode) == [.openFile])
    }

    @Test func withoutADelegateThePageGetsNoFile() async throws {
        let tab = try await loadedTab()
        tab.uiDelegate = nil
        try await open("one", in: tab)
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:cancel")
    }

    private func file(_ name: String) -> URL { Self.folder.appendingPathComponent(name) }

    /// Answers each chooser at once with `answer`, or lets the completion go.
    private final class ChooserRecorder: EngineWebContentsUIDelegate {
        private(set) var requests: [EngineFileChooserRequest] = []
        var answer: [URL]?
        var dropsCompletion: Bool

        init(answer: [URL]?, dropsCompletion: Bool = false) {
            self.answer = answer
            self.dropsCompletion = dropsCompletion
        }

        func webContents(_ webContents: any EngineWebContents, runFileChooser request: EngineFileChooserRequest, completion: @escaping ([URL]?) -> Void) {
            requests.append(request)
            if !dropsCompletion { completion(answer) }
        }
    }

    /// Clicks the input from a script, which WebKit runs with a user gesture.
    private func open(_ input: String, in tab: WebKitWebContents) async throws {
        _ = try await evaluate("document.getElementById('\(input)').click()", in: tab)
    }

    private func logEntry(startingWith prefix: String, in tab: WebKitWebContents) async throws -> String? {
        try await logEntries(startingWith: prefix, count: 1, in: tab).first
    }

    /// The page's log entries for one input once there are `count` of them; fails after 5 seconds with fewer.
    private func logEntries(startingWith prefix: String, count: Int, in tab: WebKitWebContents) async throws -> [String] {
        var entries: [String] = []
        for _ in 0..<50 {
            let json = try await evaluate("JSON.stringify(log)", in: tab) as? String ?? "[]"
            entries = try JSONDecoder().decode([String].self, from: Data(json.utf8)).filter { $0.hasPrefix(prefix) }
            if entries.count >= count { return entries }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WaitError("The page logged \(entries) for \(prefix) within 5 seconds, not \(count) entries.")
    }

    /// A tab whose view fills a window that is never ordered in, once the page has loaded.
    private func loadedTab() async throws -> WebKitWebContents {
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.all.append(window)
        tab.view.frame = window.contentLayoutRect
        window.contentView?.addSubview(tab.view)
        tab.webView.loadHTMLString(Self.page, baseURL: nil)
        // A JavaScript error means the page's script has not run yet; a page that does not answer fails with `evaluate`'s error.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            do {
                if try await evaluate("document.readyState === 'complete' && Array.isArray(window.log)", in: tab) as? Bool == true { return tab }
            } catch let error as WaitError {
                throw error
            } catch {}
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WaitError("The page did not load within 5 seconds.")
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
