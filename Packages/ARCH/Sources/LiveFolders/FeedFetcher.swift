// Loads feeds straight from their sites (docs/bookmarks.md, Live folders ▸ Feeds; live folder rules 2 and 7): an ephemeral `URLSession` outside every Persona's storage, with no cookies, cache, or stored credentials, over HTTPS only, 30 seconds and 5 MB per response, and the feed's validators so an unchanged feed answers 304.
import Foundation

/// The HTTP validators a feed's server sent, which the next request sends back.
public struct FeedValidators: Codable, Hashable, Sendable {
    /// `ETag`, sent back as `If-None-Match`.
    public var entityTag: String?
    /// `Last-Modified`, sent back as `If-Modified-Since`.
    public var lastModified: String?

    public init(entityTag: String? = nil, lastModified: String? = nil) {
        self.entityTag = entityTag
        self.lastModified = lastModified
    }
}

/// A parsed feed with validators or an unchanged response.
public enum FeedFetchResult: Equatable, Sendable {
    /// 304: the items stay as they are.
    case notModified
    case fetched(Feed, FeedValidators)
}

/// Fetches HTTPS feeds without browser cookies, cache, or stored credentials.
public final class FeedFetcher: Sendable {
    public static let timeLimit: TimeInterval = 30
    public static let sizeLimit = 5 * 1_024 * 1_024
    private static let accept = "application/rss+xml, application/atom+xml, application/rdf+xml;q=0.9, application/xml;q=0.8, text/xml;q=0.8, */*;q=0.5"

    /// Ephemeral, with no cookies, cache, or credential storage, and the time limit for each response.
    public static var defaultConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeLimit
        configuration.timeoutIntervalForResource = timeLimit
        return configuration
    }

    private let session: URLSession

    /// Tests pass a configuration whose protocol classes answer the requests.
    public init(configuration: URLSessionConfiguration = FeedFetcher.defaultConfiguration) {
        session = URLSession(configuration: configuration, delegate: HTTPSRedirectGuard(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Loads and parses the feed at `address`, sending `validators`. Throws `LiveFolderError`.
    public func fetch(_ address: URL, validators: FeedValidators = FeedValidators()) async throws -> FeedFetchResult {
        guard let body = try await load(address, validators: validators) else { return .notModified }
        return .fetched(try FeedParser.parse(body.data, address: body.url), body.validators)
    }

    /// Loads `address` for New Live Folder…: a feed, or the feeds that its page names. Throws `LiveFolderError`.
    public func discover(_ address: URL) async throws -> FeedDiscovery.Outcome {
        guard let body = try await load(address, validators: FeedValidators()) else { return .links([]) }
        if let feed = try? FeedParser.parse(body.data, address: body.url) { return .feed(feed) }
        return .links(FeedDiscovery.links(inHTML: body.data, address: body.url))
    }

    // MARK: Loading

    private struct Body {
        var data: Data
        /// The address after redirects, against which relative addresses resolve.
        var url: URL
        var validators: FeedValidators
    }

    /// The response body, or nil for 304.
    private func load(_ address: URL, validators: FeedValidators) async throws -> Body? {
        var request = URLRequest(url: try LiveFolderSource.feedAddress(address))
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")
        if let tag = validators.entityTag { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        if let date = validators.lastModified { request.setValue(date, forHTTPHeaderField: "If-Modified-Since") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw LiveFolderError.network("The server's answer is not HTTP.") }
            switch response.statusCode {
            case 200..<300:
                break
            case 304:
                return nil
            case 429, 503:
                throw LiveFolderError.httpStatus(response.statusCode, retryAfter: Self.retryDate(response.value(forHTTPHeaderField: "Retry-After")))
            default:
                throw LiveFolderError.httpStatus(response.statusCode, retryAfter: nil)
            }
            if response.expectedContentLength > Self.sizeLimit { throw LiveFolderError.tooLarge(bytes: Self.sizeLimit) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.sizeLimit { throw LiveFolderError.tooLarge(bytes: Self.sizeLimit) }
            }
            let sent = FeedValidators(entityTag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
            return Body(data: data, url: response.url ?? request.url ?? address, validators: sent)
        } catch let error as URLError {
            throw Self.liveFolderError(error)
        }
    }

    /// `Retry-After` in seconds or as an HTTP date.
    static func retryDate(_ value: String?, now: Date = Date()) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return seconds >= 0 ? now.addingTimeInterval(TimeInterval(seconds)) : nil }
        return FeedDate.rfc822(value)
    }

    /// Converts URL loading failures into the live folder's network errors.
    private static func liveFolderError(_ error: URLError) -> any Error {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost: return LiveFolderError.offline
        case .timedOut: return LiveFolderError.timedOut
        case .cancelled: return CancellationError()
        default: return LiveFolderError.network(error.localizedDescription)
        }
    }
}

/// Follows a redirect only to another `https` address without a user name or password, so a feed never loads over plain HTTP; a refused redirect ends as its 3xx status.
private final class HTTPSRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        return request
    }
}
