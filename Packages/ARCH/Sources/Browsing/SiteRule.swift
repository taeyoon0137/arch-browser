// Site rules choose the Persona and space before a covered opening makes its first request.
import AI
import Darwin
import Foundation

public struct SiteRule: Codable, Equatable, Identifiable, Sendable {
    public enum Window: String, Codable, CaseIterable, Sendable {
        case space
        case newWindow
    }

    public var id: UUID
    public var host: String
    public var pathPrefix: String
    public var spaceID: UUID
    public var personaID: UUID
    public var window: Window
    public var modifiedAt: Date

    public init(id: UUID = UUID(), host: String, pathPrefix: String = "", spaceID: UUID, personaID: UUID,
                window: Window = .space, modifiedAt: Date = Date()) {
        self.id = id
        self.host = host
        self.pathPrefix = pathPrefix
        self.spaceID = spaceID
        self.personaID = personaID
        self.window = window
        self.modifiedAt = modifiedAt
    }
}

/// A host and an optional path prefix, without a query, fragment, port, or credentials.
public struct SiteRuleSite: Equatable, Hashable, Sendable {
    public let host: String
    public let pathPrefix: String

    public init(parsing text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = text.contains("://") ? text : "https://\(text)"
        guard let components = URLComponents(string: address), let url = components.url,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              let site = AISitePattern(parsing: address), !site.value.isEmpty,
              !site.value.contains("*"), !site.value.contains(where: \.isWhitespace), url.host != nil else {
            throw SiteRuleStore.Error.invalidSite
        }
        host = site.value
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        pathPrefix = prefix
    }

    /// Validates the separate fields kept on disk and in sync records.
    public init(host: String, pathPrefix: String) throws {
        guard !host.contains(where: { "/?#@".contains($0) }),
              pathPrefix.isEmpty || pathPrefix.hasPrefix("/"),
              !pathPrefix.contains("?"), !pathPrefix.contains("#") else { throw SiteRuleStore.Error.invalidSite }
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        try self.init(parsing: "https://\(authority)\(pathPrefix)")
    }

    func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let candidate = url.host.map(Self.normalizedHost) else { return false }
        let matchesHost = candidate == host || (!Self.isExactHost(host) && candidate.hasSuffix(".\(host)"))
        guard matchesHost else { return false }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return pathPrefix.isEmpty || path == pathPrefix || path.hasPrefix(pathPrefix + "/")
    }

    private static func normalizedHost(_ value: String) -> String {
        var host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func isExactHost(_ host: String) -> Bool {
        if host == "localhost" || host.contains(":") { return true }
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }
}

public enum SiteRuleSet {
    /// The most specific matching host, then path. The UUID breaks ties from concurrent sync edits.
    public static func match(url: URL, rules: [SiteRule]) -> SiteRule? {
        rules.filter { rule in
            (try? SiteRuleSite(host: rule.host, pathPrefix: rule.pathPrefix))?.matches(url) == true
        }.sorted { left, right in
            let leftLabels = left.host.split(separator: ".").count
            let rightLabels = right.host.split(separator: ".").count
            if leftLabels != rightLabels { return leftLabels > rightLabels }
            if left.pathPrefix.count != right.pathPrefix.count { return left.pathPrefix.count > right.pathPrefix.count }
            return left.id.uuidString < right.id.uuidString
        }.first
    }
}
