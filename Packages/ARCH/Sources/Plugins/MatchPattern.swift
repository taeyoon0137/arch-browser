// Match patterns: the web addresses a plugin's sites cover. A pattern names http and https addresses only, so no pattern reaches local files or internal pages.
import Foundation

/// A set of web addresses, written `scheme://host/path` or `<all_urls>`.
///
/// - The scheme is `http`, `https`, or `*` for both.
/// - The host is `*` for every host, a name such as `example.com` for that host only, or `*.` and a name for that host and its subdomains. A name is dot-separated labels of ASCII letters, digits, and `-`; an internationalized name is written in its `xn--` form. A pattern has no port and covers every port of its host.
/// - The path starts with `/`, and each `*` in it matches any run of characters. It is compared with the address's percent-encoded path and query, so `/search*` covers `/search?q=arch`. The fragment does not count.
/// - `<all_urls>` is `*://*/*`.
///
/// Schemes and hosts ignore case; paths do not.
public struct MatchPattern: Hashable, Sendable, CustomStringConvertible {
    /// `http` or `https`; nil for both.
    private let scheme: String?
    /// nil for every host.
    private let host: String?
    /// Whether the pattern also covers the subdomains of `host`.
    private let includesSubdomains: Bool
    private let path: String

    /// Throws `PluginError.invalidMatchPattern` for text that breaks the rules above.
    public init(_ pattern: String) throws {
        let text = pattern == "<all_urls>" ? "*://*/*" : pattern
        guard let separator = text.range(of: "://") else { throw PluginError.invalidMatchPattern(pattern) }
        let scheme = text[..<separator.lowerBound].lowercased()
        let rest = text[separator.upperBound...]
        let pathStart = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = rest[..<pathStart].lowercased()
        let includesSubdomains = host.hasPrefix("*.")
        let name = includesSubdomains ? String(host.dropFirst(2)) : host
        guard ["*", "http", "https"].contains(scheme), host == "*" || name.isDomainName, pathStart < rest.endIndex else {
            throw PluginError.invalidMatchPattern(pattern)
        }
        self.scheme = scheme == "*" ? nil : scheme
        self.host = host == "*" ? nil : name
        self.includesSubdomains = includesSubdomains
        path = String(rest[pathStart...])
    }

    /// Keep it in step with `javaScriptMatcher`.
    public func matches(_ url: URL) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(), urlScheme == "http" || urlScheme == "https", scheme == nil || scheme == urlScheme,
              let urlHost = url.host()?.lowercased(), !urlHost.isEmpty else { return false }
        if let host, urlHost != host, !(includesSubdomains && urlHost.hasSuffix("." + host)) { return false }
        let urlPath = url.path()
        let target = (urlPath.isEmpty ? "/" : urlPath) + (url.query().map { "?" + $0 } ?? "")
        return Self.glob(Array(path.utf8), matches: Array(target.utf8))
    }

    /// The pattern in its written form, with the scheme and host in lowercase.
    public var description: String {
        "\(scheme ?? "*")://\(host.map { (includesSubdomains ? "*." : "") + $0 } ?? "*")\(path)"
    }

    /// The sites the pattern covers in words, such as `example.com`, `example.com and its subdomains`, `every .com website`, or `every website`, without its scheme and path.
    public var siteName: String {
        guard let host else { return localized("every website") }
        if coversTopLevelDomain { return localized("every .\(host) website") }
        return includesSubdomains ? localized("\(host) and its subdomains") : host
    }

    /// What a grant of the pattern lets a plugin do, as the sentence that Settings and the install sheet show.
    public var accessSummary: String {
        Self.accessSummary(ofSites: siteName)
    }

    private static func accessSummary(ofSites name: String) -> String {
        localized("Run scripts on pages from \(name)")
    }

    /// One sentence for all of `patterns` in place of each one's `accessSummary`, as Settings states a long list of sites (`InstalledPlugin.accessBrief`), which names the sites by the broadest: every website when one covers every host; the site's name when all name one site, such as `example.com and its subdomains`; with one that covers a top-level domain, that domain and the number of the other sites, such as "Run scripts on pages from every .com website and 3 more"; else the number of sites, such as "Run scripts on pages from 14 websites". A site that another pattern covers with its subdomains, as `*.example.com` covers `example.com` and `www.example.com`, counts as that pattern's. Nil without patterns.
    static func briefAccessSummary(of patterns: [MatchPattern]) -> String? {
        var names: [String] = []
        for pattern in patterns where !patterns.contains(where: { $0.takesIn(pattern) }) && !names.contains(pattern.siteName) {
            names.append(pattern.siteName)
        }
        guard names.count > 1 else { return names.first.map(Self.accessSummary(ofSites:)) }
        return Self.accessSummary(ofSites: patterns.first(where: \.coversTopLevelDomain).map { localized("\($0.siteName) and \(names.count - 1) more") } ?? localized("\(names.count) websites"))
    }

    /// Whether the pattern's sites take in those of `other` under another name: every host takes in each name, and a host with its subdomains takes in the host alone and each name under it, as `*.example.com` takes in `example.com`, `www.example.com`, and `*.www.example.com`. Schemes and paths do not count, as `siteName` leaves them out.
    private func takesIn(_ other: MatchPattern) -> Bool {
        guard let otherHost = other.host else { return false }
        guard let host else { return true }
        guard includesSubdomains else { return false }
        return otherHost == host ? !other.includesSubdomains : otherHost.hasSuffix("." + host)
    }

    /// Whether the pattern covers every host, or every host under a top-level domain, as `*://*.com/*` does, which granting asks the user to confirm with Touch ID or the login password. A few such patterns would otherwise reach most of the web without the confirmation.
    public var coversEverySite: Bool {
        host == nil || coversTopLevelDomain
    }

    /// Whether the pattern names a top-level domain, a name of one label, and its subdomains.
    private var coversTopLevelDomain: Bool {
        includesSubdomains && host?.contains(".") == false
    }

    /// Whether `pattern`, in which each `*` matches any run of bytes, matches all of `text`. After a mismatch it lets the last `*` take one more byte and tries again. Keep it in step with `glob` in `javaScriptMatcher`.
    private static func glob(_ pattern: [UInt8], matches text: [UInt8]) -> Bool {
        let star = UInt8(ascii: "*")
        var p = 0
        var t = 0
        // The pattern position after the last `*`, and the text position that `*` stopped at.
        var retry: (pattern: Int, text: Int)?
        while t < text.count {
            if p < pattern.count, pattern[p] == star {
                p += 1
                retry = (p, t)
            } else if p < pattern.count, pattern[p] == text[t] {
                p += 1
                t += 1
            } else if let last = retry {
                p = last.pattern
                t = last.text + 1
                retry = (p, t)
            } else {
                return false
            }
        }
        return pattern[p...].allSatisfy { $0 == star }
    }
}

/// A pattern encodes as its written form, as `plugins.json` keeps the grants of installed plugins.
extension MatchPattern: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Match patterns for page scripts, which check a document's address in the page.
extension MatchPattern {
    /// A JavaScript function, `(location, patterns) => boolean`, that tells whether one of the patterns `javaScriptLiteral(_:)` writes covers the address of `location`, by the rules of `matches(_:)`. It reads the parts of the address from `location`, whose properties a page cannot replace; the URL parser writes the scheme and host in lowercase. It calls no built-in function and reads only own properties, so its answer holds in a page's main world after the page's scripts have replaced built-ins. Keep it in step with `matches(_:)` and `glob(_:matches:)`.
    static let javaScriptMatcher = #"""
    (location, patterns) => {
      const protocol = location.protocol, host = location.hostname, href = location.href;
      if ((protocol !== "http:" && protocol !== "https:") || !host) return false;
      const scheme = protocol === "http:" ? "http" : "https";
      // The path, then the query: the address's text from its first "?" to its "#" or its end.
      let target = location.pathname, inQuery = false;
      for (let i = 0; i < href.length && href[i] !== "#"; i++) {
        if (href[i] === "?") inQuery = true;
        if (inQuery) target += href[i];
      }
      const endsWith = (text, suffix) => {
        const offset = text.length - suffix.length;
        if (offset < 0) return false;
        for (let i = 0; i < suffix.length; i++) {
          if (text[offset + i] !== suffix[i]) return false;
        }
        return true;
      };
      const glob = (pattern, text) => {
        let p = 0, t = 0, retryPattern = -1, retryText = 0;
        while (t < text.length) {
          if (p < pattern.length && pattern[p] === "*") {
            p += 1;
            retryPattern = p;
            retryText = t;
          } else if (p < pattern.length && pattern[p] === text[t]) {
            p += 1;
            t += 1;
          } else if (retryPattern >= 0) {
            p = retryPattern;
            retryText += 1;
            t = retryText;
          } else {
            return false;
          }
        }
        while (p < pattern.length && pattern[p] === "*") p += 1;
        return p === pattern.length;
      };
      for (let i = 0; i < patterns.length; i++) {
        const pattern = patterns[i];
        if ((!pattern.scheme || pattern.scheme === scheme)
          && (!pattern.host || host === pattern.host || (pattern.subdomains && endsWith(host, "." + pattern.host)))
          && glob(pattern.path, target)) return true;
      }
      return false;
    }
    """#

    /// The patterns as a JavaScript array for `javaScriptMatcher`. A pattern for every scheme or host has an empty string for that part, so every part is an own property of the pattern's object.
    static func javaScriptLiteral(_ patterns: [MatchPattern]) -> String {
        /// A pattern's parts as the JavaScript matcher reads them.
        struct Parts: Encodable {
            let scheme: String
            let host: String
            let subdomains: Bool
            let path: String
        }
        let parts = patterns.map { Parts(scheme: $0.scheme ?? "", host: $0.host ?? "", subdomains: $0.includesSubdomains, path: $0.path) }
        // JSON is JavaScript, and strings and booleans always encode.
        return String(decoding: try! JSONEncoder().encode(parts), as: UTF8.self)
    }
}
