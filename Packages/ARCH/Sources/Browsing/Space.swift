// Spaces group sidebar tabs, and folders group tabs inside a space. Favorites are site shortcuts shared by all spaces; once opened, each keeps a tab of its own. `symbol` is an SF Symbol name.
import Foundation

public struct Space: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var tint: SpaceTint
    /// The page Home opens in the selected tab. `nil` when the user has set none or the file predates home pages.
    public var homeURL: URL?

    /// The symbols the space menu offers, with their names.
    public static let symbolChoices: [(symbol: String, name: String)] = [
        ("circle.fill", "Circle"), ("star.fill", "Star"), ("heart.fill", "Heart"), ("house.fill", "House"), ("briefcase.fill", "Briefcase"),
        ("book.fill", "Book"), ("graduationcap.fill", "Graduation Cap"), ("leaf.fill", "Leaf"), ("gamecontroller.fill", "Game Controller"), ("cart.fill", "Cart"),
    ]

    public init(id: UUID = UUID(), name: String, symbol: String = "circle.fill", tint: SpaceTint = .blue) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
    }
}

/// A space's theme: a tint color, or Automatic for the accent color chosen in System Settings. `session.json` stores the raw value, so Automatic needs no new snapshot version.
public enum SpaceTint: String, Codable, CaseIterable {
    case blue, purple, pink, orange, green, teal, gray
    case automatic
}

/// A named group of tabs among a space's pinned or open tabs. Its tabs refer to it by `id` and share its space and pinned state.
public struct TabFolder: Identifiable, Codable, Hashable {
    public var id = UUID()
    public var spaceID: UUID
    public var name: String
    /// Whether the folder sits among the pinned tabs rather than the open ones.
    public var isPinned: Bool
    /// A collapsed folder hides its tabs in the sidebar.
    public var isCollapsed = false
}

public struct Favorite: Identifiable, Codable, Hashable {
    public var id: UUID
    public var url: URL
    public var title: String

    public init(id: UUID = UUID(), url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}
