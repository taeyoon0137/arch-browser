// Downloads site icons for engine adapters and caches them in memory by icon URL. Concurrent requests for the same URL share one download. Failures are not cached. Icons from data URLs are decoded without caching. Clears a full 200-entry cache before caching another icon.
import AppKit
import Foundation

public enum FaviconLoader {
    private static var cache: [URL: NSImage] = [:]
    private static var pending: [URL: [(NSImage?) -> Void]] = [:]

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
        URLSession.shared.dataTask(with: url) { data, _, _ in
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
