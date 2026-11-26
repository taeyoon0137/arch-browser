// The app-wide site rules file. A later version stays untouched until a build that understands it reads it.
import Combine
import Darwin
import Foundation

public final class SiteRuleStore: ObservableObject {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidSite
        case duplicateSite(UUID)
        case readOnly

        public var errorDescription: String? {
            switch self {
            case .invalidSite: localized("Enter a host or web address without a username, password, or wildcard.")
            case .duplicateSite: localized("A rule for this site already exists. Edit that rule to change its destination.")
            case .readOnly: localized("These site rules were saved by a newer version of Arch and cannot be changed here.")
            }
        }
    }

    @Published public private(set) var rules: [SiteRule] = []
    public private(set) var isReadOnly = false
    public let didChange = PassthroughSubject<Void, Never>()
    private let fileURL: URL
    private var hasUnreadableFile = false

    private struct File: Codable {
        var version = 1
        var rules: [SiteRule]
    }

    private struct Header: Decodable {
        var version: Int
    }

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("site-rules.json")
        do {
            let data = try Data(contentsOf: fileURL)
            if let header = try? JSONDecoder().decode(Header.self, from: data), header.version > 1 {
                isReadOnly = true
                return
            }
            do {
                let file = try JSONDecoder().decode(File.self, from: data)
                guard file.version == 1 else { throw Error.invalidSite }
                rules = try file.rules.map(Self.normalized)
            } catch {
                hasUnreadableFile = true
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        } catch {
            // An unreadable file is not replaced while the store cannot preserve its contents.
            isReadOnly = true
        }
    }

    public func save(_ rule: SiteRule) throws {
        guard !isReadOnly else { throw Error.readOnly }
        let rule = try Self.normalized(rule)
        if let duplicate = rules.first(where: { $0.id != rule.id && $0.host == rule.host && $0.pathPrefix == rule.pathPrefix }) {
            throw Error.duplicateSite(duplicate.id)
        }
        var next = rules
        if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index] = rule }
        else { next.append(rule) }
        try replace(next)
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard !isReadOnly else { return false }
        let next = rules.filter { $0.id != id }
        guard next != rules else { return true }
        return (try? replace(next)) != nil
    }

    /// Keeps concurrent rules for the same site until sync resolves them; the editor rejects new duplicates.
    public func replaceFromSync(_ rules: [SiteRule]) throws {
        guard !isReadOnly else { throw Error.readOnly }
        try replace(rules.map(Self.normalized))
    }

    private static func normalized(_ rule: SiteRule) throws -> SiteRule {
        let site = try SiteRuleSite(host: rule.host, pathPrefix: rule.pathPrefix)
        var rule = rule
        rule.host = site.host
        rule.pathPrefix = site.pathPrefix
        return rule
    }

    private func replace(_ next: [SiteRule]) throws {
        guard next != rules || hasUnreadableFile else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(File(rules: next))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if hasUnreadableFile {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("site-rules.unreadable.json")
            try Self.rename(fileURL, to: backup)
            hasUnreadableFile = false
        }
        try write(data)
        rules = next
        didChange.send()
    }

    /// The temporary file has mode 0600 before any rule is written, then replaces the old file atomically.
    private func write(_ data: Data) throws {
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".site-rules-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.close()
        try Self.rename(temporary, to: fileURL)
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
