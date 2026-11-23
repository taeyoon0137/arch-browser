// ⌘F pressed twice opens New Agent Task (`AppDelegate.installDoubleFindShortcut`). WebKit hands a key its page leaves unhandled back through `NSApp.sendEvent`, so one press reaches the key monitor twice with one timestamp; it counts once.
import Foundation
import Testing
@testable import Preferences

@Suite struct DoublePressCounterTests {
    @Test func onePressSeenTwiceCountsOnce() {
        var counter = DoublePressCounter()
        #expect(counter.press(at: 10) == .first)
        #expect(counter.press(at: 10) == .seenAgain)
        #expect(counter.press(at: 10.2) == .second)
    }

    @Test func aSlowSecondPressStartsOver() {
        var counter = DoublePressCounter()
        #expect(counter.press(at: 10) == .first)
        #expect(counter.press(at: 10.5) == .first)
        #expect(counter.press(at: 10.8) == .second)
        // Counting starts over after the second press.
        #expect(counter.press(at: 11) == .first)
    }

    @Test func anotherKeyInBetweenStartsOver() {
        var counter = DoublePressCounter()
        #expect(counter.press(at: 10) == .first)
        counter.reset()
        #expect(counter.press(at: 10.1) == .first)
    }
}
