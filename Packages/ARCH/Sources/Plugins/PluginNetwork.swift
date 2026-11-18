// Network hosts that an installed script plugin may name in its manifest.
import Foundation
import Darwin

/// An exact DNS host or a wildcard for its subdomains. It never represents an IP address or a local host.
public struct PluginNetworkHost: Hashable, Codable, Sendable, CustomStringConvertible {
    public let description: String
    private let name: String
    private let includesSubdomains: Bool

    public init?(_ entry: String) {
        let value = entry.lowercased()
        let wildcard = value.hasPrefix("*.")
        let host = wildcard ? String(value.dropFirst(2)) : value
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host != "localhost", !host.hasSuffix(".localhost"),
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              labels.allSatisfy({ label in
                  guard let first = label.first, let last = label.last,
                        first.isASCII && first.isLetter || first.isASCII && first.isNumber,
                        last.isASCII && last.isLetter || last.isASCII && last.isNumber,
                        label.count <= 63 else { return false }
                  return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }), host.utf8.count <= 253 else { return nil }
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

/// One bounded HTTPS request. The delegate checks every redirect and stops reading at the body limit.
final class PluginNetworkFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let bodyLimit = 5 * 1024 * 1024
    static let requestLimit = 1024 * 1024
    private let hosts: [PluginNetworkHost]
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var redirects = 0
    private var failure: PluginError?
    private var session: URLSession?

    init(hosts: [PluginNetworkHost]) { self.hosts = hosts }

    func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Self.check(request.url, hosts: hosts)
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(request.httpMethod ?? "GET"),
              (request.httpBody?.count ?? 0) <= Self.requestLimit,
              request.httpBodyStream == nil, request.url?.user == nil, request.url?.password == nil,
              !(request.allHTTPHeaderFields ?? [:]).keys.contains(where: {
                  ["cookie", "host", "origin", "referer", "content-length"].contains($0.lowercased())
              }) else { throw PluginError.invalidRequest }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let count = redirects
        lock.unlock()
        guard count <= 5 else {
            lock.lock(); failure = .redirectRefused; lock.unlock()
            completionHandler(nil)
            task.cancel()
            return
        }
        do {
            try Self.check(request.url, hosts: hosts)
            completionHandler(request)
        } catch {
            lock.lock(); failure = .redirectRefused; lock.unlock()
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            lock.lock(); failure = .invalidResponse; lock.unlock()
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = response
        let tooLarge = response.expectedContentLength > Self.bodyLimit
        if tooLarge { failure = .responseTooLarge }
        lock.unlock()
        completionHandler(tooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if data.count > Self.bodyLimit - body.count {
            failure = .responseTooLarge
            lock.unlock()
            dataTask.cancel()
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result = (body, response, failure)
        lock.unlock()
        session.finishTasksAndInvalidate()
        guard let continuation else { return }
        if let failure = result.2 { continuation.resume(throwing: failure) }
        else if let error = error as? URLError, error.code == .timedOut { continuation.resume(throwing: PluginError.timedOut) }
        else if let error { continuation.resume(throwing: error) }
        else if let response = result.1, String(data: result.0, encoding: .utf8) != nil {
            continuation.resume(returning: (result.0, response))
        } else { continuation.resume(throwing: PluginError.invalidResponse) }
    }

    /// Reject local and unroutable addresses before each request, including redirected hosts.
    static func check(_ url: URL?, hosts: [PluginNetworkHost]) throws {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host,
              hosts.contains(where: { $0.covers(host) }), PluginNetworkHost(host) != nil else {
            throw PluginError.hostRefused
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &first) == 0, let first else { throw PluginError.hostRefused }
        defer { freeaddrinfo(first) }
        var item: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let address = item {
            defer { item = address.pointee.ai_next }
            guard let raw = address.pointee.ai_addr else { throw PluginError.hostRefused }
            switch address.pointee.ai_family {
            case AF_INET:
                let bytes = withUnsafeBytes(of: raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }) { Array($0) }
                guard bytes.count == 4, bytes[0] != 0, bytes[0] != 10, bytes[0] != 127, bytes[0] != 169 || bytes[1] != 254,
                      bytes[0] != 172 || !(16...31).contains(bytes[1]), bytes[0] != 192 || bytes[1] != 168,
                      bytes[0] != 100 || !(64...127).contains(bytes[1]), bytes[0] < 224 else { throw PluginError.hostRefused }
            case AF_INET6:
                let bytes = withUnsafeBytes(of: raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }) { Array($0) }
                guard bytes.count == 16, !bytes.allSatisfy({ $0 == 0 }), bytes != [UInt8](repeating: 0, count: 15) + [1],
                      bytes[0] & 0xfe != 0xfc, !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80), bytes[0] != 0xff else { throw PluginError.hostRefused }
                if bytes.prefix(12) == [UInt8](repeating: 0, count: 10) + [255, 255] {
                    let mapped = Array(bytes.suffix(4))
                    guard mapped[0] != 10, mapped[0] != 127, mapped[0] != 192 || mapped[1] != 168,
                          mapped[0] != 172 || !(16...31).contains(mapped[1]) else { throw PluginError.hostRefused }
                }
            default: throw PluginError.hostRefused
            }
            found = true
        }
        guard found else { throw PluginError.hostRefused }
    }
}
