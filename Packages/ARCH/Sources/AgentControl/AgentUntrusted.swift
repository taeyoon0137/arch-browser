// How page-derived text reaches an agent (docs/agents.md, Tools ▸ Untrusted marking): wrapped as `<untrusted source="page" url="https://host/path">…</untrusted>`, with `</untrusted` inside it escaped as `<\/untrusted` so that a page cannot end its block early, as the AI interface escapes `</page`. Addresses lose their query, fragment, and user name and password, which can carry what a page or the user put there.
import Foundation

public enum AgentUntrusted {
    static let tag = "untrusted"

    /// Text from a page as an untrusted block, with the page's reduced address when it has one.
    public static func wrap(_ text: String, url: URL?) -> String {
        var attributes = " source=\"page\""
        if let url { attributes += " url=\"\(escapedAttribute(AgentAddress.reduced(url).absoluteString))\"" }
        let escaped = text.replacingOccurrences(of: "</\(tag)", with: "<\\/\(tag)", options: .caseInsensitive)
        return "<\(tag)\(attributes)>\(escaped)</\(tag)>"
    }

    private static func escapedAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

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
}
