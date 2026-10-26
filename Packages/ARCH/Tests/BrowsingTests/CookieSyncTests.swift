// What a copy between the engines writes and deletes: what the source changed since the stores last agreed, never a cookie that differs only in its SameSite policy, so the target keeps a policy the source store could not hold. A deletion travels like a change, a cookie only the target changed stays, a deletion leaves a cookie the target changed, and a write the target refused is not taken for agreement. The cookies hold made-up values only.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@Suite struct CookieSyncTests {
    private static let expiry = Date(timeIntervalSince1970: 2_000_000_000.5)
    /// A sign-in cookie as Chromium holds it, without a policy, which Chromium treats as Lax.
    private static let held = EngineCookie(name: "sid", value: "a1", domain: "example.com", expires: expiry, isSecure: true, isHTTPOnly: true)
    private static let agreed = [CookieSync.CookieKey(held): held]

    @Test func aCookieTheTargetHoldsWithOtherPolicyStays() {
        // WebKit reads the cookie it took from Chromium as SameSite=None, with its expiry to the whole second.
        var readBack = Self.held
        readBack.sameSite = .noRestriction
        readBack.expires = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(CookieSync.changes(from: [readBack], to: [Self.held], agreed: [:]).write.isEmpty)
        #expect(CookieSync.changes(from: [readBack], to: [Self.held], agreed: Self.agreed).write.isEmpty)
    }

    @Test func theFirstCopyWritesWhatTheTargetLacksOrHoldsOtherwiseAndDeletesNothing() {
        var newValue = Self.held
        newValue.value = "b2"
        var laterExpiry = Self.held
        laterExpiry.expires = Self.expiry.addingTimeInterval(3_600)
        var otherPath = Self.held
        otherPath.path = "/account"
        let other = EngineCookie(name: "pref", value: "dark", domain: ".example.com")
        let source = [newValue, laterExpiry, otherPath, other]
        let changes = CookieSync.changes(from: source, to: [Self.held], agreed: [:])
        #expect(changes.write == source)
        #expect(changes.remove.isEmpty)
        #expect(CookieSync.changes(from: [], to: [Self.held], agreed: [:]).remove.isEmpty)
    }

    @Test func aCookieTheSourceDeletedGoesFromTheTarget() {
        let changes = CookieSync.changes(from: [], to: [Self.held], agreed: Self.agreed)
        #expect(changes.write.isEmpty)
        #expect(changes.remove == [CookieSync.CookieKey(Self.held)])
        // A cookie neither store holds any longer needs no deletion.
        #expect(CookieSync.changes(from: [], to: [], agreed: Self.agreed).remove.isEmpty)
    }

    @Test func aCookieOnlyTheTargetChangedStaysAndTravelsTheOtherWay() {
        var rotated = Self.held
        rotated.value = "b2"
        // The target's page replaced the agreed value, so the source's older one is not written over it.
        #expect(CookieSync.changes(from: [Self.held], to: [rotated], agreed: Self.agreed).write.isEmpty)
        // The target's page deleted it, so the source's copy does not bring it back.
        #expect(CookieSync.changes(from: [Self.held], to: [], agreed: Self.agreed).write.isEmpty)
        // The copy the other way carries the new value, or the deletion.
        #expect(CookieSync.changes(from: [rotated], to: [Self.held], agreed: Self.agreed).write == [rotated])
        #expect(CookieSync.changes(from: [], to: [Self.held], agreed: Self.agreed).remove == [CookieSync.CookieKey(Self.held)])
    }

    @Test func whenBothChangedACookieTheSourceWinsUnlessItDeletedIt() {
        var sourceValue = Self.held
        sourceValue.value = "b2"
        var targetValue = Self.held
        targetValue.value = "c3"
        #expect(CookieSync.changes(from: [sourceValue], to: [targetValue], agreed: Self.agreed).write == [sourceValue])
        // The target's new value, such as a sign-in after the agreed cookie expired, outlasts the source's deletion.
        #expect(CookieSync.changes(from: [], to: [targetValue], agreed: Self.agreed).remove.isEmpty)
    }

    @Test func theAgreementKeepsItsEarlierVersionWhereTheStoresDiffer() {
        var rotated = Self.held
        rotated.value = "b2"
        let pref = EngineCookie(name: "pref", value: "dark", domain: ".example.com")
        // The target kept its own new value and refused `pref`: neither counts as agreed.
        let agreement = CookieSync.agreement(between: [Self.held, pref], and: [rotated], before: Self.agreed)
        #expect(agreement == Self.agreed)
        // Stores that hold a cookie alike, or both lack one, agree on it.
        #expect(CookieSync.agreement(between: [rotated, pref], and: [rotated, pref], before: Self.agreed)
            == [CookieSync.CookieKey(rotated): rotated, CookieSync.CookieKey(pref): pref])
        #expect(CookieSync.agreement(between: [], and: [], before: Self.agreed).isEmpty)
    }

    @Test func aSignOutInOneEngineStaysAcrossCopiesBothWays() {
        let sync = CookieSync()
        let webKit = CookieStore(cookies: [])
        let chromium = CookieStore(cookies: [Self.held])
        let webKitRuntime = EngineRuntime(kind: .webKit, personaID: Persona.defaultID, context: webKit.context, browser: webKit)
        let chromiumRuntime = EngineRuntime(kind: .chromium, personaID: Persona.defaultID, context: chromium.context, browser: chromium)
        sync.runtimes = { [webKitRuntime, chromiumRuntime] }
        // A tab switches to WebKit and takes the Chromium sign-in.
        var copied = false
        sync.copy(from: chromiumRuntime, to: webKitRuntime) { copied = true }
        #expect(copied)
        #expect(webKit.cookies.map(\.value) == ["a1"])
        // WebKit's own report of the copy's writes finds nothing to copy back.
        sync.copy(from: webKitRuntime, to: chromiumRuntime) {}
        #expect(chromium.writes == 0)
        // The site signs out in the WebKit tab, and the copy deletes the cookie from Chromium.
        webKit.cookies = []
        sync.copy(from: webKitRuntime, to: chromiumRuntime) {}
        #expect(chromium.cookies.isEmpty)
        // A finished Chromium load brings nothing back.
        sync.copy(from: chromiumRuntime, to: webKitRuntime) {}
        #expect(webKit.cookies.isEmpty)
    }
}

/// One engine's cookie store, which answers at once. Nothing else of the browser is used.
private final class CookieStore: EngineBrowser {
    var cookies: [EngineCookie]
    private(set) var writes = 0

    init(cookies: [EngineCookie]) {
        self.cookies = cookies
    }

    let sessionID = "test"
    let context: any EngineBrowserContext = NoContext()
    var window: NSWindow?
    weak var delegate: (any EngineBrowserDelegate)?
    var cookiesDidChange: (() -> Void)?

    func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents { fatalError("Not used") }
    func takeOwnership(of webContents: any EngineWebContents) {}
    func closeWebContents(_ webContents: any EngineWebContents) {}
    func tryToClose(skipBeforeUnloadHandlers: Bool, completion: @escaping (Bool) -> Void) { completion(true) }

    func allCookies(completion: @escaping ([EngineCookie]) -> Void) { completion(cookies) }
    func setCookie(_ cookie: EngineCookie, for url: URL) { setCookies([cookie]) {} }
    func setCookies(_ cookies: [EngineCookie], completion: @escaping () -> Void) {
        for cookie in cookies {
            self.cookies.removeAll { CookieSync.CookieKey($0) == CookieSync.CookieKey(cookie) }
            self.cookies.append(cookie)
            writes += 1
        }
        completion()
    }
    func removeCookie(named name: String, for url: URL) { cookies.removeAll { $0.name == name } }
    func removeCookies(where shouldRemove: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void) {
        cookies.removeAll(where: shouldRemove)
        completion()
    }
    func removeSiteData(for origins: [URL], completion: @escaping () -> Void) { completion() }
}

private final class NoContext: EngineBrowserContext {
    let id = EngineBrowserContextID.default
    let type = EngineBrowserContextType.regular
    let userVisibleName = "Test"
    let downloads: any EngineDownloads = NoDownloads()
    var preferences = EnginePreferences()
    let extensions: (any EngineExtensions)? = nil
}

private final class NoDownloads: EngineDownloads {
    weak var delegate: (any EngineDownloadsDelegate)?
    let items: [any EngineDownloadItem] = []
}
