// Which cookies a copy between the engines writes: those the target lacks or holds with another value, flag, or expiry, never one that differs only in its SameSite policy, so the target keeps a policy the source store could not hold. The cookies hold made-up values only.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@Suite struct CookieSyncTests {
    private static let expiry = Date(timeIntervalSince1970: 2_000_000_000.5)
    /// A sign-in cookie as Chromium holds it, without a policy, which Chromium treats as Lax.
    private static let held = EngineCookie(name: "sid", value: "a1", domain: "example.com", expires: expiry, isSecure: true, isHTTPOnly: true)

    @Test func aCookieTheTargetHoldsWithOtherPolicyStays() {
        // WebKit reads the cookie it took from Chromium as SameSite=None, with its expiry to the whole second.
        var readBack = Self.held
        readBack.sameSite = .noRestriction
        readBack.expires = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(CookieSync.cookies([readBack], changedFrom: [Self.held]).isEmpty)
    }

    @Test func aCookieWithOtherContentsOrNoneInTheTargetIsWritten() {
        var newValue = Self.held
        newValue.value = "b2"
        var laterExpiry = Self.held
        laterExpiry.expires = Self.expiry.addingTimeInterval(3_600)
        var otherPath = Self.held
        otherPath.path = "/account"
        let other = EngineCookie(name: "pref", value: "dark", domain: ".example.com")
        let source = [newValue, laterExpiry, otherPath, other]
        #expect(CookieSync.cookies(source, changedFrom: [Self.held]) == source)
    }
}
