// Spaces group sidebar tabs. Favorites are site shortcuts shared by all spaces. `symbol` is an SF Symbol name.
import Foundation

public struct Space: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var tint: SpaceTint

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

public enum SpaceTint: String, Codable, CaseIterable {
    case blue, purple, pink, orange, green, teal, gray
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
