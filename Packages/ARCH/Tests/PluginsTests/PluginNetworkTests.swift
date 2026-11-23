// Plugin network access: the host entries a manifest may list, the addresses a request may connect to, the requests and redirects the fetcher sends, the responses it reads, and the manager's checks at each request's start: the current grant, HTTPS on port 443 at a granted host, and 60 requests a minute, with `arch.net.fetch` through the bridge.
import Foundation
import Testing
@testable import Plugins

@Suite struct PluginNetworkHostTests {
    @Test func refusesAddressesInEveryNotation() {
        for entry in ["127.0.0.1", "127.1", "0x7f.0x1", "0x7f.0.0.1", "0x08.0x08.0x08.0x08", "010.0.0.1", "8.8.8.8", "example.123", "example.0x1f",
                      "localhost", "a.localhost", "example", "example.com.", "-a.example.com", "a_b.example.com", "[::1]", "example.com:443"] {
            #expect(PluginNetworkHost(entry) == nil, "\(entry)")
        }
        for entry in ["api.example.com", "*.example.com", "API.Example.COM", "1password.com", "a1.b2"] {
            #expect(PluginNetworkHost(entry) != nil, "\(entry)")
        }
        let wildcard = PluginNetworkHost("*.example.com")!
        #expect(wildcard.covers("api.example.com") && !wildcard.covers("example.com") && !wildcard.covers("badexample.com"))
    }

    @Test func connectsOnlyToPublicAddresses() {
        func v6(_ text: String) -> [UInt8] {
            var address = in6_addr()
            #expect(inet_pton(AF_INET6, text, &address) == 1, "\(text)")
            return withUnsafeBytes(of: address) { Array($0) }
        }
        let refused: [[UInt8]] = [
            [0, 0, 0, 0], [10, 1, 2, 3], [100, 64, 0, 1], [100, 127, 255, 255], [127, 0, 0, 1], [169, 254, 169, 254], [172, 16, 0, 1], [172, 31, 255, 255],
            [192, 0, 0, 1], [192, 0, 2, 1], [192, 88, 99, 1], [192, 168, 1, 1], [198, 18, 0, 1], [198, 19, 255, 255], [198, 51, 100, 1], [203, 0, 113, 1],
            [224, 0, 0, 1], [239, 255, 255, 250], [240, 0, 0, 1], [255, 255, 255, 255],
            v6("::"), v6("::1"), v6("::127.0.0.1"), v6("::ffff:127.0.0.1"), v6("::ffff:10.0.0.1"), v6("::ffff:169.254.169.254"), v6("::ffff:100.64.0.1"),
            v6("::ffff:224.0.0.1"), v6("::ffff:0.0.0.1"), v6("64:ff9b::7f00:1"), v6("64:ff9b::a9fe:a9fe"), v6("64:ff9b:1::808:808"), v6("2002:7f00:1::1"),
            v6("2002:c0a8:101::1"), v6("2001::1"), v6("2001:db8::1"), v6("3fff::1"), v6("fc00::1"), v6("fd12:3456::1"), v6("fe80::1"), v6("fec0::1"),
            v6("ff02::1"), v6("100::1"),
        ]
        for address in refused {
            #expect(!PluginNetworkAddress.isPublic(address), "\(address)")
        }
        let accepted: [[UInt8]] = [[8, 8, 8, 8], [1, 1, 1, 1], [172, 32, 0, 1], [100, 128, 0, 1], [192, 169, 0, 1],
                                   v6("2606:4700:4700::1111"), v6("::ffff:8.8.8.8"), v6("64:ff9b::808:808"), v6("2002:808:808::1")]
        for address in accepted {
            #expect(PluginNetworkAddress.isPublic(address), "\(address)")
        }
        #expect(!PluginNetworkAddress.isPublic([1, 2, 3]))
    }

    @Test func reachesOnlyGrantedHostsOverHTTPSOnPort443() {
        let hosts = [PluginNetworkHost("api.example.com")!, PluginNetworkHost("*.example.org")!]
        func host(_ address: String) -> String? { PluginNetworkFetch.checkedHost(of: URL(string: address)!, hosts: hosts) }
        #expect(host("https://api.example.com/v1?q=1") == "api.example.com")
        #expect(host("https://API.example.com:443/") == "api.example.com")
        #expect(host("https://a.example.org/") == "a.example.org")
        for address in ["http://api.example.com/", "https://api.example.com:22/", "https://api.example.com:8443/", "https://user@api.example.com/",
                        "https://example.com/", "https://example.org/", "https://127.0.0.1/", "https://[::1]/", "wss://api.example.com/"] {
            #expect(host(address) == nil, "\(address)")
        }
    }
}

@Suite struct PluginNetworkMessageTests {
    private let hosts = [PluginNetworkHost("api.example.com")!, PluginNetworkHost("cdn.example.com")!]

    private func request(_ address: String = "https://api.example.com/v1/items?q=a%20b#part", method: String = "GET", headers: [String: String] = [:], body: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body.map { Data($0.utf8) }
        return request
    }

    @Test func refusesHeadersAndBodiesItDoesNotSend() {
        for headers in [["Cookie": "a=b"], ["Host": "evil.example"], ["Origin": "https://a"], ["Transfer-Encoding": "chunked"], ["Connection": "upgrade"],
                        ["Upgrade": "websocket"], ["TE": "trailers"], ["Expect": "100-continue"], ["Proxy-Authorization": "x"], ["Proxy-Anything": "x"],
                        ["Accept-Encoding": "gzip"], ["Bad Name": "x"], ["Naïve": "x"], ["X-Null": "a\u{0}b"],
                        ["X-Big": String(repeating: "a", count: PluginNetworkFetch.headerLimit)]] {
            #expect(throws: PluginError.invalidRequest, "\(headers)") { try PluginNetworkFetch.validate(request(headers: headers)) }
        }
        // URLRequest drops a value with a line break, and the bridge checks the plugin's headers before they reach one.
        #expect(!PluginNetworkFetch.isAllowedHeader(name: "X-Split", value: "a\r\nInjected: b") && !PluginNetworkFetch.isAllowedHeader(name: "X-Split", value: "a\nb"))
        #expect(PluginNetworkFetch.isAllowedHeader(name: "X-Tab", value: "a\tb"))
        #expect(throws: PluginError.invalidRequest) { try PluginNetworkFetch.validate(request(body: "a")) }
        #expect(throws: PluginError.invalidRequest) { try PluginNetworkFetch.validate(request(method: "HEAD")) }
        #expect(throws: PluginError.invalidRequest) { try PluginNetworkFetch.validate(request("https://u:p@api.example.com/")) }
        #expect(throws: Never.self) { try PluginNetworkFetch.validate(request(method: "POST", headers: ["Content-Type": "application/json", "Authorization": "Bearer t"], body: "{}")) }
    }

    @Test func writesAnHTTP11RequestThatClosesTheConnection() throws {
        let get = String(decoding: try PluginNetworkFetch.message(for: request(headers: ["X-Key": "k"])), as: UTF8.self)
        #expect(get == "GET /v1/items?q=a%20b HTTP/1.1\r\nHost: api.example.com\r\nX-Key: k\r\nAccept: */*\r\nUser-Agent: Arch\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n")
        let post = String(decoding: try PluginNetworkFetch.message(for: request("https://api.example.com", method: "POST", headers: ["Accept": "text/plain"], body: "hé")), as: UTF8.self)
        #expect(post == "POST / HTTP/1.1\r\nHost: api.example.com\r\nAccept: text/plain\r\nUser-Agent: Arch\r\nAccept-Encoding: identity\r\nConnection: close\r\nContent-Length: 3\r\n\r\nhé")
    }

    @Test func followsRedirectsOnlyWithinTheGrant() throws {
        func response(_ status: Int, _ location: String?) -> PluginHTTPResponse {
            PluginHTTPResponse(status: status, headers: location.map { [("Location", $0)] } ?? [], body: Data())
        }
        let post = request(method: "POST", headers: ["Authorization": "Bearer t", "Content-Type": "text/plain"], body: "a")
        let seeOther = try #require(try PluginNetworkFetch.redirect(of: post, by: response(303, "/done"), hosts: hosts))
        #expect(seeOther.url?.absoluteString == "https://api.example.com/done" && seeOther.httpMethod == "GET" && seeOther.httpBody == nil)
        #expect(seeOther.value(forHTTPHeaderField: "Content-Type") == nil && seeOther.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let kept = try #require(try PluginNetworkFetch.redirect(of: post, by: response(307, "https://cdn.example.com/x"), hosts: hosts))
        #expect(kept.httpMethod == "POST" && kept.httpBody == Data("a".utf8) && kept.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try PluginNetworkFetch.redirect(of: post, by: response(200, "/x"), hosts: hosts) == nil)
        #expect(try PluginNetworkFetch.redirect(of: post, by: response(302, nil), hosts: hosts) == nil)
        for location in ["http://api.example.com/", "https://evil.example/", "https://api.example.com:8443/", "https://127.0.0.1/", "file:///etc/passwd"] {
            #expect(throws: PluginError.redirectRefused, "\(location)") { try PluginNetworkFetch.redirect(of: post, by: response(302, location), hosts: hosts) }
        }
    }

    @Test func readsResponsesByTheirFraming() throws {
        func parse(_ text: String, ended: Bool = false) throws -> PluginHTTPResponse? { try PluginHTTPResponse.parse(Data(text.utf8), ended: ended) }
        let length = try #require(try parse("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"))
        #expect(length.status == 200 && length.body == Data("hello".utf8) && length.header("content-type") == "text/plain")
        #expect(try parse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel") == nil)
        #expect(throws: PluginError.invalidResponse) { try parse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel", ended: true) }
        let chunked = try #require(try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;x=y\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: a\r\n\r\n"))
        #expect(chunked.body == Data("Wikipedia".utf8))
        #expect(try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWi") == nil)
        let closed = try #require(try parse("HTTP/1.0 404 Not Found\r\n\r\nmissing", ended: true))
        #expect(closed.status == 404 && closed.body == Data("missing".utf8))
        #expect(try parse("HTTP/1.1 200 OK\r\n\r\npart") == nil)
        let interim = try #require(try parse("HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n"))
        #expect(interim.status == 204 && interim.body.isEmpty)
        #expect(try parse("HTTP/1.1 200 OK\r\nContent-Le") == nil)
        let repeated = try #require(try parse("HTTP/1.1 200 OK\r\nSet-Thing: a\r\nset-thing: b\r\nContent-Length: 0\r\n\r\n"))
        #expect(repeated.headerFields == ["Set-Thing": "a, b", "Content-Length": "0"])
        for malformed in ["HTTP/2 200\r\n\r\n", "HTTP/1.1 2000 OK\r\n\r\n", "HTTP/1.1 200 OK\r\n folded\r\n\r\n", "HTTP/1.1 200 OK\r\nNo-Colon\r\n\r\n",
                          "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n", "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n",
                          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab",
                          "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\nab\r\n", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n+4\r\nWiki\r\n0\r\n\r\n", "HTTP/1.1 101 Switching\r\n\r\n"] {
            #expect(throws: PluginError.invalidResponse, "\(malformed)") { try parse(malformed) }
        }
        #expect(throws: PluginError.responseTooLarge) { try parse("HTTP/1.1 200 OK\r\nContent-Length: \(PluginNetworkFetch.bodyLimit + 1)\r\n\r\n") }
        #expect(throws: PluginError.responseTooLarge) { try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(String(PluginNetworkFetch.bodyLimit + 1, radix: 16))\r\n") }
        #expect(throws: PluginError.responseTooLarge) { try parse("HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: PluginNetworkFetch.headerLimit)) }
    }
}

@MainActor
@Suite struct PluginNetworkGrantTests {
    private let folder = TemporaryFolder()

    private func manager() -> PluginManager {
        PluginManager(persona: UUID(), directory: folder.url, builtIns: [], secretStore: MemorySecretStore())
    }

    /// Installs, enabled, a plugin that asks for `api.example.com` and the background script.
    private func install(in manager: PluginManager, background: String = "") async throws -> InstalledPlugin {
        let root = folder.url.appendingPathComponent("Packages/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = #"{"id": "org.example.net", "name": "Net", "version": "1", "apiVersion": 1, "summary": "Fetches.", "permissions": [{"network": ["api.example.com"]}], "background": "b.js", "contributes": {"commands": [{"id": "get", "title": "Get"}]}}"#
        try Data(manifest.utf8).write(to: root.appendingPathComponent("plugin.json"))
        try Data(background.utf8).write(to: root.appendingPathComponent("b.js"))
        let package = try await manager.stage(root)
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        return try #require(manager.plugins.first)
    }

    private static func answer(_ request: URLRequest, _ hosts: [PluginNetworkHost]) -> (Data, HTTPURLResponse) {
        (Data("ok".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!)
    }

    @Test func startsAtMostSixtyRequestsAMinute() async throws {
        let manager = manager()
        defer { manager.close() }
        let sent = Recorder()
        manager.networkTransport = { request, hosts in
            sent.record(request)
            return Self.answer(request, hosts)
        }
        let context = manager.makeContext(for: try await install(in: manager))
        let request = URLRequest(url: URL(string: "https://api.example.com/a")!)
        for _ in 0..<PluginManager.networkRequestLimit {
            #expect(try await context.fetch(request).0 == Data("ok".utf8))
        }
        await #expect(throws: PluginError.rateLimited) { try await context.fetch(request) }
        #expect(sent.requests.count == PluginManager.networkRequestLimit)
    }

    @Test func checksTheGrantAndTheAddressAtEachRequest() async throws {
        let manager = manager()
        defer { manager.close() }
        manager.networkTransport = { request, hosts in Self.answer(request, hosts) }
        let installed = try await install(in: manager)
        let context = manager.makeContext(for: installed)
        for address in ["http://api.example.com/", "https://api.example.com:8443/", "https://other.example.com/"] {
            await #expect(throws: PluginError.hostRefused, "\(address)") { try await context.fetch(URLRequest(url: URL(string: address)!)) }
        }
        let request = URLRequest(url: URL(string: "https://api.example.com/a")!)
        _ = try await context.fetch(request)
        // A revoke takes effect on the context that the running instance holds.
        manager.revoke(.network, from: installed.id)
        await #expect(throws: PluginError.permissionDenied(.network)) { try await context.fetch(request) }
        // A switched-off plugin's new context fetches nothing either.
        let fresh = try await install(in: manager)
        manager.setEnabled(false, for: fresh.id)
        await #expect(throws: PluginError.permissionDenied(.network)) { try await manager.makeContext(for: fresh).fetch(request) }
    }

    @Test func endingTheContextStopsItsRequests() async throws {
        let manager = manager()
        defer { manager.close() }
        manager.networkTransport = { request, hosts in
            try await Task.sleep(for: .seconds(30))
            return Self.answer(request, hosts)
        }
        let context = manager.makeContext(for: try await install(in: manager))
        let fetch = Task { try await context.fetch(URLRequest(url: URL(string: "https://api.example.com/a")!)) }
        try await Task.sleep(for: .milliseconds(100))
        context.end()
        await #expect(throws: PluginError.stopped) { try await fetch.value }
    }

    @Test func fetchesThroughTheBridge() async throws {
        let manager = manager()
        defer { manager.close() }
        let recorder = Recorder()
        manager.networkTransport = { request, hosts in
            recorder.record(request)
            return Self.answer(request, hosts)
        }
        let background = """
        arch.commands.onRun("get", async () => {
          const reply = await arch.net.fetch("https://api.example.com/v1", { method: "POST", headers: { "Content-Type": "text/plain" }, body: "hi" });
          await arch.storage.set("reply", reply);
          try { await arch.net.fetch("https://api.example.com/v1", { headers: { "Transfer-Encoding": "chunked" } }); } catch (error) { await arch.storage.set("refused", error.message); }
        });
        """
        let installed = try await install(in: manager, background: background)
        await manager.run(PluginCommandRef(plugin: installed.id, command: "get"), PluginInvocation(tab: nil))
        let storage = manager.makeContext(for: installed).storage
        #expect(await eventually { storage.value(forKey: "refused") != nil })
        #expect(storage.value(forKey: "reply") == .object(["status": .number(200), "headers": .object(["Content-Type": .string("text/plain")]), "text": .string("ok")]))
        #expect(storage.value(forKey: "refused") == .string("invalidRequest"))
        let sent = recorder.requests.first
        #expect(recorder.requests.count == 1 && sent?.httpMethod == "POST" && sent?.httpBody == Data("hi".utf8) && sent?.value(forHTTPHeaderField: "Content-Type") == "text/plain")
    }
}

/// The requests a test's transport received.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }

    func record(_ request: URLRequest) {
        lock.withLock { recorded.append(request) }
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
