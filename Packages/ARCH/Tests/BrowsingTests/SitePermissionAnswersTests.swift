// The answers to websites' permission requests: remembered answers decide without a sheet, requests that wait for one sheet share its answer, only a given answer is remembered, engine profiles take the remembered answers and, when they start, the removals of answers, and a website's notifications ask macOS only after the sheet's Allow and offer System Settings while Arch's notifications are off, as the permission is when the sheet shows. Each test keeps its store in a temporary folder of its own.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct SitePermissionAnswersTests {
    private static let site = URL(string: "https://example.com/page")!
    private static let origin = "https://example.com"

    @Test func rememberedAnswersDecideWithoutASheet() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera, .microphone], origin: Self.origin)
        store.set(.deny, for: [.geolocation], origin: Self.origin)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        let sheets = SheetRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera, .microphone]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera, .geolocation]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        #expect(granted == [true, false])
        #expect(sheets.alerts.isEmpty)
    }

    @Test func requestsThatWaitForOneSheetShareItsAnswerAndTheAnswerIsRemembered() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        let sheets = SheetRecorder()
        let tabID = UUID()
        let request = EnginePermissionRequest(origin: Self.site, types: [.camera])

        var granted: [Bool] = []
        answers.answer(request, forTab: tabID, in: nil, ask: sheets.ask) { granted.append($0) }
        answers.answer(request, forTab: tabID, in: nil, ask: sheets.ask) { granted.append($0) }
        #expect(sheets.alerts.count == 1)
        #expect(sheets.alerts.first?.informativeText.isEmpty == false)

        sheets.respond(.alertFirstButtonReturn)
        #expect(granted == [true, true])
        #expect(store.decision(for: .camera, origin: Self.origin) == .allow)
        #expect(SitePermissionStore(directory: folder.url).decision(for: .camera, origin: Self.origin) == .allow)
    }

    @Test func aSheetClosedWithoutAnAnswerAndScreenRecordingLeaveNothingRemembered() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        let sheets = SheetRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        sheets.respond(.cancel)
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.screenCapture]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        #expect(sheets.alerts.last?.informativeText.isEmpty == true)
        sheets.respond(.alertFirstButtonReturn)

        #expect(granted == [false, true])
        #expect(store.decisions.isEmpty)
    }

    @Test func profilesTakeTheRememberedAnswersNowAndAfterEachChange() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera], origin: Self.origin)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        let context = RecordingContext()

        answers.follow(context)
        #expect(context.kept["camera \(Self.origin)"] == .some(true))
        store.set(.deny, for: [.microphone], origin: Self.origin)
        #expect(context.kept["microphone \(Self.origin)"] == .some(false))
        store.set(nil, for: [.camera], origin: Self.origin)
        #expect(context.kept["camera \(Self.origin)"] == .some(nil))

        let other = RecordingContext()
        answers.restoreRememberedAnswers(for: EnginePermissionRequest(origin: Self.site, types: [.camera, .microphone]), in: other)
        #expect(other.kept["camera \(Self.site.absoluteString)"] == .some(nil))
        #expect(other.kept["microphone \(Self.site.absoluteString)"] == .some(false))
    }

    @Test func aProfileThatStartsAfterAnAnswerWasRemovedForgetsItToo() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.geolocation, .camera], origin: Self.origin)
        store.set(nil, for: [.geolocation, .camera], origin: Self.origin)
        store.set(.deny, for: [.camera], origin: Self.origin)
        #expect(store.removed == [Self.origin: [.geolocation]])

        // The next launch reads the removal from the file, and a profile that starts then takes the answer away.
        let relaunched = SitePermissionStore(directory: folder.url)
        #expect(relaunched.removed == [Self.origin: [.geolocation]])
        let answers = SitePermissionAnswers(store: relaunched, notifications: NotificationAuthorization(system: nil))
        let context = RecordingContext()
        answers.follow(context)
        #expect(context.kept["geolocation \(Self.origin)"] == .some(nil))
        #expect(context.kept["camera \(Self.origin)"] == .some(false))

        // A new answer takes the type off the list.
        relaunched.set(.allow, for: [.geolocation], origin: Self.origin)
        #expect(relaunched.removed.isEmpty)
        #expect(context.kept["geolocation \(Self.origin)"] == .some(true))
    }

    @Test func allowingNotificationsAsksMacOSOnceAfterTheSheet() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let system = FakeNotificationSystem(status: .notDetermined)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: system.system))
        let sheets = SheetRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        let alert = try #require(sheets.show())
        #expect(alert.informativeText == "Arch remembers your answer for this website. You can change it in Settings > Websites. After you allow, macOS asks whether Arch may show notifications.")
        #expect(alert.buttons.map(\.title) == ["Allow", "Don\u{2019}t Allow"])
        #expect(system.requests == 0)

        sheets.respond(.alertFirstButtonReturn)
        #expect(granted == [true])
        #expect(system.requests == 1)
        #expect(store.decision(for: .notifications, origin: Self.origin) == .allow)

        // The remembered Allow answers without a sheet and without asking macOS again.
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        #expect(granted == [true, true])
        #expect(sheets.alerts.count == 1)
        #expect(system.requests == 1)
    }

    @Test func dontAllowAndOtherPermissionsDoNotAskMacOS() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let system = FakeNotificationSystem(status: .notDetermined)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: system.system))
        let sheets = SheetRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        _ = sheets.show()
        sheets.respond(.alertSecondButtonReturn)
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        #expect(sheets.show()?.informativeText == "Arch remembers your answer for this website. You can change it in Settings > Websites.")
        sheets.respond(.alertFirstButtonReturn)

        #expect(granted == [false, true])
        #expect(system.requests == 0)
        #expect(store.decision(for: .notifications, origin: Self.origin) == .deny)
    }

    @Test func whileArchsNotificationsAreOffTheSheetOpensSystemSettingsAndRemembersNothing() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let system = FakeNotificationSystem(status: .denied)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: system.system))
        let sheets = SheetRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        let alert = try #require(sheets.show())
        #expect(alert.buttons.map(\.title) == ["Allow", "Don\u{2019}t Allow", "Open System Settings"])
        #expect(alert.informativeText.contains("off in System Settings"))

        sheets.respond(.alertThirdButtonReturn)
        #expect(granted == [false])
        #expect(system.opened.count == 1)
        #expect(system.requests == 0)
        #expect(store.decisions.isEmpty)

        // A bare build says that it cannot show notifications and offers no setting.
        let bare = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        bare.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        let bareAlert = try #require(sheets.show())
        #expect(bareAlert.buttons.count == 2)
        #expect(bareAlert.informativeText.contains("can\u{2019}t show notifications"))
    }

    /// A sheet that waits behind another while macOS's answer changes the permission shows, and acts on, the permission as it is when it shows.
    @Test func aWaitingSheetShowsThePermissionAsItIsWhenItShows() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let system = FakeNotificationSystem(status: .notDetermined)
        system.grants = false
        let authorization = NotificationAuthorization(system: system.system)
        let answers = SitePermissionAnswers(store: store, notifications: authorization)
        let sheets = SheetRecorder()
        let other = try #require(URL(string: "https://example.org/"))

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        answers.answer(EnginePermissionRequest(origin: other, types: [.notifications]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        // Both sheets said that macOS asks when they were queued.
        #expect(sheets.alerts.allSatisfy { $0.informativeText.contains("macOS asks") })
        #expect(sheets.show()?.informativeText.contains("macOS asks") == true)
        // Allow on the first sheet asks macOS, and the user refuses there.
        sheets.respond(.alertFirstButtonReturn)
        #expect(system.requests == 1)
        #expect(authorization.status == .denied)

        // The second sheet, made again as it shows, says that Arch's notifications are off, and its Allow does not ask macOS.
        let waiting = try #require(sheets.show())
        #expect(waiting.buttons.map(\.title) == ["Allow", "Don\u{2019}t Allow", "Open System Settings"])
        sheets.respond(.alertFirstButtonReturn)
        #expect(granted == [true, true])
        #expect(system.requests == 1)
        #expect(system.opened.isEmpty)
    }
}

/// Keeps the sheets that the answers asked with, each as its maker made it when asked, as a tab's sheet queue makes it, and shows and answers the oldest one still waiting.
private final class SheetRecorder {
    private(set) var alerts: [NSAlert] = []
    private var waiting: [(makeAlert: () -> NSAlert, completion: (NSApplication.ModalResponse) -> Void)] = []

    func ask(_ makeAlert: @escaping () -> NSAlert, _ completion: @escaping (NSApplication.ModalResponse) -> Void) {
        alerts.append(makeAlert())
        waiting.append((makeAlert, completion))
    }

    /// The oldest waiting sheet's alert as the maker makes it when the sheet shows, or nil without one.
    func show() -> NSAlert? {
        waiting.first?.makeAlert()
    }

    func respond(_ response: NSApplication.ModalResponse) {
        waiting.removeFirst().completion(response)
    }
}

/// A profile that keeps the last answer set for each type and origin, keyed by both.
private final class RecordingContext: EngineBrowserContext {
    let downloads: any EngineDownloads = NoDownloads()
    var preferences = EnginePreferences()
    let extensions: (any EngineExtensions)? = nil
    private(set) var kept: [String: Bool?] = [:]

    func setRememberedPermission(_ allowed: Bool?, for type: EnginePermissionType, origin: URL) {
        kept["\(type.rawValue) \(origin.absoluteString)"] = .some(allowed)
    }
}

private final class NoDownloads: EngineDownloads {
    weak var delegate: (any EngineDownloadsDelegate)?
    let items: [any EngineDownloadItem] = []
}

private final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSitePermissionAnswersTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
