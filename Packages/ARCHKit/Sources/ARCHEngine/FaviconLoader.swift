// Downloads site icons for engine adapters and caches them in memory by icon URL. Concurrent requests for the same URL share one download. Failures are not cached. Icons from data URLs are decoded without caching. Clears a full 200-entry cache before caching another icon. Icons load outside every profile's store, without cookies or stored credentials, so the cache holds only what any profile would get. A page names its icon's URL, so only web and data URLs load, and a download ends after 30 seconds or once it passes `maximumSize`: a page can make the app neither read a local file nor buffer an endless response.
import AppKit
import Foundation

public enum FaviconLoader {
    private static var cache: [URL: NSImage] = [:]
    private static var pending: [URL: [(NSImage?) -> Void]] = [:]
    /// The schemes an icon loads from. An icon URL with any other, such as `file`, loads nothing.
    static let schemes: Set<String> = ["http", "https", "data"]
    /// The most bytes an icon's body may have after decompression. A longer body loads nothing, and its download stops as it passes this size.
    static let maximumSize = 1 << 20
    /// Sends no cookies or stored credentials, keeps none that a response sets, and writes nothing to disk. An icon request therefore never carries one Persona's sign-in to a site for another Persona's tab, and its response never sets a cookie any page sees. An icon a site shows only to signed-in users does not load. A download that has not finished after 30 seconds fails, so a response that trickles in forever never holds the icon's later requests.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    /// Call on the main thread; the cache is not synchronized. Calls `completion` on the main thread with the image or `nil` if downloading or decoding fails. For cached images and URLs of a scheme outside `schemes`, `completion` runs synchronously.
    public static func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else {
            completion(nil)
            return
        }
        if let image = cache[url] {
            completion(image)
            return
        }
        if pending[url] != nil {
            pending[url]?.append(completion)
            return
        }
        pending[url] = [completion]
        Task {
            let image = await download(url).flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                if let image, url.scheme != "data" {
                    // A full flush keeps the cache simple; an LRU cache would keep more icons if browsing churns through many.
                    if cache.count >= 200 { cache.removeAll() }
                    cache[url] = image
                }
                pending.removeValue(forKey: url)?.forEach { $0(image) }
            }
        }
    }

    /// The body at `url`, or nil when the request fails or the body passes `maximumSize`. The body arrives as it streams, so a long one stops at the limit, also one whose length the response does not state.
    static func download(_ url: URL) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= maximumSize else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < maximumSize else { return nil }
                data.append(byte)
            }
        } catch {
            return nil
        }
        return data
    }

    /// Whether a tab keeps its icon when its page changes from `oldURL` to `newURL`: the pages of one host share an icon until the new page reports its own, and a same-document navigation, such as `history.pushState` or a fragment, never leaves the host. A page without a host, such as `about:blank` or a file, keeps none.
    public static func keepsIcon(from oldURL: URL?, to newURL: URL?) -> Bool {
        guard let oldHost = oldURL?.host, let newHost = newURL?.host else { return false }
        return oldHost.caseInsensitiveCompare(newHost) == .orderedSame
    }

    /// The usual icon URL for a page that declares no icon.
    public static func defaultIconURL(for pageURL: URL) -> URL? {
        guard pageURL.scheme?.hasPrefix("http") == true, pageURL.host != nil,
              var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}
