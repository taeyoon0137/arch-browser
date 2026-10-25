// Where a restored window opens: at its saved frame while that frame is on a screen, otherwise centered on the main screen.
import CoreGraphics
import Testing
@testable import Browsing

@Suite struct WindowFrameTests {
    private let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let externalScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1055)

    @Test func aFrameOnAnyScreenStays() {
        let frame = CGRect(x: 1600, y: 100, width: 1200, height: 800)
        #expect(BrowserWindowController.restoredFrame(frame, screens: [mainScreen, externalScreen]) == frame)
    }

    @Test func aFrameThatReachesFarEnoughOntoAScreenStays() {
        let frame = CGRect(x: -1100, y: 100, width: 1200, height: 800)
        #expect(BrowserWindowController.restoredFrame(frame, screens: [mainScreen]) == frame)
    }

    @Test func aFrameOnADisplayThatIsGoneMovesToTheMainScreenAtItsSize() {
        let frame = CGRect(x: 1600, y: 100, width: 1200, height: 800)
        #expect(BrowserWindowController.restoredFrame(frame, screens: [mainScreen]) == CGRect(x: 120, y: 37.5, width: 1200, height: 800))
    }

    @Test func aFrameThatBarelyReachesAScreenMoves() {
        let frame = CGRect(x: -1150, y: 100, width: 1200, height: 800)
        #expect(BrowserWindowController.restoredFrame(frame, screens: [mainScreen]) == CGRect(x: 120, y: 37.5, width: 1200, height: 800))
    }

    @Test func aMovedFrameShrinksToTheMainScreen() {
        let frame = CGRect(x: 1600, y: 100, width: 1800, height: 1000)
        #expect(BrowserWindowController.restoredFrame(frame, screens: [mainScreen]) == mainScreen)
    }
}
