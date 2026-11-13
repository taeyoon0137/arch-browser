// A page's file chooser on WebKit: a file input's click reaches the UI delegate as a request with the input's mode and, while the private API flags allow it, its accepted types; the page receives the files the delegate answers with, only the first for an input that takes one, a folder's files for a folder input, and a cancel for nil, also from a delegate that lets the completion go or from no delegate at all. A script's `click()` opens the chooser because `evaluateJavaScript` runs with a user gesture, in the page's world and in a world of the app's own, as `executeJavaScript(_:inWorld:completion:)` runs the agents' page script. The request names the frame that asks and the page, also while the page loads another address. The adapter's favicon lookup runs no code of the page with its gesture. The window is never ordered in. Every wait ends with a failure after a few seconds. The tests use a private profile and load no page from the network; one keeps a navigation loading from a local port that never answers.
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

    /// Logs each input's `change`, with its files' names or, for a folder, their paths in it, and its `cancel`. Its icon is an empty data address, so that no icon is fetched for a page with a web address.
    private static let page = """
        <!doctype html><title>Files</title><link rel="icon" href="data:,">
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

    /// The adapter's favicon lookup runs with the gesture `evaluateJavaScript` carries, so it runs in a world of the app's own, where a DOM method that the page replaced is the original. The page's own timer, which clicks the input all along, shows that the lookup leaves the page no activation either.
    @Test func theIconLookupRunsNoCodeOfThePage() async throws {
        let recorder = ChooserRecorder(answer: [file("a.txt")])
        let tab = try await loadedTab(page: Self.page + Self.replacedQuerySelector, uiDelegate: recorder)
        tab.refreshFavicon()
        // WebKit runs a web view's scripts in order and reports an open panel before a later script's answer, so the lookups have run once this answers; the wait gives the timer its turns.
        _ = try await evaluate("0", in: tab)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await evaluate("JSON.stringify(log)", in: tab) as? String == "[]")
        #expect(recorder.requests.isEmpty)
    }

    /// Replaces `Document.prototype.querySelector`, which the favicon lookup calls, with one that logs and clicks the first input, and clicks it from a timer as well.
    private static let replacedQuerySelector = """
        <script>
          const querySelector = Document.prototype.querySelector;
          Document.prototype.querySelector = function (...selectors) {
            log.push("querySelector");
            document.getElementById("one").click();
            return querySelector.apply(this, selectors);
          };
          setInterval(() => document.getElementById("one").click(), 50);
        </script>
        """

    /// A page can point the web view's address at another site by starting a navigation that has not committed, so the request names the frame that asks and the page it committed.
    @Test func theRequestNamesTheFrameThatAsksNotAnAddressThePageIsStillLoading() async throws {
        let port = try SilentPort()
        let site = try #require(URL(string: "https://a.example/"))
        let loading = try #require(URL(string: "http://127.0.0.1:\(port.number)/bank"))
        let recorder = ChooserRecorder(answer: nil)
        let tab = try await loadedTab(baseURL: site, uiDelegate: recorder)
        _ = try await evaluate("location.href = '\(loading.absoluteString)'; 0", in: tab)
        try await waitUntil("The web view did not report the address it loads within 5 seconds.") { tab.url == loading }
        try await open("one", in: tab)
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:cancel")
        #expect(recorder.addresses == [loading])
        #expect(recorder.requests.map(\.origin) == [site])
        #expect(recorder.requests.map(\.pageOrigin) == [site])
    }

    @Test func withoutADelegateThePageGetsNoFile() async throws {
        let tab = try await loadedTab()
        tab.uiDelegate = nil
        try await open("one", in: tab)
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:cancel")
    }

    private func file(_ name: String) -> URL { Self.folder.appendingPathComponent(name) }

    /// Answers each chooser at once with `answer`, or lets the completion go, and keeps each request with the web view's address at the time.
    private final class ChooserRecorder: EngineWebContentsUIDelegate {
        private(set) var requests: [EngineFileChooserRequest] = []
        private(set) var addresses: [URL?] = []
        var answer: [URL]?
        var dropsCompletion: Bool

        init(answer: [URL]?, dropsCompletion: Bool = false) {
            self.answer = answer
            self.dropsCompletion = dropsCompletion
        }

        func webContents(_ webContents: any EngineWebContents, runFileChooser request: EngineFileChooserRequest, completion: @escaping ([URL]?) -> Void) {
            requests.append(request)
            addresses.append(webContents.url)
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

    /// A tab whose view fills a window that is never ordered in, once the page, the tests' own unless another is given, has loaded at `baseURL`, with `uiDelegate` from the start.
    private func loadedTab(page: String? = nil, baseURL: URL? = nil, uiDelegate: (any EngineWebContentsUIDelegate)? = nil) async throws -> WebKitWebContents {
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        tab.uiDelegate = uiDelegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.all.append(window)
        tab.view.frame = window.contentLayoutRect
        window.contentView?.addSubview(tab.view)
        tab.webView.loadHTMLString(page ?? Self.page, baseURL: baseURL)
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

    /// Waits for `condition`, failing with `message` after 5 seconds.
    private func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WaitError(message)
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

    /// A port on 127.0.0.1 that takes connections and never answers: the system completes them into the listening socket's queue, which nothing reads, so a page loading from it stays loading until the socket closes.
    private final class SilentPort {
        let number: UInt16
        private let socket: Int32

        init() throws {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let listening = socket >= 0 && withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) == 0 && listen(socket, 8) == 0 && getsockname(socket, $0, &length) == 0 }
            }
            guard listening else {
                if socket >= 0 { close(socket) }
                throw WaitError("No port on 127.0.0.1 could listen: \(String(cString: strerror(errno))).")
            }
            self.socket = socket
            number = UInt16(bigEndian: address.sin_port)
        }

        deinit {
            close(socket)
        }
    }

    private struct WaitError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
