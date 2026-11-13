// Asks the Web Store's update endpoint about extensions and downloads their packages (`docs/web-store.md`, Install flow and Privacy decision). A request carries the identifiers and installed versions it asks about, the Chromium version of Arch's engine, and the Mac's `os` and `arch`, through a session that keeps and sends no cookies, caches nothing, and sends no language. The answer is update protocol 2.0 XML, which `XMLParser` reads; a package downloads only over HTTPS, up to 256 MB, and must match the size and SHA-256 digest that the answer gives.
import CryptoKit
import Foundation

/// What the Web Store offers for an extension: its current version and where its package is.
public struct WebStoreRelease: Equatable, Sendable {
    /// The extension's identifier.
    public let id: String
    public let version: String
    /// The package's HTTPS address, the answer's `codebase`.
    let package: URL
    /// The package's SHA-256 digest, the answer's `hash_sha256`, when the answer gives one.
    let sha256: Data?
    /// The package's size in bytes, when the answer gives it.
    let size: Int?
}

/// The Web Store's answer about one extension.
enum WebStoreAnswer: Equatable, Sendable {
    /// A package newer than the version asked about.
    case release(WebStoreRelease)
    /// Nothing newer than the version asked about; for `0.0.0.0`, nothing that the store offers this browser.
    case noUpdate
    /// The store has no extension with the identifier.
    case unknown
    /// Another status, such as `error-osnotsupported`, which messages quote.
    case refused(String)
}

/// Why an install from the Web Store stopped, as the store sheet says it. The network's own failures keep the system's error and message.
public enum WebStoreError: Error, Equatable, Sendable {
    /// The store has no extension with the identifier.
    case unknownExtension(String)
    /// The store offered no package for the identifier, with the status it gave.
    case notOffered(String, status: String)
    /// The Persona has the store's current version of the extension installed from the store.
    case alreadyInstalled(name: String, version: String)
    /// The endpoint's answer is not the update protocol's XML, or a package it offers lacks its address or version.
    case unreadableAnswer
    /// The endpoint or the package's address answered with another HTTP status than 200.
    case httpStatus(Int)
    /// The package's address, or a redirect from it, is not HTTPS.
    case insecurePackage
    /// The package is larger than `WebStoreClient.maximumPackageSize`.
    case packageTooLarge
    /// The downloaded package's size or digest differs from the answer's.
    case damagedDownload
    /// The client has no Chromium version to ask with, as when the CEF version does not name one.
    case noEngineVersion
}

extension WebStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unknownExtension(id): return "The Web Store has no extension with the identifier \u{201C}\(id)\u{201D}."
        case let .notOffered(id, status): return "The Web Store did not offer \u{201C}\(id)\u{201D}: \(status)."
        case let .alreadyInstalled(name, version): return "\u{201C}\(name)\u{201D} \(version) is installed, the Web Store's current version."
        case .unreadableAnswer: return "The Web Store's answer does not read."
        case let .httpStatus(status): return "The Web Store answered with HTTP status \(status)."
        case .insecurePackage: return "The Web Store offered the package at an address without HTTPS."
        case .packageTooLarge: return "The package from the Web Store is larger than 256 MB."
        case .damagedDownload: return "The download from the Web Store is damaged. Try again."
        case .noEngineVersion: return "Arch cannot ask the Web Store without the version of its Chromium engine."
        }
    }
}

public final class WebStoreClient: Sendable {
    /// The most identifiers that one request asks about.
    static let identifiersPerRequest = 25
    /// The largest package that Arch downloads, 256 MB.
    static let maximumPackageSize = 256 << 20
    /// The Mac's architecture as the endpoint's `arch` names it, as Chromium's updater sends it.
    #if arch(arm64)
    static let architecture = "arm64"
    #else
    static let architecture = "x64"
    #endif

    /// The Chromium version that the requests give as `prodversion`, without which the store offers nothing; empty when the client has none.
    let productVersion: String
    private let session: URLSession
    private let packageSizeLimit: Int

    /// `productVersion` is the Chromium version in the CEF version of Arch's engine (`chromiumVersion(inCEFVersion:)`), such as 156.0.8078.48.
    public convenience init(productVersion: String) {
        self.init(productVersion: productVersion, session: Self.makeSession(), packageSizeLimit: Self.maximumPackageSize)
    }

    /// Tests pass a session whose configuration comes from `makeSession(configuration:)` with a protocol that answers for the endpoint, and a smaller package limit.
    init(productVersion: String, session: URLSession, packageSizeLimit: Int = maximumPackageSize) {
        self.productVersion = productVersion
        self.session = session
        self.packageSizeLimit = packageSizeLimit
    }

    /// No cookies, cache, or stored credentials, as for the AI providers' requests and site icons.
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// The Chromium version that a CEF version names after `+chromium-`, four dot-separated numbers, such as 156.0.8078.48 in `156.0.49-arch-8078.3694+gc51d2f8+chromium-156.0.8078.48`; nil when it names none.
    public static func chromiumVersion(inCEFVersion cefVersion: String) -> String? {
        guard let start = cefVersion.range(of: "+chromium-")?.upperBound else { return nil }
        let version = cefVersion[start...].prefix { $0 != "+" }
        let numbers = version.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 4, numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } }) else { return nil }
        return String(version)
    }

    // MARK: Asking

    /// Asks about each identifier with its installed version, or `0.0.0.0` for nil, at most `identifiersPerRequest` to a request, one request after another, and gives the store's answer for each identifier it answered. Cancelling the task stops the request and throws `CancellationError`, not the system's error for a cancelled request.
    func releases(of queries: [(id: String, version: String?)]) async throws -> [String: WebStoreAnswer] {
        guard !productVersion.isEmpty else { throw WebStoreError.noEngineVersion }
        let asked = Set(queries.map(\.id))
        var answers: [String: WebStoreAnswer] = [:]
        for request in requests(for: queries) {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                try Task.checkCancellation()
                throw error
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw WebStoreError.httpStatus(status) }
            let answered = try Self.answers(in: data)
            answers.merge(answered.filter { asked.contains($0.key) }) { $1 }
        }
        return answers
    }

    /// The requests for the queries, `identifiersPerRequest` to each: `response=updatecheck`, `os`, `arch`, `prodversion`, and `acceptformat=crx3`, then an `x` for each identifier, `id=<identifier>&v=<version>&installsource=ondemand&uc` encoded as one value. The endpoint offers nothing without `prodversion`, `acceptformat`, or `uc`. Each request sends an empty `Accept-Language`, since URLSession would otherwise send the user's languages.
    func requests(for queries: [(id: String, version: String?)]) -> [URLRequest] {
        stride(from: 0, to: queries.count, by: Self.identifiersPerRequest).map { start in
            let batch = queries[start..<min(start + Self.identifiersPerRequest, queries.count)]
            let parameters = [("response", "updatecheck"), ("os", "mac"), ("arch", Self.architecture), ("prodversion", productVersion), ("acceptformat", "crx3")]
                + batch.map { ("x", "id=\(Self.encoded($0.id))&v=\(Self.encoded($0.version ?? "0.0.0.0"))&installsource=ondemand&uc") }
            var components = URLComponents(url: WebStore.updateEndpoint, resolvingAgainstBaseURL: false)!
            components.percentEncodedQuery = parameters.map { "\($0)=\(Self.encoded($1))" }.joined(separator: "&")
            var request = URLRequest(url: components.url!)
            request.setValue("", forHTTPHeaderField: "Accept-Language")
            return request
        }
    }

    /// Letters, digits, and `-._~`, which a query value keeps as they are; `URLComponents` would keep `&` and `=` too.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The answers in the endpoint's XML, by identifier: a `gupdate` element with an `app` element for each identifier, whose `status` is `ok` or an error such as `error-unknownApplication`, and, for `ok`, an `updatecheck` element whose `status` is `ok` with `codebase`, `version`, `hash_sha256`, and `size`, `noupdate`, or an error. An `app` without an `updatecheck` offers nothing. Throws `unreadableAnswer` for other XML and for an offer without its address or version, or with a digest that is not 64 hexadecimal digits.
    static func answers(in data: Data) throws -> [String: WebStoreAnswer] {
        let reader = UpdateResponseReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.isUpdateResponse else { throw WebStoreError.unreadableAnswer }
        var answers: [String: WebStoreAnswer] = [:]
        for app in reader.apps {
            answers[app.id] = try answer(for: app)
        }
        return answers
    }

    private static func answer(for app: UpdateResponseReader.App) throws -> WebStoreAnswer {
        guard app.status == "ok" else { return app.status == "error-unknownApplication" ? .unknown : .refused(app.status) }
        guard let check = app.updateCheck else { return .noUpdate }
        switch check["status"] {
        case "ok":
            guard let version = check["version"], !version.isEmpty, let package = check["codebase"].flatMap(URL.init(string:)) else { throw WebStoreError.unreadableAnswer }
            let sha256 = try check["hash_sha256"].map { hex in
                guard let digest = Self.data(hexadecimal: hex), digest.count == 32 else { throw WebStoreError.unreadableAnswer }
                return digest
            }
            return .release(WebStoreRelease(id: app.id, version: version, package: package, sha256: sha256, size: check["size"].flatMap { Int($0) }))
        case "noupdate": return .noUpdate
        case "error-unknownApplication": return .unknown
        case let status?: return .refused(status)
        case nil: throw WebStoreError.unreadableAnswer
        }
    }

    /// The bytes that pairs of hexadecimal digits in either case write, or nil for other text.
    private static func data(hexadecimal text: String) -> Data? {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return Data(bytes)
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return digit - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: Downloading

    /// Writes the release's package to `file`, which must not exist, from its HTTPS address only, following redirects only to HTTPS addresses, and stopping once it passes the package limit, which a size the answer gives above the limit refuses before any request. A package whose size or SHA-256 digest differs from the answer's throws `damagedDownload`. Any failure, cancelling the task among them, deletes the file; cancelling throws `CancellationError`.
    func download(_ release: WebStoreRelease, to file: URL) async throws {
        guard release.package.scheme?.lowercased() == "https" else { throw WebStoreError.insecurePackage }
        guard (release.size ?? 0) <= packageSizeLimit else { throw WebStoreError.packageTooLarge }
        try Data().write(to: file, options: .withoutOverwriting)
        var isComplete = false
        defer { if !isComplete { try? FileManager.default.removeItem(at: file) } }
        let handle = try FileHandle(forWritingTo: file)
        var request = URLRequest(url: release.package)
        request.setValue("", forHTTPHeaderField: "Accept-Language")
        let received: (digest: Data, size: Int)
        do {
            received = try await PackageDownload(handle: handle, limit: packageSizeLimit).run(session.dataTask(with: request))
            try handle.close()
        } catch {
            try? handle.close()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard release.sha256.map({ $0 == received.digest }) ?? true, release.size.map({ $0 == received.size }) ?? true else { throw WebStoreError.damagedDownload }
        isComplete = true
    }
}

/// Collects the `app` elements of an update response with their `updatecheck` element's attributes.
private final class UpdateResponseReader: NSObject, XMLParserDelegate {
    struct App {
        let id: String
        let status: String
        var updateCheck: [String: String]?
    }

    private(set) var apps: [App] = []
    /// Whether the document's root is `gupdate`.
    private(set) var isUpdateResponse = false
    private var depth = 0
    private var app: App?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        defer { depth += 1 }
        if depth == 0 {
            isUpdateResponse = elementName == "gupdate"
            if !isUpdateResponse { parser.abortParsing() }
            return
        }
        switch elementName {
        case "app" where depth == 1:
            guard let id = attributes["appid"], let status = attributes["status"] else { return fail(parser) }
            app = App(id: id.lowercased(), status: status)
        case "updatecheck" where depth == 2 && app != nil && app?.updateCheck == nil:
            app?.updateCheck = attributes
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        guard depth == 1, elementName == "app", let app else { return }
        apps.append(app)
        self.app = nil
    }

    private func fail(_ parser: XMLParser) {
        isUpdateResponse = false
        parser.abortParsing()
    }
}

/// One package download, which writes the body to the file as it arrives and takes its SHA-256 digest, and stops at a redirect to an address without HTTPS, at a status other than 200, and once the body passes the limit, also one whose length the response does not state. URLSession calls a task's delegate one call at a time, after `run` has set the continuation, so its state needs no lock.
private final class PackageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private var hasher = SHA256()
    private var size = 0
    /// The first reason the download stopped, which wins over the cancellation that it causes.
    private var failure: (any Error)?
    private var continuation: CheckedContinuation<(digest: Data, size: Int), any Error>?

    init(handle: FileHandle, limit: Int) {
        self.handle = handle
        self.limit = limit
    }

    /// Runs the task with this download as its delegate until it ends; cancelling the calling task cancels it.
    func run(_ task: URLSessionDataTask) async throws -> (digest: Data, size: Int) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.delegate = self
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            stop(task, because: WebStoreError.insecurePackage)
            return completionHandler(nil)
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            failure = failure ?? WebStoreError.httpStatus(status)
        } else if response.expectedContentLength > limit {
            failure = failure ?? WebStoreError.packageTooLarge
        }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        size += data.count
        guard size <= limit else { return stop(dataTask, because: WebStoreError.packageTooLarge) }
        hasher.update(data: data)
        do {
            try handle.write(contentsOf: data)
        } catch {
            stop(dataTask, because: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let failure = failure ?? error {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume(returning: (Data(hasher.finalize()), size))
        }
        continuation = nil
    }

    private func stop(_ task: URLSessionTask, because reason: any Error) {
        failure = failure ?? reason
        task.cancel()
    }
}
