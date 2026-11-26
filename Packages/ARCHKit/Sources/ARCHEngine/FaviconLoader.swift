// Downloads site icons for engine adapters and caches them in memory by icon URL. Concurrent requests for the same URL share one download. Failures are not cached. Icons from data URLs are decoded without caching. Clears a full 200-entry cache before caching another icon. Icons load outside every profile's store, without cookies or stored credentials, so the cache holds only what any profile would get. A page names its icon's URL, so only web and data URLs load, and a download ends after 30 seconds or once it passes `maximumSize`: a page can make the app neither read a local file nor buffer an endless response. Other images that a page names, such as Now Playing's artwork, download the same way with a limit of their own.
import AppKit
import Foundation

/// Loads and caches site icons for both engines' tabs, unloaded tabs, and favorites, and downloads Now Playing artwork, without cookies or credentials.
public enum FaviconLoader {
    private static var cache: [URL: NSImage] = [:]
    private static var pending: [URL: [(NSImage?) -> Void]] = [:]
    private static var pageCache: [URL: NSImage] = [:]
    private static var pendingPages: [URL: [(NSImage?) -> Void]] = [:]
    /// The schemes an icon loads from. An icon URL with any other, such as `file`, loads nothing.
    static let schemes: Set<String> = ["http", "https", "data"]
    /// The most bytes an icon's body may have after decompression. A longer body loads nothing, and its download stops as it passes this size.
    public static let maximumSize = 1 << 20
    /// Sends no cookies or stored credentials, keeps none that a response sets, and writes nothing to disk. An icon request therefore never carries one Persona's sign-in to a site for another Persona's tab, and its response never sets a cookie any page sees. An icon a site shows only to signed-in users does not load. A download that has not finished after 30 seconds fails, so a response that trickles in forever never holds the icon's later requests.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: FaviconRequestDelegate(), delegateQueue: nil)
    }()

    /// Call on the main thread; the cache is not synchronized. Calls `completion` on the main thread with the image or `nil` if downloading or decoding fails. For cached images and URLs of a scheme outside `schemes`, `completion` runs synchronously.
    public static func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        let url = withoutCredentials(url)
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
            let image = await download(url).flatMap(decode)
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

    /// Finds a page's icon without loading its engine. Engine declarations are tried first; otherwise a bounded HTML prefix supplies icon and manifest links, followed by touch icons and `/favicon.ico`. Call on the main thread, as for `load`.
    public static func loadPageIcon(for pageURL: URL, iconURLs: [URL] = [], headHTML: String? = nil, completion: @escaping (NSImage?) -> Void) {
        let pageURL = withoutCredentials(pageURL)
        if !iconURLs.isEmpty {
            loadFirst(Array(FaviconDeclarations.unique(iconURLs).prefix(16))) { image in
                if let image {
                    remember(image, for: pageURL)
                    completion(image)
                } else {
                    loadPageIcon(for: pageURL, headHTML: headHTML, completion: completion)
                }
            }
            return
        }
        if let headHTML {
            loadDeclarations(FaviconDeclarations(html: headHTML, pageURL: pageURL), pageURL: pageURL) { image in
                if let image { remember(image, for: pageURL) }
                completion(image)
            }
            return
        }
        // Non-web pages may declare a web or data icon, but discovery must never read their page from disk.
        guard defaultIconURL(for: pageURL) != nil else { completion(nil); return }
        if let image = pageCache[pageURL] { completion(image); return }
        if pendingPages[pageURL] != nil {
            pendingPages[pageURL]?.append(completion)
            return
        }
        pendingPages[pageURL] = [completion]
        Task {
            // A large page can have a small head, so keep its prefix instead of rejecting its Content-Length.
            let response = await downloadResponse(pageURL, limit: maximumSize, allowPrefix: true)
            DispatchQueue.main.async {
                let finalURL = response?.1.url ?? pageURL
                let html = response.map { String(decoding: $0.0, as: UTF8.self) } ?? ""
                loadDeclarations(FaviconDeclarations(html: html, pageURL: finalURL), pageURL: finalURL) { image in
                    if let image { remember(image, for: pageURL) }
                    pendingPages.removeValue(forKey: pageURL)?.forEach { $0(image) }
                }
            }
        }
    }

    private static func remember(_ image: NSImage, for pageURL: URL) {
        if pageCache.count >= 200 { pageCache.removeAll() }
        pageCache[pageURL] = image
    }

    private static func loadDeclarations(_ declarations: FaviconDeclarations, pageURL: URL, completion: @escaping (NSImage?) -> Void) {
        loadFirst(declarations.icons) { image in
            if let image { completion(image); return }
            loadManifests(declarations.manifests) { image in
                if let image { completion(image); return }
                loadFirst(declarations.touchIcons + [defaultIconURL(for: pageURL)].compactMap { $0 }, completion: completion)
            }
        }
    }

    private static func loadManifests(_ urls: [URL], completion: @escaping (NSImage?) -> Void) {
        guard let url = urls.first else { completion(nil); return }
        Task {
            let response = await downloadResponse(url, limit: maximumSize)
            let icons = response.map { FaviconDeclarations.manifestIcons(in: $0.0, manifestURL: $0.1.url ?? url) } ?? []
            DispatchQueue.main.async {
                loadFirst(icons) { image in
                    if let image { completion(image) }
                    else { loadManifests(Array(urls.dropFirst()), completion: completion) }
                }
            }
        }
    }

    static func loadFirst(_ urls: [URL], completion: @escaping (NSImage?) -> Void) {
        guard let url = urls.first else { completion(nil); return }
        load(url) { image in
            if let image { completion(image) }
            else { loadFirst(Array(urls.dropFirst()), completion: completion) }
        }
    }

    /// AppKit decodes SVG as well as bitmap icons. A failed representation must not prevent the next declaration from loading.
    static func decode(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.isValid else { return nil }
        return image
    }

    /// The body at `url` through `session`, or nil when the request fails or the body passes `limit` bytes. The body arrives as it streams, so a long one stops at the limit, also one whose length the response does not state. The caller checks the scheme, as `load` does.
    public static func download(_ url: URL, limit: Int = maximumSize) async -> Data? {
        await downloadResponse(url, limit: limit)?.0
    }

    static func downloadResponse(_ url: URL, limit: Int, allowPrefix: Bool = false, using session: URLSession = session) async -> (Data, URLResponse)? {
        guard let (bytes, response) = try? await session.bytes(from: withoutCredentials(url)) else { return nil }
        defer { bytes.task.cancel() }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Even an unavailable page can redirect to a site whose root icon works.
            return allowPrefix ? (Data(), response) : nil
        }
        guard allowPrefix || response.expectedContentLength <= limit else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else { return allowPrefix ? (data, response) : nil }
                data.append(byte)
            }
        } catch {
            return nil
        }
        return (data, response)
    }

    /// URL user information is a credential too, even with credential storage disabled.
    static func withoutCredentials(_ url: URL) -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.user = nil
        components.password = nil
        return components.url ?? url
    }

    /// Whether a tab keeps its icon when its page changes from `oldURL` to `newURL`: the pages of one host share an icon until the new page reports its own, and a same-document navigation, such as `history.pushState` or a fragment, never leaves the host. A page without a host, such as `about:blank` or a file, keeps none.
    public static func keepsIcon(from oldURL: URL?, to newURL: URL?) -> Bool {
        guard let oldHost = oldURL?.host, let newHost = newURL?.host else { return false }
        return oldHost.caseInsensitiveCompare(newHost) == .orderedSame
    }

    /// The usual icon URL for a page that declares no icon.
    public static func defaultIconURL(for pageURL: URL) -> URL? {
        guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? ""), pageURL.host != nil,
              var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}

/// Redirects keep the same cookie-free, credential-free web requests as the initial load.
private final class FaviconRequestDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { completionHandler(nil); return }
        var redirected = request
        redirected.url = FaviconLoader.withoutCredentials(url)
        for header in ["Cookie", "Authorization", "Proxy-Authorization"] { redirected.setValue(nil, forHTTPHeaderField: header) }
        completionHandler(redirected)
    }
}
