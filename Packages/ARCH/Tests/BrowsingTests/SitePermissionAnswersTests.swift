// The answers to websites' permission requests: remembered answers decide without a sheet, requests that wait for one sheet share its answer, only a given answer is remembered, engine profiles take the remembered answers and, when they start, the removals of answers, and a sheet for notifications says that they don't show as banners yet. Each test keeps its store in a temporary folder of its own.
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
        let answers = SitePermissionAnswers(store: store)
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
        let answers = SitePermissionAnswers(store: store)
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
        let answers = SitePermissionAnswers(store: store)
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
        let answers = SitePermissionAnswers(store: store)
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
        let answers = SitePermissionAnswers(store: relaunched)
        let context = RecordingContext()
        answers.follow(context)
        #expect(context.kept["geolocation \(Self.origin)"] == .some(nil))
        #expect(context.kept["camera \(Self.origin)"] == .some(false))

        // A new answer takes the type off the list.
        relaunched.set(.allow, for: [.geolocation], origin: Self.origin)
        #expect(relaunched.removed.isEmpty)
        #expect(context.kept["geolocation \(Self.origin)"] == .some(true))
    }

    @Test func aSheetForNotificationsSaysTheyDoNotShowAsBannersYetAndOffersOnlyTheAnswers() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let answers = SitePermissionAnswers(store: store)
        let sheets = SheetRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        let alert = try #require(sheets.alerts.first)
        #expect(alert.buttons.map(\.title) == ["Allow", "Don\u{2019}t Allow"])
        #expect(alert.informativeText == "Arch remembers your answer for this website. You can change it in Settings \u{25B8} Websites. Websites\u{2019} notifications don\u{2019}t show as banners yet.")
        sheets.respond(.alertFirstButtonReturn)
        #expect(granted == [true])
        #expect(store.decision(for: .notifications, origin: Self.origin) == .allow)

        // A sheet for another permission says nothing about notifications.
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), in: nil, ask: sheets.ask) { granted.append($0) }
        #expect(sheets.alerts.last?.informativeText == "Arch remembers your answer for this website. You can change it in Settings \u{25B8} Websites.")
    }
}

/// Keeps the sheets that the answers asked with and answers the oldest one still waiting.
private final class SheetRecorder {
    private(set) var alerts: [NSAlert] = []
    private var waiting: [(NSApplication.ModalResponse) -> Void] = []

    func ask(_ alert: NSAlert, _ completion: @escaping (NSApplication.ModalResponse) -> Void) {
        alerts.append(alert)
        waiting.append(completion)
    }

    func respond(_ response: NSApplication.ModalResponse) {
        waiting.removeFirst()(response)
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
