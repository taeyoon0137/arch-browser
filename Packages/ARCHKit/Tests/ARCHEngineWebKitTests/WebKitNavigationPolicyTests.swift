// Which navigations the WebKit adapter asks its navigation delegate about, as the agents' site checks need (docs/agents.md, Site exclusions): every main frame navigation, again at each server redirect with the redirect's address, marked as one, and before its request leaves, and nothing for a frame inside the page. A server on the loopback address answers the requests, so no page comes from the network; the profile keeps nothing on disk.
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Network
import Testing

@MainActor @Suite(.serialized) struct WebKitNavigationPolicyTests {
    private let browser: any EngineBrowser

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        let application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder)) as? WebKitApplication)
        browser = application.createBrowser(context: application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent()))
    }

    /// `/start` redirects to `/hop`, which redirects to `/final`, a page with a frame at `/frame`.
    private static let routes: [String: LoopbackServer.Response] = [
        "/start": .redirect("/hop"),
        "/hop": .redirect("/final"),
        "/final": .page("<!doctype html><title>Final</title><iframe src=\"/frame\"></iframe>"),
        "/frame": .page("<!doctype html><title>Frame</title><p>Inside"),
    ]

    @Test func theDelegateHearsOfEachRedirectHopAndNotOfFrames() async throws {
        let server = try await LoopbackServer.start(routes: Self.routes)
        defer { server.stop() }
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        let recorder = PolicyRecorder()
        tab.navigationDelegate = recorder
        tab.navigationController.load(URLRequest(url: server.url("/start")))
        #expect(await eventually { tab.webView.title == "Final" && server.paths.contains("/frame") })
        #expect(recorder.paths == ["/start", "/hop", "/final"])
        #expect(recorder.dispositions.allSatisfy { $0 == .currentTab })
        // Each hop is marked as a redirect, and a navigation after the commit is not.
        #expect(recorder.redirects == [false, true, true])
        tab.navigationController.load(URLRequest(url: server.url("/final")))
        #expect(await eventually { recorder.paths.count == 4 && !tab.isLoading })
        #expect(recorder.redirects == [false, true, true, false])
    }

    @Test func aHopTheDelegateCancelsSendsNoRequest() async throws {
        let server = try await LoopbackServer.start(routes: Self.routes)
        defer { server.stop() }
        let tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
        let recorder = PolicyRecorder()
        recorder.cancelledPath = "/final"
        tab.navigationDelegate = recorder
        tab.navigationController.load(URLRequest(url: server.url("/start")))
        #expect(await eventually { recorder.paths.contains("/final") && !tab.isLoading })
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.paths == ["/start", "/hop"])
        #expect(tab.webView.title != "Final")
        // The cancelled hop ended the navigation, so the next one is no redirect.
        recorder.cancelledPath = nil
        tab.navigationController.load(URLRequest(url: server.url("/final")))
        #expect(await eventually { tab.webView.title == "Final" })
        #expect(recorder.redirects == [false, true, true, false])
    }

    private final class PolicyRecorder: EngineWebContentsNavigationDelegate {
        var cancelledPath: String?
        private(set) var paths: [String] = []
        private(set) var dispositions: [EngineNavigationDisposition] = []
        private(set) var redirects: [Bool] = []

        func webContents(_ webContents: any EngineWebContents, decidePolicyFor action: EngineNavigationAction) -> EngineNavigationPolicy {
            paths.append(action.url.path)
            dispositions.append(action.disposition)
            redirects.append(action.isRedirect)
            return action.url.path == cancelledPath ? .cancel : .allow
        }
    }

    /// Waits up to ten seconds for `condition`, checking every tenth of a second, and reports whether it held.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}

/// An HTTP server on 127.0.0.1 with fixed answers, which records each request's path.
final class LoopbackServer: @unchecked Sendable {
    enum Response {
        case redirect(String)
        case page(String)

        var bytes: Data {
            switch self {
            case .redirect(let location):
                return Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            case .page(let html):
                let body = Data(html.utf8)
                return Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            }
        }
    }

    private let listener: NWListener
    private let routes: [String: Response]
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let lock = NSLock()
    private var recorded: [String] = []

    private init(routes: [String: Response]) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.routes = routes
    }

    /// A server that listens, or an error after five seconds.
    static func start(routes: [String: Response]) async throws -> LoopbackServer {
        let server = try LoopbackServer(routes: routes)
        server.listener.newConnectionHandler = { [weak server] connection in server?.serve(connection) }
        server.listener.start(queue: server.queue)
        for _ in 0..<50 where server.listener.port == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard server.listener.port != nil else { throw ServerError.didNotListen }
        return server
    }

    enum ServerError: Error {
        case didNotListen
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)\(path)")!
    }

    /// The paths requested so far, in order.
    var paths: [String] { lock.withLock { recorded } }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first else { return connection.cancel() }
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            if path != "/favicon.ico" { self.lock.withLock { self.recorded.append(path) } }
            let response = self.routes[path]?.bytes ?? Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
