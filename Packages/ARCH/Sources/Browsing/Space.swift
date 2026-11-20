// Spaces group sidebar tabs, and folders, which nest up to four levels (`FolderTree`), group tabs inside a space; a live folder's source fills it (`LiveFolderTabs.swift`). Favorites are site shortcuts shared by all spaces; once opened, each keeps a tab of its own. Each space and favorite belongs to a Persona. `symbol` is an SF Symbol name.
import Foundation
import LiveFolders

/// A named sidebar space with a symbol, tint, optional home page, and owning Persona.
public struct Space: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var tint: SpaceTint
    /// The page Home opens in the selected tab. `nil` when the user has set none or the file predates home pages.
    public var homeURL: URL?
    /// The space's Persona. `nil` in files before version 9 until `normalized()` gives every space one; code reads `resolvedPersonaID`.
    public var personaID: UUID?

    /// The symbols the space menu offers, with their names.
    public static let symbolChoices: [(symbol: String, name: String)] = [
        ("circle.fill", "Circle"), ("star.fill", "Star"), ("heart.fill", "Heart"), ("house.fill", "House"), ("briefcase.fill", "Briefcase"),
        ("book.fill", "Book"), ("graduationcap.fill", "Graduation Cap"), ("leaf.fill", "Leaf"), ("gamecontroller.fill", "Game Controller"), ("cart.fill", "Cart"),
    ]

    public init(id: UUID = UUID(), name: String, symbol: String = "circle.fill", tint: SpaceTint = .blue, personaID: UUID? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.personaID = personaID
    }

    public var resolvedPersonaID: UUID { personaID ?? Persona.defaultID }
}

/// A space's theme: a tint color, or Automatic for the accent color chosen in System Settings. `session.json` stores the raw value, so Automatic needs no new snapshot version.
public enum SpaceTint: String, Codable, CaseIterable {
    case blue, purple, pink, orange, green, teal, gray
    case automatic
}

/// A named group of tabs and folders among a space's pinned or open tabs. Its tabs refer to it by `id` and its folders by `parentID`, and all share its space and pinned state.
public struct TabFolder: Identifiable, Codable, Hashable {
    public var id = UUID()
    public var spaceID: UUID
    public var name: String
    /// Whether the folder sits among the pinned tabs rather than the open ones.
    public var isPinned: Bool
    /// A collapsed folder hides its tabs and folders in the sidebar.
    public var isCollapsed = false
    /// The folder that holds this one, in the same space and list, or `nil` at the top of the list and in files before version 15 (bookmark rule 6). `FolderTree` reads it, and `SessionSnapshot.normalized()` clears one that the file cannot keep.
    public var parentID: UUID?
    /// A live folder's source, item limit, and refresh interval (live folder rule 1), or `nil` for an ordinary folder and in files before version 16. A live folder sits among its space's pinned tabs and holds only its items' tabs. A private feed's address appears here without its query, which the Keychain keeps (live folder rule 8).
    public var live: LiveFolderConfiguration?
    /// The agent session or outside client's grant whose tabs the folder holds, or nil for a folder of the user's (docs/agents.md, In the browser ▸ Agent folders). It is never encoded, and `session.json` leaves an agent folder out with its tabs (agent decision 10); Keep Tabs clears it, which makes the folder and its tabs the user's.
    public var agentSessionID: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, spaceID, name, isPinned, isCollapsed, parentID, live
    }

    /// Whether the folder holds an agent's tabs.
    public var isAgentFolder: Bool { agentSessionID != nil }
}

extension TabFolder {
    /// A live folder's configuration that does not decode, such as one whose source a later build adds, decodes as none, so that the folder loads as an ordinary folder with its tabs instead of making the whole of `session.json` unreadable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        spaceID = try container.decode(UUID.self, forKey: .spaceID)
        name = try container.decode(String.self, forKey: .name)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        isCollapsed = try container.decode(Bool.self, forKey: .isCollapsed)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        live = try? container.decodeIfPresent(LiveFolderConfiguration.self, forKey: .live)
    }
}

/// A Persona-wide site shortcut that opens its own tab when selected.
public struct Favorite: Identifiable, Codable, Hashable {
    public var id: UUID
    public var url: URL
    public var title: String
    /// The favorite's Persona. `nil` in files before version 9 until `normalized()` gives every favorite one, and in imported bookmarks until the session adds them; code reads `resolvedPersonaID`.
    public var personaID: UUID?

    public init(id: UUID = UUID(), url: URL, title: String, personaID: UUID? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.personaID = personaID
    }

    public var resolvedPersonaID: UUID { personaID ?? Persona.defaultID }
}
