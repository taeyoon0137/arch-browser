// Fetches a script package from its declared source without browser credentials or cookies.
import Foundation
import Plugins

enum PluginSyncDownload {
    static let maximumSize = 256 << 20

    @MainActor static func stage(_ url: URL, in manager: PluginManager) async throws -> PluginPackage {
        guard isAllowed(url) else { throw URLError(.unsupportedURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= maximumSize else { throw URLError(.badServerResponse) }
        let file = manager.stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension.lowercased() == "crx" ? "crx" : "zip")
        try FileManager.default.createDirectory(at: manager.stagingDirectory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        var count = 0
        for try await byte in bytes {
            count += 1
            guard count <= maximumSize else { throw URLError(.dataLengthExceedsMaximum) }
            buffer.append(byte)
            if buffer.count == 65_536 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
        try handle.close()
        try Task.checkCancellation()
        guard !manager.isClosed else { throw PluginError.closed }
        return try await manager.stage(file, origin: .file(url))
    }

    static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(PluginSyncDownload.isAllowed) == true ? request : nil)
        }
    }
}
