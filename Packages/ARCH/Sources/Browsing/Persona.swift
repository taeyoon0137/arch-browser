// Personas partition the session: every space, favorite, tab, and closed tab belongs to exactly one, and a tab keeps its Persona for its whole life. Until Personas have an interface, the session holds only the default Persona.
import ARCHEngine
import Foundation

/// A set of spaces whose tabs share one engine context per engine: cookies, site storage, caches, and, with V.11, installed plugins.
public struct Persona: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// The Persona that holds everything from builds before Personas. It keeps each engine's default storage. Sync names its record `default`; V.11 uses it for `Plugins/<id>/`.
    public static let defaultID = UUID(uuidString: "D59DAF4B-E372-4AF9-890E-455B8B3860F3")!
    public var isDefault: Bool { id == Self.defaultID }

    /// The profile the Persona's tabs use in each engine. The default Persona keeps the engines' `default` profile, and any other Persona names its profile by its UUID.
    var contextAttributes: EngineBrowserContextAttributes {
        EngineBrowserContextAttributes(id: isDefault ? .default : EngineBrowserContextID(rawValue: id.uuidString), userVisibleName: name, type: .regular)
    }
}
