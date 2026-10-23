// Downloads site icons for the engine adapters and caches them in memory by icon URL. Concurrent requests for the same URL share one download. Failures are not cached.
import AppKit
import Foundation

public enum FaviconLoader {
    private static var cache: [URL: NSImage] = [:]
    private static var pending: [URL: [(NSImage?) -> Void]] = [:]

    /// Call on the main thread because the cache is not synchronized. Calls `completion` on the main thread with the image or `nil` if downloading or decoding fails. For cached images, `completion` runs synchronously.
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
                if let image { cache[url] = image }
                pending.removeValue(forKey: url)?.forEach { $0(image) }
            }
        }.resume()
    }

    /// The conventional icon URL for a page whose document declares no icon.
    public static func defaultIconURL(for pageURL: URL) -> URL? {
        guard let scheme = pageURL.scheme, let host = pageURL.host, scheme.hasPrefix("http") else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }
}
