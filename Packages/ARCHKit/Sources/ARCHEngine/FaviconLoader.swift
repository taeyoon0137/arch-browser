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
                    if cache.count >= 200 { cache.removeAll() } // ponytail: full flush, LRU if icon churn matters
                    cache[url] = image
                }
                pending.removeValue(forKey: url)?.forEach { $0(image) }
            }
        }.resume()
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
