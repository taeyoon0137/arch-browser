// What a copy between the engines writes and deletes: what the source changed since the stores last agreed, never a cookie that differs only in its SameSite policy, so the target keeps a policy the source store could not hold. A deletion travels like a change, a cookie only the target changed stays, a deletion leaves a cookie the target changed, and a write the target refused is not taken for agreement. The record of what the stores agreed on outlasts a launch in a file without values or session cookies, and a store that lost most of it makes the next launch's first copy work without it. The cookies hold made-up values only.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct CookieSyncTests {
    private static let expiry = Date(timeIntervalSince1970: 2_000_000_000.5)
    /// A sign-in cookie as Chromium holds it, without a policy, which Chromium treats as Lax.
    private static let held = EngineCookie(name: "sid", value: "a1", domain: "example.com", expires: expiry, isSecure: true, isHTTPOnly: true)
    private static let agreed = record(held)
    /// A cookie of another site, which stays in both stores while the site signs out.
    private static let other = EngineCookie(name: "pref", value: "dark", domain: ".example.org", expires: expiry)

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
        #expect(CookieSync.agreement(between: [rotated, pref], and: [rotated, pref], before: Self.agreed) == Self.record(rotated, pref))
        #expect(CookieSync.agreement(between: [], and: [], before: Self.agreed).isEmpty)
    }

    @Test func bothEnginesVersionsOfACookieHaveOneDigest() {
        // WebKit keeps the expiry to the whole second and the policy as SameSite=None.
        var readBack = Self.held
        readBack.sameSite = .noRestriction
        readBack.expires = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(CookieSync.Digest(readBack) == CookieSync.Digest(Self.held))
        var otherValue = Self.held
        otherValue.value = "a2"
        var laterExpiry = Self.held
        laterExpiry.expires = Date(timeIntervalSince1970: 2_000_000_001)
        var session = Self.held
        session.expires = nil
        var notHTTPOnly = Self.held
        notHTTPOnly.isHTTPOnly = false
        let digests = Set([Self.held, otherValue, laterExpiry, session, notHTTPOnly].map(CookieSync.Digest.init))
        #expect(digests.count == 5)
    }

    @Test func aRecordCountsWhileEachStoreHoldsMostOfItsCookies() {
        let record = Self.record(Self.held, Self.other)
        // One site signed out in one store.
        #expect(CookieSync.stores([[Self.other], [Self.held, Self.other]], holdMostOf: record))
        // One store came back empty, or holds only cookies set since.
        let fresh = EngineCookie(name: "visit", value: "1", domain: "example.net", expires: Self.expiry)
        #expect(!CookieSync.stores([[fresh], [Self.held, Self.other]], holdMostOf: record))
        // A cookie neither store holds any longer, as after it expired, counts against neither.
        #expect(CookieSync.stores([[Self.other], [Self.other]], holdMostOf: record))
        #expect(CookieSync.stores([[], []], holdMostOf: record))
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

    @Test func aSignOutWhileTheOtherEngineDidNotRunReachesItInTheNextLaunch() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engines = Engines(webKit: [], chromium: [Self.held, Self.other])
        // A launch with both engines: WebKit starts and takes the Chromium cookies.
        CookieSync(recordURL: Self.recordURL(in: folder)).copy(from: engines.chromiumRuntime, to: engines.webKitRuntime) {}
        CookieSync.finishWrites()
        #expect(engines.webKit.cookies.map(\.name).sorted() == ["pref", "sid"])
        // A launch in which only WebKit runs: the site signs out there.
        engines.webKit.cookies.removeAll { $0.name == "sid" }
        // The next launch: Chromium runs, and WebKit starts second. Its first copy leaves WebKit signed out, and WebKit's next copy signs Chromium out.
        let sync = CookieSync(recordURL: Self.recordURL(in: folder))
        sync.runtimes = { [engines.webKitRuntime, engines.chromiumRuntime] }
        sync.copy(from: engines.chromiumRuntime, to: engines.webKitRuntime) {}
        #expect(engines.webKit.cookies.map(\.name) == ["pref"])
        sync.copy(from: engines.webKitRuntime, to: engines.chromiumRuntime) {}
        #expect(engines.chromium.cookies.map(\.name) == ["pref"])
        // The same holds when the engine that signed out runs first.
        let other = Engines(webKit: [], chromium: [Self.held, Self.other])
        let otherFolder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: otherFolder) }
        CookieSync(recordURL: Self.recordURL(in: otherFolder)).copy(from: other.chromiumRuntime, to: other.webKitRuntime) {}
        CookieSync.finishWrites()
        other.webKit.cookies.removeAll { $0.name == "sid" }
        CookieSync(recordURL: Self.recordURL(in: otherFolder)).copy(from: other.webKitRuntime, to: other.chromiumRuntime) {}
        #expect(other.chromium.cookies.map(\.name) == ["pref"])
    }

    @Test func aValueOneEngineChangedAloneStaysTheNewerInTheNextLaunch() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engines = Engines(webKit: [], chromium: [Self.held, Self.other])
        CookieSync(recordURL: Self.recordURL(in: folder)).copy(from: engines.chromiumRuntime, to: engines.webKitRuntime) {}
        CookieSync.finishWrites()
        // A launch in which only Chromium runs: the site replaces the sign-in cookie.
        var rotated = Self.held
        rotated.value = "b2"
        engines.chromium.cookies = [rotated, Self.other]
        // The next launch: WebKit's older value does not replace Chromium's, and Chromium's reaches WebKit.
        let sync = CookieSync(recordURL: Self.recordURL(in: folder))
        sync.copy(from: engines.webKitRuntime, to: engines.chromiumRuntime) {}
        #expect(engines.chromium.cookies.first { $0.name == "sid" }?.value == "b2")
        sync.copy(from: engines.chromiumRuntime, to: engines.webKitRuntime) {}
        #expect(engines.webKit.cookies.first { $0.name == "sid" }?.value == "b2")
    }

    @Test func aStoreThatLostMostOfTheRecordSignsTheOtherOutOfNothing() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engines = Engines(webKit: [], chromium: [Self.held, Self.other])
        CookieSync(recordURL: Self.recordURL(in: folder)).copy(from: engines.chromiumRuntime, to: engines.webKitRuntime) {}
        CookieSync.finishWrites()
        // Chromium's cookies could not be read in the next launch, and a page set a new one.
        let fresh = EngineCookie(name: "visit", value: "1", domain: "example.net", expires: Self.expiry)
        engines.chromium.cookies = [fresh]
        let sync = CookieSync(recordURL: Self.recordURL(in: folder))
        sync.copy(from: engines.chromiumRuntime, to: engines.webKitRuntime) {}
        #expect(engines.webKit.cookies.map(\.name).sorted() == ["pref", "sid", "visit"])
        // WebKit's copy brings the lost cookies back to Chromium.
        sync.copy(from: engines.webKitRuntime, to: engines.chromiumRuntime) {}
        #expect(engines.chromium.cookies.map(\.name).sorted() == ["pref", "sid", "visit"])
    }

    @Test func theFileKeepsNeitherValuesNorCookiesWithoutAnExpiry() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = EngineCookie(name: "token", value: "made-up-secret-value", domain: "example.com", expires: Self.expiry, isSecure: true)
        let session = EngineCookie(name: "per-launch", value: "1", domain: "example.com")
        let engines = Engines(webKit: [], chromium: [secret, session])
        CookieSync(recordURL: Self.recordURL(in: folder)).copy(from: engines.chromiumRuntime, to: engines.webKitRuntime) {}
        CookieSync.finishWrites()
        let text = try String(contentsOf: Self.recordURL(in: folder), encoding: .utf8)
        #expect(text.contains("token"))
        #expect(!text.contains("made-up-secret-value"))
        #expect(!text.contains("per-launch"))
    }

    @Test func clearedCookiesLeaveTheFile() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engines = Engines(webKit: [], chromium: [Self.held, Self.other])
        let sync = CookieSync(recordURL: Self.recordURL(in: folder))
        sync.runtimes = { [engines.webKitRuntime, engines.chromiumRuntime] }
        sync.copy(from: engines.chromiumRuntime, to: engines.webKitRuntime) {}
        await withCheckedContinuation { continuation in
            sync.removeCookies(where: { $0.domain == "example.com" }) { continuation.resume() }
        }
        CookieSync.finishWrites()
        #expect(engines.webKit.cookies.map(\.name) == ["pref"] && engines.chromium.cookies.map(\.name) == ["pref"])
        // The site sets the same cookie again on WebKit alone, and the next launch copies it to Chromium.
        engines.webKit.cookies.append(Self.held)
        CookieSync(recordURL: Self.recordURL(in: folder)).copy(from: engines.webKitRuntime, to: engines.chromiumRuntime) {}
        #expect(engines.chromium.cookies.map(\.name).sorted() == ["pref", "sid"])
    }

    @Test func removingAPersonasRecordDeletesItsFile() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engines = Engines(webKit: [], chromium: [Self.held])
        CookieSync(recordURL: Self.recordURL(in: folder)).copy(from: engines.chromiumRuntime, to: engines.webKitRuntime) {}
        CookieSync.finishWrites()
        #expect(FileManager.default.fileExists(atPath: Self.recordURL(in: folder).path))
        #expect(CookieSync.removeRecord(ofPersona: Self.persona, in: folder))
        #expect(!FileManager.default.fileExists(atPath: Self.recordURL(in: folder).path))
        #expect(CookieSync.removeRecord(ofPersona: Self.persona, in: folder))
    }

    private static let persona = UUID(uuidString: "5E1B0C1A-7D9E-4C35-9B6A-2F51A5C0D7E3")!

    private static func record(_ cookies: EngineCookie...) -> CookieSync.Record {
        Dictionary(uniqueKeysWithValues: cookies.map { (CookieSync.CookieKey($0), CookieSync.Digest($0)) })
    }

    private static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchCookieSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func recordURL(in folder: URL) -> URL {
        CookieSync.recordURL(ofPersona: persona, in: folder)
    }
}

/// One Persona's two cookie stores, each in a runtime of its engine.
private struct Engines {
    let webKit: CookieStore
    let chromium: CookieStore
    let webKitRuntime: EngineRuntime
    let chromiumRuntime: EngineRuntime

    init(webKit webKitCookies: [EngineCookie], chromium chromiumCookies: [EngineCookie]) {
        webKit = CookieStore(cookies: webKitCookies)
        chromium = CookieStore(cookies: chromiumCookies)
        webKitRuntime = EngineRuntime(kind: .webKit, personaID: Persona.defaultID, context: webKit.context, browser: webKit)
        chromiumRuntime = EngineRuntime(kind: .chromium, personaID: Persona.defaultID, context: chromium.context, browser: chromium)
    }
}

/// One engine's cookie store, which answers at once, with a profile for its runtime. Nothing else of the browser is used.
private final class CookieStore: EngineBrowser {
    var cookies: [EngineCookie]
    private(set) var writes = 0

    init(cookies: [EngineCookie]) {
        self.cookies = cookies
    }

    let context: any EngineBrowserContext = NoContext()
    var cookiesDidChange: (() -> Void)?

    func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents { fatalError("Not used") }
    func takeOwnership(of webContents: any EngineWebContents) {}
    func closeWebContents(_ webContents: any EngineWebContents) {}
    func closeAllWebContents() {}

    func allCookies(completion: @escaping ([EngineCookie]) -> Void) { completion(cookies) }
    func setCookies(_ cookies: [EngineCookie], completion: @escaping () -> Void) {
        for cookie in cookies {
            self.cookies.removeAll { CookieSync.CookieKey($0) == CookieSync.CookieKey(cookie) }
            self.cookies.append(cookie)
            writes += 1
        }
        completion()
    }
    func removeCookies(where shouldRemove: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void) {
        cookies.removeAll(where: shouldRemove)
        completion()
    }
    func removeSiteData(for origins: [URL], completion: @escaping () -> Void) { completion() }
}

private final class NoContext: EngineBrowserContext {
    let downloads: any EngineDownloads = NoDownloads()
    var preferences = EnginePreferences()
    let extensions: (any EngineExtensions)? = nil
}

private final class NoDownloads: EngineDownloads {
    weak var delegate: (any EngineDownloadsDelegate)?
    let items: [any EngineDownloadItem] = []
}
