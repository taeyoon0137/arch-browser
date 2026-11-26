// Plugin sync's allowlist excludes packages, private storage, and Keychain values.
import ARCHEngine
import Foundation

/// A package location that another Mac can use without this Mac's files or credentials.
public enum PluginSyncSource: Codable, Hashable, Sendable {
    case webStore(String)
    case url(URL)

    public var isValid: Bool {
        switch self {
        case .webStore(let id): id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
        case .url(let url): Self.accepts(url)
        }
    }

    /// Package addresses use HTTPS, with no credentials or transient query tokens.
    public static func accepts(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https" && components.host?.isEmpty == false
            && components.user == nil && components.password == nil && components.query == nil && components.fragment == nil
    }
}

/// One Persona's installed package. Settings contain only the non-secret fields the manifest declares.
public struct PluginSyncItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var manifestID: String
    public var name: String
    public var kind: String
    public var source: PluginSyncSource?
    public var isEnabled: Bool
    public var settings: [String: PluginValue]
    public var grant: PluginGrant
    public var engine: String?
    public var counterpartID: String?

    public init(id: String, manifestID: String, name: String, kind: String, source: PluginSyncSource? = nil,
                isEnabled: Bool, settings: [String: PluginValue] = [:], grant: PluginGrant = PluginGrant(permissions: [], sites: []),
                engine: String? = nil, counterpartID: String? = nil) {
        self.id = id
        self.manifestID = manifestID
        self.name = name
        self.kind = kind
        self.source = source
        self.isEnabled = isEnabled
        self.settings = settings
        self.grant = grant
        self.engine = engine
        self.counterpartID = counterpartID
    }

    /// Unknown kinds and engines stay in the cloud mirror until a build can use them.
    public var isValid: Bool {
        guard let entry = PluginID(rawValue: id), entry.rawValue == id,
              let manifest = PluginID(rawValue: manifestID), manifest.rawValue == manifestID,
              let kind = PluginKind(rawValue: kind), kind != .builtIn, source?.isValid != false else { return false }
        if let engine, EngineKind(rawValue: engine) == nil { return false }
        if let counterpartID, PluginID(rawValue: counterpartID)?.rawValue != counterpartID || counterpartID == id { return false }
        if kind != .webExtension, engine != nil || counterpartID != nil { return false }
        return entry == manifest || (kind == .webExtension && PluginEngineVersions.engines.contains { manifest.version(for: $0) == entry })
    }
}
