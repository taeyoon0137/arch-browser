// Engine versions of one web extension: two installed plugins of one Persona that are versions of one extension, each for the engine whose runtime runs its package, which Arch shows as one plugin, and the rule by which a staged package names the same extension as an installed plugin. `docs/plugins.md`, Web extensions as plugins ▸ Engine versions, describes them.
import ARCHEngine
import Foundation

/// Two installed web extension plugins of one Persona that are versions of one extension, with the engine each runs on. `plugins.json` holds it as an object from engine name to plugin identifier.
public struct PluginEngineVersions: Hashable, Sendable {
    /// The engines whose extension runtimes a pair divides between its versions, one engine each.
    public static let engines: [EngineKind] = [.webKit, .chromium]

    public var versions: [EngineKind: PluginID]

    public init(_ versions: [EngineKind: PluginID]) {
        self.versions = versions
    }

    /// The pair's versions in the order of `engines`.
    public var plugins: [PluginID] {
        Self.engines.compactMap { versions[$0] }
    }

    /// Whether the record gives each engine of `engines` a version, two plugins in all.
    var isComplete: Bool {
        Set(versions.keys) == Set(Self.engines) && Set(versions.values).count == Self.engines.count
    }

    /// The engine of the pair that is not `engine`, which the other version runs on.
    static func other(than engine: EngineKind) -> EngineKind? {
        guard engines.contains(engine) else { return nil }
        return engines.first { $0 != engine }
    }

    /// The record as `plugins.json` holds it.
    var fileRecord: [String: String] {
        Dictionary(uniqueKeysWithValues: versions.map { ($0.key.rawValue, $0.value.rawValue) })
    }

    /// The record of the file, or nil for one that names an engine a pair does not hold, as one this build does not know, or that gives an engine no valid identifier.
    init?(fileRecord: [String: String]) {
        var versions: [EngineKind: PluginID] = [:]
        for (name, id) in fileRecord {
            guard let engine = EngineKind(rawValue: name), Self.engines.contains(engine), let plugin = PluginID(rawValue: id) else { return nil }
            versions[engine] = plugin
        }
        self.init(versions)
    }
}

extension PluginManifest {
    /// Whether the two manifests name one extension: the same identifier, or the same name as Arch shows it, compared without case and spaces at either end, with at least one developer field, `author` or `homepage`, that both give and that matches, and none that both give and that differs.
    func namesSameExtension(as other: PluginManifest) -> Bool {
        if id == other.id { return true }
        let trimmed = { (name: String) in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard trimmed(name) == trimmed(other.name) else { return false }
        let fields = [(author, other.author), (homepage, other.homepage)].compactMap { pair -> Bool? in
            guard let mine = pair.0, let theirs = pair.1 else { return nil }
            return mine == theirs
        }
        return !fields.isEmpty && !fields.contains(false)
    }
}

/// The two versions of an installed pair that another Persona can stage together (`PluginManager.pairForCopy(of:)`). Only a manager makes one, from its installed packages, whose origin and proof their installs checked.
public struct PluginPairCopy: Sendable {
    struct Version: Sendable {
        let folder: URL
        let origin: PluginOrigin
        let proof: PluginProof?
        let engine: EngineKind
    }

    /// The leading version first.
    let versions: [Version]

    /// The engine of each version, the leading version's first.
    public var engines: [EngineKind] { versions.map(\.engine) }
}

/// A staged version of a pair that another Persona's review installs (`PluginManager.stage(_:)`), with the engine it is the version for.
public struct PluginStagedVersion: Identifiable, Sendable {
    public var id: URL { package.rootURL }
    public let package: PluginPackage
    public let engine: EngineKind
}

extension PluginID {
    /// The identifier of a version that joins, for `engine`, a plugin whose version has this identifier: this one followed by `.webkit` or `.chromium`. Nil when it would grow past 128 characters.
    func version(for engine: EngineKind) -> PluginID? {
        PluginID(rawValue: rawValue + "." + engine.rawValue.lowercased())
    }
}
