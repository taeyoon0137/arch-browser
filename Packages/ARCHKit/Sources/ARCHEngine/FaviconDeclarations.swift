// Reads icon links without loading a page or running its scripts. All addresses resolve against the response's final URL.
import Foundation

struct FaviconDeclarations {
    var icons: [URL] = []
    var touchIcons: [URL] = []
    var manifests: [URL] = []

    init(html: String, pageURL: URL) {
        // Skip comments and raw text so an example link in a script is not an icon declaration.
        let tags = Self.matches(#"<!--.*?-->|<(script|style|template)\b[^>]*>.*?</\1\s*>|<(link|base)\b(?:"[^"]*"|'[^']*'|[^'">])*>"#, in: html)
        var baseURL = pageURL
        var foundBase = false
        var candidates: [(String, String, String, Bool)] = []
        var manifestLinks: [String] = []
        for tag in tags {
            guard let kind = tag[2]?.lowercased() else { continue }
            var attributes: [String: String] = [:]
            for attribute in Self.matches(#"([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, in: tag[0] ?? "") {
                guard let name = attribute[1]?.lowercased(), attributes[name] == nil else { continue }
                attributes[name] = Self.unescape(attribute[2] ?? attribute[3] ?? attribute[4] ?? "")
            }
            guard let href = attributes["href"], !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if kind == "base" {
                if !foundBase, let resolved = Self.resolve(href, against: pageURL), resolved.scheme != "data" {
                    baseURL = resolved
                    foundBase = true
                }
                continue
            }
            let relations = Set((attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            if relations.contains("manifest") { manifestLinks.append(href) }
            let touch = !relations.isDisjoint(with: ["apple-touch-icon", "apple-touch-icon-precomposed"])
            if relations.contains("icon") || touch {
                candidates.append((href, attributes["sizes"] ?? "", attributes["type"] ?? "", touch))
            }
        }
        let resolved = candidates.compactMap { candidate -> (URL, String, String, Bool)? in
            guard let address = Self.resolve(candidate.0, against: baseURL) else { return nil }
            return (address, candidate.1, candidate.2, candidate.3)
        }
        icons = Self.ordered(resolved.filter { !$0.3 }.map { ($0.0, $0.1, $0.2) })
        touchIcons = Self.ordered(resolved.filter { $0.3 }.map { ($0.0, $0.1, $0.2) })
        manifests = Self.unique(manifestLinks.compactMap { Self.resolve($0, against: baseURL) }).prefix(2).map { $0 }
    }

    static func manifestIcons(in data: Data, manifestURL: URL) -> [URL] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = object["icons"] as? [[String: Any]] else { return [] }
        return ordered(icons.compactMap { icon in
            // Maskable and monochrome-only assets need treatment that a plain sidebar icon does not apply.
            let purposes = (icon["purpose"] as? String ?? "any").lowercased().split(whereSeparator: \.isWhitespace)
            guard purposes.contains("any"), let source = icon["src"] as? String,
                  let address = resolve(source, against: manifestURL) else { return nil }
            return (address, icon["sizes"] as? String ?? "", icon["type"] as? String ?? "")
        })
    }

    static func resolve(_ value: String, against baseURL: URL) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), FaviconLoader.schemes.contains(scheme),
              scheme == "data" || url.host != nil else { return nil }
        return url
    }

    static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.filter { seen.insert($0).inserted }
    }

    /// Prefer vectors, then the smallest bitmap at least 32 pixels wide for the sidebar's Retina icons.
    private static func ordered(_ candidates: [(URL, String, String)]) -> [URL] {
        func rank(_ candidate: (URL, String, String)) -> Int {
            if candidate.2.lowercased() == "image/svg+xml" || candidate.0.pathExtension.lowercased() == "svg" { return 0 }
            let sizes = candidate.1.lowercased().split(whereSeparator: \.isWhitespace)
            if sizes.contains("any") { return 1 }
            let widths = sizes.compactMap { size -> Int? in
                let sides = size.split(separator: "x")
                guard sides.count == 2, let width = Int(sides[0]), width > 0, Int(sides[1]) == width else { return nil }
                return min(width, 65_536)
            }
            if let width = widths.filter({ $0 >= 32 }).min() { return 2 + width - 32 }
            if let width = widths.max() { return 100_000 - width }
            return 50_000
        }
        return unique(candidates.enumerated().sorted {
            let left = rank($0.element), right = rank($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map { $0.element.0 }).prefix(16).map { $0 }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String?]] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }

    private static func unescape(_ value: String) -> String {
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
        guard let expression = try? NSRegularExpression(pattern: #"&(#x[0-9a-f]+|#[0-9]+|amp|quot|apos|lt|gt);"#, options: .caseInsensitive) else { return value }
        let result = NSMutableString(string: value)
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            let lower = (value as NSString).substring(with: match.range(at: 1)).lowercased()
            let replacement: String?
            if lower.hasPrefix("#x") {
                replacement = UInt32(lower.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            } else if lower.hasPrefix("#") {
                replacement = UInt32(lower.dropFirst()).flatMap(UnicodeScalar.init).map(String.init)
            } else {
                replacement = named[lower]
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}
