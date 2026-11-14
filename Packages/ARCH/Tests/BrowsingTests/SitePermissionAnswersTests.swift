// The answers to websites' permission requests: remembered answers decide without a card, requests that wait for one card share its answer, Allow and Don't Allow are remembered and a card that ended without the user is not, engine profiles take the remembered answers and, when they start, the removals of answers, and a card for notifications says that they don't show as banners yet. Each test keeps its store in a temporary folder of its own.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct SitePermissionAnswersTests {
    private static let site = URL(string: "https://example.com/page")!
    private static let origin = "https://example.com"
    private static let identity = PromptIdentity(icon: .symbol("globe"), name: "example.com", isSecure: true)
    private static let allow = PromptResponse.answered(PromptAnswer(buttonID: "allow"))
    private static let deny = PromptResponse.answered(PromptAnswer(buttonID: "deny"))

    @Test func rememberedAnswersDecideWithoutACard() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera, .microphone], origin: Self.origin)
        store.set(.deny, for: [.geolocation], origin: Self.origin)
        let answers = SitePermissionAnswers(store: store)
        let prompts = PromptRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera, .microphone]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera, .geolocation]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        #expect(granted == [true, false])
        #expect(prompts.contents.isEmpty)
    }

    @Test func requestsThatWaitForOneCardShareItsAnswerAndTheAnswerIsRemembered() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let answers = SitePermissionAnswers(store: store)
        let prompts = PromptRecorder()
        let tabID = UUID()
        let request = EnginePermissionRequest(origin: Self.site, types: [.camera])

        var granted: [Bool] = []
        answers.answer(request, forTab: tabID, personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        answers.answer(request, forTab: tabID, personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        #expect(prompts.contents.count == 1)
        #expect(prompts.contents.first?.notes.isEmpty == false)

        prompts.respond(Self.allow)
        #expect(granted == [true, true])
        #expect(store.decision(for: .camera, origin: Self.origin) == .allow)
        #expect(SitePermissionStore(directory: folder.url).decision(for: .camera, origin: Self.origin) == .allow)
    }

    @Test func aCardThatEndedWithoutTheUserAndScreenRecordingLeaveNothingRemembered() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let answers = SitePermissionAnswers(store: store)
        let prompts = PromptRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        prompts.respond(.dismissed)
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.screenCapture]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        #expect(prompts.contents.last?.notes.isEmpty == true)
        #expect(prompts.contents.last?.glyph == .symbol("rectangle.dashed.badge.record", tint: .purple, label: "Screen Recording"))
        prompts.respond(Self.allow)

        #expect(granted == [false, true])
        #expect(store.decisions.isEmpty)
    }

    @Test func profilesTakeTheRememberedAnswersNowAndAfterEachChange() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera], origin: Self.origin)
        let answers = SitePermissionAnswers(store: store)
        let context = RecordingContext()

        answers.follow(context, of: Persona.defaultID)
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
        answers.follow(context, of: Persona.defaultID)
        #expect(context.kept["geolocation \(Self.origin)"] == .some(nil))
        #expect(context.kept["camera \(Self.origin)"] == .some(false))

        // A new answer takes the type off the list.
        relaunched.set(.allow, for: [.geolocation], origin: Self.origin)
        #expect(relaunched.removed.isEmpty)
        #expect(context.kept["geolocation \(Self.origin)"] == .some(true))
    }

    @Test func aCardForNotificationsSaysTheyDoNotShowAsBannersYetAndOffersOnlyTheAnswers() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let answers = SitePermissionAnswers(store: store)
        let prompts = PromptRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        let content = try #require(prompts.contents.first)
        #expect(content.buttons.map(\.title) == ["Don\u{2019}t Allow", "Allow"])
        #expect(content.notes.map(\.text) == ["Arch remembers your answer for this website. You can change it in Settings \u{25B8} Websites.", "Websites\u{2019} notifications don\u{2019}t show as banners yet."])
        #expect(content.notes.map(\.symbol) == ["info.circle", "bell.slash"])
        prompts.respond(Self.allow)
        #expect(granted == [true])
        #expect(store.decision(for: .notifications, origin: Self.origin) == .allow)

        // A card for another permission says nothing about notifications.
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        #expect(prompts.contents.last?.notes.map(\.id) == ["remembers"])
    }

    @Test func theCardAsksUnderTheSiteWithAllowArmedLaterAndEscapeOnDontAllow() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let answers = SitePermissionAnswers(store: store)
        let prompts = PromptRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.microphone, .camera]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        let content = try #require(prompts.contents.first)
        #expect(content.kind == .sitePermission && content.identity == Self.identity)
        // A call's camera and microphone read as one phrase, and the camera's symbol comes before the microphone's.
        #expect(content.title == "Allow this website to use the camera and microphone?")
        #expect(content.glyph == .symbol("video.fill", tint: .green, label: "Camera"))
        #expect(content.buttons.first { $0.id == "allow" }?.needsArming == true)
        #expect(PromptKeys.returnButton(in: content) == "allow" && PromptKeys.escapeButton(in: content) == "deny")

        // Don't Allow, whether clicked or through Escape, is remembered.
        prompts.respond(Self.deny)
        #expect(granted == [false])
        #expect(store.decision(for: .camera, origin: Self.origin) == .deny)
        #expect(store.decision(for: .microphone, origin: Self.origin) == .deny)

        // A page without a host is "this page", and nothing about it is remembered.
        answers.answer(EnginePermissionRequest(origin: URL(string: "data:text/html,hi")!, types: [.geolocation]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        #expect(prompts.contents.last?.title == "Allow this page to see your location?")
        #expect(prompts.contents.last?.notes.isEmpty == true)
    }
}

/// Keeps the cards that the answers asked with and answers the oldest one still waiting.
private final class PromptRecorder {
    private(set) var contents: [PromptContent] = []
    private var waiting: [(PromptResponse) -> Void] = []

    func ask(_ content: PromptContent, _ completion: @escaping (PromptResponse) -> Void) {
        contents.append(content)
        waiting.append(completion)
    }

    func respond(_ response: PromptResponse) {
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
