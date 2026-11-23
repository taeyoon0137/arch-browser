// Network hosts that an installed script plugin may name in its manifest, and the fetcher of `arch.net.fetch`, which connects to the address it checked.
import Foundation
import Darwin
import Network
import Security

/// An exact DNS host or a wildcard for its subdomains. It never represents an IP address or a local host.
public struct PluginNetworkHost: Hashable, Codable, Sendable, CustomStringConvertible {
    public let description: String
    private let name: String
    private let includesSubdomains: Bool

    /// Refuses IP literals in every notation that `inet_aton` reads, such as `127.1`, `0x7f.0.0.1`, or `017700000001`, and a name whose last label is a number, which URL parsers read as an IPv4 address.
    public init?(_ entry: String) {
        let value = entry.lowercased()
        let wildcard = value.hasPrefix("*.")
        let host = wildcard ? String(value.dropFirst(2)) : value
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host != "localhost", !host.hasSuffix(".localhost"),
              let last = labels.last, !last.allSatisfy(\.isNumber),
              !(last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit)),
              labels.allSatisfy({ label in
                  guard let first = label.first, let last = label.last,
                        first.isASCII && first.isLetter || first.isASCII && first.isNumber,
                        last.isASCII && last.isLetter || last.isASCII && last.isNumber,
                        label.count <= 63 else { return false }
                  return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }), host.utf8.count <= 253 else { return nil }
        var address = in_addr()
        guard inet_aton(host, &address) == 0 else { return nil }
        self.name = host
        includesSubdomains = wildcard
        description = value
    }

    public func covers(_ host: String) -> Bool {
        let host = host.lowercased()
        return includesSubdomains ? host.hasSuffix("." + name) : host == name
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let host = Self(value) else { throw PluginError.hostRefused }
        self = host
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Which resolved addresses a plugin's request may connect to: public unicast ones only.
enum PluginNetworkAddress {
    /// Whether the address, 4 bytes for IPv4 or 16 for IPv6, is public unicast. IPv4 refuses this network, private, shared (100.64/10), loopback, link-local, the IETF and documentation blocks, the 6to4 relay, benchmarking (198.18/15), multicast, reserved, and broadcast. IPv6 accepts only global unicast (2000::/3), without 6to4 (2002::/16) and NAT64 (64:ff9b::/96) addresses whose embedded IPv4 address IPv4 refuses, the IETF block with Teredo (2001::/23), and documentation (2001:db8::/32, 3fff::/20), so loopback, unspecified, IPv4-compatible, unique-local, link-local, site-local, multicast, and the local NAT64 prefix (64:ff9b:1::/48) are refused. An IPv4-mapped address (::ffff:0:0/96) is judged by its IPv4 address.
    static func isPublic(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4: return isPublicIPv4(bytes)
        case 16: return isPublicIPv6(bytes)
        default: return false
        }
    }

    private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _), (224..., _, _): return false
        case (100, 64...127, _), (169, 254, _), (172, 16...31, _), (192, 168, _), (198, 18...19, _): return false
        case (192, 0, 0), (192, 0, 2), (192, 88, 99), (198, 51, 100), (203, 0, 113): return false
        default: return true
        }
    }

    private static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        let embedded = Array(b[12...])
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPublicIPv4(embedded) }
        if b[0..<12] == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] { return isPublicIPv4(embedded) }
        guard b[0] & 0xe0 == 0x20 else { return false }
        if b[0] == 0x20 && b[1] == 0x02 { return isPublicIPv4(Array(b[2...5])) }
        if b[0] == 0x20 && b[1] == 0x01 && (b[2] <= 0x01 || b[2] == 0x0d && b[3] == 0xb8) { return false }
        if b[0] == 0x3f && b[1] == 0xff && b[2] & 0xf0 == 0 { return false }
        return true
    }
}

/// One bounded HTTPS request with up to five redirects, each hop to a granted host on port 443. Each hop resolves its host once, refuses it unless every address is public (`PluginNetworkAddress`), and connects to one of those addresses itself, so a second DNS answer can never pick the address; TLS sends and verifies the host's name. It uses no proxy, cookies, cache, or stored credentials, sends HTTP/1.1 with `Connection: close`, and stops reading at the body limit and at 30 seconds for the whole request.
final class PluginNetworkFetch: @unchecked Sendable {
    static let bodyLimit = 5 * 1024 * 1024
    static let requestLimit = 1024 * 1024
    /// The most bytes of headers a request sends or a response's head may have.
    static let headerLimit = 64 * 1024
    static let redirectLimit = 5
    static let timeLimit: TimeInterval = 30
    /// Headers a plugin may not set: those that carry the user's identity or the page's, and those that frame the message or the connection, which the fetcher writes itself.
    static let refusedHeaders: Set<String> = [
        "cookie", "host", "origin", "referer", "content-length", "transfer-encoding", "connection", "keep-alive", "upgrade", "te", "trailer", "expect",
        "accept-encoding", "proxy-authorization", "proxy-connection",
    ]
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    private let hosts: [PluginNetworkHost]
    private let lock = NSLock()
    private var isCancelled = false
    private var exchange: Exchange?

    init(hosts: [PluginNetworkHost]) { self.hosts = hosts }

    func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Self.validate(request)
        let deadline = Date().addingTimeInterval(Self.timeLimit)
        return try await withTaskCancellationHandler {
            var request = request
            var hops = 0
            while true {
                guard let url = request.url, let host = url.host?.lowercased() else { throw PluginError.hostRefused }
                let addresses = try await Self.resolve(url, hosts: hosts)
                let response = try await send(Self.message(for: request), to: host, at: addresses, deadline: deadline)
                guard let next = try Self.redirect(of: request, by: response, hosts: hosts) else {
                    guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headerFields) else {
                        throw PluginError.invalidResponse
                    }
                    return (response.body, http)
                }
                hops += 1
                guard hops <= Self.redirectLimit else { throw PluginError.redirectRefused }
                request = next
            }
        } onCancel: {
            let exchange = lock.withLock {
                isCancelled = true
                return self.exchange
            }
            exchange?.fail(PluginError.stopped)
        }
    }

    /// Sends the message to the first of the addresses that connects.
    private func send(_ message: Data, to host: String, at addresses: [NWEndpoint.Host], deadline: Date) async throws -> PluginHTTPResponse {
        var failure: any Error = PluginError.networkUnavailable
        for address in addresses {
            let exchange = Exchange(host: host, address: address, message: message, deadline: deadline)
            // Registering under the lock, after the cancellation flag's check, means a cancellation either finds this exchange or happened before it, so no exchange starts once the request is cancelled.
            let isCancelled = lock.withLock {
                if !self.isCancelled { self.exchange = exchange }
                return self.isCancelled
            }
            guard !isCancelled else { throw PluginError.stopped }
            do {
                return try await exchange.run()
            } catch Exchange.Failure.notConnected {
                failure = PluginError.networkUnavailable
            }
        }
        throw failure
    }

    /// Refuses a request that the bridge's checks would refuse, for Swift callers that build their own.
    static func validate(_ request: URLRequest) throws {
        let method = request.httpMethod ?? "GET"
        let headers = request.allHTTPHeaderFields ?? [:]
        guard methods.contains(method), (request.httpBody?.count ?? 0) <= requestLimit, request.httpBodyStream == nil,
              method != "GET" || request.httpBody == nil, request.url?.user == nil, request.url?.password == nil,
              headers.allSatisfy({ isAllowedHeader(name: $0.key, value: $0.value) }),
              headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count + 4 }) <= headerLimit else { throw PluginError.invalidRequest }
    }

    /// An RFC 9110 token as the name, outside `refusedHeaders`, with a value without control characters other than tab.
    static func isAllowedHeader(name: String, value: String) -> Bool {
        let symbols = Set("!#$%&'*+-.^_`|~".unicodeScalars)
        let isToken = name.unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value) || (0x41...0x5a).contains(scalar.value) || (0x61...0x7a).contains(scalar.value) || symbols.contains(scalar)
        }
        return !name.isEmpty && isToken
            && !refusedHeaders.contains(name.lowercased()) && !name.lowercased().hasPrefix("proxy-")
            && value.unicodeScalars.allSatisfy { $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7f) }
    }

    /// The addresses that the URL's host resolves to, each of them public, for an HTTPS URL on port 443 whose host a granted entry covers. Throws `PluginError.hostRefused` otherwise, and for a host that does not resolve.
    static func resolve(_ url: URL, hosts: [PluginNetworkHost]) async throws -> [NWEndpoint.Host] {
        guard let host = checkedHost(of: url, hosts: hosts) else { throw PluginError.hostRefused }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try addresses(of: host) })
            }
        }
    }

    /// The URL's host when the URL is one the grant lets a request reach: HTTPS, without a user, on the default port, at a host name that a granted entry covers.
    static func checkedHost(of url: URL, hosts: [PluginNetworkHost]) -> String? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), PluginNetworkHost(host) != nil, hosts.contains(where: { $0.covers(host) }) else { return nil }
        return host
    }

    /// Resolves once with `getaddrinfo` and refuses the host when any of its addresses is not public, since a host that answers with a local address is not one a plugin may reach.
    private static func addresses(of host: String) throws -> [NWEndpoint.Host] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &first) == 0, let first else { throw PluginError.hostRefused }
        defer { freeaddrinfo(first) }
        var found: [NWEndpoint.Host] = []
        var item: UnsafeMutablePointer<addrinfo>? = first
        while let address = item {
            defer { item = address.pointee.ai_next }
            guard let raw = address.pointee.ai_addr else { throw PluginError.hostRefused }
            let bytes: [UInt8]
            switch address.pointee.ai_family {
            case AF_INET:
                bytes = withUnsafeBytes(of: raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }) { Array($0) }
            case AF_INET6:
                bytes = withUnsafeBytes(of: raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }) { Array($0) }
            default: throw PluginError.hostRefused
            }
            guard PluginNetworkAddress.isPublic(bytes) else { throw PluginError.hostRefused }
            // A mapped address connects as the IPv4 address it was judged by.
            let isMapped = bytes.count == 16 && bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            if bytes.count == 4 || isMapped, let ipv4 = IPv4Address(Data(bytes.suffix(4))) { found.append(.ipv4(ipv4)) }
            else if let ipv6 = IPv6Address(Data(bytes)) { found.append(.ipv6(ipv6)) }
            else { throw PluginError.hostRefused }
        }
        guard !found.isEmpty else { throw PluginError.hostRefused }
        return found
    }

    /// The HTTP/1.1 request: the method, the path and query, `Host`, the plugin's headers, `Accept` and `User-Agent` unless it set them, `Accept-Encoding: identity`, `Connection: close`, and `Content-Length` with the body.
    static func message(for request: URLRequest) throws -> Data {
        guard let url = request.url, let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PluginError.invalidRequest }
        let method = request.httpMethod ?? "GET"
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?" + query }
        guard !target.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value >= 0x7f }) else { throw PluginError.invalidRequest }
        let headers = request.allHTTPHeaderFields ?? [:]
        let given = Set(headers.keys.map { $0.lowercased() })
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(host)"]
        lines += headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        if !given.contains("accept") { lines.append("Accept: */*") }
        if !given.contains("user-agent") { lines.append("User-Agent: Arch") }
        lines += ["Accept-Encoding: identity", "Connection: close"]
        let body = request.httpBody ?? Data()
        if !body.isEmpty || ["POST", "PUT", "PATCH"].contains(method) { lines.append("Content-Length: \(body.count)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }

    /// The next hop's request for a redirect, or nil for a response that is not one. 303, and 301 or 302 after a POST, continue with GET and no body; a hop to another host drops `Authorization`. Throws `PluginError.redirectRefused` for a location that is not a granted HTTPS address on port 443.
    static func redirect(of request: URLRequest, by response: PluginHTTPResponse, hosts: [PluginNetworkHost]) throws -> URLRequest? {
        guard [301, 302, 303, 307, 308].contains(response.status), let location = response.header("location") else { return nil }
        guard let current = request.url, let url = URL(string: location, relativeTo: current)?.absoluteURL,
              let host = checkedHost(of: url, hosts: hosts) else { throw PluginError.redirectRefused }
        var next = request
        next.url = url
        if response.status == 303 || (response.status == 301 || response.status == 302) && request.httpMethod == "POST" {
            next.httpMethod = "GET"
            next.httpBody = nil
            next.setValue(nil, forHTTPHeaderField: "Content-Type")
        }
        if host != current.host?.lowercased() { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        return next
    }

    /// One connection to one checked address, on its own queue, which every state change runs on.
    private final class Exchange: @unchecked Sendable {
        enum Failure: Error {
            /// The connection ended before it was ready, so another address may still connect.
            case notConnected
        }

        private let queue = DispatchQueue(label: "xyz.taeyoon.arch.plugin-fetch")
        private let connection: NWConnection
        private let message: Data
        private let deadline: Date
        private var buffer = Data()
        private var isReady = false
        private var continuation: CheckedContinuation<PluginHTTPResponse, any Error>?
        private var pendingFailure: (any Error)?

        init(host: String, address: NWEndpoint.Host, message: Data, deadline: Date) {
            self.message = message
            self.deadline = deadline
            let tls = NWProtocolTLS.Options()
            let security = tls.securityProtocolOptions
            sec_protocol_options_set_tls_server_name(security, host)
            sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
            sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
            // The connection's endpoint is an address, so the certificate is checked against the host's name, as a connection by name would check it.
            sec_protocol_options_set_verify_block(security, { _, trust, complete in
                let trust = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
                complete(SecTrustEvaluateWithError(trust, nil))
            }, queue)
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = Int(PluginNetworkFetch.timeLimit)
            let parameters = NWParameters(tls: tls, tcp: tcp)
            parameters.preferNoProxies = true
            connection = NWConnection(host: address, port: 443, using: parameters)
        }

        func run() async throws -> PluginHTTPResponse {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let pendingFailure { return continuation.resume(throwing: pendingFailure) }
                    self.continuation = continuation
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { return finish(.failure(PluginError.timedOut)) }
                    queue.asyncAfter(deadline: .now() + remaining) { [weak self] in self?.finish(.failure(PluginError.timedOut)) }
                    connection.stateUpdateHandler = { [weak self] state in self?.change(to: state) }
                    connection.start(queue: queue)
                }
            }
        }

        /// Ends the exchange with the error from any thread; an exchange that has not started ends at its start.
        func fail(_ error: any Error) {
            queue.async { [self] in
                if continuation == nil { pendingFailure = error } else { finish(.failure(error)) }
            }
        }

        private func change(to state: NWConnection.State) {
            switch state {
            case .ready:
                isReady = true
                connection.send(content: message, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.finish(.failure(PluginError.networkUnavailable)) }
                })
                receive()
            case .waiting, .failed:
                finish(.failure(isReady ? PluginError.networkUnavailable : Failure.notConnected))
            default:
                break
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, continuation != nil else { return }
                if let data { buffer.append(data) }
                do {
                    if let response = try PluginHTTPResponse.parse(buffer, ended: isComplete || error != nil) { return finish(.success(response)) }
                } catch {
                    return finish(.failure(error))
                }
                if error != nil { return finish(.failure(PluginError.networkUnavailable)) }
                receive()
            }
        }

        private func finish(_ result: Result<PluginHTTPResponse, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(with: result)
        }
    }
}

/// A response read from an HTTP/1.1 connection that the fetcher closes after it: its status, headers, and body, framed by `Transfer-Encoding: chunked`, `Content-Length`, or the end of the connection.
struct PluginHTTPResponse: Equatable {
    let status: Int
    let headers: [(name: String, value: String)]
    let body: Data

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body && lhs.headers.map(\.name) == rhs.headers.map(\.name) && lhs.headers.map(\.value) == rhs.headers.map(\.value)
    }

    /// The first value of the header, by name in any case.
    func header(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name }?.value
    }

    /// The headers as `HTTPURLResponse` takes them, repeated names joined with commas.
    var headerFields: [String: String] {
        var fields: [String: String] = [:]
        for (name, value) in headers {
            if let key = fields.keys.first(where: { $0.lowercased() == name.lowercased() }) { fields[key]! += ", " + value } else { fields[name] = value }
        }
        return fields
    }

    /// The response once `data` holds all of it, or nil while more may come. `ended` says the connection has closed, after which a response that is not whole is invalid. Interim 1xx responses are skipped. Throws `PluginError.invalidResponse` for a malformed head, framing, or a compressed body, and `responseTooLarge` past the limits.
    static func parse(_ data: Data, ended: Bool) throws -> PluginHTTPResponse? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            if data.count > PluginNetworkFetch.headerLimit { throw PluginError.responseTooLarge }
            if ended { throw PluginError.invalidResponse }
            return nil
        }
        guard end.lowerBound - data.startIndex <= PluginNetworkFetch.headerLimit,
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .isoLatin1) else { throw PluginError.responseTooLarge }
        let lines = head.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusLine.count >= 2, statusLine[0] == "HTTP/1.1" || statusLine[0] == "HTTP/1.0", statusLine[1].count == 3,
              let status = Int(statusLine[1]), (100...599).contains(status) else { throw PluginError.invalidResponse }
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), let first = line.first, first != " ", first != "\t" else { throw PluginError.invalidResponse }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else { throw PluginError.invalidResponse }
            headers.append((name, line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))))
        }
        let rest = data[end.upperBound...]
        if (100...199).contains(status) {
            guard status != 101 else { throw PluginError.invalidResponse }
            return try parse(Data(rest), ended: ended)
        }
        let response = PluginHTTPResponse(status: status, headers: headers, body: Data())
        if let encoding = response.header("content-encoding"), encoding.lowercased() != "identity" { throw PluginError.invalidResponse }
        let body: Data?
        if status == 204 || status == 304 {
            body = Data()
        } else if let transfer = response.header("transfer-encoding") {
            guard transfer.lowercased() == "chunked", response.header("content-length") == nil else { throw PluginError.invalidResponse }
            body = try chunks(of: Data(rest), ended: ended)
        } else if response.header("content-length") != nil {
            let values = Set(headers.filter { $0.name.lowercased() == "content-length" }.flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
            guard values.count == 1, let value = values.first, !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let count = Int(value) else {
                throw PluginError.invalidResponse
            }
            guard count <= PluginNetworkFetch.bodyLimit else { throw PluginError.responseTooLarge }
            if rest.count >= count { body = Data(rest.prefix(count)) }
            else if ended { throw PluginError.invalidResponse }
            else { body = nil }
        } else {
            guard rest.count <= PluginNetworkFetch.bodyLimit else { throw PluginError.responseTooLarge }
            body = ended ? Data(rest) : nil
        }
        return body.map { PluginHTTPResponse(status: status, headers: headers, body: $0) }
    }

    /// The body of a chunked message once its last chunk and trailers have arrived, or nil before then.
    private static func chunks(of data: Data, ended: Bool) throws -> Data? {
        let lineEnd = Data("\r\n".utf8)
        var body = Data()
        var index = data.startIndex
        while true {
            guard let sizeEnd = data[index...].range(of: lineEnd) else {
                if data.count - (index - data.startIndex) > 1024 { throw PluginError.invalidResponse }
                if ended { throw PluginError.invalidResponse }
                return nil
            }
            guard let line = String(data: data[index..<sizeEnd.lowerBound], encoding: .ascii),
                  let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first?.trimmingCharacters(in: .whitespaces),
                  // Hex digits only: `Int(_:radix:)` also reads a sign, and a negative size would make an invalid range.
                  !sizeText.isEmpty, sizeText.count <= 8, sizeText.allSatisfy(\.isHexDigit), sizeText.allSatisfy(\.isASCII),
                  let size = Int(sizeText, radix: 16) else { throw PluginError.invalidResponse }
            index = sizeEnd.upperBound
            if size == 0 {
                // Trailers follow until an empty line.
                while true {
                    guard let trailerEnd = data[index...].range(of: lineEnd) else {
                        if ended { throw PluginError.invalidResponse }
                        return nil
                    }
                    let isEmpty = trailerEnd.lowerBound == index
                    index = trailerEnd.upperBound
                    if isEmpty { return body }
                }
            }
            guard body.count + size <= PluginNetworkFetch.bodyLimit else { throw PluginError.responseTooLarge }
            guard data.endIndex - index >= size + 2 else {
                if ended { throw PluginError.invalidResponse }
                return nil
            }
            body.append(data[index..<(index + size)])
            index += size
            guard data[index..<(index + 2)] == lineEnd else { throw PluginError.invalidResponse }
            index += 2
        }
    }
}
