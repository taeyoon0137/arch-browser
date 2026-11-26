import AppKit
import ARCHPrivateAPI
import Testing
@testable import ARCHEngineChromium

@MainActor @Suite struct ChromiumPictureInPictureHostAPITests {
    @Test func eachDisabledFlagKeepsThePublicSourceUntouched() {
        let flags = PrivateAPIFlags.shared
        let saved = flagKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { restore(saved) }
        let host = ChromiumPictureInPictureHostAPI()
        var resizeCount = 0, restoreCount = 0
        for disabled in ["global", "api", "feature"] {
            flags.allowsPrivateAPIs = disabled != "global"
            flags.setOn(disabled != "api", api: ChromiumPictureInPictureHostAPI.apiID)
            flags.setOn(disabled != "feature", feature: ChromiumPictureInPictureHostAPI.featureID)
            #expect(!host.start(resize: { _ in resizeCount += 1 }, restore: { restoreCount += 1 }))
            #expect(flags.features.first { $0.id == ChromiumPictureInPictureHostAPI.featureID }?.apiIDs
                == [ChromiumPictureInPictureHostAPI.apiID])
            #expect(!flags.allows(ChromiumPictureInPictureHostAPI.featureID))
            host.stop()
            host.stop()
        }
        #expect(resizeCount == 0)
        #expect(restoreCount == 0)
    }

    @Test func aMissingPiPHierarchyAndRepeatedStopsLeaveTheSourceUntouched() {
        _ = NSApplication.shared
        let flags = PrivateAPIFlags.shared
        let saved = flagKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { restore(saved) }
        flags.allowsPrivateAPIs = true
        flags.setOn(true, api: ChromiumPictureInPictureHostAPI.apiID)
        flags.setOn(true, feature: ChromiumPictureInPictureHostAPI.featureID)
        let host = ChromiumPictureInPictureHostAPI()
        host.stop()
        var resizeCount = 0, restoreCount = 0
        #expect(!host.start(resize: { _ in resizeCount += 1 }, restore: { restoreCount += 1 }))
        host.stop()
        host.stop()
        #expect(resizeCount == 0)
        #expect(restoreCount == 0)
    }

    private var flagKeys: [String] {
        ["ARCHPrivateAPIs", "ARCHPrivateAPI.\(ChromiumPictureInPictureHostAPI.apiID)",
         "ARCHPrivateAPIFeature.\(ChromiumPictureInPictureHostAPI.featureID)"]
    }

    private func restore(_ saved: [(String, Any?)]) {
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}
