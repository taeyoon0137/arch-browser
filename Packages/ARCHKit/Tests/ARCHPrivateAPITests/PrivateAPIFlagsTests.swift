// How the private API flags decide whether a feature may run: every flag is on until the user turns it off, and stays as set; a registered API is checked on a background queue at once; a feature runs only while the flag for all private APIs, its own flag, and the flag of each of its APIs are on and each API exists; and a check that a view's drawing asks for is recorded only after that turn of the main actor.
@testable import ARCHPrivateAPI
import Foundation
import Testing

@MainActor @Suite struct PrivateAPIFlagsTests {
    private let suiteName = "ARCHPrivateAPIFlagsTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    @Test func flagsAreOnUntilTurnedOffAndStayAsSet() {
        let flags = PrivateAPIFlags(defaults: defaults)
        #expect(flags.allowsPrivateAPIs)
        #expect(flags.isOn(api: "present"))
        #expect(flags.isOn(feature: "feature"))
        flags.allowsPrivateAPIs = false
        flags.setOn(false, api: "present")
        flags.setOn(false, feature: "feature")
        let later = PrivateAPIFlags(defaults: defaults)
        #expect(!later.allowsPrivateAPIs)
        #expect(!later.isOn(api: "present"))
        #expect(!later.isOn(feature: "feature"))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func aRegisteredAPIIsCheckedInTheBackground() async {
        let flags = PrivateAPIFlags(defaults: defaults)
        flags.register(PrivateAPI(id: "present", name: "Present", framework: "Test") { true })
        flags.register(PrivateAPI(id: "missing", name: "Missing", framework: "Test") { false })
        #expect(await eventually { flags.availability == ["present": true, "missing": false] })
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func aFeatureRunsWhileEveryFlagIsOnAndEveryAPIExists() {
        let flags = PrivateAPIFlags(defaults: defaults)
        flags.register(PrivateAPI(id: "present", name: "Present", framework: "Test") { true })
        flags.register(PrivateAPI(id: "missing", name: "Missing", framework: "Test") { false })
        flags.register(PrivateAPIFeature(id: "usesPresent", name: "Uses Present", apiIDs: ["present"]))
        flags.register(PrivateAPIFeature(id: "usesBoth", name: "Uses Both", apiIDs: ["present", "missing"]))
        #expect(flags.allows("usesPresent"))
        #expect(!flags.allows("usesBoth"))
        #expect(!flags.allows("unregistered"))
        flags.setOn(false, api: "present")
        #expect(!flags.allows("usesPresent"))
        flags.setOn(true, api: "present")
        flags.setOn(false, feature: "usesPresent")
        #expect(!flags.allows("usesPresent"))
        flags.setOn(true, feature: "usesPresent")
        flags.allowsPrivateAPIs = false
        #expect(!flags.allows("usesPresent"))
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The flags page asks while it draws, and a view must not change what it observes then.
    @Test func aCheckThatRunsOnRequestIsRecordedAfterTheRequest() async {
        let flags = PrivateAPIFlags(defaults: defaults)
        flags.register(PrivateAPI(id: "present", name: "Present", framework: "Test") { true })
        #expect(flags.isAvailable("present"))
        #expect(flags.availability["present"] == nil)
        #expect(await eventually { flags.availability["present"] == true })
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Waits up to five seconds for `condition`, checking every hundredth of a second, and reports whether it held.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
