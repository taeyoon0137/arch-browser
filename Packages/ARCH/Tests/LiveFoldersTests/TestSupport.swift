// Test doubles that keep the live folder tests off the network, out of the Keychain, and away from the user's shell and `gh`: a URL protocol that answers each test's own host, shell scripts in the run's folder, and bounded waits.
import Foundation
@testable import LiveFolders

/// Answers every request to a host with the reply its handler gives. Each test makes its own host, so tests can run in parallel.
final class FeedStubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/rss+xml"]
        var body = Data()
        /// Fails the load instead of answering.
        var failure: URLError.Code?
    }

    private static let lock = NSLock()
    private static var handlers: [String: @Sendable (URLRequest) -> Reply] = [:]
    private static var captured: [String: [URLRequest]] = [:]

    /// A new host whose requests `answer` replies to.
    static func host(answering answer: @escaping @Sendable (URLRequest) -> Reply) -> String {
        let host = "\(UUID().uuidString.lowercased()).example.test"
        lock.lock()
        handlers[host] = answer
        lock.unlock()
        return host
    }

    static func requests(to host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured[host] ?? []
    }

    static func fetcher() -> FeedFetcher {
        let configuration = FeedFetcher.defaultConfiguration
        configuration.protocolClasses = [FeedStubProtocol.self]
        return FeedFetcher(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        Self.lock.lock()
        let answer = Self.handlers[host]
        Self.captured[host, default: []].append(request)
        Self.lock.unlock()
        let reply = answer?(request) ?? Reply(status: 599)
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The folder that holds every test's files in this run, which the run removes as it exits.
let testRunFolder: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchLiveFoldersTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    atexit { try? FileManager.default.removeItem(at: testRunFolder) }
    return url
}()

/// A new, empty folder in the run's folder.
func temporaryDirectory() throws -> URL {
    let url = testRunFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An executable shell script named `name` in `folder`.
@discardableResult
func script(_ name: String, in folder: URL, _ body: String) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// Waits until `condition` holds, for at most `limit`.
@MainActor
func waitUntil(_ limit: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

func item(_ id: String, title: String? = nil, date: Date? = nil, gitHub: GitHubItem? = nil) -> LiveItem {
    LiveItem(id: id, url: URL(string: "https://example.org/\(id)")!, title: title ?? "Item \(id)", date: date, gitHub: gitHub)
}

let pullRequest = GitHubItem(kind: .pullRequest, state: .open, repository: "owner/repo", number: 1, author: "octo")
