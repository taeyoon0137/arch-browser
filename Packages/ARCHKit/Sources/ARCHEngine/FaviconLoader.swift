// Downloads site icons for engine adapters and caches them in memory by icon URL. Concurrent requests for the same URL share one download. Failures are not cached. Icons from data URLs are decoded without caching. Clears a full 200-entry cache before caching another icon. Icons load outside every profile's store, without cookies or stored credentials, so the cache holds only what any profile would get.
import AppKit
import Foundation

public enum FaviconLoader {
    private static var cache: [URL: NSImage] = [:]
    private static var pending: [URL: [(NSImage?) -> Void]] = [:]
    /// Sends no cookies or stored credentials, keeps none that a response sets, and writes nothing to disk. An icon request therefore never carries one Persona's sign-in to a site for another Persona's tab, and its response never sets a cookie any page sees. An icon a site shows only to signed-in users does not load.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// Call on the main thread; the cache is not synchronized. Calls `completion` on the main thread with the image or `nil` if downloading or decoding fails. For cached images, `completion` runs synchronously.
    public static func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if let image = cache[url] {
            completion(image)
            return
        }
        if pending[url] != nil {
            pending[url]?.append(completion)
            return
        }
        pending[url] = [completion]
        session.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                if let image, url.scheme != "data" {
                    // A full flush keeps the cache simple; an LRU cache would keep more icons if browsing churns through many.
                    if cache.count >= 200 { cache.removeAll() }
                    cache[url] = image
                }
                pending.removeValue(forKey: url)?.forEach { $0(image) }
            }
        }.resume()
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
