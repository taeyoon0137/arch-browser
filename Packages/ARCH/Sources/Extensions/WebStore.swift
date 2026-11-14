// The Web Store's addresses, which no other file names (`docs/web-store.md`): Google's public update endpoint, which Arch asks for an extension's current package, and the hosts of the store's extension pages, whose addresses name the extension to install, as does a pasted identifier.
import Foundation

public enum WebStore {
    /// The update endpoint, which Chromium's extension updater asks about extensions by identifier (`docs/web-store.md`, Facts).
    static let updateEndpoint = URL(string: "https://clients2.google.com/service/update2/crx")!
    /// The hosts of store pages, the current one first, from which the tests build their addresses. Both host names name another browser product, which `AGENTS.md` allows here only once the user's step IV.27 adds the exception, so until then the list is empty and no address is a store page.
    static let pageHosts: [String] = []
    /// The path to an extension's page on each of `pageHosts`, in the same order, before the optional slug and the identifier: `/detail/` on the current host, and `/webstore/detail/` on the older one, which redirects there.
    static let pagePaths: [[String]] = [["detail"], ["webstore", "detail"]]

    /// The identifier of the extension whose store page `url` is, or nil for any other address.
    public static func extensionID(in url: URL) -> String? {
        extensionID(in: url, pageHosts: pageHosts)
    }

    /// The identifier that typed or pasted text names: a store page's address, with or without `https://`, or a bare identifier, without case and spaces at either end.
    public static func extensionID(from text: String) -> String? {
        extensionID(from: text, pageHosts: pageHosts)
    }

    /// `extensionID(in:)` with the store's page hosts in `pageHosts`, which the tests choose until the store's own are written. A page is `https://<host>/<page path>/<slug>/<identifier>`, where the slug is optional and a query or fragment may follow; the store's other pages, such as categories and search, hold no identifier.
    static func extensionID(in url: URL, pageHosts: [String]) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              let index = pageHosts.firstIndex(where: { $0.lowercased() == host }), index < pagePaths.count else { return nil }
        let path = pagePaths[index]
        let components = url.pathComponents.filter { $0 != "/" }
        guard (path.count + 1...path.count + 2).contains(components.count),
              zip(components, path).allSatisfy({ $0.lowercased() == $1 }), let last = components.last else { return nil }
        return identifier(last)
    }

    /// `extensionID(from:)` with the store's page hosts in `pageHosts`.
    static func extensionID(from text: String, pageHosts: [String]) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = identifier(text) { return id }
        guard let url = URL(string: text.contains("://") ? text : "https://" + text) else { return nil }
        return extensionID(in: url, pageHosts: pageHosts)
    }

    /// `text` in lowercase when it is an extension identifier: 32 letters from `a` to `p` in any case (`docs/plugins.md`, Identifier); otherwise nil.
    static func identifier(_ text: some StringProtocol) -> String? {
        let id = text.lowercased()
        guard id.utf8.count == 32, id.utf8.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "p")).contains($0) }) else { return nil }
        return id
    }
}
