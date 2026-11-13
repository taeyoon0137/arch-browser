// Low Power Mode's state: read at creation and again at each change macOS posts, which arrives off the main thread.
import Foundation
import os
import Testing
@testable import Browsing

@MainActor @Suite struct LowPowerModeTests {
    @Test func readsTheModeAtCreation() {
        #expect(LowPowerMode(center: NotificationCenter(), read: { true }).isEnabled)
        #expect(!LowPowerMode(center: NotificationCenter(), read: { false }).isEnabled)
    }

    @Test func followsAChangePostedOffTheMainThread() async throws {
        let state = OSAllocatedUnfairLock(initialState: false)
        let center = NotificationCenter()
        let mode = LowPowerMode(center: center, read: { state.withLock { $0 } })
        #expect(!mode.isEnabled)

        state.withLock { $0 = true }
        await Task.detached { center.post(name: .NSProcessInfoPowerStateDidChange, object: ProcessInfo.processInfo) }.value
        for _ in 0..<200 where !mode.isEnabled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mode.isEnabled)
    }
}
