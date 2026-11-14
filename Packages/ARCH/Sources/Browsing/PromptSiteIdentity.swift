// Who a tab's prompt comes from, as its identity row shows it: the site from the address that asks, with the tab's icon when it is the tab's own site, and where it is when it is not.
import AppKit

enum PromptSiteIdentity {
    static func make(for url: URL?, in tab: Tab) -> PromptIdentity {
        make(for: url, tabURL: tab.url, favicon: tab.favicon)
    }

    /// The asker at `url` in a tab at `tabURL`: its host with the tab's icon when it is the tab's host, or with a globe and "in <the tab's host>" when it is another, as for a frame from another site. An address without a host, such as a file's, is "This page". An https address gets the lock.
    static func make(for url: URL?, tabURL: URL?, favicon: NSImage?) -> PromptIdentity {
        guard let url, let host = url.host, !host.isEmpty else {
            return PromptIdentity(icon: .symbol("doc"), name: "This page", isSecure: false)
        }
        let isSecure = url.scheme?.lowercased() == "https"
        let tabHost = tabURL?.host
        guard let tabHost, !tabHost.isEmpty, tabHost.lowercased() != host.lowercased() else {
            return PromptIdentity(icon: favicon.map(PromptIcon.image) ?? .symbol("globe"), name: host, isSecure: isSecure)
        }
        return PromptIdentity(icon: .symbol("globe"), name: host, isSecure: isSecure, context: "in \(tabHost)")
    }

    /// The host of the frame that shows a page's `alert`, `confirm`, or `prompt`, when the frame is on another host than the tab's page, as an embedded page of another site is, and nil for the page's own frame or a frame whose origin the engine does not name, as for an opaque origin. The card names that host above the frame's words.
    static func embeddedHost(of frameOrigin: URL?, tabURL: URL?) -> String? {
        guard let host = frameOrigin?.host, !host.isEmpty else { return nil }
        guard let tabHost = tabURL?.host, !tabHost.isEmpty, tabHost.lowercased() == host.lowercased() else { return host }
        return nil
    }

    /// The server that asks for a login: a proxy with its own symbol and tag, or the site as `make` names it. The lock shows only for a site reached over https; a method that keeps the password from the wire, such as Digest, encrypts nothing else, and the protection space does not say whether the connection to a proxy is encrypted.
    static func signIn(_ space: URLProtectionSpace, tabURL: URL?, favicon: NSImage?) -> PromptIdentity {
        if space.isProxy() {
            return PromptIdentity(icon: .symbol("network"), name: space.host, isSecure: false, tag: "Proxy")
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
