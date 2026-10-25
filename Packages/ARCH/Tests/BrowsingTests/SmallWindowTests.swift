// When a link from another app opens a small window, and where a small window opens without another to cascade from.
import CoreGraphics
import Foundation
import Testing
@testable import Browsing

@Suite struct SmallWindowTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aLinkWhileArchIsInTheBackgroundOpensASmallWindow() {
        #expect(BrowserSession.opensLinkInSmallWindow(isAppActive: false, becameActiveAt: nil, now: now))
        #expect(BrowserSession.opensLinkInSmallWindow(isAppActive: false, becameActiveAt: now.addingTimeInterval(-60), now: now))
    }

    @Test func aLinkThatCameWithArchsActivationOpensASmallWindow() {
        #expect(BrowserSession.opensLinkInSmallWindow(isAppActive: true, becameActiveAt: now.addingTimeInterval(-0.2), now: now))
    }

    @Test func aLinkWhileArchIsActiveOpensATab() {
        #expect(!BrowserSession.opensLinkInSmallWindow(isAppActive: true, becameActiveAt: now.addingTimeInterval(-BrowserSession.smallWindowActivationGrace), now: now))
        #expect(!BrowserSession.opensLinkInSmallWindow(isAppActive: true, becameActiveAt: now.addingTimeInterval(-60), now: now))
    }

    @Test func aLinkWhileArchHasBeenActiveSinceLaunchOpensATab() {
        #expect(!BrowserSession.opensLinkInSmallWindow(isAppActive: true, becameActiveAt: nil, now: now))
    }

    private let mainScreen = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
    private let externalScreen = (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
    private let size = CGSize(width: 900, height: 640)

    @Test func theWindowOpensOnTheScreenWithThePointer() {
        let frame = BrowserWindowController.centeredFrame(size: size, pointer: CGPoint(x: 2000, y: 500), screens: [mainScreen, externalScreen])
        #expect(frame == CGRect(x: 1950, y: 207.5, width: 900, height: 640))
    }

    @Test func aPointerInTheMenuBarStillPicksItsScreen() {
        let frame = BrowserWindowController.centeredFrame(size: size, pointer: CGPoint(x: 2000, y: 1070), screens: [mainScreen, externalScreen])
        #expect(frame == CGRect(x: 1950, y: 207.5, width: 900, height: 640))
    }

    @Test func aPointerOnNoScreenPicksTheMainScreen() {
        let frame = BrowserWindowController.centeredFrame(size: size, pointer: CGPoint(x: -500, y: 500), screens: [mainScreen, externalScreen])
        #expect(frame == CGRect(x: 270, y: 117.5, width: 900, height: 640))
    }

    @Test func theWindowShrinksToASmallScreen() {
        let small = (frame: CGRect(x: 0, y: 0, width: 800, height: 600), visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 575))
        let frame = BrowserWindowController.centeredFrame(size: size, pointer: CGPoint(x: 100, y: 100), screens: [small])
        #expect(frame == CGRect(x: 0, y: 0, width: 800, height: 575))
    }
}
