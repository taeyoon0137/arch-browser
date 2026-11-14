// RSS 2.0, RSS 1.0, and Atom 1.0 feeds through Foundation's `XMLParser` (docs/bookmarks.md, Live folders ▸ Feeds). The document becomes a small element tree first, which each format then reads; a feed response is at most 5 MB.
import Foundation

/// A parsed feed.
public struct Feed: Equatable, Sendable {
    /// The feed's own title, the folder's default name.
    public var title: String?
    /// In document order, or newest first when every item has a date, one item per ID.
    public var items: [LiveItem]
    /// The interval the feed asks for: RSS's `ttl` or the syndication module's period and frequency, whichever is longer.
    public var interval: TimeInterval?

    public init(title: String?, items: [LiveItem], interval: TimeInterval?) {
        self.title = title
        self.items = items
        self.interval = interval
    }
}

public enum FeedParser {
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let rss1Namespace = "http://purl.org/rss/1.0/"
    private static let dublinCoreNamespace = "http://purl.org/dc/elements/1.1/"
    private static let syndicationNamespace = "http://purl.org/rss/1.0/modules/syndication/"

    /// Parses `data`, resolving relative addresses against `xml:base` and the feed's `address`. Throws `LiveFolderError.notAFeed` for a document whose root is not `rss`, `rdf:RDF`, or `feed`, and `unreadableFeed` for a feed that is not well-formed XML. Items without an `http` or `https` address are skipped.
    public static func parse(_ data: Data, address: URL) throws -> Feed {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let parsed = parser.parse()
        guard let root = builder.root, let format = format(of: root) else { throw LiveFolderError.notAFeed }
        guard parsed else { throw LiveFolderError.unreadableFeed(describe(builder.error ?? parser.parserError)) }
        let base = base(of: root, inheriting: address)
        let feed: Feed
        switch format {
        case .rss2: feed = rss2(root, base: base)
        case .rss1: feed = rss1(root, base: base)
        case .atom: feed = atom(root, base: base)
        }
        return Feed(title: feed.title, items: ordered(feed.items), interval: feed.interval)
    }

    private enum Format {
        case rss2, rss1, atom
    }

    private static func format(of root: Node) -> Format? {
        switch (root.name, root.namespace) {
        case ("rss", ""): return .rss2
        case ("RDF", rdfNamespace): return .rss1
        case ("feed", _): return .atom
        default: return nil
        }
    }

    // MARK: Formats

    private static func rss2(_ root: Node, base: URL) -> Feed {
        guard let channel = root.child("channel", in: "") else { return Feed(title: nil, items: [], interval: nil) }
        let channelBase = self.base(of: channel, inheriting: base)
        let ttl = channel.child("ttl", in: "").flatMap { Int($0.trimmedText) }.flatMap { $0 > 0 ? TimeInterval($0 * 60) : nil }
        let items = channel.children("item", in: "").compactMap { item -> LiveItem? in
            let itemBase = self.base(of: item, inheriting: channelBase)
            let guidNode = item.child("guid", in: "")
            let guid = guidNode?.trimmedText.nonEmpty
            let isPermaLink = guidNode?.attributes["isPermaLink"]?.lowercased() != "false"
            let linkNode = item.child("link", in: "")
            let link = linkNode.flatMap { node in node.trimmedText.nonEmpty.flatMap { webAddress($0, base: self.base(of: node, inheriting: itemBase)) } }
            let permalink = isPermaLink ? guid.flatMap { webAddress($0, base: itemBase) } : nil
            guard let url = link ?? permalink else { return nil }
            let date = item.child("pubDate", in: "").flatMap { FeedDate.rfc822($0.trimmedText) }
                ?? item.child("date", in: dublinCoreNamespace).flatMap { FeedDate.iso8601($0.trimmedText) }
            return LiveItem(id: guid ?? url.absoluteString, url: url, title: title(item.child("title", in: "").map { FeedText.plain($0.allText) }, url: url), date: date)
        }
        let feedTitle = channel.child("title", in: "").map { FeedText.plain($0.allText) }?.nonEmpty
        return Feed(title: feedTitle, items: items, interval: [ttl, syndicationInterval(channel)].compactMap { $0 }.max())
    }

    private static func rss1(_ root: Node, base: URL) -> Feed {
        let channel = root.child("channel", in: rss1Namespace)
        let items = root.children("item", in: rss1Namespace).compactMap { item -> LiveItem? in
            let itemBase = self.base(of: item, inheriting: base)
            let about = item.attributes.first { $0.key == "about" || $0.key.hasSuffix(":about") }?.value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            guard let linkNode = item.child("link", in: rss1Namespace),
                  let url = linkNode.trimmedText.nonEmpty.flatMap({ webAddress($0, base: self.base(of: linkNode, inheriting: itemBase)) }) else { return nil }
            let date = item.child("date", in: dublinCoreNamespace).flatMap { FeedDate.iso8601($0.trimmedText) }
            return LiveItem(id: about ?? url.absoluteString, url: url, title: title(item.child("title", in: rss1Namespace).map { FeedText.plain($0.allText) }, url: url), date: date)
        }
        let feedTitle = channel?.child("title", in: rss1Namespace).map { FeedText.plain($0.allText) }?.nonEmpty
        return Feed(title: feedTitle, items: items, interval: channel.flatMap(syndicationInterval))
    }

    private static func atom(_ root: Node, base: URL) -> Feed {
        let namespace = root.namespace
        let items = root.children("entry", in: namespace).compactMap { entry -> LiveItem? in
            let entryBase = self.base(of: entry, inheriting: base)
            let alternates = entry.children("link", in: namespace).filter { ($0.attributes["rel"] ?? "alternate").lowercased() == "alternate" }
            guard let url = alternates.lazy.compactMap({ link in link.attributes["href"].flatMap { webAddress($0, base: self.base(of: link, inheriting: entryBase)) } }).first else { return nil }
            let id = entry.child("id", in: namespace)?.trimmedText.nonEmpty
            let date = (entry.child("updated", in: namespace) ?? entry.child("published", in: namespace)).flatMap { FeedDate.iso8601($0.trimmedText) }
            return LiveItem(id: id ?? url.absoluteString, url: url, title: title(entry.child("title", in: namespace).map(atomText), url: url), date: date)
        }
        let feedTitle = root.child("title", in: namespace).map(atomText)?.nonEmpty
        return Feed(title: feedTitle, items: items, interval: syndicationInterval(root))
    }

    // MARK: Values

    /// An Atom text construct as plain text: `text` is plain already, `html` is markup in text, and `xhtml` is markup as elements.
    private static func atomText(_ node: Node) -> String {
        switch node.attributes["type"]?.lowercased() {
        case "html": return FeedText.plain(node.allText)
        default: return FeedText.collapsed(node.allText)
        }
    }

    /// The item's title, or without one its address without the scheme.
    private static func title(_ text: String?, url: URL) -> String {
        if let text = text?.nonEmpty { return String(text.prefix(LiveItem.maximumTitleLength)) }
        let address = url.absoluteString
        guard let scheme = url.scheme, address.hasPrefix("\(scheme)://") else { return String(address.prefix(LiveItem.maximumTitleLength)) }
        return String(address.dropFirst(scheme.count + 3).prefix(LiveItem.maximumTitleLength))
    }

    /// `text` resolved against `base`, when the result is an `http` or `https` address.
    private static func webAddress(_ text: String, base: URL) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The base address inside `node`: its `xml:base` resolved against the base around it.
    private static func base(of node: Node, inheriting base: URL) -> URL {
        guard let value = node.attributes["xml:base"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              let url = URL(string: value, relativeTo: base)?.absoluteURL else { return base }
        return url
    }

    /// The syndication module's interval: `sy:updatePeriod` (daily by default) divided by `sy:updateFrequency` (1 by default).
    private static func syndicationInterval(_ node: Node) -> TimeInterval? {
        let period = node.child("updatePeriod", in: syndicationNamespace)?.trimmedText.lowercased()
        let frequency = node.child("updateFrequency", in: syndicationNamespace).flatMap { Int($0.trimmedText) }
        guard period != nil || frequency != nil else { return nil }
        let periods: [String: TimeInterval] = ["hourly": 3_600, "daily": 86_400, "weekly": 604_800, "monthly": 2_592_000, "yearly": 31_536_000]
        return (periods[period ?? "daily"] ?? 86_400) / TimeInterval(max(frequency ?? 1, 1))
    }

    /// The first item for each ID, newest first when every item has a date and otherwise in document order.
    private static func ordered(_ items: [LiveItem]) -> [LiveItem] {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        guard unique.allSatisfy({ $0.date != nil }) else { return unique }
        return unique.enumerated().sorted { lhs, rhs in
            lhs.element.date! != rhs.element.date! ? lhs.element.date! > rhs.element.date! : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func describe(_ error: (any Error)?) -> String {
        let info = (error as NSError?)?.userInfo ?? [:]
        let message = (info["NSXMLParserErrorMessage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "it is not well-formed XML."
        guard let line = info["NSXMLParserErrorLineNumber"] as? Int else { return message }
        return "line \(line): \(message)"
    }
}

// MARK: - Element tree

/// An element with its namespace, its attributes under their qualified names, and its text and child elements in document order.
private final class Node {
    enum Content {
        case text(String)
        case element(Node)
    }

    let name: String
    let namespace: String
    let attributes: [String: String]
    private(set) var content: [Content] = []

    init(name: String, namespace: String, attributes: [String: String]) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
    }

    func append(_ item: Content) {
        content.append(item)
    }

    func children(_ name: String, in namespace: String) -> [Node] {
        content.compactMap { item in
            guard case .element(let node) = item, node.name == name, node.namespace == namespace else { return nil }
            return node
        }
    }

    func child(_ name: String, in namespace: String) -> Node? {
        children(name, in: namespace).first
    }

    /// The text of the element and every element inside it.
    var allText: String {
        content.map { item in
            switch item {
            case .text(let text): return text
            case .element(let node): return node.allText
            }
        }.joined()
    }

    var trimmedText: String {
        allText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: Node?
    /// The first parse error, whose details say what went wrong where.
    private(set) var error: (any Error)?
    private var stack: [Node] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = Node(name: elementName, namespace: namespaceURI ?? "", attributes: attributeDict)
        if let parent = stack.last {
            parent.append(.element(node))
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.append(.text(string))
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.append(.text(String(decoding: CDATABlock, as: UTF8.self)))
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        if error == nil { error = parseError }
    }
}

// MARK: - Text

/// Markup and character references in feed text.
enum FeedText {
    /// Plain text from text that may hold markup: tags removed, character references decoded, whitespace collapsed, and cut at 300 characters.
    static func plain(_ text: String) -> String {
        collapsed(decodingReferences(removingTags(text)))
    }

    /// Runs of whitespace as single spaces, without any at either end, cut at 300 characters.
    static func collapsed(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(LiveItem.maximumTitleLength))
    }

    /// `text` without its tags, comments, and declarations. A `<` that starts none of them stays.
    static func removingTags(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "<", next < text.endIndex, text[next].isLetter || "/!?".contains(text[next]),
               let end = text[next...].firstIndex(of: ">") {
                result.append(" ")
                index = text.index(after: end)
            } else {
                result.append(character)
                index = next
            }
        }
        return result
    }

    private static let namedReferences: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "copy": "©", "reg": "®", "trade": "™",
    ]

    /// `text` with numeric character references and the common named ones decoded. Others stay as they are.
    static func decodingReferences(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&", let end = text[index...].prefix(12).firstIndex(of: ";"),
                  let decoded = decode(String(text[text.index(after: index)..<end])) else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            result += decoded
            index = text.index(after: end)
        }
        return result
    }

    private static func decode(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            return value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
        }
        return namedReferences[name]
    }
}

// MARK: - Dates

enum FeedDate {
    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let zones: [String: Int] = ["UT": 0, "UTC": 0, "GMT": 0, "Z": 0, "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7]

    /// An RFC 822 date, as RSS 2.0 and HTTP use: `Mon, 02 Jan 2006 15:04:05 -0700`, with or without the weekday and the seconds, a two- or four-digit year, and a numeric zone or a named one; an unknown name counts as GMT.
    static func rfc822(_ text: String) -> Date? {
        var tokens = text.replacingOccurrences(of: ",", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        if let first = tokens.first, first.allSatisfy(\.isLetter) { tokens.removeFirst() }
        guard tokens.count >= 4, let day = Int(tokens[0]), (1...31).contains(day),
              let month = months[tokens[1].prefix(3).lowercased()], var year = Int(tokens[2]) else { return nil }
        if year < 100 { year += year < 50 ? 2000 : 1900 }
        let time = tokens[3].split(separator: ":").map { Int($0) }
        guard time.count == 2 || time.count == 3, let hour = time[0], let minute = time[1], (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let second = time.count == 3 ? time[2] : 0
        guard let second, (0...60).contains(second), let offset = zoneOffset(tokens.count > 4 ? tokens[4] : "GMT") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else { return nil }
        return date.addingTimeInterval(-TimeInterval(offset))
    }

    /// Seconds east of GMT for `+hhmm`, `-hh:mm`, or a zone's name.
    private static func zoneOffset(_ zone: String) -> Int? {
        guard let sign = zone.first, sign == "+" || sign == "-" else {
            return zone.allSatisfy(\.isLetter) ? (zones[zone.uppercased()] ?? 0) * 3_600 : nil
        }
        let digits = zone.dropFirst().filter { $0 != ":" }
        guard digits.count == 4, digits.allSatisfy(\.isNumber), let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3_600 + minutes * 60)
    }

    /// An ISO 8601 date, as Atom and Dublin Core use, with or without fractions of a second, or a date alone.
    static func iso8601(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
            ?? (text.count == 10 ? try? Date.ISO8601FormatStyle().year().month().day().parse(text) : nil)
    }
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
