// Remembers the user's Allow and Don't Allow answers to websites' permission requests, per Persona, origin, and permission type, in `permissions.json` in the app's Application Support folder (Persona rule 6). The session answers a tab's request from its Persona's answers before asking, and Settings ▸ Websites changes and removes each Persona's answers. For each Persona the file also lists the answers the user removed until new ones replace them, so that an engine profile that was not running at a removal forgets its own copy of the answer when it starts. A file from before Personas kept their own answers holds one app-wide set, which the session copies into every Persona once at launch.
import ARCHEngine
import Combine
import Foundation

/// Persists website permission answers and removals by Persona and origin.
public final class SitePermissionStore: ObservableObject {
    /// Whether a website may use a requested permission.
    public enum Decision: String, Codable {
        case allow
        case deny
    }

    /// One Persona's answers and removals.
    public struct Answers: Equatable {
        /// Each origin's answers, keyed by origins such as `https://example.com`.
        public var decisions: [String: [EnginePermissionType: Decision]] = [:]
        /// The types whose answers were removed, by origin, until a new answer replaces them. An engine profile keeps the answers it was given, so each profile that starts forgets these too.
        public var removed: [String: Set<EnginePermissionType>] = [:]

        var isEmpty: Bool { decisions.isEmpty && removed.isEmpty }
    }

    /// Each Persona's answers, keyed by the Persona's ID. A Persona without answers has no entry.
    @Published public private(set) var answers: [UUID: Answers] = [:]
    /// The app-wide answers of a file from before Personas kept their own, until `adoptAppWideAnswers(into:)` copies them into the Personas.
    private(set) var appWideAnswers: Answers?
    /// Sends the Persona, the origin, and the types whose answers changed, after the change.
    public let didChange = PassthroughSubject<(personaID: UUID, origin: String, types: [EnginePermissionType]), Never>()
    private let fileURL: URL

    /// The file's layout. Version 2 keys each Persona's answers by its UUID; version 1 had one app-wide `sites` and `removed`. Answers and removed types are keyed by the permission type's raw value.
    private struct File: Codable {
        /// One Persona's answers in the file, and the types the user removed from them.
        struct Entry: Codable {
            var sites: [String: [String: Decision]]
            var removed: [String: [String]]?
        }
        var version = 2
        var personas: [String: Entry]?
        var sites: [String: [String: Decision]]?
        var removed: [String: [String]]?
    }

    /// Loads known permission answers and removals from the profile directory.
    init(directory: URL) {
        fileURL = directory.appendingPathComponent("permissions.json")
        guard let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        for (key, entry) in file.personas ?? [:] {
            guard let id = UUID(uuidString: key) else { continue }
            let loaded = Self.answers(sites: entry.sites, removed: entry.removed)
            if !loaded.isEmpty { answers[id] = loaded }
        }
        if file.personas == nil, let sites = file.sites {
            let loaded = Self.answers(sites: sites, removed: file.removed)
            if !loaded.isEmpty { appWideAnswers = loaded }
        }
    }

    /// Reads one set of answers. Types this version does not know are dropped.
    private static func answers(sites: [String: [String: Decision]], removed: [String: [String]]?) -> Answers {
        var result = Answers()
        for (origin, answers) in sites {
            let known = Dictionary(uniqueKeysWithValues: answers.compactMap { key, decision in EnginePermissionType(rawValue: key).map { ($0, decision) } })
            if !known.isEmpty { result.decisions[origin] = known }
        }
        for (origin, types) in removed ?? [:] {
            let known = Set(types.compactMap(EnginePermissionType.init(rawValue:)))
            if !known.isEmpty { result.removed[origin] = known }
        }
        return result
    }

    /// Copies the app-wide answers of a file from before Personas kept their own into each of `personaIDs`, the session's Personas but the Agents Persona, and saves the file in the new layout, so that nothing the user allowed stops working. Runs once at launch, before any engine starts; afterwards there is nothing to copy.
    func adoptAppWideAnswers(into personaIDs: [UUID]) {
        guard let appWide = appWideAnswers else { return }
        appWideAnswers = nil
        for id in personaIDs { answers[id] = appWide }
        save()
    }

    /// The Persona's answers by origin.
    public func decisions(in personaID: UUID) -> [String: [EnginePermissionType: Decision]] {
        answers[personaID]?.decisions ?? [:]
    }

    /// Returns the Persona's saved answer for a permission at an origin, if present.
    public func decision(for type: EnginePermissionType, origin: String, in personaID: UUID) -> Decision? {
        answers[personaID]?.decisions[origin]?[type]
    }

    /// The types whose answers the Persona removed, by origin, until new answers replace them.
    public func removed(in personaID: UUID) -> [String: Set<EnginePermissionType>] {
        answers[personaID]?.removed ?? [:]
    }

    /// A draft shows only permission types, never the sites whose answers its Persona keeps. Agent tabs deny every request they make themselves, so only an allowed answer of the Persona, which a Chromium profile applies before asking, needs a note.
    func agentPermissionNote(for personaID: UUID, agentOnlyPersonaID: UUID?) -> String? {
        guard personaID != agentOnlyPersonaID else { return nil }
        let types: [(EnginePermissionType, String)] = [(.camera, localized("the camera")), (.microphone, localized("the microphone")), (.geolocation, localized("your location"))]
        let decisions = decisions(in: personaID)
        let allowed = types.filter { type, _ in decisions.values.contains { $0[type] == .allow } }.map(\.1)
        return allowed.isEmpty ? nil : localized("Sites you allowed to use \(allowed.formatted(.list(type: .or))) keep that access in agent tabs that run in Chromium.")
    }

    /// Remembers `decision` for each of `types` in the Persona, or forgets their answers when it is `nil` and lists them in its `removed`, and saves the file.
    public func set(_ decision: Decision?, for types: [EnginePermissionType], origin: String, in personaID: UUID) {
        var persona = answers[personaID] ?? Answers()
        var originAnswers = persona.decisions[origin] ?? [:]
        var removedTypes = persona.removed[origin] ?? []
        for type in types {
            originAnswers[type] = decision
            if decision == nil { removedTypes.insert(type) } else { removedTypes.remove(type) }
        }
        persona.decisions[origin] = originAnswers.isEmpty ? nil : originAnswers
        persona.removed[origin] = removedTypes.isEmpty ? nil : removedTypes
        answers[personaID] = persona.isEmpty ? nil : persona
        save()
        didChange.send((personaID, origin, types))
    }

    /// Moves the Persona's answers into `target`, as Merge Persona Into… does before it removes the Persona. The target keeps its own answer wherever both have one, and its profiles take each moved answer at once through `didChange`.
    func moveAnswers(from source: UUID, to target: UUID) {
        guard source != target, let moving = answers.removeValue(forKey: source) else { return }
        var merged = answers[target] ?? Answers()
        var changed: [(String, [EnginePermissionType])] = []
        for (origin, decisions) in moving.decisions {
            var originAnswers = merged.decisions[origin] ?? [:]
            let added = decisions.filter { originAnswers[$0.key] == nil }
            guard !added.isEmpty else { continue }
            originAnswers.merge(added) { kept, _ in kept }
            merged.decisions[origin] = originAnswers
            if var removedTypes = merged.removed[origin] {
                removedTypes.subtract(added.keys)
                merged.removed[origin] = removedTypes.isEmpty ? nil : removedTypes
            }
            changed.append((origin, Array(added.keys)))
        }
        answers[target] = merged.isEmpty ? nil : merged
        save()
        for (origin, types) in changed { didChange.send((target, origin, types)) }
    }

    /// Forgets a deleted Persona's answers, at the launch that removes its data (`PersonaDataRemoval`), and reports whether the file holds none of them.
    func removeAnswers(ofPersona personaID: UUID) -> Bool {
        guard answers.removeValue(forKey: personaID) != nil else { return true }
        return save()
    }

    /// Writes current answers and removals atomically to the permissions file, and reports whether it did.
    @discardableResult
    private func save() -> Bool {
        let personas = answers.reduce(into: [String: File.Entry]()) { result, entry in
            result[entry.key.uuidString] = File.Entry(sites: entry.value.decisions.mapValues { answers in Dictionary(uniqueKeysWithValues: answers.map { ($0.key.rawValue, $0.value) }) },
                                                    removed: entry.value.removed.isEmpty ? nil : entry.value.removed.mapValues { $0.map(\.rawValue).sorted() })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(File(personas: personas)) else { return false }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: fileURL, options: .atomic)) != nil
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
