import Foundation

/// Hosts whose links from other apps skip small windows. This preference stays on this Mac.
struct RegularWindowSites {
    static let defaultsKey = "ARCHRegularWindowSites"
    private(set) var hosts: [String]

    init(defaults: UserDefaults = .standard) {
        hosts = []
        for text in defaults.stringArray(forKey: Self.defaultsKey) ?? [] { _ = add(text) }
    }

    @discardableResult
    mutating func add(_ text: String) -> Bool {
        guard let host = Self.host(parsing: text), !hosts.contains(host) else { return false }
        hosts.append(host)
        return true
    }

    mutating func remove(_ host: String) { hosts.removeAll { $0 == host } }

    func save(in defaults: UserDefaults = .standard) { defaults.set(hosts, forKey: Self.defaultsKey) }

    func contains(_ url: URL) -> Bool {
        guard let host = Self.host(from: url) else { return false }
        return hosts.contains { site in
            if host == site { return true }
            let isAddress = site.contains(":") || site.split(separator: ".").allSatisfy { UInt8($0) != nil }
            return site != "localhost" && !isAddress && host.hasSuffix("." + site)
        }
    }

    func opensInSmallWindow(_ url: URL, prefersSmallWindow: Bool, hasSiteRuleDestination: Bool) -> Bool {
        prefersSmallWindow && !hasSiteRuleDestination && !contains(url)
    }

    static func host(from url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host?.lowercased() else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || "*%/\\".contains($0) }) else { return nil }
        return host
    }

    static func host(parsing text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("*.") { text.removeFirst(2) }
        if !text.contains("://"), !text.hasPrefix("["), text.filter({ $0 == ":" }).count > 1 {
            text = "[\(text)]"
        }
        let address = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: address), url.user == nil, url.password == nil else { return nil }
        return host(from: url)
    }
}
