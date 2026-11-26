// Tests a page's file chooser on WebKit.
// A file input's click reaches the UI delegate as a request with the input's mode.
// The request includes accepted types while the private API flags allow it.
// The page receives the files the delegate returns.
// An input that takes one file receives only the first.
// A folder input receives the folder's files.
// A nil answer cancels the chooser.
// A delegate that drops the completion or no delegate at all also cancels it.
// A script's `click()` opens the chooser because WebKit's public `evaluateJavaScript` runs with a user gesture.
// This applies in both the page's world and the app's own world.
// `executeJavaScript(_:inWorld:completion:)` runs the agents' page script without a gesture while the private API flags allow it.
// Its `click()` therefore opens no chooser.
// `executeJavaScriptWithoutUserGesture(_:inWorld:completion:)` runs plugins' page runs only without a gesture, or not at all.
// `postPageScriptMessage(_:toWorld:)` follows the same rule for plugins' messages.
// The public `callAsyncJavaScript` would run their listeners with a gesture.
// The request names the frame that asks and the page its main frame committed.
// This holds while the page loads another address and while a page with a frame goes back to one.
// The adapter's favicon lookup runs no page code with its gesture.
// The window is never ordered in.
// Every wait ends with a failure after a few seconds.
// The tests use a private profile.
// They load no page from the network.
// Two tests keep a navigation loading on 127.0.0.1.
// One uses a port that never answers; the other uses a server that answers only its first request.
import AppKit
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing
import WebKit

// Each test starts a real renderer. Limit concurrent cold starts so input and chooser deadlines measure their own page.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WebKitFileChooserTests {
    private let browser: any EngineBrowser
    /// Keeps the tests' windows while they are not ordered in.
    /// Nothing else holds them then.
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

    /// A valid data image prevents fallback icon fetches from using a test server's limited replies.
    private static let iconURL = "data:image/svg+xml;base64," + Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path d="M0 0h16v16H0z"/></svg>"#.utf8).base64EncodedString()

    /// Logs each input's `change` with file names or, for a folder, paths within it.
    /// Also logs each input's `cancel`.
    private static let page = """
        <!doctype html><title>Files</title><link rel="icon" href="\(iconURL)">
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
        // WebKit lowercases the types.
        // It lists MIME types before extensions.
        // It drops entries that are neither.
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

    /// WebKit raises an exception when it releases an open panel's uncalled completion.
    /// It opens no other panel until one receives an answer.
    /// The adapter therefore answers for a delegate that drops the completion.
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

    /// The agents' page script acts through DOM events in its own world.
    /// `executeJavaScript(_:inWorld:completion:)` runs it without a user gesture while the private API flags allow it.
    /// Its `click()` therefore opens no chooser.
    /// Otherwise, it uses WebKit's public evaluation, which runs with a gesture in an app's world too.
    /// The same `click()` then opens the chooser.
    @Test func theAgentsScriptOpensTheChooserOnlyWithThePublicEvaluationsGesture() async throws {
        let tab = try await loadedTab()
        let recorder = ChooserRecorder(answer: [file("a.txt")])
        tab.uiDelegate = recorder
        let click = "(channel) => { document.getElementById('one').click(); return 'clicked'; }"
        if WebKitUserGestureAPI.isAllowed {
            let ran = try await withCheckedThrowingContinuation { continuation in
                tab.executeJavaScript(click, inWorld: "arch.test") { continuation.resume(with: $0) }
            }
            #expect(ran == "clicked")
            // A chooser would reach the delegate within the click's turn.
            // Give it a second.
            try await Task.sleep(for: .seconds(1))
            #expect(recorder.requests.isEmpty)
        }
        tab.webView.evaluateJavaScript("document.getElementById('one').click()", in: nil, in: WKContentWorld.world(name: "arch.test")) { _ in }
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:a.txt")
        #expect(recorder.requests.map(\.mode) == [.openFile])
    }

    /// A plugin's page run uses only the evaluation without a user gesture.
    /// Its `click()` therefore opens no chooser.
    /// It runs nothing while the private API flags switch plugins' page runs off.
    @Test func aPluginsRunOpensNoChooserAndRunsNothingWithoutItsFlags() async throws {
        let tab = try await loadedTab()
        let recorder = ChooserRecorder(answer: [file("a.txt")])
        tab.uiDelegate = recorder
        let click = "(channel) => { document.documentElement.dataset.ran = 'yes'; document.getElementById('one').click(); return 'clicked'; }"
        let ran = await withCheckedContinuation { (continuation: CheckedContinuation<Result<String?, any Error>, Never>) in
            tab.executeJavaScriptWithoutUserGesture(click, inWorld: "arch.test") { continuation.resume(returning: $0) }
        }
        if WebKitUserGestureAPI.allowsPluginRuns {
            #expect(try ran.get() == "clicked")
            // A chooser would reach the delegate within the click's turn.
            // Give it a second.
            try await Task.sleep(for: .seconds(1))
        } else {
            #expect(throws: EngineUserGestureError.self) { try ran.get() }
            #expect(try await evaluate("document.documentElement.dataset.ran ?? 'no'", in: tab) as? String == "no")
        }
        #expect(recorder.requests.isEmpty)
    }

    /// A plugin's message reaches its page scripts' listeners only through the evaluation without a user gesture.
    /// A listener's `click()` therefore opens no chooser.
    /// The message arrives nowhere while the private API flags switch plugins' page runs off.
    /// WebKit's public `callAsyncJavaScript` runs the same listener with the user's gesture.
    /// The adapter does not use it for these messages.
    /// The same `click()` then opens the chooser.
    @Test func aPluginsMessageReachesItsListenerWithoutTheUsersGesture() async throws {
        let recorder = ChooserRecorder(answer: [file("a.txt")])
        let tab = try shownTab(EngineWebContentsConfiguration(), uiDelegate: recorder)
        let listener = "(channel) => { channel.onMessage((value) => { document.documentElement.dataset.message = value; document.getElementById('one').click(); }); }"
        tab.setPageScripts([EnginePageScript(world: "arch.test", source: listener, injectionTime: .documentEnd, mainFrameOnly: true)])
        tab.webView.loadHTMLString(Self.page, baseURL: nil)
        try await waitForPage(at: "about:blank", in: tab)
        if WebKitUserGestureAPI.allowsPluginRuns {
            try tab.postPageScriptMessage(#""posted""#, toWorld: "arch.test")
            try await waitForMessage("posted", in: tab)
            // A chooser would reach the delegate within the click's turn.
            // Give it a second.
            try await Task.sleep(for: .seconds(1))
            #expect(recorder.requests.isEmpty)
        } else {
            #expect(throws: EngineUserGestureError.self) { try tab.postPageScriptMessage(#""posted""#, toWorld: "arch.test") }
            try await Task.sleep(for: .seconds(1))
            #expect(try await evaluate("document.documentElement.dataset.message ?? 'none'", in: tab) as? String == "none")
        }
        tab.webView.callAsyncJavaScript("globalThis.__archPageScriptDeliver?.(json)", arguments: ["json": #""public""#], in: nil, in: WebKitPageScripts.contentWorld("arch.test"))
        try await waitForMessage("public", in: tab)
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:a.txt")
        #expect(recorder.requests.map(\.mode) == [.openFile])
    }

    /// Waits until a page script's listener writes the message into the document.
    /// Fails after 5 seconds.
    private func waitForMessage(_ message: String, in tab: WebKitWebContents) async throws {
        for _ in 0..<50 {
            if try await evaluate("document.documentElement.dataset.message ?? ''", in: tab) as? String == message { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WaitError("No listener received \(message) within 5 seconds.")
    }

    /// The adapter's favicon lookup runs with the gesture `evaluateJavaScript` carries.
    /// It therefore uses the app's own world, where a DOM method that the page replaced keeps its original form.
    /// The page's own timer clicks the input throughout.
    /// It opens no chooser after the lookup.
    @Test func theIconLookupRunsNoCodeOfThePage() async throws {
        let recorder = ChooserRecorder(answer: [file("a.txt")])
        let tab = try await loadedTab(page: Self.page + Self.replacedQuerySelector, uiDelegate: recorder)
        tab.refreshFavicon()
        // WebKit runs a web view's scripts in order.
        // It reports an open panel before a later script's answer.
        // The lookups have therefore run once this answers.
        // The wait gives the timer its turns.
        _ = try await evaluate("0", in: tab)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await evaluate("JSON.stringify(log)", in: tab) as? String == "[]")
        #expect(recorder.requests.isEmpty)
    }

    /// Replaces `Document.prototype.querySelector`, which the favicon lookup calls, with one that logs and clicks the first input.
    /// Also clicks the input from a timer.
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

    /// A page can point the web view's address at another site by starting a navigation that has not committed.
    /// The request therefore names the frame that asks and the page it committed.
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

    /// Going back moves the web view's address and current back-forward item to the earlier page before it loads again.
    /// A frame inside the page therefore names the page the main frame committed.
    /// A page in the back-forward cache returns at once.
    /// A tab with restored history keeps no pages in that cache.
    /// The test therefore goes back in a tab restored from another tab's state.
    /// The page's server leaves its second request unanswered.
    /// Pages that `loadHTMLString` loads get no back-forward item.
    /// Both pages therefore come from local servers on two ports, giving them two origins.
    @Test func aFrameNamesThePageItsMainFrameCommittedWhileTheTabGoesBack() async throws {
        let bank = try PageServer(page: "<!doctype html><title>Earlier</title><link rel=\"icon\" href=\"\(Self.iconURL)\"><script>window.log = [];</script>", answers: 1)
        let framed = try PageServer(page: Self.framedPage, answers: 2)
        let earlier = try #require(URL(string: "http://127.0.0.1:\(bank.number)/bank"))
        let page = try #require(URL(string: "http://127.0.0.1:\(framed.number)/framed"))
        let site = try #require(URL(string: "http://127.0.0.1:\(framed.number)/"))
        let first = try await loadedTab()
        try await load(earlier, in: first)
        try await load(page, in: first)
        let recorder = ChooserRecorder(answer: nil)
        let tab = try shownTab(EngineWebContentsConfiguration(restorableState: first.restorableState), uiDelegate: recorder)
        try await waitForPage(at: page.absoluteString, in: tab)
        _ = try await evaluate("history.back(); 0", in: tab)
        try await waitUntil("The web view did not report the address it goes back to within 5 seconds.") { tab.url == earlier }
        #expect(tab.webView.backForwardList.currentItem?.url == earlier)
        #expect(try await evaluate("document.title", in: tab) as? String == "Framed")
        _ = try await evaluate("frames[0].document.getElementById('one').click(); 0", in: tab)
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:cancel")
        #expect(recorder.addresses == [earlier])
        #expect(recorder.requests.map(\.origin) == [site])
        #expect(recorder.requests.map(\.pageOrigin) == [site])
    }

    /// A page whose only file input is in a frame of the same origin, which logs its `cancel` in the page.
    private static let framedPage = """
        <!doctype html><title>Framed</title><link rel="icon" href="\(iconURL)"><script>window.log = [];</script>
        <iframe srcdoc='<input type="file" id="one"><script>document.getElementById("one").addEventListener("cancel", () => parent.log.push("one:cancel"));</script>'></iframe>
        """

    @Test func withoutADelegateThePageGetsNoFile() async throws {
        let tab = try await loadedTab()
        tab.uiDelegate = nil
        try await open("one", in: tab)
        #expect(try await logEntry(startingWith: "one:", in: tab) == "one:cancel")
    }

    private func file(_ name: String) -> URL { Self.folder.appendingPathComponent(name) }

    /// Answers each chooser at once with `answer` or drops the completion.
    /// Keeps each request with the web view's address at the time.
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

    /// Returns the page's log entries for one input once there are `count` of them.
    /// Fails after 5 seconds if there are fewer.
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

    /// Returns a tab once its page has loaded at `baseURL`.
    /// Uses the tests' own page unless another is given.
    /// The tab's view fills a window that is never ordered in.
    /// Sets `uiDelegate` from the start.
    private func loadedTab(page: String? = nil, baseURL: URL? = nil, uiDelegate: (any EngineWebContentsUIDelegate)? = nil) async throws -> WebKitWebContents {
        let tab = try shownTab(EngineWebContentsConfiguration(), uiDelegate: uiDelegate)
        tab.webView.loadHTMLString(page ?? Self.page, baseURL: baseURL)
        try await waitForPage(at: baseURL?.absoluteString ?? "about:blank", in: tab)
        return tab
    }

    /// Creates a tab with the configuration and `uiDelegate` from the start.
    /// Its view fills a window that is never ordered in.
    private func shownTab(_ configuration: EngineWebContentsConfiguration, uiDelegate: (any EngineWebContentsUIDelegate)?) throws -> WebKitWebContents {
        let tab = try #require(browser.createWebContents(configuration) as? WebKitWebContents)
        tab.uiDelegate = uiDelegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.all.append(window)
        tab.view.frame = window.contentLayoutRect
        window.contentView?.addSubview(tab.view)
        return tab
    }

    /// Loads the address in the tab and returns once its page has loaded.
    private func load(_ url: URL, in tab: WebKitWebContents) async throws {
        tab.webView.load(URLRequest(url: url))
        try await waitForPage(at: url.absoluteString, in: tab)
    }

    /// Returns once the tab's page at the address has loaded, not while the tab still shows the page before it.
    private func waitForPage(at address: String, in tab: WebKitWebContents) async throws {
        // A JavaScript error means the page's script has not run yet.
        // A page that does not answer fails with `evaluate`'s error.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            do {
                if try await evaluate("location.href === '\(address)' && document.readyState === 'complete' && Array.isArray(window.log)", in: tab) as? Bool == true { return }
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

    /// A port on 127.0.0.1 that accepts connections and never answers.
    /// The system completes them into the listening socket's queue.
    /// Nothing reads the queue, so a page keeps loading until the socket closes.
    private final class SilentPort {
        let number: UInt16
        private let socket: Int32

        init() throws {
            (socket, number) = try Self.listeningSocket()
        }

        deinit {
            close(socket)
        }

        /// A socket that listens on a free port of 127.0.0.1, with the port.
        static func listeningSocket() throws -> (Int32, UInt16) {
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
            return (socket, UInt16(bigEndian: address.sin_port))
        }
    }

    /// A server on a port of 127.0.0.1 that answers its first requests with a page no cache may keep.
    /// It leaves every later request unanswered.
    /// A navigation that loads the page again therefore keeps loading until the server closes.
    private final class PageServer {
        let number: UInt16
        private let source: DispatchSourceRead
        private let connections: Connections

        init(page: String, answers: Int) throws {
            let (socket, number) = try SilentPort.listeningSocket()
            self.number = number
            let body = Data(page.utf8)
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            let connections = Connections(answers: answers)
            self.connections = connections
            source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .global())
            source.setEventHandler {
                let connection = accept(socket, nil, nil)
                guard connection >= 0 else { return }
                connections.add(connection)
                // Read the request on its own queue because a connection may send nothing.
                DispatchQueue.global().async {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    guard read(connection, &buffer, buffer.count) > 0, connections.takeAnswer() else { return }
                    _ = response.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
                    shutdown(connection, SHUT_RDWR)
                }
            }
            source.setCancelHandler {
                close(socket)
                connections.closeAll()
            }
            source.resume()
        }

        deinit {
            source.cancel()
        }

        /// Tracks the server's connections and how many requests it still answers.
        /// The server closes the connections when it ends.
        private final class Connections: @unchecked Sendable {
            private let lock = NSLock()
            private var all: [Int32] = []
            private var answers: Int

            init(answers: Int) {
                self.answers = answers
            }

            func add(_ connection: Int32) {
                lock.withLock { all.append(connection) }
            }

            /// Whether the server answers the request it has just read.
            func takeAnswer() -> Bool {
                lock.withLock {
                    defer { answers -= 1 }
                    return answers > 0
                }
            }

            /// Shutting a connection down ends a read that waits on it.
            func closeAll() {
                lock.withLock {
                    all.forEach { shutdown($0, SHUT_RDWR); close($0) }
                    all = []
                }
            }
        }
    }

    private struct WaitError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
