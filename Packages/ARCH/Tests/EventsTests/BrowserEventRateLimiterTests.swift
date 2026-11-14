// Loop protection's rate: an owner's runs within a minute, at most 10 for one subject and 60 in all, runs past a cap not counted, other owners apart, and a reset.
import Foundation
import Testing
import Events

@Suite struct BrowserEventRateLimiterTests {
    @Test func capsAnOwnersRunsForOneSubjectAndInAllWithinAMinute() {
        var limiter = BrowserEventRateLimiter()
        let start = Date()
        let subject = UUID()
        for _ in 0..<BrowserEventRateLimiter.runsPerSubject {
            #expect(limiter.admit("hook.a", subject: subject, at: start) == .allowed)
        }
        #expect(limiter.admit("hook.a", subject: subject, at: start) == .overSubject)
        // Another owner counts apart.
        #expect(limiter.admit("plugin.b", subject: subject, at: start) == .allowed)
        for _ in BrowserEventRateLimiter.runsPerSubject..<BrowserEventRateLimiter.runsPerOwner {
            #expect(limiter.admit("hook.a", subject: UUID(), at: start) == .allowed)
        }
        #expect(limiter.admit("hook.a", subject: UUID(), at: start) == .overOwner)
        // Runs past the caps were not counted, so a minute after the first runs the owner runs again.
        #expect(limiter.admit("hook.a", subject: subject, at: start + BrowserEventRateLimiter.window) == .allowed)
        limiter.reset("plugin.b")
        for _ in 0..<BrowserEventRateLimiter.runsPerSubject {
            #expect(limiter.admit("plugin.b", subject: subject, at: start) == .allowed)
        }
    }
}
