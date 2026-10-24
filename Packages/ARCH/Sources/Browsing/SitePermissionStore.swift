// Remembers the user's Allow and Don't Allow answers to websites' permission requests, per origin and permission type, in `permissions.json` in the app's Application Support folder. The session answers from it before asking, and Settings ▸ Websites changes and removes the answers.
import ARCHEngine
import Combine
import Foundation

public final class SitePermissionStore: ObservableObject {
    public enum Decision: String, Codable {
        case allow
        case deny
    }

    /// The store in the app's Application Support folder.
    public static let shared = SitePermissionStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arch"))

    /// Each origin's answers, keyed by origins such as `https://example.com`.
    @Published public private(set) var decisions: [String: [EnginePermissionType: Decision]] = [:]
    /// Sends the origin and the types whose answers changed, after the change.
    public let didChange = PassthroughSubject<(origin: String, types: [EnginePermissionType]), Never>()
    private let fileURL: URL

    /// The file's layout. Answers are keyed by the permission type's raw value.
    private struct File: Codable {
        var version = 1
        var sites: [String: [String: Decision]]
    }

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("permissions.json")
        guard let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        // Types this version does not know are dropped.
        for (origin, answers) in file.sites {
            let known = Dictionary(uniqueKeysWithValues: answers.compactMap { key, decision in EnginePermissionType(rawValue: key).map { ($0, decision) } })
            if !known.isEmpty { decisions[origin] = known }
        }
    }

    public func decision(for type: EnginePermissionType, origin: String) -> Decision? {
        decisions[origin]?[type]
    }

    /// Remembers `decision` for each of `types`, or forgets their answers when it is `nil`, and saves the file.
    public func set(_ decision: Decision?, for types: [EnginePermissionType], origin: String) {
        var answers = decisions[origin] ?? [:]
        for type in types { answers[type] = decision }
        decisions[origin] = answers.isEmpty ? nil : answers
        save()
        didChange.send((origin, types))
    }

    private func save() {
        let file = File(sites: decisions.mapValues { answers in Dictionary(uniqueKeysWithValues: answers.map { ($0.key.rawValue, $0.value) }) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The origin that answers are kept under: the scheme, the host, and a port other than the scheme's default. Only web addresses with a host have one.
    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.map { $0 == (scheme == "https" ? 443 : 80) ? "" : ":\($0)" } ?? ""
        // An IPv6 address keeps its brackets, so that its colons do not read as a port.
        return "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)\(port)"
    }

    /// Screen recording asks every time: a site the user let record the screen once should not start recording unasked on a later visit.
    public static func remembers(_ type: EnginePermissionType) -> Bool {
        type != .screenCapture
    }
}
