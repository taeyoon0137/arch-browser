// How page-derived text reaches an agent (docs/agents.md, Tools ▸ Untrusted marking): wrapped as `<untrusted source="page" url="https://host/path">…</untrusted>`, with `</untrusted` inside it escaped as `<\/untrusted` so that a page cannot end its block early, as the AI interface escapes `</page`. Addresses lose their query, fragment, and user name and password, which can carry what a page or the user put there.
import Foundation

/// Marks page-derived text as untrusted before it reaches an agent.
public enum AgentUntrusted {
    static let tag = "untrusted"

    /// Text from a page as an untrusted block, with the page's reduced address when it has one.
    public static func wrap(_ text: String, url: URL?) -> String {
        var attributes = " source=\"page\""
        if let url { attributes += " url=\"\(escapedAttribute(AgentAddress.reduced(url).absoluteString))\"" }
        let escaped = text.replacingOccurrences(of: "</\(tag)", with: "<\\/\(tag)", options: .caseInsensitive)
        return "<\(tag)\(attributes)>\(escaped)</\(tag)>"
    }

    /// Escapes characters that could change the opening tag's address attribute.
    private static func escapedAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// Reduces page addresses and recognizes titles that repeat an address.
public enum AgentAddress {
    /// The address without its query, fragment, user name, and password, as results show it. `ref` lets an agent follow a link whose full address it does not see.
    public static func reduced(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url ?? url
    }

    /// Whether a page name is the page's own address, as an engine titles a page that has none: the address itself, or Chromium's display form, without the scheme and a leading `www.` and with spaces and other characters unescaped. Only an address with a query or fragment matters, since results leave those out. The form is often no valid address, so it is compared as text: by the host, or for a host shown in Unicode, by the query or fragment.
    public static func isOwnAddress(_ name: String, of url: URL) -> Bool {
        if name == url.absoluteString { return true }
        guard url.query != nil || url.fragment != nil, let host = url.host?.lowercased() else { return false }
        var shown = Substring(name.lowercased())
        for scheme in ["https://", "http://"] where shown.hasPrefix(scheme) {
            shown = shown.dropFirst(scheme.count)
            break
        }
        if shown.hasPrefix("www.") { shown = shown.dropFirst(4) }
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if shown.hasPrefix(bareHost) {
            let rest = shown.dropFirst(bareHost.count)
            // The host alone carries nothing results leave out, as a sign-in's message that names it.
            if let next = rest.first, "/:?#".contains(next) { return true }
        }
        let parts = [url.query.map { "?" + $0 }, url.fragment.map { "#" + $0 }].compactMap { $0 }
        return parts.contains { name.contains($0) || ($0.removingPercentEncoding.map(name.contains) ?? false) }
    }
}

extension AgentUntrusted {
    /// A piece of text that `wrap` wrote blocks into.
    public enum Segment: Equatable, Sendable {
        /// Text outside blocks, and a block without an address, tags included.
        case text(String)
        /// A block's text, unescaped, and the address its opening tag names.
        case page(String, url: URL)
    }

    /// The text as the blocks with an address that `wrap` wrote and the text around them, so that a reader such as an API-key session can check each page's site. A block ends at the first closing tag, since `wrap` escapes every one inside it, or at the end of the text when it has none. Nil when the text holds `<untrusted` outside a block in any form `wrap` does not write, so that the caller refuses the text rather than send page text as text of its own.
    public static func segments(in text: String) -> [Segment]? {
        let opening = "<\(tag)"
        let closing = "</\(tag)>"
        var segments: [Segment] = []
        var pending = ""
        var rest = text[...]
        while let start = rest.range(of: opening, options: .caseInsensitive) {
            pending += rest[..<start.lowerBound]
            guard rest[start] == opening, let tagEnd = rest[start.upperBound...].firstIndex(of: ">"),
                  let kind = Opening(rest[start.upperBound..<tagEnd]) else { return nil }
            let contentStart = rest.index(after: tagEnd)
            let end = rest[contentStart...].range(of: closing)
            let blockEnd = end?.upperBound ?? rest.endIndex
            switch kind {
            case .page(let url):
                if !pending.isEmpty { segments.append(.text(pending)) }
                pending = ""
                let content = rest[contentStart..<(end?.lowerBound ?? rest.endIndex)]
                segments.append(.page(content.replacingOccurrences(of: "<\\/\(tag)", with: "</\(tag)"), url: url))
            case .withoutAddress:
                pending += rest[start.lowerBound..<blockEnd]
            }
            rest = rest[blockEnd...]
        }
        pending += rest
        if !pending.isEmpty { segments.append(.text(pending)) }
        return segments
    }

    /// An opening tag's attributes as `wrap` writes them.
    private enum Opening {
        case withoutAddress
        case page(URL)

        init?(_ attributes: Substring) {
            let source = " source=\"page\""
            guard attributes.hasPrefix(source) else { return nil }
            let rest = attributes.dropFirst(source.count)
            if rest.isEmpty {
                self = .withoutAddress
                return
            }
            let prefix = " url=\""
            guard rest.count > prefix.count, rest.hasPrefix(prefix), rest.hasSuffix("\"") else { return nil }
            let value = rest.dropFirst(prefix.count).dropLast()
            let unescaped = value.replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard !value.contains("\""), let url = URL(string: unescaped) else { return nil }
            self = .page(url)
        }
    }
}
