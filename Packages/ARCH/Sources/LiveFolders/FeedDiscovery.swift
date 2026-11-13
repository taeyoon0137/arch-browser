// The feeds a web page names in `<link rel="alternate">` tags of the RSS and Atom types (docs/bookmarks.md, Live folders ▸ Feeds), for New Live Folder… on a page that is not a feed itself.
import Foundation

/// A feed a page names, with the title its tag gives.
public struct FeedLink: Hashable, Sendable {
    public var url: URL
    public var title: String?

    public init(url: URL, title: String?) {
        self.url = url
        self.title = title
    }
}

public enum FeedDiscovery {
    /// The page's first bytes that are read for links.
    public static let readLimit = 512 * 1_024
    public static let linkLimit = 10
    private static let feedTypes: Set<String> = ["application/rss+xml", "application/atom+xml"]

    /// What an address the user gives turns out to be.
    public enum Outcome: Equatable, Sendable {
        /// A feed, used directly.
        case feed(Feed)
        /// A page and the feeds it names, none or several.
        case links([FeedLink])
    }

    /// Up to ten feeds that the page's alternate links name, in order and each once, resolved against the page's address. Only `http` and `https` addresses count.
    public static func links(inHTML data: Data, address: URL) -> [FeedLink] {
        let bytes = [UInt8](data.prefix(readLimit))
        var links: [FeedLink] = []
        var scanner = TagScanner(bytes: bytes)
        while links.count < linkLimit, let attributes = scanner.nextTag(named: "link") {
            let rel = (attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            let type = (attributes["type"] ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            guard rel.contains("alternate"), feedTypes.contains(type),
                  let href = attributes["href"], let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: address)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  !links.contains(where: { $0.url == url }) else { continue }
            links.append(FeedLink(url: url, title: attributes["title"].map { FeedText.collapsed($0) }?.nonEmpty))
        }
        return links
    }
}

/// Finds tags of one name in HTML bytes and reads their attributes, skipping comments. Attribute values have their character references decoded.
private struct TagScanner {
    let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The attributes of the next tag named `name`, ignoring case, with lowercase names.
    mutating func nextTag(named name: String) -> [String: String]? {
        let name = Array(name.lowercased().utf8)
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            if starts(with: Array("<!--".utf8), at: index) {
                index = find(Array("-->".utf8), from: index + 4).map { $0 + 3 } ?? bytes.count
                continue
            }
            let nameEnd = index + 1 + name.count
            guard nameEnd <= bytes.count, lowercased(index + 1..<nameEnd) == name,
                  nameEnd == bytes.count || isSpace(bytes[nameEnd]) || bytes[nameEnd] == UInt8(ascii: "/") || bytes[nameEnd] == UInt8(ascii: ">") else {
                index += 1
                continue
            }
            index = nameEnd
            return attributes()
        }
        return nil
    }

    /// Reads attributes up to the end of the tag.
    private mutating func attributes() -> [String: String] {
        var result: [String: String] = [:]
        while index < bytes.count {
            while index < bytes.count, isSpace(bytes[index]) || bytes[index] == UInt8(ascii: "/") { index += 1 }
            guard index < bytes.count, bytes[index] != UInt8(ascii: ">") else {
                index += 1
                return result
            }
            let nameStart = index
            while index < bytes.count, !isSpace(bytes[index]), ![UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "/")].contains(bytes[index]) { index += 1 }
            let attribute = String(decoding: lowercased(nameStart..<index), as: UTF8.self)
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else {
                if !attribute.isEmpty, result[attribute] == nil { result[attribute] = "" }
                continue
            }
            index += 1
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            let value: ArraySlice<UInt8>
            if index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                let quote = bytes[index]
                let start = index + 1
                let end = bytes[start...].firstIndex(of: quote) ?? bytes.count
                value = bytes[start..<end]
                index = min(end + 1, bytes.count)
            } else {
                let start = index
                while index < bytes.count, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">") { index += 1 }
                value = bytes[start..<index]
            }
            // The first of two attributes with one name counts, as in HTML.
            if !attribute.isEmpty, result[attribute] == nil {
                result[attribute] = FeedText.decodingReferences(String(decoding: value, as: UTF8.self))
            }
        }
        return result
    }

    private func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    private func lowercased(_ range: Range<Int>) -> [UInt8] {
        bytes[range].map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    }

    private func starts(with prefix: [UInt8], at position: Int) -> Bool {
        position + prefix.count <= bytes.count && Array(bytes[position..<position + prefix.count]) == prefix
    }

    private func find(_ pattern: [UInt8], from position: Int) -> Int? {
        var position = position
        while position + pattern.count <= bytes.count {
            if starts(with: pattern, at: position) { return position }
            position += 1
        }
        return nil
    }
}
