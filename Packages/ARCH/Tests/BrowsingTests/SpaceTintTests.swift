// The tint an imported space takes from its theme color: the tint of the nearest hue, or gray for a color with little saturation.
import AppKit
import SwiftUI
import Testing
@testable import Browsing

@Suite struct SpaceTintTests {
    @Test func eachTintsOwnColorMapsToIt() {
        for tint in SpaceTint.colors {
            let color = SRGBColor(tint.nsColor, in: .light)
            #expect(SpaceTint.nearest(red: color.red, green: color.green, blue: color.blue) == tint)
        }
    }

    @Test func aColorBelowOneFifthSaturationMapsToGray() {
        // Saturations of 16% and 24%.
        #expect(SpaceTint.nearest(red: 0.5, green: 0.45, blue: 0.42) == .gray)
        #expect(SpaceTint.nearest(red: 0.5, green: 0.38, blue: 0.38) != .gray)
    }
}
