// Personas partition the session: every space, favorite, tab, and closed tab belongs to exactly one, and a tab keeps its Persona for its whole life. The default Persona always exists. From the space menu and the Spaces menu, the user adds and renames Personas and deletes any but the default one.
import Foundation

/// A set of spaces whose tabs share one engine context per engine, with its cookies, site storage, and caches, and one set of installed plugins.
public struct Persona: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// The Persona that holds everything from builds before Personas. It keeps each engine's default storage and cannot be deleted. Sync names its record `default`, and its plugins live in `Plugins/<id>/`.
    public static let defaultID = UUID(uuidString: "D59DAF4B-E372-4AF9-890E-455B8B3860F3")!
    public var isDefault: Bool { id == Self.defaultID }

    /// The storage of the profile the Persona's tabs use in each engine. The default Persona keeps the engines' default storage, nil, and any other Persona names its storage by its UUID.
    var storageIdentifier: UUID? {
        isDefault ? nil : id
    }
}
