// The short wait before a prompt's buttons that grant something work, so that a key or click the user meant for the page cannot press them as the card shows.
import Foundation

struct PromptArming: Equatable {
    static let delay: TimeInterval = 0.5

    /// When the card last showed: first, after its tab came back, or after its window became key.
    private(set) var shownAt: Date

    init(shownAt: Date) {
        self.shownAt = shownAt
    }

    func isArmed(at date: Date) -> Bool {
        date.timeIntervalSince(shownAt) >= Self.delay
    }

    /// The moment the buttons work, which the card waits for.
    var armedAt: Date { shownAt.addingTimeInterval(Self.delay) }

    mutating func restart(at date: Date) {
        shownAt = date
    }
}
