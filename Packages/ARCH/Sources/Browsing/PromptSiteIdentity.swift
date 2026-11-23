// Who a tab's prompt comes from, as its identity row shows it: the site from the address that asks, with the tab's icon when it is the tab's own site, and where it is when it is not; a web extension's page by the extension.
import AppKit

/// Builds the `PromptIdentity` of a tab's prompt from the address that asks, as the file header describes.
enum PromptSiteIdentity {
    @MainActor static func make(for url: URL?, in tab: Tab) -> PromptIdentity {
        make(for: url, tabURL: tab.url, favicon: tab.favicon) { tab.extensionName?($0) }
    }

    /// The asker at `url` in a tab at `tabURL`: its host with the tab's icon when it is the tab's host, or with a globe and "in <the tab's host>" when it is another, as for a frame from another site. A file's page is its file name, as the address pill shows it, and another address without a host, such as `about:blank` or a `data:` address, is "This page". An https address gets the lock. An address of a web extension's page that `extensionName` names, whose host is the extension's identifier, is the extension's name with the extension symbol and the Extension tag, as the address pill marks it, so that an extension cannot pass its page off as a website by the name it gives itself; such a tab is "in" the extension's name.
    static func make(for url: URL?, tabURL: URL?, favicon: NSImage?, extensionName: (URL) -> String? = { _ in nil }) -> PromptIdentity {
        guard let url, let host = url.host, !host.isEmpty else {
            // A file origin, `file://` from WebKit or `file:///` from Chromium for a file page's permission request, names no file, so the tab's file names it.
            if let url, url.isFileURL, let file = ([url] + (tabURL.map { [$0] } ?? [])).first(where: { $0.isFileURL && !$0.path.isEmpty && $0.path != "/" }) {
                return PromptIdentity(icon: .symbol("doc"), name: file.lastPathComponent, isSecure: false)
            }
            return PromptIdentity(icon: .symbol("doc"), name: localized("This page"), isSecure: false)
        }
        let isSecure = url.scheme?.lowercased() == "https"
        let tabHost = tabURL?.host.flatMap { $0.isEmpty ? nil : $0 }
        let context = tabHost.flatMap { $0.lowercased() == host.lowercased() ? nil : localized("in \(tabURL.flatMap(extensionName) ?? $0)") }
        if let name = extensionName(url) {
            return PromptIdentity(icon: .symbol("puzzlepiece.extension"), name: name, isSecure: false, tag: localized("Extension"), context: context)
        }
        guard let context else {
            return PromptIdentity(icon: favicon.map(PromptIcon.image) ?? .symbol("globe"), name: host, isSecure: isSecure)
        }
        return PromptIdentity(icon: .symbol("globe"), name: host, isSecure: isSecure, context: context)
    }

    /// A frame inside the page that shows a page's `alert`, `confirm`, or `prompt`.
    enum EmbeddedFrame: Equatable {
        /// A frame on another host than the page's, as an embedded page of another site is.
        case host(String)
        /// A frame whose origin the engine does not name on a page that has a host: one with an opaque origin, or on Chromium, which names a frame by its address, an `about:blank`, `about:srcdoc`, `data:`, or `blob:` frame, which any frame of the page can add and script.
        case unnamed
    }

    /// The frame that shows a page dialog when it is not the page's own, which the card names above the frame's words, or nil for the page's own frame. On a page without a host, such as a file's, a frame whose origin the engine does not name counts as the page's.
    static func embeddedFrame(of frameOrigin: URL?, pageURL: URL?) -> EmbeddedFrame? {
        let pageHost = pageURL?.host.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        guard let host = frameOrigin?.host, !host.isEmpty else { return pageHost == nil ? nil : .unnamed }
        return host.lowercased() == pageHost ? nil : .host(host)
    }

    /// The server that asks for a login: a proxy with its own symbol and tag, or the site as `make` names it. The lock shows only for a site reached over https; a method that keeps the password from the wire, such as Digest, encrypts nothing else, and the protection space does not say whether the connection to a proxy is encrypted.
    static func signIn(_ space: URLProtectionSpace, tabURL: URL?, favicon: NSImage?) -> PromptIdentity {
        if space.isProxy() {
            return PromptIdentity(icon: .symbol("network"), name: space.host, isSecure: false, tag: localized("Proxy"))
        }
        var components = URLComponents()
        components.scheme = space.protocol ?? "https"
        components.host = space.host
        var identity = make(for: components.url, tabURL: tabURL, favicon: favicon)
        identity.name = space.host
        identity.isSecure = space.protocol?.lowercased() == "https"
        return identity
    }
}
