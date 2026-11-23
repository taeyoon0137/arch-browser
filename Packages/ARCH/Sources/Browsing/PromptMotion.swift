// How a prompt card moves: it comes down from behind the top edge of the page frame on a critically damped spring and goes back up, the dimming fades, and a card that refuses a login shakes. With Reduce Motion the card only fades, and nothing moves or shakes.
import SwiftUI

/// The animations of a prompt card's arrival, departure, dimming, and shake.
enum PromptMotion {
    static func arrival(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1)
    }

    static func departure(reduceMotion: Bool) -> Animation {
        .easeIn(duration: departureDuration(reduceMotion: reduceMotion))
    }

    /// How long a card takes to leave, after which the tab's next card arrives.
    static func departureDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0.12 : 0.2
    }

    static func scrim(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? 0.15 : 0.2)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top)
    }

    static let shake = Animation.linear(duration: 0.35)
}

/// Moves a card from side to side 6 points, three times for each whole step of `animatableData`, ending where it started.
struct PromptShake: GeometryEffect {
    var animatableData: CGFloat
    var travel: CGFloat = 6
    var shakes: CGFloat = 3

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 2 * shakes), y: 0))
    }
}
