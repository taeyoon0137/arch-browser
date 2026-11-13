// How strongly each end of a space's tab list fades: not at all with nothing hidden past it, then in proportion to the hidden rows up to the fade's length.
import Testing
@testable import Browsing

@Suite struct ScrollEdgeFadeTests {
    @Test func anEndWithNothingHiddenPastItStaysSharp() {
        #expect(ScrollEdgeFade.strength(hidden: 0) == 0)
        // An elastic overscroll at the end moves the content inward, which reads as a negative amount hidden.
        #expect(ScrollEdgeFade.strength(hidden: -12) == 0)
    }

    @Test func theFadeGrowsWithTheHiddenRowsAndStopsAtFull() {
        #expect(ScrollEdgeFade.strength(hidden: ScrollEdgeFade.length / 2) == 0.5)
        #expect(ScrollEdgeFade.strength(hidden: ScrollEdgeFade.length) == 1)
        #expect(ScrollEdgeFade.strength(hidden: 400) == 1)
    }
}
