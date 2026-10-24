// Decides which cookies, origins, and tabs belong to the site that Clear Site Data clears.
import ARCHEngine
import Foundation

/// A web page's host with its subdomains, as Clear Site Data clears it.
struct SiteDataScope {
    /// The page's host, lowercased.
    let host: String

    /// `nil` for a page that is not on the web, such as a file or a blank page.
    init?(url: URL?) {
        guard let url, url.scheme == "http" || url.scheme == "https", let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.host = host
    }

    /// The host as the address pill shows it, without `www.`.
    var displayName: String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

    /// The host's own origins, which are cleared even when no open tab shows them.
    var origins: [URL] { ["https", "http"].compactMap { URL(string: "\($0)://\(host)") } }

    /// Whether `other` is the host or one of its subdomains.
    func contains(host other: String) -> Bool {
        let other = other.lowercased()
        return other == host || other.hasSuffix("." + host)
    }

    /// The cookies of the host and its subdomains, and the domain cookies of its parent domains, which the host also receives. Both engines mark a domain cookie with a leading dot.
    func contains(_ cookie: EngineCookie) -> Bool {
        let isDomainCookie = cookie.domain.hasPrefix(".")
        let domain = (isDomainCookie ? String(cookie.domain.dropFirst()) : cookie.domain).lowercased()
        return contains(host: domain) || (isDomainCookie && host.hasSuffix("." + domain))
    }

    /// The origin of a page: its scheme, host, and port.
    static func origin(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
