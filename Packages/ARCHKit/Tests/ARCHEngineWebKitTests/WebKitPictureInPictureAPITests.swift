// The private preference that lets WebKit pages enter picture in picture (`docs/features.md`, Private APIs). WebKit names it with a leading underscore, and key-value coding reaches its setter through the key without one. The test reads the preference on a configuration of its own and loads no page.
@testable import ARCHEngineWebKit
import Foundation
import Testing
import WebKit

@MainActor @Suite struct WebKitPictureInPictureAPITests {
    @Test func theAvailabilityCheckNamesTheSetterWebKitHas() throws {
        try #require(WKPreferences.instancesRespond(to: WebKitPictureInPictureAPI.setter), "This WebKit has no picture in picture preference.")
        #expect(!WKPreferences.instancesRespond(to: NSSelectorFromString("setAllowsPictureInPictureMediaPlayback:")))
        let preferences = WKWebViewConfiguration().preferences
        preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        #expect((preferences.value(forKey: "_allowsPictureInPictureMediaPlayback") as? Bool) == true)
    }
}
