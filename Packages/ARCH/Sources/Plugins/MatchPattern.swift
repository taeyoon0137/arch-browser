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

/// Match patterns for page scripts, which check a document's address in the page.
extension MatchPattern {
    /// A JavaScript function, `(location, patterns) => boolean`, that tells whether one of the patterns `javaScriptLiteral(_:)` writes covers the address of `location`, by the rules of `matches(_:)`. It reads the parts of the address from `location`, whose properties a page cannot replace; the URL parser writes the scheme and host in lowercase. Keep it in step with `matches(_:)` and `glob(_:matches:)`.
    static let javaScriptMatcher = #"""
    (location, patterns) => {
      const scheme = location.protocol.slice(0, -1), host = location.hostname;
      if ((scheme !== "http" && scheme !== "https") || !host) return false;
      const href = location.href, hash = href.indexOf("#"), end = hash < 0 ? href.length : hash, query = href.indexOf("?");
      const target = location.pathname + (query >= 0 && query < end ? href.slice(query, end) : "");
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
        while (pattern[p] === "*") p += 1;
        return p === pattern.length;
      };
      return patterns.some((pattern) => (!pattern.scheme || pattern.scheme === scheme)
        && (!pattern.host || host === pattern.host || (pattern.subdomains && host.endsWith("." + pattern.host)))
        && glob(pattern.path, target));
    }
    """#

    /// The patterns as a JavaScript array for `javaScriptMatcher`. A pattern for every scheme or host leaves that part out.
    static func javaScriptLiteral(_ patterns: [MatchPattern]) -> String {
        struct Parts: Encodable {
            let scheme: String?
            let host: String?
            let subdomains: Bool
            let path: String
        }
        let parts = patterns.map { Parts(scheme: $0.scheme, host: $0.host, subdomains: $0.includesSubdomains, path: $0.path) }
        // JSON is JavaScript, and strings and booleans always encode.
        return String(decoding: try! JSONEncoder().encode(parts), as: UTF8.self)
    }
}
